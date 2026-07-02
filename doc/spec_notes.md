# Implementation notes and known deviations

This decoder is ported from [jxlatte](https://github.com/Traneptora/jxlatte)
(MIT) and inherits its behavior. Divergences from libjxl (`djxl`) observed
during gate testing:

## Lossless (modular)

Bit-exact against `djxl` on the entire local corpus and the modular
conformance testcases. No known deviations.

## Lossy (VarDCT)

- Output matches jxlatte to within **1 of 255** (differences from
  double-vs-float arithmetic in a few spots).
- jxlatte itself — and therefore this decoder — deviates from libjxl by up
  to ~26/255 on isolated **large-DCT varblocks** (DCT 16x32 and larger),
  concentrated in low-frequency LLF components. Overall RMSE stays below
  ~1.7/255 even on smooth gradients at d2; typical images are ~0.4–0.9
  RMSE. Verified by decoding the same files with jxlatte: its
  output-vs-djxl error is identical to ours (e.g. color_cover_d2.0_e1:
  rmse 1.679, max 23 for both).
- Suspected cause: float precision in the quant-weight interpolation
  (`getDCTQuantWeights`/`interpolate`) or the long-IDCT LUT accumulation
  order. Candidate for a post-1.0 precision pass against libjxl's
  `dec_xyb`/`quant_weights` computations.

## Default squeeze parameters with meta channels

jxlatte derives default squeeze parameters from `channels[0]`; libjxl uses
`channel[nb_meta_channels]`. This port follows **libjxl** (the spec-correct
choice). Only affects files combining palette + `--responsive=1`.

## Patch blend modes

jxlatte's patch-mode remapping mishandles patch modes 3 (mul) and 4 (blend
above); this port maps all eight patch modes per the spec table.

The `patches` conformance testcase (alpha-blended patches over a VarDCT
frame) deviates from djxl at rmse ~21.9 / max 77 — identically in jxlatte
(verified) and in this port. Root cause is somewhere in jxlatte's
alpha-weighted patch blending; tracked for a fix against libjxl's
dec_patch_dictionary. `patches_lossless` (additive patches) is bit-exact.

## Output color pipeline

XYB images are inverted to linear RGB with the image's primaries, then
encoded with the header's *enum* transfer function. Files whose color is
only described by an embedded ICC profile (`want_icc`) are decoded as if
tagged sRGB; a full ICC-driven output transform is out of scope for v1
(the raw ICC profile is exposed on `JxlImage.iccProfile`).

## Performance status

Lossless decoding runs at ~3.5x single-threaded djxl. Lossy decoding is
currently much slower (multi-second for multi-megapixel pages): the
dominant costs are the naive O(N^2) large-block IDCT (the 1D transforms
should become recursive O(N log N), as in libjxl) and the EPF inner loop.
Tracked as the main pre-1.0 optimization work.
