/// 小端字节流操作 (移植自 ICStreamBuffer)
class StreamBuffer {
  final List<int> _data;
  int _position;

  StreamBuffer(List<int> data)
      : _data = List<int>.from(data),
        _position = 0;

  StreamBuffer.withSize(int size)
      : _data = List<int>.filled(size, 0),
        _position = 0;

  int get length => _data.length;
  int get position => _position;
  List<int> get data => List.unmodifiable(_data);

  void setLittleEndian(bool le) {
    // 此实现始终使用小端 — 原Java版默认为小端
  }

  void skip(int n) => _position = (_position + n).clamp(0, _data.length);
  void rewind() => _position = 0;
  void seekEnd(int offset) =>
      _position = (_data.length + offset).clamp(0, _data.length);

  int readByte() {
    if (_position >= _data.length) return 0;
    return _data[_position++] & 0xFF;
  }

  int readShort() {
    final low = readByte();
    final high = readByte();
    return (high << 8) | low;
  }

  int readInt() {
    final b0 = readByte();
    final b1 = readByte();
    final b2 = readByte();
    final b3 = readByte();
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
  }

  List<int> readData(int count) {
    final n = count.clamp(0, _data.length - _position);
    final result = _data.sublist(_position, _position + n);
    _position += n;
    return result;
  }

  double readIeee11073Float() {
    // IEEE 11073-20601 16-bit float
    if (_position + 2 > _data.length) return 0;
    final mantissa = readShort();
    if (mantissa == 0x7FF || mantissa == 0x800) return 0; // NaN/Inf
    final exp = (mantissa >> 12) & 0x0F;
    if ((mantissa & 0x8000) != 0) {
      // 负数
      return -((~(mantissa & 0xFFF) + 1) & 0xFFF).toDouble() * _pow10(exp - 4);
    }
    return (mantissa & 0xFFF).toDouble() * _pow10(exp - 4);
  }

  static double _pow10(int exp) {
    double r = 1.0;
    if (exp >= 0) {
      for (int i = 0; i < exp; i++) {
        r *= 10;
      }
    } else {
      for (int i = 0; i < -exp; i++) {
        r /= 10;
      }
    }
    return r;
  }

  void writeByte(int v) {
    if (_position < _data.length) _data[_position++] = v & 0xFF;
  }

  void writeShort(int v) {
    writeByte(v & 0xFF);
    writeByte((v >> 8) & 0xFF);
  }

  void writeInt(int v) {
    writeByte(v & 0xFF);
    writeByte((v >> 8) & 0xFF);
    writeByte((v >> 16) & 0xFF);
    writeByte((v >> 24) & 0xFF);
  }

  void writeData(List<int> src, int offset, int count) {
    final end = (offset + count).clamp(0, src.length);
    for (int i = offset; i < end && _position < _data.length; i++) {
      _data[_position++] = src[i];
    }
  }

  List<int> getBuffer() => List<int>.from(_data);
}

/// 位操作 (移植自 ICCommon)
class BitUtils {
  static int getBit(int value, int bit) => ((value >> bit) & 1);

  static double ceil(double v) => v.roundToDouble();

  static double calcBmi(double weightKg, int heightCm) {
    if (heightCm <= 0 || weightKg <= 0) return 0;
    final h = heightCm / 100.0;
    return weightKg / (h * h);
  }
}
