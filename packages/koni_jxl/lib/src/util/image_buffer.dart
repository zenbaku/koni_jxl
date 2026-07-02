import 'dart:typed_data';

/// A single image plane, either integer or float samples, stored flat with
/// row stride == width (replaces jxlatte's nested `int[y][x]` arrays).
final class ImageBuffer {
  ImageBuffer.int32(this.height, this.width)
      : _intBuffer = Int32List(height * width),
        _floatBuffer = null;

  ImageBuffer.float32(this.height, this.width)
      : _intBuffer = null,
        _floatBuffer = Float32List(height * width);

  ImageBuffer.copy(ImageBuffer other, {bool copyData = true})
      : height = other.height,
        width = other.width,
        _intBuffer = switch (other._intBuffer) {
          null => null,
          final b => copyData
              ? Int32List.fromList(b)
              : Int32List(other.height * other.width),
        },
        _floatBuffer = switch (other._floatBuffer) {
          null => null,
          final b => copyData
              ? Float32List.fromList(b)
              : Float32List(other.height * other.width),
        };

  ImageBuffer.fromInt(this.height, this.width, Int32List buffer)
      : _intBuffer = buffer,
        _floatBuffer = null;

  ImageBuffer.fromFloat(this.height, this.width, Float32List buffer)
      : _intBuffer = null,
        _floatBuffer = buffer;

  final int height;
  final int width;
  Int32List? _intBuffer;
  Float32List? _floatBuffer;

  bool get isInt => _intBuffer != null;
  bool get isFloat => _floatBuffer != null;

  Int32List get intBuffer => _intBuffer!;
  Float32List get floatBuffer => _floatBuffer!;

  /// Converts integer samples to floats in [0, 1] by dividing by [maxValue].
  /// No-op if already float.
  void castToFloatWithMax(int maxValue) {
    final ints = _intBuffer;
    if (ints == null) return;
    assert(maxValue >= 1);
    final floats = Float32List(height * width);
    final scale = 1.0 / maxValue;
    for (var i = 0; i < ints.length; i++) {
      floats[i] = ints[i] * scale;
    }
    _floatBuffer = floats;
    _intBuffer = null;
  }

  void castToFloat(int depth) => castToFloatWithMax((1 << depth) - 1);

  /// Converts float samples in [0, 1] to integers 0..[maxValue], rounding
  /// and clamping. No-op if already int.
  void castToIntWithMax(int maxValue) {
    final floats = _floatBuffer;
    if (floats == null) return;
    assert(maxValue >= 1);
    final ints = Int32List(height * width);
    for (var i = 0; i < floats.length; i++) {
      final v = (floats[i] * maxValue + 0.5).truncate();
      ints[i] = v < 0
          ? 0
          : v > maxValue
              ? maxValue
              : v;
    }
    _intBuffer = ints;
    _floatBuffer = null;
  }

  void castToInt(int depth) => castToIntWithMax((1 << depth) - 1);
}
