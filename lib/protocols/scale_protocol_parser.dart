import 'dart:typed_data';
import 'stream_buffer.dart';

/// 体脂秤 BLE 协议解析器 (移植自 ICBleScale27Protocol / ICBleScaleGeneralProtocolV2)
///
/// 支持的秤协议:
///   - 0xD5 (213): 体重数据包
///   - 0xD6 (214): ADC多频阻抗数据包
///   - 0xD8 (216): 历史数据包
///
/// BLE Service UUID:  0000FFB0-0000-1000-8000-00805F9B34FB
/// BLE Notify UUID:   0000FFB2-0000-1000-8000-00805F9B34FB
/// BLE Write UUID:    0000FFB1-0000-1000-8000-00805F9B34FB
class ScaleProtocolParser {
  static const int packetWeight = 0xD5;
  static const int packetAdc = 0xD6;
  static const int packetHistory = 0xD8;
  static const int packetGeneralWeight = 0xA2;

  /// 解析从 BLE 收到的原始数据包
  /// 返回 [ScalePacketResult] 列表 (可能分片)
  static List<ScalePacketResult> decode(Uint8List rawData, int mtu) {
    if (rawData.length < 2) return [];

    if (rawData.length == 20) {
      if (_isV27Frame(rawData)) return _decodeV27Frame(rawData, mtu);
      if (_isV27FrameVariant(rawData)) return _decodeV27FrameVariant(rawData, mtu);
    }

    final generalV2 = _decodeGeneralV2Frame(rawData, mtu);
    if (generalV2.isNotEmpty) return generalV2;

    final buf = StreamBuffer(rawData.toList());
    buf.readByte(); // flag
    buf.readShort(); // length
    buf.rewind();

    final packetType = buf.readByte() & 0xFF;
    final deviceType = buf.readByte() & 0xFF;
    final dataLen = buf.readShort() & 0xFFFF;
    if (dataLen > buf.length - buf.position) return [];
    final payload = buf.readData(dataLen);

    // 第一字节拼回
    final fullPayload = Uint8List(dataLen + 1);
    fullPayload[0] = deviceType;
    fullPayload.setRange(1, dataLen + 1, payload);

    List<Map<String, dynamic>> results = [];

    if (packetType == packetWeight) {
      results = _decodeWeightData(fullPayload, mtu);
    } else if (packetType == packetAdc) {
      results = _decodeAdcData(fullPayload, mtu);
    } else if (packetType == packetHistory) {
      results = _decodeHistoryData(fullPayload, mtu);
    }

    for (final r in results) {
      r['packet_type'] = packetType;
      r['device_type'] = deviceType;
    }

    return results.map((m) => ScalePacketResult.fromMap(m)).toList();
  }

  static List<ScalePacketResult> _decodeGeneralV2Frame(
      Uint8List rawData, int mtu) {
    // ICBleScaleGeneralProtocolV2 单帧通知: addData 重组 + decode 分发
    // 原始 BLE 帧: [packageIndex:1][totalLen:2 LE][frameIndex:1][payload:N][checksum:1]
    if (rawData.length < 7) return [];

    // frameIndex at [3] — some devices use this as a status byte, we accept any value

    final totalLen = rawData[1] | (rawData[2] << 8);
    final maxPayload = rawData.length - 5;
    if (totalLen <= 0 || totalLen > maxPayload) return [];

    final payload = Uint8List.sublistView(rawData, 4, 4 + totalLen);
    final checksumByte = rawData[4 + totalLen];

    // 校验低 5 位
    final expected = _checksum(payload) & 0x1F;
    final actual = checksumByte & 0x1F;
    if (expected != actual) return [];

    // addData 重组: [packageIndex:4][totalLen:2][unit:1][payload:N]
    final packageIndex = rawData[0] & 0xFF;
    final unit = (checksumByte >> 5) & 0x07;

    // decode: 从重组 buffer 读 cmd
    if (payload.isEmpty) return [];
    final cmd = payload[0] & 0xFF;

    // 传给解码器的 payload 不含 cmd 字节 (decode 已消费)
    final decoderPayload =
        Uint8List.sublistView(payload, 1, payload.length);
    List<Map<String, dynamic>> results = [];

    if (cmd == packetGeneralWeight) {
      results = _decodeGeneralV2Weight(decoderPayload);
    }

    for (final r in results) {
      r['packet_type'] = cmd;
      r['package_index'] = packageIndex;
      r['unit'] = unit;
    }
    return results.map((m) => ScalePacketResult.fromMap(m)).toList();
  }

  static List<Map<String, dynamic>> _decodeGeneralV2Weight(
      Uint8List decoderPayload) {
    // decodeUnStableWeightData_A2 payload (不含 cmd):
    //   [state:1][flags:4 LE][hr:1][measure_mode:1]
    if (decoderPayload.length < 7) return [];
    final buf = StreamBuffer(decoderPayload.toList());

    final state = buf.readByte() & 0xFF;
    final flags = buf.readInt();
    final hr = buf.readByte() & 0xFF;
    final measureMode = buf.readByte() & 0xFF;

    final weightG = flags & 0x3FFFF;
    final kgDiv = (flags >> 18) & 0x07;
    final lbDiv = (flags >> 21) & 0x07;
    final kgPrecision = (kgDiv == 0 || kgDiv == 1 || kgDiv == 2) ? 2 : 1;
    final lbPrecision = (lbDiv == 0 || lbDiv == 1 || lbDiv == 2) ? 2 : 1;

    return [
      {
        'section': 'weight',
        'weight_g': weightG,
        'weight_kg': weightG / 1000.0,
        'weight_lb': weightG / 1000.0 * 2.20462,
        'state': state,
        'hr': hr,
        'measure_mode': measureMode,
        'precision_kg': kgPrecision,
        'precision_lb': lbPrecision,
      }
    ];
  }

  static int _checksum(Uint8List data) {
    var sum = 0;
    for (final b in data) {
      sum = (sum + b) & 0xFF;
    }
    return sum;
  }

  static bool _isV27Frame(Uint8List data) {
    final packetType = data[16] & 0xFF;
    if (packetType != packetWeight &&
        packetType != packetAdc &&
        packetType != packetHistory) {
      return false;
    }

    final expectedCrc = _crc5(data, 0, 17);
    final actualCrc = data[17] & 0x1F;
    return expectedCrc == actualCrc;
  }

  static List<ScalePacketResult> _decodeV27Frame(Uint8List rawData, int mtu) {
    final packetType = rawData[16] & 0xFF;
    final payload = Uint8List.sublistView(rawData, 0, 16);
    List<Map<String, dynamic>> results = [];

    if (packetType == packetWeight) {
      results = _decodeWeightData(payload, mtu);
    } else if (packetType == packetAdc) {
      results = _decodeAdcData(payload, mtu);
    } else if (packetType == packetHistory) {
      results = _decodeHistoryData(payload, mtu);
    }

    for (final r in results) {
      r['packet_type'] = packetType;
      r['device_type'] = rawData[0] & 0xFF;
      r['algorithm'] = (rawData[17] >> 5) & 0x07;
    }

    return results.map((m) => ScalePacketResult.fromMap(m)).toList();
  }

  // 变体帧: 18 字节载荷, byte[18]=packet_type, byte[19]=CRC5
  static bool _isV27FrameVariant(Uint8List data) {
    final packetType = data[18] & 0xFF;
    if (packetType != packetWeight &&
        packetType != packetAdc &&
        packetType != packetHistory) {
      return false;
    }

    final expectedCrc = _crc5(data, 0, 18);
    final actualCrc = data[19] & 0x1F;
    return expectedCrc == actualCrc;
  }

  static List<ScalePacketResult> _decodeV27FrameVariant(Uint8List rawData, int mtu) {
    final packetType = rawData[18] & 0xFF;
    // OEM 变体: weight 在 bytes[4:6] BE uint16 (克), 不在标准 flags bit0-17
    // 标准 payload=bytes[0:16] 仍用于其他字段解析
    final payload = Uint8List.sublistView(rawData, 0, 16);
    List<Map<String, dynamic>> results = [];

    if (packetType == packetWeight) {
      results = _decodeWeightData(payload, mtu);
      // 用 bytes 4-5 (BE uint16) 覆盖真实体重
      final realWeightG = (rawData[4] << 8) | rawData[5];
      for (final r in results) {
        if (r['section'] == 'weight') {
          r['weight_g'] = realWeightG;
          r['weight_kg'] = realWeightG / 1000.0;
          r['weight_lb'] = realWeightG / 1000.0 * 2.20462;
          // OEM variant: 设备在 ACK 帧中直接回报当前体重, 没有独立 stable bit
          r['state'] = 1;
        }
      }
    } else if (packetType == packetAdc) {
      results = _decodeAdcData(payload, mtu);
    } else if (packetType == packetHistory) {
      results = _decodeHistoryData(payload, mtu);
    }

    for (final r in results) {
      r['packet_type'] = packetType;
      r['device_type'] = rawData[0] & 0xFF;
      r['algorithm'] = (rawData[19] >> 5) & 0x07;
    }

    return results.map((m) => ScalePacketResult.fromMap(m)).toList();
  }

  static int _crc5(Uint8List data, int offset, int length) {
    var crc = 0;
    for (var i = offset; i < offset + length; i++) {
      crc = (crc + data[i]) & 0x1F;
    }
    return crc;
  }

  /// 0xD5 体重数据包解析
  static List<Map<String, dynamic>> _decodeWeightData(Uint8List data, int mtu) {
    final results = <Map<String, dynamic>>[];
    final buf = StreamBuffer(data.toList());
    buf.readByte(); // device type

    final flags = buf.readInt(); // 控制位
    final ctrl1 = buf.readByte() & 0xFF;

    if (ctrl1 == 1) {
      // 配置/状态段
      final calMode = buf.readByte() & 0xFF;
      final batteryRaw = buf.readByte();
      final overWeight = buf.readByte() & 0xFF;
      results.add({
        'section': 'config',
        'calibrationMode': calMode,
        'charging': BitUtils.getBit(batteryRaw & 0xFF, 7),
        'battery': batteryRaw & 0x7F,
        'over_weight': overWeight,
      });
    } else if (ctrl1 == 2) {
      // 功能支持段
      final funFlags = buf.readInt();
      final supportFuns = <int>[];
      for (int i = 0; i < 32; i++) {
        if (BitUtils.getBit(funFlags, i) == 1) supportFuns.add(i);
      }
      results.add({
        'section': 'features',
        'support_funs': supportFuns,
      });
    }

    // 解析体重
    // flags: bit0-17=weight_g, bit18-20=kg_division, bit21-23=lb_division
    final weightG = flags & 0x3FFFF;
    final kgDiv = (flags >> 18) & 0x07;
    final lbDiv = (flags >> 21) & 0x07;
    final temperature = BitUtils.getBit(flags, 28);
    final hasImpedance = BitUtils.getBit(flags, 27);
    final hasHR = BitUtils.getBit(flags, 26);
    final unit = BitUtils.getBit(flags, 31);
    final state = BitUtils.getBit(flags, 24); // bit24=稳定标志
    final electrode = BitUtils.getBit(flags, 25);

    final kgPrecision = (kgDiv == 0 || kgDiv == 1 || kgDiv == 2) ? 2 : 1;
    final lbPrecision = (lbDiv == 0 || lbDiv == 1 || lbDiv == 2) ? 2 : 1;

    double weightKg = weightG / 1000.0;
    double weightLb = weightKg * 2.20462;

    results.add({
      'section': 'weight',
      'weight_g': weightG,
      'weight_kg': weightKg,
      'weight_lb': weightLb,
      'state': state,
      'unit': unit,
      'electrode': electrode,
      'has_temperature': temperature == 1,
      'has_impedance': hasImpedance == 1,
      'has_hr': hasHR == 1,
      'precision_kg': kgPrecision,
      'precision_lb': lbPrecision,
    });

    return results;
  }

  /// 0xD6 ADC多频阻抗数据包解析
  static List<Map<String, dynamic>> _decodeAdcData(Uint8List data, int mtu) {
    final results = <Map<String, dynamic>>[];
    final buf = StreamBuffer(data.toList());
    buf.readByte(); // device type / reserved

    final flag = buf.readByte() & 0xFF;
    if (BitUtils.getBit(flag, 7) != 0) return results;

    final count = buf.readByte() & 0xFF;
    buf.readByte(); // reserved

    final impedances = <double>[];
    for (int i = 0; i < count; i++) {
      final imp = (buf.readShort() & 0xFFFF).toDouble();
      impedances.add(imp);
    }

    final state = buf.readByte() & 0xFF;
    if (state == 1) {
      final flags = buf.readInt();
      final weightG = flags & 0x3FFFF;

      double kg = weightG / 1000.0;
      double lb = kg * 2.20462;

      results.add({
        'section': 'adc_weight',
        'weight_g': weightG,
        'weight_kg': kg,
        'weight_lb': lb,
        'adcs': impedances,
      });
    } else {
      results.add({
        'section': 'adc',
        'adcs': impedances,
      });
    }

    return results;
  }

  /// 0xD8 历史数据解析
  static List<Map<String, dynamic>> _decodeHistoryData(
      Uint8List data, int mtu) {
    final results = <Map<String, dynamic>>[];
    final buf = StreamBuffer(data.toList());
    buf.readByte(); // device type

    while (buf.position + 14 <= buf.length) {
      final flags = buf.readInt();
      final weightG = flags & 0x3FFFF;
      final year = buf.readByte() + 2000;
      final month = buf.readByte().clamp(1, 12);
      final day = buf.readByte().clamp(1, 31);
      final hour = buf.readByte().clamp(0, 23);
      final min = buf.readByte().clamp(0, 59);
      buf.readByte(); // reserved
      final imp = buf.readShort().toDouble();

      results.add({
        'section': 'history',
        'weight_g': weightG,
        'weight_kg': weightG / 1000.0,
        'imp': imp,
        'timestamp': DateTime(year, month, day, hour, min),
      });
    }
    return results;
  }

  /// 编码用户信息发送给秤 (V2.7协议)
  static Uint8List encodeUserInfo(
      int heightCm, int age, int gender, double weightKg) {
    // 标准格式: 0xAC + 数据
    final buf = StreamBuffer.withSize(10);
    buf.writeByte(0xAC); // command
    buf.writeByte(0); // reserved
    buf.writeByte(heightCm);
    buf.writeByte(age);
    buf.writeByte(gender);
    buf.writeByte(0); // reserved
    buf.writeByte(0); // reserved
    buf.writeByte(0); // reserved
    // 4-byte weight in 0.1kg
    final w = (weightKg * 10).round();
    buf.writeByte(w & 0xFF);
    buf.writeByte((w >> 8) & 0xFF);
    return Uint8List.fromList(buf.getBuffer());
  }

  /// 编码时间同步命令
  static Uint8List encodeTimeSync() {
    final now = DateTime.now();
    final buf = StreamBuffer.withSize(8);
    buf.writeByte(0xA4); // time sync command
    buf.writeByte(now.year - 2000);
    buf.writeByte(now.month);
    buf.writeByte(now.day);
    buf.writeByte(now.hour);
    buf.writeByte(now.minute);
    buf.writeByte(now.second);
    buf.writeByte(0); // reserved
    return Uint8List.fromList(buf.getBuffer());
  }

  /// General V2: encodeUserInfo_BE (0xBE) — 触发设备进入完整测量模式
  /// 返回 General V2 帧列表，适配 MTU 分片
  static List<Uint8List> encodeUserInfoBE({
    required int heightCm,
    required int age,
    required int gender,
    required double weightKg,
    int mtu = 23,
    int unit = 0,
  }) {
    final buf = StreamBuffer.withSize(64);
    // BE 负载 (uint8)
    buf.setLittleEndian(true);
    buf.writeByte(0xBE); // cmd

    // time (epoch seconds, LE int32)
    final now = DateTime.now();
    final epoch = now.millisecondsSinceEpoch ~/ 1000;
    buf.writeInt(epoch);

    // utc_offset (minutes/60, LE int16, bit15=sign)
    final offsetSec = now.timeZoneOffset.inSeconds;
    final absOff = offsetSec.abs() ~/ 60;
    final offVal = offsetSec < 0 ? (absOff | 0x8000) : absOff;
    buf.writeShort(offVal);

    buf.writeByte(0); // user_index
    buf.writeByte(heightCm);
    buf.writeShort((weightKg * 100).round()); // weight * 100
    buf.writeByte(age);
    buf.writeShort((weightKg * 100).round()); // start_weight
    buf.writeShort((weightKg * 100).round()); // target_weight
    buf.writeByte(5); // flags: bit0=imp bit2=hr
    buf.writeInt(0); // userId
    buf.writeByte(0); // headSeq
    buf.writeByte(0); // headIndex
    buf.writeByte(0); // nick_len

    final rawPayload = buf.getBuffer();
    // 仅保留已写入的实际字节数
    final payload = rawPayload.sublist(0, buf.position);
    return _wrapGeneralV2Frames(payload, unit: unit, mtu: mtu);
  }

  /// General V2 帧包装: [pkgIdx:1][totalLen:2 LE][frameIdx:1][payload:N][checksum:1]
  static List<Uint8List> _wrapGeneralV2Frames(
    List<int> payload, {
    required int unit,
    required int mtu,
  }) {
    final maxPayload = mtu - 5; // 减去帧头(4)和校验(1)
    final totalLen = payload.length;
    final frameCount = ((totalLen - 1) ~/ maxPayload) + 1;
    final frames = <Uint8List>[];
    int offset = 0;
    int pkgIdx = 0;

    for (int i = 0; i < frameCount; i++) {
      final chunkLen = (i == frameCount - 1)
          ? totalLen - offset
          : maxPayload;
      final frame = Uint8List(4 + chunkLen + 1);
      frame[0] = pkgIdx & 0xFF;
      frame[1] = totalLen & 0xFF;
      frame[2] = (totalLen >> 8) & 0xFF;
      frame[3] = i; // frameIndex
      frame.setRange(4, 4 + chunkLen, payload.sublist(offset, offset + chunkLen));
      final chunk = Uint8List.sublistView(frame, 4, 4 + chunkLen);
      frame[4 + chunkLen] = (_checksum(chunk) & 0x1F) | ((unit & 0x07) << 5);
      frames.add(frame);
      offset += chunkLen;
      pkgIdx = (pkgIdx + 1) & 0xFF;
    }
    return frames;
  }
}

/// 解析结果
class ScalePacketResult {
  final Map<String, dynamic> data;

  const ScalePacketResult({required this.data});

  factory ScalePacketResult.fromMap(Map<String, dynamic> m) =>
      ScalePacketResult(data: m);

  String get section => data['section'] as String? ?? '';
  int get packetType => data['packet_type'] as int? ?? 0;

  double? get weightKg => data['weight_kg'] as double?;
  int? get weightG => data['weight_g'] as int?;

  List<double> get adcs => (data['adcs'] as List?)?.cast<double>() ?? [];
  List<int> get supportFuns =>
      (data['support_funs'] as List?)?.cast<int>() ?? [];

  @override
  String toString() =>
      'Packet(type=${packetType.toRadixString(16)}, section=$section)';
}
