/// 体脂秤测量数据 (移植自 ICWeightData)
class ScaleMeasurement {
  final int weightG;
  final double weightKg;
  final double weightLb;
  final double bodyFatPercent;
  final double bodyFatKg;
  final double bmi;
  final double bmr;
  final double musclePercent;
  final double muscleKg;
  final double boneMass;
  final double moisturePercent;
  final double waterKg;
  final double proteinPercent;
  final double proteinKg;
  final double visceralFat;
  final double skeletalMusclePercent;
  final double subcutaneousFatPercent;
  final double bodyAge;
  final double bodyScore;
  final int gender; // 0=女 1=男
  final List<double> impedances;
  final int hr;
  final bool isStabilized;
  final bool isSupportHR;
  final bool isSupportImpedance;
  final int packetType;
  final DateTime measuredAt;

  ScaleMeasurement({
    required this.weightG,
    required this.weightKg,
    required this.weightLb,
    this.bodyFatPercent = 0,
    this.bodyFatKg = 0,
    this.bmi = 0,
    this.bmr = 0,
    this.musclePercent = 0,
    this.muscleKg = 0,
    this.boneMass = 0,
    this.moisturePercent = 0,
    this.waterKg = 0,
    this.proteinPercent = 0,
    this.proteinKg = 0,
    this.visceralFat = 0,
    this.skeletalMusclePercent = 0,
    this.subcutaneousFatPercent = 0,
    this.bodyAge = 0,
    this.bodyScore = 0,
    this.gender = 1,
    this.impedances = const [],
    this.hr = 0,
    this.isStabilized = false,
    this.isSupportHR = false,
    this.isSupportImpedance = false,
    this.packetType = 0,
    DateTime? measuredAt,
  }) : measuredAt = measuredAt ?? DateTime.now();

  @override
  String toString() =>
      '${weightKg.toStringAsFixed(2)}kg fat=${bodyFatPercent.toStringAsFixed(1)}% stable=$isStabilized';
}

/// 用户信息
class ScaleUserInfo {
  final int heightCm;
  final int age;
  final int gender; // 0=女 1=男
  final double weightKg;

  const ScaleUserInfo({
    this.heightCm = 170,
    this.age = 30,
    this.gender = 1,
    this.weightKg = 70,
  });
}

/// 扫描设备
class ScaleDevice {
  final String deviceId;
  final String name;
  final int rssi;
  final String? macAddress;
  final List<String> serviceUuids;
  final String manufacturerDataHex;
  final bool likelyScale;
  final String matchReason;

  const ScaleDevice({
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.macAddress,
    this.serviceUuids = const [],
    this.manufacturerDataHex = '',
    this.likelyScale = false,
    this.matchReason = '',
  });
}
