/// Frame type, encoding, flag, and blend-mode constants (spec values).
abstract final class FrameFlags {
  static const regularFrame = 0;
  static const lfFrame = 1;
  static const referenceOnly = 2;
  static const skipProgressive = 3;

  static const vardct = 0;
  static const modular = 1;

  static const noise = 1 << 0;
  static const patches = 1 << 1;
  static const splines = 1 << 4;
  static const useLfFrame = 1 << 5;
  static const skipAdaptiveLfSmoothing = 1 << 7;

  static const blendReplace = 0;
  static const blendAdd = 1;
  static const blendBlend = 2;
  static const blendMulAdd = 3;
  static const blendMult = 4;
}
