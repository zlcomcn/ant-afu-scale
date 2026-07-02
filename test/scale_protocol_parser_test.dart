import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/protocols/scale_protocol_parser.dart';
import 'package:scale_app/protocols/bia_algorithm.dart';

void main() {
  test('bmiExact 精确复刻逆向 getBMI + ICCommon.ceil (截断到1位)', () {
    // 逆向: bmi = weight / (height_cm²/10000); ceil = ((int)(x*10))/10
    // 70kg / (170²/10000) = 70 / 2.89 = 24.221... → 截断 → 24.2
    expect(BiaBodyComposition.bmiExact(70, 170), 24.2);
    // 65kg / (170²/10000) = 22.49... → 22.4 (截断非四舍五入)
    expect(BiaBodyComposition.bmiExact(65, 170), 22.4);
    // 100kg / (180²/10000) = 30.86... → 30.8
    expect(BiaBodyComposition.bmiExact(100, 180), 30.8);
  });

  test('decodes 20 byte v2.7 weight frame', () {
    final frame = _buildFrame(packetType: 0xD5, flags: (1 << 24) | 72500);

    final results = ScaleProtocolParser.decode(frame, 64);

    final weight = results.singleWhere((r) => r.section == 'weight');
    expect(weight.packetType, 0xD5);
    expect(weight.weightG, 72500);
    expect(weight.weightKg, 72.5);
    expect(weight.data['state'], 1);
  });

  test('decodes 20 byte v2.7 adc frame', () {
    final frame = _buildFrame(
      packetType: 0xD6,
      payload: [0x00, 0x02, 0x00, 0xf4, 0x01, 0x08, 0x02, 0x00],
    );

    final results = ScaleProtocolParser.decode(frame, 64);

    final adc = results.singleWhere((r) => r.section == 'adc');
    expect(adc.packetType, 0xD6);
    expect(adc.adcs, [500.0, 520.0]);
  });

  test('decodes general v2 A2 live weight frame', () {
    // payload = [cmd=0xA2][state=1][flags=72500 LE][hr=0][measure_mode=0]
    const weightG = 72500;
    final payload = <int>[
      0xA2, // cmd
      0x01, // state
      weightG & 0xff,
      (weightG >> 8) & 0xff,
      (weightG >> 16) & 0xff,
      (weightG >> 24) & 0xff,
      0, // hr
      0, // measure_mode
    ];
    final frame =
        _buildGeneralV2Frame(packageIndex: 7, unit: 0, payload: payload);

    final results = ScaleProtocolParser.decode(frame, 64);

    final weight = results.singleWhere((r) => r.section == 'weight');
    expect(weight.packetType, 0xA2);
    expect(weight.weightG, 72500);
    expect(weight.weightKg, 72.5);
    expect(weight.data['state'], 1);
  });

  test('decodes 20 byte v2.7 weight frame with packet at byte 18', () {
    // OEM variant: weight at bytes 4-5 BE uint16
    const weightG = 65500; // 65.50 kg
    final frame = _buildFrameVariant(packetType: 0xD5, weightG: weightG);

    final results = ScaleProtocolParser.decode(frame, 64);

    final weight = results.singleWhere((r) => r.section == 'weight');
    expect(weight.packetType, 0xD5);
    expect(weight.weightG, 65500);
    expect(weight.weightKg, 65.5);
    // state always 1 for OEM variant
    expect(weight.data['state'], 1);
  });
}

Uint8List _buildGeneralV2Frame({
  required int packageIndex,
  required int unit,
  required List<int> payload,
}) {
  final frame = Uint8List(4 + payload.length + 1);
  frame[0] = packageIndex;
  frame[1] = payload.length & 0xff;
  frame[2] = (payload.length >> 8) & 0xff;
  frame[3] = 0;
  frame.setRange(4, 4 + payload.length, payload);
  frame[4 + payload.length] =
      ((_checksum(payload) & 0x1f) | ((unit & 0x07) << 5));
  return frame;
}

int _checksum(List<int> bytes) {
  var sum = 0;
  for (final b in bytes) {
    sum = (sum + b) & 0xff;
  }
  return sum;
}

Uint8List _buildFrameVariant({
  required int packetType,
  int weightG = 0,
}) {
  final frame = Uint8List(20);
  // OEM variant: weight at bytes 4-5 BE uint16
  frame[4] = (weightG >> 8) & 0xff;
  frame[5] = weightG & 0xff;
  frame[18] = packetType;
  frame[19] = _crc5(frame, 0, 18);
  return frame;
}

Uint8List _buildFrame({
  required int packetType,
  int flags = 0,
  List<int>? payload,
}) {
  final frame = Uint8List(20);
  frame[1] = flags & 0xff;
  frame[2] = (flags >> 8) & 0xff;
  frame[3] = (flags >> 16) & 0xff;
  frame[4] = (flags >> 24) & 0xff;
  if (payload != null) {
    frame.setRange(1, 1 + payload.length, payload);
  }
  frame[16] = packetType;
  frame[17] = _crc5(frame, 0, 17);
  return frame;
}

int _crc5(Uint8List bytes, int offset, int length) {
  var crc = 0;
  for (var i = offset; i < offset + length; i++) {
    crc = (crc + bytes[i]) & 0x1f;
  }
  return crc;
}
