import 'dart:typed_data';

import '../exceptions.dart';
import '../jxl_limits.dart';

/// A single image plane, either integer or float samples.
///
/// Storage is row-based: each row is an independent typed list. This keeps
/// hot loops monomorphic (typed-data *views* are a different internal class
/// than real typed lists and wreck AOT inlining/bounds-check elimination).
void _checkPlaneSize(int height, int width) {
  if (height < 0 ||
      width < 0 ||
      (width != 0 && height > JxlLimits.maxPlanePixels ~/ width)) {
    throw JxlInvalidBitstreamException(
        'plane ${width}x$height exceeds JxlLimits.maxPlanePixels');
  }
}

final class ImageBuffer {
  factory ImageBuffer.int32(int height, int width) {
    _checkPlaneSize(height, width);
    return ImageBuffer._int32(height, width);
  }

  ImageBuffer._int32(this.height, this.width)
      : _intRows =
            List.generate(height, (_) => Int32List(width), growable: false),
        _floatRows = null;

  factory ImageBuffer.float32(int height, int width) {
    _checkPlaneSize(height, width);
    return ImageBuffer._float32(height, width);
  }

  ImageBuffer._float32(this.height, this.width)
      : _intRows = null,
        _floatRows =
            List.generate(height, (_) => Float32List(width), growable: false);

  ImageBuffer.copy(ImageBuffer other, {bool copyData = true})
      : height = other.height,
        width = other.width,
        _intRows = switch (other._intRows) {
          null => null,
          final rows => List.generate(
              other.height,
              (y) => copyData
                  ? Int32List.fromList(rows[y])
                  : Int32List(other.width),
              growable: false),
        },
        _floatRows = switch (other._floatRows) {
          null => null,
          final rows => List.generate(
              other.height,
              (y) => copyData
                  ? Float32List.fromList(rows[y])
                  : Float32List(other.width),
              growable: false),
        };

  final int height;
  final int width;
  List<Int32List>? _intRows;
  List<Float32List>? _floatRows;

  bool get isInt => _intRows != null;
  bool get isFloat => _floatRows != null;

  List<Int32List> get intRows => _intRows!;
  List<Float32List> get floatRows => _floatRows!;

  /// Converts integer samples to floats in [0, 1] by dividing by [maxValue].
  /// No-op if already float.
  void castToFloatWithMax(int maxValue) {
    final ints = _intRows;
    if (ints == null) return;
    assert(maxValue >= 1);
    final scale = 1.0 / maxValue;
    final floats = List.generate(height, (y) {
      final src = ints[y];
      final row = Float32List(width);
      for (var x = 0; x < width; x++) {
        row[x] = src[x] * scale;
      }
      return row;
    }, growable: false);
    _floatRows = floats;
    _intRows = null;
  }

  void castToFloat(int depth) => castToFloatWithMax((1 << depth) - 1);

  /// Converts float samples in [0, 1] to integers 0..[maxValue], rounding
  /// and clamping. No-op if already int.
  void castToIntWithMax(int maxValue) {
    final floats = _floatRows;
    if (floats == null) return;
    assert(maxValue >= 1);
    final ints = List.generate(height, (y) {
      final src = floats[y];
      final row = Int32List(width);
      for (var x = 0; x < width; x++) {
        final v = (src[x] * maxValue + 0.5).truncate();
        row[x] = v < 0
            ? 0
            : v > maxValue
                ? maxValue
                : v;
      }
      return row;
    }, growable: false);
    _intRows = ints;
    _floatRows = null;
  }

  void castToInt(int depth) => castToIntWithMax((1 << depth) - 1);
}

/// A free-standing jagged float matrix (Java-style `float[h][w]`), used by
/// the VarDCT block code where jxlatte uses nested arrays.
/// Float32x4 views over each row (row widths must be multiples of 4).
List<Float32x4List> rowVectorViews(List<Float32List> rows) =>
    List<Float32x4List>.generate(
        rows.length,
        (y) => Float32x4List.view(
            rows[y].buffer, rows[y].offsetInBytes, rows[y].length >> 2),
        growable: false);

List<Float32List> floatMatrix(int height, int width) =>
    List.generate(height, (_) => Float32List(width), growable: false);
