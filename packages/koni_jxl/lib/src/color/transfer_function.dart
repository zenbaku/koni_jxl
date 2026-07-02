import 'dart:math' as math;

import '../exceptions.dart';
import 'color_encoding.dart';

/// A transfer function: conversions between encoded and linear light.
abstract final class TransferFunction {
  const TransferFunction();

  double toLinear(double input);
  double fromLinear(double linear);

  static TransferFunction forTransfer(int transfer) {
    switch (transfer) {
      case ColorFlags.tfLinear:
        return const _Linear();
      case ColorFlags.tfSrgb:
        return const _Srgb();
      case ColorFlags.tfPq:
        return const _Pq();
      case ColorFlags.tfBt709:
        return const _Bt709();
      case ColorFlags.tfDci:
        return const GammaTransferFunction(3846154);
    }
    if (transfer < 1 << 24) return GammaTransferFunction(transfer);
    throw JxlUnsupportedException('transfer-function-$transfer');
  }
}

final class _Linear extends TransferFunction {
  const _Linear();
  @override
  double toLinear(double input) => input;
  @override
  double fromLinear(double linear) => linear;
}

final class _Srgb extends TransferFunction {
  const _Srgb();
  @override
  double toLinear(double f) => f < 0.0404482362771082
      ? f * 0.07739938080495357
      : math.pow((f + 0.055) * 0.9478672985781991, 2.4).toDouble();
  @override
  double fromLinear(double f) => f < 0.00313066844250063
      ? f * 12.92
      : 1.055 * math.pow(f, 0.4166666666666667) - 0.055;
}

final class _Bt709 extends TransferFunction {
  const _Bt709();
  @override
  double toLinear(double f) => f < 0.081242858298635133011
      ? f * 0.22222222222222222222
      : math
          .pow((f + 0.0992968268094429403) * 0.90967241568627260377,
              2.2222222222222222222)
          .toDouble();
  @override
  double fromLinear(double f) => f < 0.018053968510807807336
      ? 4.5 * f
      : 1.0992968268094429403 * math.pow(f, 0.45) - 0.0992968268094429403;
}

final class _Pq extends TransferFunction {
  const _Pq();
  @override
  double toLinear(double f) {
    final d = math.pow(f, 0.012683313515655965121).toDouble();
    return math
        .pow(
            (d - 0.8359375) / (18.8515625 + 18.6875 * d), 6.2725880551301684533)
        .toDouble();
  }

  @override
  double fromLinear(double f) {
    final d = math.pow(f, 0.159423828125).toDouble();
    return math
        .pow((0.8359375 + 18.8515625 * d) / (1 + 18.6875 * d), 78.84375)
        .toDouble();
  }
}

final class GammaTransferFunction extends TransferFunction {
  const GammaTransferFunction(this.gammaE7);

  /// Gamma scaled by 1e7, as stored in the bitstream.
  final int gammaE7;

  double get _gamma => gammaE7 * 1e-7;

  @override
  double toLinear(double f) =>
      f <= 0 ? 0 : math.pow(f, 1.0 / _gamma).toDouble();

  @override
  double fromLinear(double f) => f <= 0 ? 0 : math.pow(f, _gamma).toDouble();
}
