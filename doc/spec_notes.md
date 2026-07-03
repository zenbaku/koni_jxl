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

### Lossy (VarDCT) encoder — L3: filters and variable transform size

Both L3 additions are implemented, verified end-to-end against djxl
(bitstream decodes correctly in every configuration tested), and **off
by default** — both are real capabilities that help smooth/photographic
content but were measured to regress manga's dominant content types
(screentone, line art), so neither is a net win for this project's
primary use case without further tuning. This mirrors the shape of
several L1/L2 bugs: every configuration produces a valid,
djxl-decodable file with no crash or gate failure, so the "should this
be on by default" question can only be answered by measuring RMSE/size,
never by a thrown exception.

**Filters** (`VardctL0Config.enableFilters`). `RestorationFilter`'s own
library defaults are `gab = true` (Gaborish deringing) and 2 EPF
(edge-preserving filter) iterations; L0-L2 wrote `all_default = false`
with every sub-field explicit and off. Turning them on needs no encoder
compensation — `_writeVardctFrameHeader` just writes the library
defaults for `gab`/`customGab`/`epfIterations`/`epfSharpCustom`/
`epfWeightCustom`/`epfSigmaCustom` instead of the all-off values (4 extra
header bits total). Measured on 256x256 synthetic content at `distance =
1.0`: gradient RMSE 0.742→0.672, photoish RMSE 1.762→1.683 (both
improved, as expected — these filters exist to reduce exactly the
blocking/ringing quantization introduces); screentone RMSE 1.786→23.412,
line art RMSE 1.275→17.026 (both ~13x *worse* — Gaborish/EPF are
smoothing filters, and screentone dot patterns / high-contrast line
edges are made of exactly the sharp, regular high-frequency detail they
blur). Given manga is this project's primary use case, filters default
off.

**Variable transform size** (`VardctL0Config.enableVariableTransforms`).
Adaptively chooses one 16x16 DCT instead of four separate 8x8 DCTs per
aligned 16x16 pixel region. This is the most cross-cutting change in the
encoder so far — every subsystem that assumed "one 8x8 block per grid
cell" needed generalizing:

- **Placement is the wire format, not just bookkeeping.** HfMetadata's
  block list is a flat sequence that the decoder places greedily,
  row-major, at the first free cell (`hf_metadata.dart`'s `_placeBlock`);
  a 16x16 block consumes a 2x2-block footprint in one list entry. The
  encoder must decide the *entire* layout up front and then walk the
  block grid in the same raster-scan-with-skip order the decoder would
  reconstruct, emitting one list entry per placed block (`_PlacedBlock`
  in `vardct_l0_encoder.dart`). 16x16 blocks are only started at
  globally-even block coordinates, which turns out to guarantee they
  never straddle a 32-block-aligned group boundary — one less interlocking
  constraint to handle explicitly.
- **A hidden decoder-side field-width dependency.** `HfMetadata.read`
  sizes the `nbBlocks - 1` field from `ceilLog2(bh * bw)` — the LfGroup's
  *full* block-grid size — not from `nbBlocks` itself, since the decoder
  doesn't know `nbBlocks` until after this exact read. This project's own
  encoder code initially (wrongly) used `ceilLog2(nbBlocks)`, which is
  numerically smaller whenever any 16x16 blocks are placed and silently
  desyncs every bit read afterward — caught immediately by the small
  test suite (`stream uses global tree but no global tree exists`, a
  downstream symptom of the desync) rather than by any check in this
  specific field, since both are valid-looking bit counts.
- **DC/LLF inversion for 16x16 blocks.** DC/LF is always coded at native
  8x8-cell granularity, regardless of the HF transform covering it. On
  decode, a 16x16 block's top-left 2x2 "LLF" coefficient corner comes
  from a *forward* 2x2 DCT of its four underlying 8x8-cell DC values,
  scaled by `TransformType.llfScale` (`hf_coefficients.dart`'s
  `_finalizeLLF`) — those 4 positions are never read as AC tokens at all.
  The encoder must invert this: compute the true 16x16 DCT's own LLF
  corner, divide out `llfScale`, then solve for the four DC-plane values
  that will reproduce it — an *exact* algebraic inversion (verified by
  direct substitution), not an approximation: the forward 2x2 DCT reduces
  to a 1/4-scaled Hadamard-like transform, `C[k] = (P00±P01±P10±P11)/4`
  for each sign pattern, and inverting it is the same sign-pattern sum
  without the 1/4 (a self-inverse structure).
- **Per-transform-type context/order state.** Block context depends on
  `orderID` (8x8 is orderID 0, 16x16 is orderID 2 — different values from
  `HfBlockContext`'s default 39-entry cluster map, so 8x8 and 16x16
  blocks use *different* context clusters even for corresponding
  channels), and natural order/weight-table/`numBlocks`-bucketing
  (`HfCoefficients.getCoefficientContext`'s internal `nonZeroes ~/
  numBlocks` and `k ~/ numBlocks` normalization) all vary by type. All of
  this reuses the decoder's own `TransformType` objects
  (`TransformType.byType(4)` for 16x16) rather than hand-deriving
  constants like `orderID`/`parameterIndex`/`llfScale` — the same
  "reuse, don't reimplement" approach already used for
  `getDCTQuantWeights`/`getNaturalOrder`, extended to the whole
  `TransformType` object this time, specifically to avoid a repeat of
  the `nbBlocks` field-width mistake above.

The selection heuristic (`_should16x16`) is a rough proxy — sum of
log-scaled above-threshold coefficient magnitudes, comparing one 16x16
DCT of a Y-channel patch against four independent 8x8 DCTs of the same
patch — evaluated before any real quantization or entropy coding
happens. This proxy **does not match real end-to-end cost**: on a
256x256 screentone test pattern it picked 16x16 for 100% of eligible
regions, yet the actual djxl-verified output was both larger (24761 vs
20681 bytes) and worse RMSE (1.845 vs 1.786) than plain 8x8; line art
was similarly worse (18901 vs 14398 bytes, +31%) despite the proxy
picking 16x16 only ~50% of the time there. Smooth photographic content
did benefit as expected (~4% smaller at matched RMSE). The gap is that
the proxy has no visibility into the *entropy coder's* context modeling
— `getPredictedNonZeroes` predicts each block's non-zero count from its
already-decoded neighbors, which works better with more numerous,
correlated small blocks than fewer large ones, and a large DCT applied
across a sharp discontinuity (a screentone dot edge, a line-art stroke)
spreads Gibbs-phenomenon ringing across proportionally more frequency
bins than a small one does — a bit-magnitude proxy computed pre-entropy-
coding can't see either effect. A higher-fidelity per-region decision
(e.g. actually assembling both candidates' real bytes and keeping the
smaller, mirroring `_chooseAcClustering`'s "estimates can't resolve
near-ties, verify by real assembly" rule) is the natural next step if
this is revisited, rather than a better closed-form proxy. Given manga
is this project's primary use case, variable transforms default off.

### Lossy (VarDCT) encoder — per-region chroma-from-luma

Upgrades L2's global-only chroma-from-luma fit to the spec's real
per-64x64-region granularity, and — unlike filters/variable-transforms —
is a genuine, on-by-default win: it only ever adds precision the global
fit didn't have, at a small, mostly-self-limiting bit cost (see below).

**Two separate correlation values, only one of which varies per region.**
`LfChannelCorrelation` has exactly one pair of per-frame fields for DC/LF
(`xFactorLF`/`bFactorLF`, read once, applied to every DC value uniformly
— `lf_coefficients.dart`) and a *separate* per-64x64-region pair for HF/AC
(`HfMetadata`'s `xFromY`/`bFromY`, one integer per region — read once per
LfGroup, applied in `hf_coefficients.dart`'s `_chromaFromLuma`). Both are
offsets from the same `baseCorrelationX`/`baseCorrelationB` "center"
values scaled by `colorFactor`, but they're otherwise independent: this
encoder keeps `xFactorLF`/`bFactorLF` at their neutral value (128, an
offset of 0) as before, so DC/LF always uses exactly the whole-image
global fit, and only writes real per-region deltas into `xFromY`/`bFromY`.

**Confirmed no double-counting with the LLF corner, by call order.**
`HfCoefficients.decode` calls `_chromaFromLuma()` *before*
`_finalizeLLF()`. At the time `_chromaFromLuma` runs, a block's LLF/DC
coefficient positions are still zero (AC token decoding never touches
them), so its per-region correction there is a no-op (`0 += kX_region *
0`), and `_finalizeLLF` immediately overwrites those same positions with
the true DC-derived value afterward. So the per-region delta only ever
has a real effect on true AC coefficients — this confirms (rather than
assumes) that `_PlacedBlock.computeAndQuantize`'s 16x16 LLF-corner
inversion should keep using the *global* fit for the LLF corner while
every other (true AC) position in the same block uses that block's own
region's fit; this was verified by reading the exact call sequence before
writing any code, not inferred from matching test output.

**One combined pass, not two.** The per-region fit is computed in the
same forward-DCT sweep that produces the global fit (`_chromaFromLumaFit`,
replacing the former `_globalChromaFromLuma`) — the global sums are just
the region sums added together — so this added no measurable encode-time
regression (1064x1600 synthetic: 1611ms before, 1631ms after). A region
with too little AC energy to fit reliably (`sumYY < 1e-6`) falls back to
the global slope, which costs nothing (rounds to a `0` delta, the
cheapest symbol in the trivial modular stream).

**Measured trade-off.** On synthetic content with genuinely different
color relationships in different regions (a reddish left half, a bluish
right half, both textured), per-region CfL improved RMSE ~26% (3.261 →
2.403) at essentially the same file size (13632 → 13588 bytes) versus the
prior global-only fit. On content with no real regional color variation
(a checkerboard of unrelated gradient/noise/ramp patterns, deliberately
adversarial), it cost ~1% more bytes (47633 → 48160) for a negligible
RMSE change — the per-region deltas there are fitting genuine but
not-worth-encoding local differences, since a region's few encoded
symbols cost more than the marginal quality they buy on this specific
synthetic stress test. Real images almost always have at least some
regional color structure (distinct panels, subjects, backgrounds), so
this is kept on by default rather than gated like L3's two additions —
the potential downside is much smaller (~1% vs. 13-31%) and the upside is
larger and more broadly applicable.

### Lossy (VarDCT) encoder — multi-LF-group support

Removes the 2048x2048 ceiling by splitting images of any size into
multiple LF groups (`frame.dart`'s `header.lfGroupDim`, `groupDim << 3` =
2048px, hardcoded `groupDim` = 256 for VarDCT — this project's encoder
never varies either). The key research finding that made this a small
change rather than a large one: **the AC entropy coding path needed zero
modifications.**

**Groups are already numbered independent of LF groups.** `frame.dart`'s
`numGroups`/`groupRowStride` are computed purely from the *frame's*
dimensions (`ceilDiv(boundsWidth, groupDim)` etc.), with no reference to
LF groups at all; a group's owning LF group is a derived, secondary fact
(`getLFGroupForGroup`). This project's `_computeGroupTokens` already used
purely global (whole-image) group/block coordinates throughout — it never
needed to know about LF groups to begin with, so multi-LF-group support
required no changes there.

**Confirmed algebraically, not assumed, that HfMetadata's LF-group-local
block coordinates don't change the group-relative math.** `HfCoefficients`
computes `groupY = posY - groupPosY` where `posY = meta.blockY[i]` is
LF-group-*local* (`HfMetadata`'s own block positions are relative to its
owning LF group's origin) and `groupPosY = frame.groupPosInLFGroup(...)`
is the group's position *within* its LF group. Substituting definitions:
`groupY = (globalBlockY - lfGroupOriginY) - (groupGlobalOriginY -
lfGroupOriginY) = globalBlockY - groupGlobalOriginY` — the LF-group-local
indirection cancels exactly, leaving the same formula this project's
`_computeGroupTokens` already used with purely global coordinates. This
was verified by writing out the substitution before touching any code,
not inferred from test results passing.

**Blocks never straddle an LF group boundary,** by the same argument
already used for the 32-block group boundary (see the L3 write-up above):
LF groups are 256 blocks (even), 16x16 blocks only start at globally-even
coordinates with a 2-block footprint, and a footprint starting at an even
position can never straddle an even-aligned boundary. Consequently,
filtering the *global* placed-block list down to one LF group's blocks —
in the same relative order — reproduces exactly the raster-scan-with-skip
order that LF group's own independent placement decoding expects. No
separate per-LF-group placement pass was needed; the existing whole-image
layout decision (`_should16x16`, unchanged) is simply partitioned by LF
group afterward.

**What actually needed new code:** splitting the whole-image DC (LF)
plane and per-region chroma-from-luma fit into per-LF-group slices
(`_assembleLfGroupSection`, extracting each LF group's own rectangular
sub-array from the whole-image `dcInt` and `_ChromaFromLumaFit`'s
`kXRegion`/`kBRegion` via an origin offset — region boundaries always
align with LF group boundaries, both being multiples of 8 blocks), and
restructuring the TOC/section assembly to match `frame.dart`'s exact
layout: LfGlobal, one section per LF group, HfGlobal+passes, then one
PassGroup section per group (`1 + numLfGroups + 1 + numGroups` sections
when not using the single-section shortcut, which now additionally
requires `numLfGroups == 1`, not just `numGroups == 1`). `LfGlobal`
(`baseCorrelationX`/`B`, `globalScale`, `quantLF`, quant weight tables)
all stay genuinely frame-wide, read once regardless of LF group count —
only `HfMetadata`'s per-region `xFromY`/`bFromY` varies by LF group, since
that's the only field the format itself scopes to the LF group's own
correlation-region grid rather than the whole frame.

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
