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

## Progressive (LF frames)

LF frames (progressive DC, `cjxl --progressive_dc=N`) decode through the
normal frame machinery: an LF frame's pixels are stored per lf-level and
become the referencing frame's dequantized LF coefficients directly (the
LF context indices stay zero, matching the reference decoders). Synthetic
progressive_dc corpus files gate this within the normal lossy thresholds.
The `progressive` conformance testcase decodes correctly but differs from
djxl by a smooth per-channel tone curve: its color is described only by
an embedded ICC profile, which koni_jxl decodes as sRGB (the documented
ICC limitation, verified as a monotonic +-1-tight value mapping).

## Streaming / progressive display

`JxlStreamingDecoder` probes headers and frame tables of contents over
the buffered prefix (tolerating truncation everywhere) and reports what
is decodable. The 1:8 preview comes from either the dequantized LF
sections of the first regular VarDCT frame or, for progressive-DC files,
from a fully-buffered level-1 LF frame (including chained level-2
frames). Previews of subsampled chroma use nearest-neighbor doubling;
extra channels are rendered opaque. How early the preview becomes
available is a property of the encoder's section order: cjxl
--progressive_dc files reach it after a few percent of the bytes, while
default cjxl output may interleave LF sections per 2048-row stripe
(observed: an e7 encode with its second LF group at 95% of the file).
Modular images have no DC image and stream straight to complete.

## Encoder

The lossless encoder emits: explicit image metadata (the all-default
header implies XYB), a modular frame with a per-image LEARNED global MA
tree (greedy entropy-minimizing splits, clamped-gradient or weighted
leaves), YCoCg RCT (type 6) for color, prefix-coded residuals,
one section per 256x256 group with the histograms shared via the
LfGlobal tree stream. Per image the encoder chooses between LZ77
(hash-chain matcher over the token-value stream, linear distances
D + 119, length symbols at 224 in the pixel contexts), palette
(<= 256 colors, luminance-sorted) and YCoCg RCT, using exact
Huffman-code-length size estimates — Shannon entropy is NOT a safe
proxy: prefix codes pay a 1-bit-per-symbol floor that dominates
highly skewed histograms (a 16-color image estimated 1K by entropy
but coded 33K until LZ77 was chosen on exact costs). 16-bit input is
supported. Remaining encoder ideas:
per-image learned trees, delta palette. ANS (rANS) IS now implemented as a
fourth per-image candidate: it spends fractional bits (no 1-bit-per-symbol
prefix floor) and is chosen by size estimate when it beats plain/LZ77
prefix, it can carry LZ77 matches too (length symbols at 224+ in the pixel
clusters, distances in the extra cluster). The encoder builds four
candidates — {plain, LZ77} x {prefix, ANS} — and, for every candidate
whose size ESTIMATE is within 3% of the best, assembles the full
codestream and keeps the smallest ACTUAL output (estimates can't resolve
sub-percent differences between near-tied modes, e.g. unified ANS+LZ77
beating LZ77-prefix by ~0.1% on a color page). With the per-image learned
context tree (the biggest single lever, matching cjxl's e2->e3 jump where
learned trees and the weighted predictor turn on), real manga pages now
land near cjxl -e3: a B/W page at ~98% of cjxl -e3, a color page at ~81%.
The encoder tries both predictors (clamped gradient and self-correcting
weighted) and both property sets, keeping the smallest actual output; the
weighted predictor's property 15 (max-error) is included in its tree
candidates, which is what makes WP win on color/tonal content (one piece
color page -4%, B/W page flips to WP).
All output is bit-exact through this decoder and djxl.

## Robustness

The public decode surfaces (`JxlInfo.parse`, `JxlDecoder.decode`,
`decodeAnimation`, `JxlStreamingDecoder`) hold a hard contract: any input
either decodes or throws a `JxlException` — never a `RangeError`,
`StateError`, `TypeError`, out-of-memory, or hang. This is enforced by a
mutation-fuzz campaign (`tool/fuzz_decode.dart`: bit-flips, truncations,
garbage over diverse seeds) and a seeded regression subset in
`test/decoder/fuzz_regression_test.dart`. `JxlLimits` bounds pre-checked
allocations (plane pixels, channels, frames, features, ICC/extension
bytes) so a crafted header can't force a huge allocation. Notable
hardening found by fuzzing: quadratic TOC-permutation decode replaced
with an O(n log n) Fenwick select (was a multi-second hang on large
entry counts), transform channel-range and block-extent validation,
prefix-code length bounds, and an entropy-context bounds guard covering
every `readSymbol` caller.

## Performance status

Lossless decoding runs at ~3.5x single-threaded djxl. Lossy decoding of a
3.4-megapixel page takes ~0.4-0.65 s single-threaded (djxl: ~0.1 s); a
real-world JPEG-transcoded manga page decodes in ~0.3 s. The float
pipeline uses dart:typed_data Float32x4 SIMD (native NEON/SSE under AOT):
the fused 8x8 inverse DCT (in-register transposes), coefficient
dequantization (float-arithmetic lane masks; Int32x4 select boxes in
AOT), the XYB opsin inverse, gaborish, and the EPF interior (8-pixel
groups so the per-block sigma and border-lane pattern are constant per
group; +-1 neighbors via shuffle + lane insert, +-2 via one shuffleMix).
Larger DCTs (16x16 to 256x256) run a batched-vector form of Lee's
O(N log N) recursion: column transforms put 4 adjacent columns in the
lanes with no shuffling at all, row transforms go through in-register
4x4 transposes, and twiddles apply via Float32x4.scale. (At N=256 the
largest twiddle is ~115, which amplifies float32 rounding to ~1e-3
relative - matching libjxl's own float32 arithmetic and far inside the
conformance thresholds.) Weight matrices and coefficient orders are generated lazily per
transform type actually used. On a 3.4MP page the EPF pass runs in
~57 ms and gaborish in ~34 ms.

Note for Flutter Web: dart2js emulates Float32x4 in software, so lossy
decoding is substantially slower there; AOT targets (Android/iOS/desktop)
get native SIMD.

Multi-core decode via isolates was evaluated and deferred: Dart isolates
share no mutable memory, so parallel pass-group decoding would need
either per-worker re-parsing of the LF/global sections or bulk copies of
coefficient state, and at ~0.3-0.5 s per page single-threaded the added
complexity outweighs the plausible ~2x. Revisit if shared-memory
isolates land or if multi-megapixel spreads become the common case.

A hard-won Dart AOT lesson encoded in the hot paths: never derive a
`List<Float32List>` used in a hot loop from a nested
`List<List<Float32List>>` (or similar generic container) inside the hot
function - pass the per-channel row lists as direct parameters from a
call site where the concrete list class is statically known. Violating
this costs 5-20x in pixel loops.

## Real-world validation

Two commercially-distributed CBZ chapters containing JPEG-transcoded JXL
pages (VarDCT + JPEG reconstruction data, YCbCr 4:2:0; 1066x1600 B/W and
up to 1920x1508 full color) decode with zero failures: all 34 pages match
djxl within a max pixel difference of 1/255, ~0.3-0.4 s per page AOT
single-threaded. The `jbrd` JPEG reconstruction box is ignored; pixels
decode through the normal VarDCT path (byte-exact JPEG re-emission is out
of scope).

Animation is decoded beyond what jxlatte implements (jxlatte stops at
the first visible frame). One spec detail matters there: for a frame
whose crop does not cover the canvas, the area outside the crop comes
from the blending-source reference (zeros when that slot is empty), not
from the previous canvas. Verified against djxl: animation_newtons_cradle
is bit-exact on all 36 frames; animation_icos4d (lossy VarDCT, cropped
alpha-blended frames) matches within max 11/255 across all 48 frames.

Deviation fixed relative to jxlatte: its Spline constructor never stores
the spline index, so jxlatte renders every spline of an image with the
first spline's color/sigma coefficients. koni_jxl uses each spline's own
coefficients; both animation_spline conformance cases match djxl within
1/255 on all 60 frames.

Deviation fixed relative to jxlatte: chroma upsampling (subsampling
inversion) mirrors its neighbor taps at the *visible* subsampled extent,
as libjxl's render pipeline does. jxlatte reads the padded DCT samples
beyond ceil(visible/2) instead, which shifts the final visible row of
4:2:0 images whose height is even but not a block multiple (verified:
jxlatte deviates from djxl by up to 10/255 on such a row; we match djxl
to 1/255 after the fix).
