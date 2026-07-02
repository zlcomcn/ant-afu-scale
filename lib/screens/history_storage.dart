import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scale_data.dart';

/// 历史记录持久化存储
class HistoryStorage {
  static const _key = 'scale_history';

  static Future<void> save(ScaleMeasurement m) async {
    if (!m.isStabilized) return;
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key) ?? [];
    jsonList.insert(0, jsonEncode(_toJson(m)));
    if (jsonList.length > 200) jsonList.removeRange(200, jsonList.length);
    await prefs.setStringList(_key, jsonList);
  }

  static Future<List<ScaleMeasurement>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key) ?? [];
    final records = jsonList
        .map((s) => _fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    records.sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
    return records;
  }

  static Future<void> delete(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key) ?? [];
    if (index >= 0 && index < jsonList.length) {
      jsonList.removeAt(index);
      await prefs.setStringList(_key, jsonList);
    }
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, []);
  }

  static Map<String, dynamic> _toJson(ScaleMeasurement m) => {
    'weightG': m.weightG, 'weightKg': m.weightKg, 'weightLb': m.weightLb,
    'bodyFatPercent': m.bodyFatPercent, 'bodyFatKg': m.bodyFatKg,
    'bmi': m.bmi, 'bmr': m.bmr,
    'musclePercent': m.musclePercent, 'muscleKg': m.muscleKg,
    'boneMass': m.boneMass,
    'moisturePercent': m.moisturePercent, 'waterKg': m.waterKg,
    'proteinPercent': m.proteinPercent, 'proteinKg': m.proteinKg,
    'visceralFat': m.visceralFat,
    'skeletalMusclePercent': m.skeletalMusclePercent,
    'subcutaneousFatPercent': m.subcutaneousFatPercent,
    'bodyAge': m.bodyAge, 'bodyScore': m.bodyScore,
    'hr': m.hr, 'isStabilized': m.isStabilized,
    'isSupportHR': m.isSupportHR, 'isSupportImpedance': m.isSupportImpedance,
    'packetType': m.packetType, 'gender': m.gender,
    'measuredAt': m.measuredAt.millisecondsSinceEpoch,
  };

  static ScaleMeasurement _fromJson(Map<String, dynamic> json) => ScaleMeasurement(
    weightG: json['weightG'] ?? 0,
    weightKg: (json['weightKg'] ?? 0).toDouble(),
    weightLb: (json['weightLb'] ?? 0).toDouble(),
    bodyFatPercent: (json['bodyFatPercent'] ?? 0).toDouble(),
    bodyFatKg: (json['bodyFatKg'] ?? 0).toDouble(),
    bmi: (json['bmi'] ?? 0).toDouble(),
    bmr: (json['bmr'] ?? 0).toDouble(),
    musclePercent: (json['musclePercent'] ?? 0).toDouble(),
    muscleKg: (json['muscleKg'] ?? 0).toDouble(),
    boneMass: (json['boneMass'] ?? 0).toDouble(),
    moisturePercent: (json['moisturePercent'] ?? 0).toDouble(),
    waterKg: (json['waterKg'] ?? 0).toDouble(),
    proteinPercent: (json['proteinPercent'] ?? 0).toDouble(),
    proteinKg: (json['proteinKg'] ?? 0).toDouble(),
    visceralFat: (json['visceralFat'] ?? 0).toDouble(),
    skeletalMusclePercent: (json['skeletalMusclePercent'] ?? 0).toDouble(),
    subcutaneousFatPercent: (json['subcutaneousFatPercent'] ?? 0).toDouble(),
    bodyAge: (json['bodyAge'] ?? 0).toDouble(),
    bodyScore: (json['bodyScore'] ?? 0).toDouble(),
    hr: json['hr'] ?? 0,
    isStabilized: json['isStabilized'] ?? true,
    isSupportHR: json['isSupportHR'] ?? false,
    isSupportImpedance: json['isSupportImpedance'] ?? false,
    packetType: json['packetType'] ?? 0,
    gender: json['gender'] ?? 1,
    measuredAt: DateTime.fromMillisecondsSinceEpoch(json['measuredAt'] ?? 0),
  );
}
