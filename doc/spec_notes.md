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

### Lossy (VarDCT) encoder — L0

`JxlEncoder.encodeLossy` (`lib/src/encode/vardct/`) implements the L0
milestone from `doc/lossy_encoder_plan.md`: single-group (width/height
multiples of 8, up to 256x256), 8x8-DCT-only, uniform quantization,
filters off. Gated against djxl end-to-end
(`test/encode/vardct_l0_test.dart`, `test/encode/vardct_forward_test.dart`).

Two channel-ordering conventions coexist in the VarDCT decoder and both
matter for a bit-exact writer:

- **Semantic/scalar order is X, Y, B** (index 0/1/2) — used by
  `jpegUpsamplingY/X`, `xqmScale`/`bqmScale` (→ `scaleFactor[0]`/`[2]`),
  `lfDequant`/`scaledDequant`, `quantBias`, and
  `defaultDctParams[0].dctParam` row order.
- **Bitstream/processing order is Y, X, B** — the `LfCoefficients` and
  `HfCoefficients` per-block channel loops, and the `lfQuant`/`info`
  channel-array order, all iterate in this order. `frame/frame.dart`'s
  `cMap = [1, 0, 2]` converts between the two (it's a self-inverse
  permutation, i.e. `cMap[cMap[i]] == i`, which makes both directions look
  identical in the source — worth tracing through concrete values rather
  than assuming a direction).

Chroma-from-luma is **not optional** at the defaults: `baseCorrelationB`
defaults to `1.0` (not `0.0`), so the decoder always adds the full
dequantized Y coefficient into B, at both DC and AC. The encoder must
pre-subtract Y from B (before quantizing) at every coefficient position,
not just DC.

The HF coefficient context model (`vardct/hf_coefficients.dart`,
`hf_block_context.dart`) has 495 contexts per (HF preset, block-context
cluster) — non-zero-count prediction from neighbor blocks, a per-position
frequency/nonzero-count table, and a `prev`-nonzero bit. L0 does not
implement per-context histograms: it writes a single `EntropyStream`
distribution but with a **collapsed cluster map** sized for the real
`495 * numHfPresets * numClusters` context domain (`simple` clustering,
`nbits = 0`, so every context decodes as cluster 0) — this is legal per
the bitstream format and correct regardless of which context a symbol
"should" have used, since cluster assignment only affects compression
ratio, not which values are decodable. `EntropyCodes.writeHeader` gained a
`clusterMapDomainSize` parameter for this. L1 is where the real context
model (and therefore competitive compression) lands.

Natural (unpermuted) coefficient order is read via the decoder's own
`getNaturalOrder` (made public, not reimplemented) so the scan is
bit-identical by construction; the same goes for the DCT8x8 quantization
weight table (`getDCTQuantWeights`, also made public).

### Lossy (VarDCT) encoder — L1: real HF context model

L1 replaced L0's single-collapsed-cluster HF entropy coding with the
decoder's real context model (`HfCoefficients.getBlockContext` /
`getNonZeroContext` / `getCoefficientContext` / `getPredictedNonZeroes`,
all made public — same "reuse, don't reimplement" rule as `getNaturalOrder`
above). This surfaced an **undocumented bitstream limit found only by
testing against djxl**: an entropy code may have **at most 256 histograms
(clusters)**. This decoder's own `EntropyStream.readClusterMap` never
enforces it — a hand-written encoder producing 257+ clusters (easy once
per-context histograms are real: a busy 24x32 synthetic image reaches
~300 distinct contexts) parses and decodes cleanly through *this*
decoder, but djxl rejects the file outright with no diagnostic detail
(`Failed to decode image`). Root-caused by a differential trace: an
isolated round-trip of the exact bits this encoder wrote, decoded via
this project's own `EntropyStream`, matched perfectly (proving the
Huffman/cluster-map *mechanics* were correct) — the count of distinct
histograms was the only remaining variable, and bisecting it against djxl
confirmed 256 passes / 257 fails exactly. `vardct_l0_encoder.dart` now
caps at `_maxHfClusters = 256`, routing the least-frequent contexts
(by usage count) into one shared overflow cluster beyond that budget.

Splitting into more clusters is not free — each pays a fixed header cost
(config + alphabet size + a prefix code table) independent of its sample
count, so for small images more clusters can make the file *larger* than
one shared histogram. Rather than guess a cluster-count budget, the
encoder tries several (1, 16, 64, 256, and the actual distinct-context
count) and assembles real bytes for each, keeping the smallest — the same
"estimates can't resolve near-ties, verify by real assembly" rule the
lossless encoder already follows.

### Lossy (VarDCT) encoder — L1: multi-group and distance

Multi-group support (images up to 2048x2048, still a single LF group)
mirrors the format's own split: `numGroups == 1` forces exactly one TOC
entry (LfGlobal/LfGroup/HfGlobal+HfPass/PassGroup bit-concatenated with no
byte alignment, per the L0 note above); `numGroups > 1` is NOT optional at
that point — the decoder computes `tocEntryCount` purely from image
dimensions, so the encoder has no choice but to switch to one
independently byte-aligned section per (LfGlobal, the single LfGroup,
HfGlobal+HfPass, and each group's own PassGroup). The HF coefficient
context model's cluster map and histograms are still built once from
every group's tokens combined (mirroring `EntropyStream.clone` sharing
one `HfPass.contextStream` across groups); only the per-symbol payload
bits are per-group. Each group gets its own non-zero-prediction grid reset
(mirrors a fresh `HfCoefficients` per (pass, group)).

`JxlEncoder.encodeLossy`'s `distance:` parameter has no decoder-side
formula to mirror (libjxl's distance-to-quantizer mapping lives entirely
in the encoder) so `VardctL0Config.fromDistance` is a hand-picked,
monotonic mapping, calibrated empirically rather than derived from spec.
Both `globalScale` and `quantLF` are dequantization *divisors*
(`dequant = stored / (something * globalScale-or-quantLF)`), so smaller
distance (finer/higher quality) needs LARGER values of both — an inverted
sign here (shipped briefly during development for `quantLF`) silently
makes "higher quality" requests coarser instead, without any error or
gate failure, since both directions produce a valid, djxl-decodable
bitstream. Caught by checking the RMSE trend empirically, not by a type
or bounds error. `globalScale`'s bitstream field caps `globalScaleF`
(`65536 / globalScale`) at a minimum of ~0.889 (`65536/73728`), so
requesting distances below ~0.5-0.8 stops improving quality — the AC
quantizer literally cannot represent a finer step via this field alone.
Reaching further requires custom per-frequency quant weight tables
(`quant_all_default = false`), deferred to L2.

### Lossy (VarDCT) encoder — L2: perceptual quantization

**Adaptive per-block quantization.** `hfMultiplier` (`HfMetadata`'s
per-block field, `hf_coefficients.dart`'s `sfc = scaleFactor[c] /
hfMultiplier`) is a *divisor* on the dequantized value, so it can only
make a block **finer** than the frame's baseline (`hfMultiplier >= 1`
always — `1 + storedValue`, `storedValue` a non-negative modular int).
There is no way to make a specific block *coarser* through this field.
The encoder therefore boosts precision selectively (Y AC energy relative
to a `distance`-scaled reference step decides low/medium/baseline
buckets: `4`/`2`/`1`) rather than trying to trade quality between blocks
— smooth/low-energy blocks (where rounding AC to zero causes visible
banding) get boosted; busy blocks stay at the baseline multiplier, since
masking hides quantization noise there and they already spend plenty of
bits regardless. Measured effect: ~65-70% RMSE reduction on a smooth
gradient test image at default distance, at an 18-26% file size cost.
Since `hfMult` doesn't change which context cluster a coefficient uses
(the default `HfBlockContext`'s `qfThresholds` are empty, so
`getBlockContext`'s threshold loop is a no-op regardless of `hfMult`'s
value), this composes with L1's context model without any interaction to
account for.

**Custom per-frequency quant weight tables.** `getDCTQuantWeights`'s
output scales *uniformly* with the first element of its `params` array
(`bands[0]`): every other band is a running product
`bands[i] = bands[i-1] * quantMult(params[i])`, and `_interpolate`'s
`a * (b/a)^frac` is scale-invariant in `frac`, so multiplying `params[0]`
by a constant `K` multiplies the entire interpolated weight table output
by `K`. This gives a quantization fineness knob (`VardctL0Config.acScale`)
with no format-imposed ceiling, unlike `globalScale`. The bitstream cost
is `quant_all_default = false` plus one `TransformMode.dct`-encoded
custom table for parameter slot 0 (the only slot this encoder's transform
type, DCT8x8, ever uses) and `TransformMode.library` (0 further bits
each) for the other 16 slots — `TransformType.validateIndex` only
enforces index restrictions for modes other than `library`/`dct`/`raw`,
so slot 0 with `TransformMode.dct` needs no special-casing.
`_readDCTParams` multiplies the first read F16 value by 64 on decode, so
the encoder must write `params[0] / 64.0`, not `params[0]`, in that slot.
This needed `BitWriter.writeF16` (new — a mirror of `BitReader.readF16`;
IEEE-754-like half precision, round-toward-zero on the mantissa, no
subnormal support since this encoder's parameter values never need it).
Removing `globalScale`'s ceiling this way took RMSE from a hard plateau
around distance 0.5-0.8 to fully monotonic down to distance 0.05 in
testing (RMSE 1.9 at that point, vs. the ~15.5 plateau L1 had).

**Chroma-from-luma.** Implemented as a single **global** (whole-image)
linear fit rather than the spec's per-64x64-region granularity
(`xFromY`/`bFromY` in `HfMetadata` still write 0 everywhere — a
deliberate scope cut). `_globalChromaFromLuma` computes the
least-squares-optimal slopes (`kX = sum(Y*X)/sum(Y*Y)`, `kB =
sum(Y*B)/sum(Y*Y)`) over every block's **AC-only** DCT coefficients
(excluding DC) across the whole image, then writes them as a custom
(non-default) `LfChannelCorrelation` (`baseCorrelationX`/
`baseCorrelationB`, with `colorFactor`/`xFactorLF`/`bFactorLF` left at
their neutral defaults so the per-region offset terms are exactly zero
and the global slopes apply everywhere, both DC and HF). Including DC in
the least-squares fit was tried first and made a smooth-gradient test
case measurably *worse* (RMSE 1.06 vs. 0.62 without adaptive
quantization's help) — DC's much larger magnitude dominates the sum and
pulls the fitted slope away from what's optimal for the AC coefficients
that determine banding, so DC is excluded from the fit even though the
resulting global `kX`/`kB` still gets applied to DC too (there's only one
frame-wide correlation value available without per-region granularity).
This is a real, measured net win on non-gradient content (e.g. one mixed
synthetic test case dropped from RMSE 16.4 to 15.5 and shrank ~6% at the
same distance) even without per-region adaptivity.

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
