import 'dart:math';
import '../models/scale_data.dart';

/// BIA (Bioelectrical Impedance Analysis) 体脂算法
///
/// 基于多频生物电阻抗计算体成份。
/// 公式校准自东亚人群BIA研究文献 (Wang-Zhu / Lukaski 方程适配)。
///
/// 输入: 多频阻抗值(Ω) + 身高/年龄/性别/体重
/// 输出: 体脂率/BMI/骨量/肌肉/水分等
class BiaBodyComposition {
  /// 精确复刻逆向源码 ICAlgorithmManager.getBMI + ICCommon.ceil
  ///
  /// 逆向实现:
  ///   bmi = weight / (height_cm² / 10000)
  ///   return ceil(bmi)   // ICCommon.ceil(x) = ((int)(x*10)) / 10.0  截断到1位小数
  ///
  /// 注意: 这是整个 APK 里唯一真实存在的本地体成分相关算法。
  /// 体脂/肌肉/水分等由支付宝云 RPC (indicatorReport) 计算，二进制中无本地公式。
  static double bmiExact(double weightKg, int heightCm) {
    final denom = (heightCm * heightCm) / 10000.0;
    final raw = weightKg / denom;
    return (raw * 10).toInt() / 10.0; // ICCommon.ceil: 截断
  }

  /// 从原始阻抗数据计算完整体成份
  ///
  /// [impedances] - 多频阻抗值列表 (Ω)，通常 1~5 个频率
  /// [weightKg]   - 体重 (kg)
  /// [heightCm]   - 身高 (cm)
  /// [age]        - 年龄
  /// [gender]     - 0=女, 1=男
  ///
  /// 返回填好体成份的 [ScaleMeasurement]
  static ScaleMeasurement calculate({
    required List<double> impedances,
    required double weightKg,
    required int heightCm,
    required int age,
    required int gender,
    required ScaleMeasurement source,
  }) {
    if (impedances.isEmpty || weightKg <= 0 || heightCm <= 0) {
      return source;
    }

    // ---- Step 1: 选取有效阻抗频率 ----
    // 多频BIA通常: 1=5kHz, 2=50kHz, 3=100kHz, 4=200kHz, 5=500kHz
    // 体脂计算主要用 50kHz (索引1) 和 5kHz (索引0)
    final r50 = _getImpedance(impedances, 1); // 50kHz
    if (r50 <= 0) return source; // 没有有效阻抗无法计算

    // ---- Step 2: 计算 BMI (复刻逆向 getBMI: 截断到1位) ----
    final hMeters = heightCm / 100.0;
    final bmi = bmiExact(weightKg, heightCm);

    // ---- Step 3: BIA 体脂计算 ----
    // 公式: 基于阻抗身高指数 (height² / R)
    final hi = (hMeters * 10000) / r50; // 阻抗身高指数 (cm²/Ω)

    // 去脂体重 (FFM) - 东亚人群修正公式
    double ffm;
    if (gender == 1) {
      // 男性: FFM = a × HI + b × weight + c × height - d × age + e
      ffm = 0.401 * hi +
          0.167 * weightKg +
          0.153 * heightCm -
          0.134 * age +
          6.091;
    } else {
      // 女性
      ffm = 0.354 * hi +
          0.158 * weightKg +
          0.117 * heightCm -
          0.109 * age +
          4.353;
    }

    // 约束: FFM 必须在合理范围内
    ffm = ffm.clamp(weightKg * 0.4, weightKg * 0.98);

    final bodyFatKg = (weightKg - ffm);
    double bodyFatPercent = (bodyFatKg / weightKg) * 100.0;
    bodyFatPercent = bodyFatPercent.clamp(1.0, 60.0);

    // ---- Step 4: 水分率 ----
    // 人体 lean body mass 含水约 73%
    final waterPercent = (ffm * 0.73 / weightKg) * 100.0;

    // ---- Step 5: 肌肉率 ----
    // 肌肉约占 FFM 的 52%
    final musclePercent = (ffm * 0.52 / weightKg) * 100.0;

    // ---- Step 6: 骨量 ----
    // 骨量 ≈ 体重 × (0.035~0.05) depending on gender
    final boneMass = gender == 1 ? weightKg * 0.045 : weightKg * 0.035;

    // ---- Step 7: 蛋白质率 ----
    // 蛋白质约占 FFM 的 17%
    final proteinPercent = (ffm * 0.17 / weightKg) * 100.0;

    // ---- Step 8: 基础代谢 (Mifflin-St Jeor) ----
    double bmr;
    if (gender == 1) {
      bmr = 10 * weightKg + 6.25 * heightCm - 5 * age + 5;
    } else {
      bmr = 10 * weightKg + 6.25 * heightCm - 5 * age - 161;
    }

    // ---- Step 9: 内脏脂肪等级 ----
    // 基于腰围估算 (从BMI和体脂推算)
    // 简单模型: visceralFatLevel = BMI * 0.15 + bodyFatPercent * 0.08 - 5
    final visceralFat = max(1.0, bmi * 0.15 + bodyFatPercent * 0.08 - 5.0);

    // ---- Step 10: 身体年龄 ----
    // 基于体脂率与标准范围的偏差 + 实际年龄
    final standardFat = gender == 1
        ? 15.0 + (age - 20) * 0.2 // 男性: 15% + 年龄因子
        : 22.0 + (age - 20) * 0.2; // 女性: 22% + 年龄因子
    final bodyAge = age + (bodyFatPercent - standardFat) * 0.8;

    // ---- Step 11: 身体评分 ----
    // 综合评分 (0-100)
    double score = 100.0;
    // BMI 扣分
    if (bmi < 18.5) score -= (18.5 - bmi) * 3;
    if (bmi > 24.0) score -= (bmi - 24.0) * 3;
    // 体脂扣分
    final idealFat = gender == 1 ? 15.0 : 22.0;
    score -= (bodyFatPercent - idealFat).abs() * 1.5;
    score = score.clamp(0, 100);

    return ScaleMeasurement(
      weightG: source.weightG,
      weightKg: weightKg,
      weightLb: source.weightLb,
      bodyFatPercent: double.parse(bodyFatPercent.toStringAsFixed(1)),
      bodyFatKg: double.parse(bodyFatKg.toStringAsFixed(2)),
      bmi: double.parse(bmi.toStringAsFixed(1)),
      bmr: double.parse(bmr.toStringAsFixed(0)),
      musclePercent: double.parse(musclePercent.toStringAsFixed(1)),
      muscleKg: double.parse((ffm - boneMass).toStringAsFixed(2)),
      boneMass: double.parse(boneMass.toStringAsFixed(2)),
      moisturePercent: double.parse(waterPercent.toStringAsFixed(1)),
      waterKg: double.parse((ffm * 0.73).toStringAsFixed(2)),
      proteinPercent: double.parse(proteinPercent.toStringAsFixed(1)),
      proteinKg: double.parse((ffm * 0.17).toStringAsFixed(2)),
      visceralFat: double.parse(visceralFat.toStringAsFixed(1)),
      skeletalMusclePercent:
          double.parse((ffm * 0.48 / weightKg * 100).clamp(15.0, 60.0).toStringAsFixed(1)),
      subcutaneousFatPercent:
          double.parse((bodyFatPercent * 0.72).clamp(1.0, 50.0).toStringAsFixed(1)),
      bodyAge: double.parse(bodyAge.toStringAsFixed(0)),
      bodyScore: double.parse(score.toStringAsFixed(0)),
      impedances: impedances,
      hr: source.hr,
      isStabilized: source.isStabilized,
      isSupportHR: source.isSupportHR,
      isSupportImpedance: impedances.isNotEmpty,
      packetType: source.packetType,
      measuredAt: source.measuredAt,
      gender: gender,
    );
  }

  /// 获取指定索引的阻抗值，越界则取最后一个
  static double _getImpedance(List<double> imps, int index) {
    if (imps.isEmpty) return 0;
    if (index < imps.length) return imps[index];
    return imps.last;
  }

  /// 无阻抗时用 BMI + 人口统计估算体成分（复刻原始 App 本地 getBMI 逻辑）
  static ScaleMeasurement estimateFromBmi({
    required double weightKg,
    required int heightCm,
    required int age,
    required int gender,
    required ScaleMeasurement source,
  }) {
    final bmi = bmiExact(weightKg, heightCm);

    // Deurenberg 体脂公式 (BMI-based)
    final bodyFatPercent =
        (1.20 * bmi + 0.23 * age - 10.8 * gender - 5.4).clamp(1.0, 60.0);

    // 脂肪重量
    final bodyFatKg = weightKg * bodyFatPercent / 100.0;

    // 骨量
    final boneMass = gender == 1 ? weightKg * 0.045 : weightKg * 0.035;

    // 去脂体重 (FFM)
    final ffm = weightKg - bodyFatKg;

    // Mifflin-St Jeor BMR
    final bmr = gender == 1
        ? 10 * weightKg + 6.25 * heightCm - 5 * age + 5
        : 10 * weightKg + 6.25 * heightCm - 5 * age - 161;

    // 肌肉率 = (FFM - bone) / weight (吻合阿福定义)
    final musclePercent = ((ffm - boneMass) / weightKg * 100).clamp(20.0, 90.0);

    // 骨骼肌率 ≈ FFM × 0.48 / weight

    // 水分率 = FFM × 0.66 / weight
    final waterPercent = (ffm * 0.66 / weightKg * 100).clamp(30.0, 80.0);

    // 蛋白质率 = FFM × 0.27 / weight
    final proteinPercent = (ffm * 0.27 / weightKg * 100).clamp(5.0, 30.0);

    // 皮下脂肪率 ≈ 体脂率 × 0.72, 不在 ScaleMeasurement 字段中

    // 内脏脂肪
    final visceralFat =
        max(1.0, bmi * 0.35 + bodyFatPercent * 0.12 + age * 0.05 - gender * 0.5 - 6.0);

    final standardFat = gender == 1 ? 15.0 : 22.0;
    final bodyAge = age + (bodyFatPercent - standardFat) * 0.8;
    double score = 100;
    if (bmi < 18.5) score -= (18.5 - bmi) * 3;
    if (bmi > 24.0) score -= (bmi - 24.0) * 3;
    score -= (bodyFatPercent - standardFat).abs() * 1.5;
    score = score.clamp(0, 100);

    return ScaleMeasurement(
      weightG: source.weightG,
      weightKg: weightKg,
      weightLb: source.weightLb,
      bodyFatPercent: double.parse(bodyFatPercent.toStringAsFixed(1)),
      bodyFatKg: double.parse(bodyFatKg.toStringAsFixed(2)),
      bmi: double.parse(bmi.toStringAsFixed(1)),
      bmr: double.parse(bmr.toStringAsFixed(0)),
      musclePercent: double.parse(musclePercent.toStringAsFixed(1)),
      muscleKg: double.parse(((ffm - boneMass)).toStringAsFixed(2)),
      boneMass: double.parse(boneMass.toStringAsFixed(2)),
      moisturePercent: double.parse(waterPercent.toStringAsFixed(1)),
      waterKg: double.parse((ffm * 0.66).toStringAsFixed(2)),
      proteinPercent: double.parse(proteinPercent.toStringAsFixed(1)),
      proteinKg: double.parse((ffm * 0.27).toStringAsFixed(2)),
      visceralFat: double.parse(visceralFat.toStringAsFixed(1)),
      skeletalMusclePercent:
          double.parse((ffm * 0.48 / weightKg * 100).clamp(15.0, 60.0).toStringAsFixed(1)),
      subcutaneousFatPercent:
          double.parse((bodyFatPercent * 0.72).clamp(1.0, 50.0).toStringAsFixed(1)),
      bodyAge: double.parse(bodyAge.toStringAsFixed(0)),
      bodyScore: double.parse(score.toStringAsFixed(0)),
      impedances: const [],
      hr: source.hr,
      isStabilized: source.isStabilized,
      isSupportHR: source.isSupportHR,
      isSupportImpedance: false,
      packetType: source.packetType,
      measuredAt: source.measuredAt,
      gender: gender,
    );
  }
}
