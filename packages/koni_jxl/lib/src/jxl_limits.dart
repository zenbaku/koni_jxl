/// Global decoder resource limits.
///
/// Malformed or malicious files can declare absurd dimensions or counts;
/// these caps bound what the decoder will allocate before failing with a
/// [JxlException]. Raise them if you legitimately need larger images.
abstract final class JxlLimits {
  /// Maximum pixels per decoded plane (width * height). The default,
  /// 2^26 (~67 megapixels), allows any realistic page or photo while
  /// bounding a plane to 256 MB of float samples.
  static int maxPlanePixels = 1 << 26;

  /// Maximum total channels (color + extra).
  static int maxChannels = 64;

  /// Maximum frames processed in one image (animation or otherwise).
  static int maxFrames = 1 << 16;

  /// Maximum patches, splines and spline control points per frame.
  static int maxFeatureCount = 1 << 20;

  /// Maximum encoded/decompressed ICC profile bytes.
  static int maxIccBytes = 1 << 24;

  /// Maximum bytes across header extension payloads.
  static int maxExtensionBytes = 1 << 20;
}
