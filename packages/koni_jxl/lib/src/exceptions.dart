/// Base class for all errors thrown by the koni_jxl decoder.
sealed class JxlException implements Exception {
  const JxlException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The input is not a valid JPEG XL bitstream.
final class JxlInvalidBitstreamException extends JxlException {
  const JxlInvalidBitstreamException(super.message);
}

/// The input ended before the decoder could finish reading.
final class JxlTruncatedException extends JxlException {
  const JxlTruncatedException(super.message);
}

/// The bitstream is valid but uses a feature this decoder does not support.
///
/// [feature] is a stable identifier (e.g. `'vardct'`, `'animation'`) so
/// callers can decide per-file whether to fall back to another decoder.
final class JxlUnsupportedException extends JxlException {
  JxlUnsupportedException(this.feature)
      : super('unsupported JPEG XL feature: $feature');

  final String feature;
}
