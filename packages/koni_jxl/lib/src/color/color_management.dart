import 'color_encoding.dart';

/// Minimal color management: white-point adaptation and primaries
/// conversion matrices (all math in doubles, 3x3 row-major lists).

const _bradford = [
  [0.8951, 0.2664, -0.1614],
  [-0.7502, 1.7135, 0.0367],
  [0.0389, -0.0685, 1.0296],
];

List<List<double>> matrixMultiply3(
    List<List<double>> left, List<List<double>> right) {
  final result = List.generate(3, (_) => List<double>.filled(3, 0));
  for (var y = 0; y < 3; y++) {
    for (var x = 0; x < 3; x++) {
      var total = 0.0;
      for (var k = 0; k < 3; k++) {
        total += left[y][k] * right[k][x];
      }
      result[y][x] = total;
    }
  }
  return result;
}

List<double> matrixVector3(List<List<double>> m, List<double> v) => [
      for (var y = 0; y < 3; y++)
        m[y][0] * v[0] + m[y][1] * v[1] + m[y][2] * v[2],
    ];

List<List<double>>? invertMatrix3x3(List<List<double>> matrix) {
  var det = 0.0;
  for (var c = 0; c < 3; c++) {
    final c1 = (c + 1) % 3;
    final c2 = (c + 2) % 3;
    det += matrix[c][0] * matrix[c1][1] * matrix[c2][2] -
        matrix[c][0] * matrix[c1][2] * matrix[c2][1];
  }
  if (det == 0) return null;
  final invDet = 1.0 / det;
  final inverse = List.generate(3, (_) => List<double>.filled(3, 0));
  for (var x = 0; x < 3; x++) {
    for (var y = 0; y < 3; y++) {
      final x1 = (x + 1) % 3;
      final x2 = (x + 2) % 3;
      final y1 = (y + 1) % 3;
      final y2 = (y + 2) % 3;
      inverse[y][x] =
          (matrix[x1][y1] * matrix[x2][y2] - matrix[x2][y1] * matrix[x1][y2]) *
              invDet;
    }
  }
  return inverse;
}

List<List<double>> matrixIdentity3() => [
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1],
    ];

List<double> _getXYZ(CieXy xy) {
  final invY = 1.0 / xy.y;
  return [xy.x * invY, 1.0, (1.0 - xy.x - xy.y) * invY];
}

List<List<double>> _adaptWhitePoint(CieXy? targetWP, CieXy? currentWP) {
  final target = targetWP ?? ColorFlags.getWhitePoint(ColorFlags.wpD50)!;
  final current = currentWP ?? ColorFlags.getWhitePoint(ColorFlags.wpD50)!;
  final lmsCurrent = matrixVector3(_bradford, _getXYZ(current));
  final lmsTarget = matrixVector3(_bradford, _getXYZ(target));
  final a = List.generate(3, (_) => List<double>.filled(3, 0));
  for (var i = 0; i < 3; i++) {
    a[i][i] = lmsTarget[i] / lmsCurrent[i];
  }
  final bradfordInverse = invertMatrix3x3(_bradford)!;
  return matrixMultiply3(matrixMultiply3(bradfordInverse, a), _bradford);
}

List<List<double>> _primariesToXYZ(CiePrimaries primaries, CieXy? wp) {
  wp ??= ColorFlags.getWhitePoint(ColorFlags.wpD50)!;
  final primariesTr = [
    _getXYZ(primaries.red),
    _getXYZ(primaries.green),
    _getXYZ(primaries.blue),
  ];
  // Transpose.
  final primariesMatrix = List.generate(
      3, (y) => List<double>.generate(3, (x) => primariesTr[x][y]));
  final inversePrimaries = invertMatrix3x3(primariesMatrix)!;
  final xyz = matrixVector3(inversePrimaries, _getXYZ(wp));
  final a = [
    [xyz[0], 0.0, 0.0],
    [0.0, xyz[1], 0.0],
    [0.0, 0.0, xyz[2]],
  ];
  return matrixMultiply3(primariesMatrix, a);
}

/// Conversion matrix from (currentPrim, currentWP) linear RGB to
/// (targetPrim, targetWP) linear RGB.
List<List<double>> getConversionMatrix(CiePrimaries targetPrim, CieXy targetWP,
    CiePrimaries currentPrim, CieXy currentWP) {
  if (targetPrim.matches(currentPrim) && targetWP.matches(currentWP)) {
    return matrixIdentity3();
  }
  List<List<double>>? whitePointConv;
  if (!targetWP.matches(currentWP)) {
    whitePointConv = _adaptWhitePoint(targetWP, currentWP);
  }
  final forward = _primariesToXYZ(currentPrim, currentWP);
  final reverse = invertMatrix3x3(_primariesToXYZ(targetPrim, targetWP))!;
  var result = forward;
  if (whitePointConv != null) result = matrixMultiply3(whitePointConv, result);
  return matrixMultiply3(reverse, result);
}
