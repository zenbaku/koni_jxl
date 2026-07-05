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

### Lossy (VarDCT) encoder — L4: API, arbitrary dimensions, gates, benchmark

**Arbitrary width/height, not just multiples of 8.** VarDCT always
operates on an 8-pixel-block-aligned canvas internally regardless of the
frame's *true* dimensions — confirmed by `writeImageHeader`'s
`SizeHeader`, which already writes an arbitrary width/height independent
of any block alignment (the `div8` shortcut is purely a smaller encoding
for the common case, not a format requirement) and by the decoder's
`paddedFrameSize` rounding up internally then cropping the output buffer
at the end. `encodeLossyVardctL0` previously required exact 8-alignment
purely as an implementation simplification (its own pixel/plane arrays
were sized to the true dimensions with no separate "padded" concept).
Fixed by allocating the XYB planes at the padded size and edge-replicating
the last true row/column into the padding (rather than a black/zero fill,
which would introduce a sharp, bit-costly edge right at the padding
boundary), while continuing to write the *true* width/height to the image
header — exactly how real-world JPEG XL files (almost never exactly
block-aligned) already work on the decode side. Verified against the
corpus's `odd_*` goldens (down to a 1x1 image) as well as hand-written
sizes in `vardct_l0_test.dart`.

**Real-corpus lossy gate** (`test/encode/encoder_lossy_corpus_test.dart`).
`_d0_` (distance 0) goldens are lossless cjxl re-encodes, so their pixels
are the exact original source; re-encoding those same pixels lossily at a
few distances and checking both this decoder and djxl accept the result
(within a generous RMSE bound) exercises real (if still synthetic —
`manga_samples/`'s real content can never be used for repo fixtures)
image statistics that hand-written test patterns don't necessarily cover,
complementing `vardct_l0_test.dart`'s gradient/screentone/line-art cases.
Grayscale goldens are replicated to RGB (this encoder is RGB-only) purely
for test coverage of the corpus's non-block-aligned `odd_*` sizes.

**`tool/bench_lossy_vs_cjxl.dart`**: matches `distance` between this
encoder and `cjxl`, decodes both through `djxl`, and reports size/RMSE/
time. Honest result: at every distance tried (0.5-8.0) on both corpus RGB
sources, this encoder produces files **1.5-5x larger** than even
`cjxl -e1` (its fastest, least-optimized mode) — the RMSE is often
comparable or better at the same nominal distance (this encoder's
`distance`-to-quantizer curve isn't calibrated to match cjxl's specific
curve — see `VardctL0Config.fromDistance`'s doc comment — so a lower
apparent RMSE at the same `distance` value doesn't mean better
compression efficiency at matched quality). The gap is expected and
matches what's actually implemented: no rate-distortion search (every
quantization/CfL/transform-size decision here is a cheap heuristic, not
an optimize-over-real-bytes search) and only 2 of the format's 27
transform types. This is now a concrete, reproducible number instead of
an assumption — worth re-running after any future work on transform
selection or RD search to see whether it actually closes the gap.

### Lossy (VarDCT) encoder — compression efficiency: DC gradient prediction

The first (and by far largest) fix found by instrumenting
`tool/bench_lossy_vs_cjxl.dart`'s gap with a per-section byte breakdown
(`jxl.encdebug`'s new `lfGroup: dc=... meta=...` line): **DC (LF)
coefficients alone accounted for more than half this encoder's total
output size** on real photo content (127697 of 235904 bytes, 54%, on the
corpus's `color_cover` at `distance = 0.5`) — more than the AC
coefficients, which is where essentially all of this project's tuning
effort had gone. The cause: every prior phase (L0-L4) wrote DC through
`_writeTrivialModularStream`'s single-leaf, predictor-0 ("Zero", i.e. no
prediction at all) MA tree — every DC value was entropy-coded as an
independent symbol through one shared histogram, with none of the strong
block-to-block spatial correlation real image content has (neighboring
8x8 blocks rarely differ much in average brightness/color) being
exploited at all.

**Fix**: `_gradientResiduals` computes predictor 5 (clamped gradient:
`clamp(w + n - nw, min(w, n), max(w, n))`) residuals for each DC channel
before entropy coding, and `_writeLfCoefficients` writes predictor 5 (not
0) in the MA tree leaf. This predictor was not written from scratch: it's
the *exact* formula `modular/modular_channel.dart`'s decode-side
`prediction(y, x, 5)` already implements (verified position-by-position,
including all four x=0/y=0 edge-case combinations, against `_west`/
`_north`/`_northWest`'s exact fallback behavior before writing any code)
and the same one `encoder.dart`'s lossless `_tileResiduals` already uses
and gates bit-exact against djxl — so this carried no risk of a new,
unverified decode-side assumption. The context/entropy model itself is
still a single shared histogram per DC channel (no per-pixel property
tree, unlike the lossless encoder's `learnContextTree`) — the predictor
alone removes the bulk of the redundancy; a context tree remains a
possible follow-up (see below) but wasn't needed to capture the bulk of
this win.

**Measured effect**: on `color_cover` at distance 0.5, DC dropped
127697 → 64623 bytes (49%), and *total file size* dropped 235904 → 172830
bytes (27%). On `palette16` at distance 0.5, DC dropped 20833 → 5259
bytes (75%), total 61057 → 45483 (25%). Against `cjxl -e1` at matched
distance, the size ratio improved from 2.17-4.88x down to 1.59-2.79x on
`color_cover`, and from 1.55-2.34x down to 1.16-1.52x on `palette16` (see
`tool/bench_lossy_vs_cjxl.dart`) — roughly halving the gap with a single,
narrowly-scoped, already-decoder-verified change. `HfMetadata`'s other
channels (`xFromY`/`bFromY`, `blockInfo`, `sharpness`) were left on
predictor 0: they're a much smaller absolute contribution (11-14KB vs.
DC's 40-130KB in the same files) and mostly near-constant (block type is
always 0 with variable transforms off; sharpness is always 0), so a flat
histogram already compresses them well — not the next priority.

**What's next for compression efficiency** (in rough order of expected
impact, least risky first): a real per-pixel context tree for DC
(spatial-correlation-aware context splitting, mirroring the lossless
encoder's `learnContextTree`, could extract more from the *residual*
distribution than a single shared histogram does); a similar
gradient-style predictor for `blockInfo`'s `hfMult` row specifically
(spatially correlated but a much smaller absolute win than DC was); and,
on the AC side (now the dominant term again post-fix), replacing the
crude 3-bucket adaptive-quantization heuristic and the cheap bit-cost
transform-size proxy (see the L3 write-up above) with something closer
to real rate-distortion search — the largest remaining lever, and the
most implementation work.

### Lossy (VarDCT) encoder — compression efficiency: weighted predictor for DC

Follow-up to the gradient-prediction fix above: `_writeLfCoefficients`
now tries predictor 6 (the self-correcting weighted predictor, "WP") in
addition to predictor 5 (clamped gradient) for all three DC channels
together, and keeps whichever assembles smaller real bytes — the exact
same "try gradient and WP, keep the smaller actual output" pattern
`encoder.dart`'s lossless `bestForPredictor` already uses. `wpTileResiduals`
(`encode/wp_predictor.dart`) already existed as a decoder-verified,
directly-callable forward mirror of predictor 6's decode-side state
machine (built for the lossless encoder), so this needed no new
prediction logic — only wiring it up as a second candidate alongside the
existing gradient path, with the winner decided by two cheap probe writes
(`BitWriter.bitsWritten`, no `toBytes()` side effects) before the real one.

**Measured effect**: content-dependent, as expected (this mirrors the
lossless encoder's own experience — WP tends to win on photographic/
tonal content, gradient on flatter or line-art-like content). On
`color_cover` (a real photo) WP wins and shaves a further ~5% off the
already-fixed size (172830 → 164230 bytes at distance 0.5, cutting the
`cjxl -e1` ratio from 1.59x to 1.51x); on `palette16` (a low-color-count
synthetic image) gradient already wins and WP never gets chosen, so the
output is byte-identical to the gradient-only version. Since the choice
is "try both, keep smaller," there's no downside case — output can only
get smaller or stay the same, never worse — so no size-based regression
test was added for this specifically (a synthetic test pattern that
reliably shows WP's win by more than ~1% wasn't easy to construct by
hand; the real-corpus gate exercises this path's *correctness* already,
which is what would actually break if this regressed).

### Lossy (VarDCT) encoder — investigated but not changed: adaptive-quant heuristic tuning

After the two DC fixes above, re-measuring the per-section byte
breakdown on `color_cover` showed AC coefficients are again clearly the
dominant term (57% of total at distance 0.5, DC down to 34%) — so the
next investigation targeted the adaptive per-block quantization
heuristic (`hfMult`'s 3-bucket `relEnergy<1.0→4, <4.0→2, else 1`
threshold, from L2), on the theory that a heuristic tuned specifically to
prevent banding on smooth *gradients* might be over-triggering (spending
extra bits) on general photographic content that doesn't have the same
banding risk.

**What was tried, empirically, without changing any shipped code**:
disabling the boost entirely (`hfMult` forced to 1 always) on
`color_cover` at distance 1.0 dropped size from 133295 → 114580 bytes
while RMSE only rose 1.78 → 2.10 (still better than `cjxl -e1`'s 2.70 at
that distance) — confirming the heuristic *is* spending real bits on this
content for a quality margin beyond what's needed to match cjxl's own
apparent target quality at that label. A narrower 2-bucket version
(`relEnergy<1.0→4, else 1`, dropping the middle `2x` bucket) landed
in between (119141 bytes, RMSE 2.06) — not a clear improvement over
either extreme, and it pushed the smooth-gradient regression test's RMSE
from a comfortable margin under 1.0 up to 0.940, uncomfortably close to
that threshold. Separately, reducing `acScale` alone (coarsening AC
quantization uniformly, independent of the adaptive heuristic) showed
strongly diminishing returns: even a 70% reduction in fineness
(`acScale * 0.3`) only cut size by 21% while RMSE was still better than
`cjxl -e1`'s — the gap isn't fixable by just "quantize coarser" either.

**Why nothing shipped from this**: every variant tried is a different
point on roughly the same rate-distortion curve, not a strictly better
one — the *shape* of the curve is what would need to improve, which
means the fix is a real per-block cost/benefit heuristic (does this
block's specific content actually risk visible banding at the baseline
step, weighed against its bit cost) or an actual rate-distortion search,
not a threshold tweak. The current 3-bucket heuristic stays as-is: it's
verified to fix the specific banding case it was built for
(`vardct_l0_test.dart`'s smooth-gradient RMSE-under-1.0 gate), and
none of the alternatives tried were unambiguously better across both
that case and general photo content. This is recorded here specifically
so a future attempt doesn't have to rediscover it — the real fix belongs
with a genuine RD search (see the L3 write-up above), not another
threshold adjustment.

### Lossy (VarDCT) encoder — a genuine RD search for hfMult, and why it's still off

Following through on the previous section's conclusion, this implements
an actual per-block rate-distortion (RD) search replacing the 3-bucket
`hfMult` heuristic — scoped, designed, and reviewed via two independent
research agents before any code was written (the scoping document is
this feature's real design rationale; summarized here). The RD machinery
is implemented, unit-tested, and djxl-verified correct in every
configuration tried — but calibration found no single global trade-off
constant that both beats the heuristic on real photo content *and*
preserves the heuristic's own smooth-gradient banding protection. This
is the "honest failure mode" the scoping explicitly planned for, not an
oversight: `VardctL0Config.enableRdHfMult` stays off by default,
documented here so the infrastructure isn't wasted and a future
attempt starts from the actual finding instead of re-deriving it.

**One grounding fact made the design tractable.**
`HfCoefficients.getBlockContext` only lets `hfMult` shift which context
cluster a token routes to via `HfBlockContext.qfThresholds`, which this
encoder's always-used `HfBlockContext.defaults()` leaves empty — so
`hfMult` never changes which histogram a block's tokens land in, only
what values land there. This means candidates can be scored against a
single, shared, frozen Huffman code-length table without a chicken-and-
egg problem: build a real `_AcClustering` from a bootstrap pass (the
heuristic's own already-committed choices), extract a real per-cluster
code-length table (`EntropyCodes.tokenBitLengths()`, a new accessor
reusing the exact same `huffmanLengths()` call `estimatedBits()` already
uses — unit-tested to reproduce `estimatedBits()`'s internal computation
exactly), and freeze both that table and the non-zero-count prediction
grid (`_computeGroupTokens`'s `predictedOut`) for scoring every
candidate afterward.

**Distortion**: weighted squared error using the existing `rawWeight`
per-frequency table (`_PlacedBlock.quantizeCandidate`) — no new table,
weights error exactly where quantization already considers a coefficient
perceptually important. **Rate**: `codeLength[cluster][token]` (from the
frozen bootstrap table) `+ exactExtraBits` (`tokenizeHybrid`'s closed-form
suffix-bit count — no table needed) per token, summed over a block's
non-zero-count and coefficient tokens (`_blockRate`). **Cost**:
`distortion + lambda * rate`, `lambda = kLambda * refStep^2` (standard
scalar-quantizer RD theory — the trade-off's slope near a step size
scales with `step^2`).

**Calibration (`tool/calibrate_rd_lambda.dart`) found a real, informative
negative result, not a bug.** An early sanity sweep of `kLambda ∈
[0.02, 10]` (the range a superficial reading of the `lambda = kLambda *
refStep^2` formula might suggest) showed *zero* observable effect —
`refStep` is tiny in this encoder's units (~0.0018 at `distance = 1.0`,
so `refStep^2 ≈ 3e-6`) while `distortion`/`rate` are both O(1)-to-O(100),
so `lambda * rate` stayed negligible regardless of `kLambda` in that
range; the real sweep needed `kLambda` in the thousands (confirmed
correct-by-construction once found: sweeping 100-100000 produced the
expected monotonic size/RMSE trade-off). With the right range:

- `kLambda ≈ 12000`: beats the heuristic on `color_cover` at
  `distance = 1.0` on *both* axes simultaneously (129607 vs 133295 bytes,
  RMSE 1.762 vs 1.805) — a genuine, non-marginal win on real photo
  content.
- The *same* `kLambda ≈ 12000` pushes the smooth-gradient banding test's
  RMSE to 0.946 — the same uncomfortable-near-miss territory a prior,
  much cruder threshold tweak hit (0.940), this time from a supposedly
  more principled mechanism.
- `kLambda ≈ 500` keeps the gradient test comfortably safe (RMSE 0.615)
  but makes `color_cover` 44.5% *larger* than the heuristic — not a win,
  a straightforward quality-for-size trade in the wrong direction for a
  compression-efficiency feature.
- No value in between (1000-8000 tested) beats the heuristic on
  `color_cover` while keeping gradient RMSE comfortably under 1.0 —
  every value is a different point on roughly one curve, exactly the
  same shape of outcome the earlier threshold-tuning investigation found,
  just shifted.

**Root cause, confirmed by direct measurement (`jxl.encdebug`'s hfMult
histogram), not inferred.** At `kLambda = 500` (gradient-safe), the
gradient image's 1024 blocks split `{1: 32, 2: 256, 4: 736}` — mostly the
heuristic's own aggressive `4x` banding protection. At `kLambda = 12000`
(photo-favorable), the *same* image's blocks split `{1: 320, 2: 544, 4:
160}` — the RD search actively *removes* most of that protection,
because weighted-squared-error judges the absolute distortion a near-
zero-AC-energy block saves by boosting as not worth the bit cost, even
though banding is far more perceptually objectionable than its raw MSE
contribution suggests. This is a real modeling gap: weighted MSE (or any
plain per-pixel error metric) structurally cannot see banding sensitivity
the way a real perceptual metric (butteraugli-class, well out of scope
here) or an explicit banding-aware distortion term would. Closing this
gap needs a better *model*, not a better constant — re-sweeping `kLambda`
further would not help, and isn't worth repeating without first changing
the distortion metric itself.

**What's shipped despite the negative result**: `EntropyCodes.
tokenBitLengths()` (correctness-verified, independently useful for any
future per-block rate-estimation work), the full RD-search machinery
behind `VardctL0Config.enableRdHfMult` (default `false`, `_kRdLambda =
3000.0` as a documented, not-fully-satisfactory placeholder for anyone
experimenting), and `tool/calibrate_rd_lambda.dart` for re-running this
analysis after any future model change. Correctness (djxl round-trip) is
verified for the opt-in path across single-group, multi-group, multi-LF-
group and 16x16-block-mixed configurations
(`vardct_l0_test.dart`'s "RD hfMult search (opt-in) decodes correctly").

**Follow-up: a multi-distance sweep (ROADMAP.md's open question — does
`_kRdLambda` share RDOQ's old, buggy `refStep^2`-scaling bug?), including
a confound found and corrected mid-investigation.** All of the above was
only ever measured at `distance=1.0`; `tool/calibrate_rd_lambda.dart` now
sweeps 0.5-8.0.

*First pass (confounded, not trustworthy — kept here as a process
lesson).* Run with the encoder's actual defaults
(`enableVariableTransforms: true`), every `kLambda` from 500 to 20000
landed at an *identical* gradient RMSE of 2.075 by `distance=8.0` — a
~56% regression over the heuristic's own baseline there (1.333), with
zero sensitivity to `kLambda`. That zero-sensitivity was itself the tell:
`jxl.encdebug`'s histogram showed the *committed* 16x16 layout at that
distance has essentially no AC left (`bestBytes=2`), so every hfMult
candidate scores near-identically and the tiebreak trivially picks the
same one — an artifact of variable-transform layout selection on coarse
gradients, not a property of the hfMult search itself. An advisor review
caught this before it shipped as a conclusion (the tool's own first
doc-comment draft claimed "no scaling bug, `acScale^2` wouldn't help" —
without ever testing `acScale^2`, and using confounded data to boot).

*Isolated re-run (`enableVariableTransforms: false`), the trustworthy
data.* Real, non-degenerate signal: `distance=1.0`'s gradient-safe
`kLambda=500` (RMSE 0.615 vs. the heuristic's 0.938) degrades
monotonically as distance grows — 1.009 at `distance=2.0` (heuristic:
0.992, already past it), 1.385 at `distance=4.0` (heuristic: 1.043),
1.882 at `distance=8.0` (heuristic: 1.513). A real, RDOQ-like
distance-dependent regression, confirmed independent of the transform
confound.

*Does `acScale^2` fix it, like it fixed RDOQ's version of this problem?
Partially — measured, not assumed.* A one-off patch to `_chooseHfMultRd`
swapping `kLambda * refStep * refStep` for `kLambda * acScale * acScale`
(not shipped — a temporary, reverted diagnostic edit; see
`tool/calibrate_rd_lambda.dart`'s module doc for what to change to
reproduce). The two formulas coincide exactly at `distance=1.0` by
construction (`acScale=1` there), so the fair comparison is the actual
shipped constant, `refStep^2` at `kLambda=3000` (`_kRdLambda`'s value),
against its `distance=1.0`-equivalent `acScale^2` counterpart,
`kLambda≈0.01` — both give identical output at `distance=1.0`, confirming
they're really the same operating point before distance moves:

| distance | heuristic RMSE | `refStep^2` (kLambda=3000) | `acScale^2` (kLambda≈0.01) |
|---|---|---|---|
| 1.0 | 0.938 | 0.935 | 0.935 |
| 2.0 | 0.992 | 1.119 | 1.007 |
| 4.0 | 1.043 | 1.666 | 1.045 |
| 8.0 | 1.513 | 2.246 | 1.513 |

At `distance>=4.0`, `acScale^2` lands within noise of the heuristic
baseline instead of 48-60% over it (+60% at `distance=4.0`, +48% at
`distance=8.0` for `refStep^2`) — a genuinely better-matched scaling
for this search's distortion metric, not a dead end. This directly
contradicts this file's (and the tool's) own first-draft conclusion that
"no rescaling would help" — that conclusion was reasoned from the
distortion metric's structure, sounded plausible, and was wrong; only the
isolated measurement caught it.

**What `acScale^2` does *not* fix**: `distance=2.0` is still right at the
gate (1.007), and the core photo-vs-banding trade-off documented above —
no single constant both beats the heuristic on photo content and stays
clearly safe on gradients — is about the distortion metric itself, not
lambda's units, so it survives the rescaling untouched. `enableRdHfMult`
stays off by default either way. **Net guidance for any future attempt**:
start from `acScale^2` scaling (not `refStep^2`), still implement the
banding-aware distortion term this section already calls for, and verify
across the *full* distance range from the start — including checking for
degenerate transform-layout interactions before trusting a flat result
across `kLambda`, the specific mistake this investigation made once.

### Lossy (VarDCT) encoder — compression efficiency: a learned context tree for DC

Follow-up to the two DC prediction fixes above, picked as the smaller,
bounded-scope item over a full AC-side RD search (see that section's
"Next" note). `_writeLfCoefficients` previously wrote DC residuals
through a trivial single-leaf MA tree — one shared histogram for the
whole LF group, all three channels combined (`_writeModularStream`'s
original form). This upgrades it to a real learned context tree
(`encode/context_tree.dart`'s `learnContextTree`/`computeProps`/
`contextFor`/`serializeContextTree`), the exact same machinery the
lossless encoder already uses for its biggest single lever, reused
without modification.

**Why this is legal, verified by reading the decoder source before
writing any code (per the project's established methodology)**:
`lf_coefficients.dart` decodes DC through `ModularStream.read` — the
*same* generic modular-channel decode path lossless images use, per
LF group (`streamIndex: 1 + lfGroupID`), already confirmed independent
per LF group (each carries its own local tree, `use_global_tree =
false`, matching what `_writeLfCoefficients` already did for the
predictor-only version). `modular_channel.dart`'s `_property` (the
MA-tree property evaluator) has cross-channel properties (0 = channel
index, 1 = stream index, and `k >= 16` = other channels' values), but
`gradProperties`/`wpProperties` (`context_tree.dart`) use only the
pure within-channel spatial properties (4-14, plus 15 = WP max-error) —
identical to what the lossless encoder already relies on when it learns
one shared tree across multiple color planes. So a single tree trained
on samples from all three DC channels (Y, X, B) together, exactly
mirroring `encoder.dart`'s `bestForPredictor`, is provably as legal here
as it already is for lossless. `computeProps` also needs *true* pixel
values (not residuals) for its neighbor lookups — matches `dcX`/`dcY`/
`dcB`, which are already true DC values before `_gradientResiduals`/
`wpTileResiduals` are applied.

**Implementation**: `_writeModularStream` gained an optional `tree`/
`contexts` parameter — when given, it calls `serializeContextTree`
instead of hand-writing a single leaf, and routes each channel's values
through `EntropyWriter(tree.contexts)` at the assigned per-pixel context
instead of always context 0. `EntropyWriter` already handles the
cluster-map form transition (simple fixed-width up to 8 contexts,
complex nested-entropy-stream form above it) internally, so no new
cluster-map code was needed. `_writeLfCoefficients` now runs the same
"probe both, keep smaller real bytes" comparison as before, but each
candidate first learns its own tree (trained on *every* pixel of all
three channels — at most 256x256 DC values per channel per LF group, far
under the lossless encoder's 300k-sample stride threshold, so no
subsampling was needed). One subtlety caught before it could corrupt
output: the original code compared two full `BitWriter` probes and
`writeBytes()`'d the winner's `toBytes()` into the real output — safe
only because the probe stream was, incidentally, always byte-unaligned
garbage-free in the single-leaf case. With per-pixel contexts the probe
is genuinely no longer meant to be reused verbatim (`_writeLfCoefficients`
is not byte-aligned within its enclosing section — anything written
after it in the same section would desync if a byte-aligned copy were
spliced in). Fixed by keeping the precomputed tree/contexts/residuals
around and calling `_writeModularStream` a second time directly into the
real `BitWriter`, exactly mirroring the original code's own two-call
probe/commit shape, just with an extra 4-tuple of precomputed state
threaded through instead of relying on `toBytes()`.

**Measured effect (`tool/bench_lossy_vs_cjxl.dart`, extended in the same
change to read grayscale `.pgm` corpus inputs — replicated to RGB, same
pattern `encoder_lossy_corpus_test.dart` already uses — so manga-typical
screentone content could be measured directly, not just the two RGB
goldens)**: on `color_cover` (real photo), 6-9% smaller across every
distance tried, at **exactly identical RMSE** in every case (133295 →
123388 bytes at distance 1.0, RMSE unchanged at 1.80) — a pure
entropy-coding improvement with zero quality cost, since prediction,
quantization and reconstruction are all untouched. On `gray_screentone`
(1536x2200, large manga-like screentone), a smaller but still real 0.3-
0.9% win, also at identical RMSE. On `screentone_256` (a small, clean
synthetic screentone pattern), output was **byte-identical** — the
learned tree found no split worth its header cost and degenerated to a
single leaf, and `serializeContextTree`'s single-leaf output is bit-for-
bit identical to the old hardcoded single-leaf tree, so the two paths
coincide exactly. This self-verifies the "no downside" property: when
there's nothing to gain, the new code doesn't just avoid regressing, it
produces the identical bitstream. The one exception: `palette16` (a
low-color-count synthetic image) saw a tiny ~0.1-0.2% *increase*
(38405 → 38453 bytes at distance 1.0) — the tree did find a marginal
split whose real assembled cost slightly exceeds its estimated training
gain, the same kind of small header-vs-gain miss already documented for
per-cluster overhead elsewhere (see the per-region CfL section above).
Judged an acceptable trade given the real wins on photo/screentone
content, following the same "try harder, keep smaller real bytes"
philosophy — no size-regression gate was added for the same reason as
the WP-for-DC change above (a hand-built synthetic case reliably showing
a >1% win is hard to construct; the real-corpus gate already covers
this path's correctness).

**Cost**: encode time increases meaningfully (roughly 20-60% slower on
the two RGB corpus images, e.g. `color_cover` at distance 1.0: 653ms →
817ms) since each LF group now runs tree-learning and a per-pixel
context-assignment pass for *both* predictor candidates, on top of the
residual computation that already existed. Still comfortably sub-second
per LF group at the sizes tested; no regression test exists for encode
time specifically (per CLAUDE.md's performance-rules doc, the tracked
reference numbers are for the decode path and the lossless encoder, not
yet this newer lossy-encoder work).

### Lossy (VarDCT) encoder — AC-side RDOQ (coefficient dropping), and why it's off despite real wins

Follow-up to round 3's block-level `hfMult` RD search and round 4's DC
context tree — the AC-side rate-distortion search both those sections'
"next" notes pointed at. Implements genuine per-AC-coefficient
rate-distortion-optimized quantization ("RDOQ"): for each block-channel's
already-quantized coefficients, walk backward from the true last-nonzero
scan position toward position 0, proposing to zero any coefficient whose
removal reduces `distortion + lambda * rate`, then only committing the
proposal if a real re-encode confirms it actually shrinks that
block-channel. Implemented in `_chooseAcRdoq`/`_rdoqBlockChannel`/
`_PlacedBlock.applyRdoqDrops` (`vardct_l0_encoder.dart`), behind
`VardctL0Config.enableRdoq` — **off by default**, same outcome as round
3, but for a different and more surprising reason: correctness is fully
verified and there's a genuine, measured win in the specific case
calibration checked — the constant that produces it is simply unsafe
outside that case, discovered only by testing a wider distance range
than the calibration tool covered.

**Algorithm shape, decided before any code was written.** A full
per-block trellis/DP (state = position × remaining-count × prev-flag)
was evaluated and rejected on a back-of-envelope perf estimate: ~60-500x
more coefficient-decision ops than a greedy single-pass alternative for a
2048x2048 image, realistically 0.7-19s of pure DP-transition compute
against a whole-image budget on the order of ~0.4-0.8s. Chose instead a
**greedy, single reverse-scan-order pass** ("coefficient dropping"),
costing about the same order of magnitude as the already-shipped
`_chooseHfMultRd`. Sound for the same reason `_chooseHfMultRd` already
established (re-verified fresh, not assumed): coefficient values, like
`hfMult`, never change which entropy cluster a token routes to in this
encoder's configuration (`HfBlockContext.defaults()` leaves
`qfThresholds` empty), so a bootstrap-then-freeze clustering/code-length
table is sound for scoring candidates.

**Two real bugs found and fixed during design review, before any code
was written** (via two research passes + two design/adversarial-review
passes, mirroring round 3's process): the format mechanic is that a
block-channel's coefficient stream stops the instant `countNonZero`
nonzero values have been emitted (everything after the true last-nonzero
is implicit, free) — dropping the current end-of-block (EOB) coefficient
retreats that boundary, removing every position in the swept gap from
the stream at once. (1) An early draft priced a *second* EOB retreat in
the same walk using a table frozen from the *original* (pre-drop) scan —
provably wrong, since the swept gap's true `remaining` context is always
1 by that point (proven by induction on a `keptCountSoFar == 0`
invariant), not whatever the original scan had there. Fixed by pricing
each retreat's swept gap live instead of from a stale table. (2) Position
0's "prev" bit is a block-global threshold (`remaining >
orderSize/16`), not a sequential dependency on position -1 — freezing it
like every other position's `prev` was needlessly wrong, since position 0
is always the *last* position decided (nothing causally blocks computing
it live). Both fixes shipped in the same commit as the initial
implementation, not as follow-ups.

**A third, larger gap found only empirically, after both bugs above were
already fixed** — this is the most important methodological finding of
this section. A debug-only differential test (comparing the walk's
claimed per-decision rate delta against a real re-scan of the actual
entropy coder, isolating one decision at a time) kept failing by small
but real amounts (1-2 bits) even after both proven-correct fixes above.
Root cause, confirmed by direct trace: dropping **any** coefficient — not
just an EOB retreat — shifts the `remaining` bucket
(`_coeffNumNonzeroCtx`'s coarse thresholds), hence the real bit cost, of
**every surviving lower position**, including ones whose own value never
changes. This walk's formulas only ever price the position(s) directly
flipped by each decision; they never retroactively re-price
already-encoded lower positions each time an earlier drop shifts their
bucket. Exactly accounting for that ripple would mean repricing up to
O(ucoeffLen) positions per drop — reintroducing the O(ucoeffLen²) cost
the whole DP-vs-greedy tradeoff was chosen to avoid. Worse, this isn't
just a diagnostic nitpick: a real test case showed the ripple can flip an
individually-"beneficial-looking" drop into a **net loss** for that
block-channel (one isolated drop, claimed savings +8 bits, real
measured effect −2 bits — i.e. the block-channel's total bits *grew*).
An estimation gap that can reverse sign on a single decision is not
safely ignorable.

**The fix: turn the diagnostic into a real, always-on safety net**,
rather than trying to model the ripple. `_rdoqBlockChannel` now ends by
real-re-encoding the proposed block-channel both before and after
applying its proposed drops (one extra pair of real `_blockChannelTokens`
calls, O(ucoeffLen) total, not per-decision) and only calls
`applyRdoqDrops` if the real total bits actually decreased — the same
"estimates can't resolve near-ties, verify by real assembly, keep the
better one" pattern `_chooseAcClustering` and the lossless encoder's
predictor choice already use elsewhere in this codebase. This makes
RDOQ provably never-worse-than-off **for total bits**, per block-channel,
regardless of any remaining rate-estimation inaccuracy.

**Structural mitigation carried over from round 3's finding**: blocks
with `hfMult == 4` (the L2 heuristic's own strongest banding-protection
signal) are skipped by RDOQ entirely, since RDOQ shares the same
weighted-squared-error distortion metric that already, in round 3's
calibration, proved unable to represent banding perceptual cost. Unlike
`_chooseHfMultRd` (which *was* the protection decision, with no
structural escape hatch), RDOQ is additive and can cheaply defer to the
heuristic's own choice for these blocks.

**Calibration at `distance = 1.0`** (`tool/calibrate_rdoq_lambda.dart`,
mirrors `tool/calibrate_rd_lambda.dart`'s structure): found a genuinely
good constant, `_kRdoqLambda = 5000.0`. On `color_cover` (real photo),
monotonic size wins from -0.5% (`kLambda=500`) to -8.7% (`kLambda=
50000`) with RMSE essentially flat (1.804-1.808) through `kLambda=8000`.
The gradient-banding regression test stayed **safely under its RMSE gate
through `kLambda=20000`** (0.930 baseline — RDOQ has *zero* effect below
`kLambda≈2000` thanks to the `hfMult==4` exclusion — rising only to
0.946 at 20000, only failing at 50000). On real corpus screentone content
(`gray_screentone`, manga-typical), a tiny but real win at negligible
RMSE cost (1159900→1159742 bytes at `kLambda=8000`, RMSE unchanged to 4
decimal places). Two small synthetic patterns (`screentone_256`, and the
tool's own synthetic screentone/line-art sanity checks) saw **zero
effect at every lambda tested** — RDOQ found nothing worth dropping
there, a safe (if unhelpful) outcome for the project's dominant content
type. `palette16` (low-color synthetic) saw a real trade, not a free
win: -1.7% size at `kLambda=5000` for +1.2% RMSE (3.44→3.48) — consistent
with round 4's DC-context-tree finding that this same synthetic image is
the one recurring case where small header/estimation overheads don't pay
for themselves cleanly.

**Why it's still off: the calibrated constant is unsafe outside
`distance = 1.0`, found only by testing a wider range than the
calibration tool covered.** `lambda = kLambda * refStep^2` (the same
scaling convention `_kRdLambda` already uses, chosen because standard
scalar-quantizer RD theory says the rate/distortion trade-off's slope
near a given step size scales with `step^2`) means `lambda` grows
*quadratically* with `refStep`, which itself grows with `distance`
(coarser quantization → larger dequant step). Re-running the standard
benchmark (`tool/bench_lossy_vs_cjxl.dart`) across its full distance
sweep (0.5-8.0), not just the single `distance=1.0` point the
calibration tool checked, surfaced a severe regression at high distance:
on `palette16` at `distance=8.0`, the *identical* `kLambda=5000` that was
safe and beneficial at `distance=1.0` cut size 42% (20135→11670 bytes)
at the cost of **RMSE nearly doubling** (9.00→17.52). A follow-up sweep
at `distance=8.0` showed this isn't a cliff at the calibrated value —
even `kLambda=100` (50x smaller than the calibrated constant) already
measurably degrades quality there (9.00→9.18), climbing steeply from
there (`kLambda=300`: 9.80, `1000`: 11.49, `3000`: 15.23). The real-bits
safety net does not catch this class of regression — it only verifies
rate decreased, not that the resulting distortion stayed acceptable, and
at a large enough `lambda` the walk's own decisions happily trade
significant distortion for a small rate saving, exactly as the
`distortion + lambda*rate` formula says to. This is a real, structural
gap in the `refStep^2`-based scaling for RDOQ specifically (plausibly
because RDOQ's cumulative, many-coefficients-per-block-channel effect
compounds in a way a single per-block `hfMult` choice's bounded 3-way
decision doesn't) — not a constant to keep re-sweeping, and not
something a same-session fix was responsibly rushable given the
stakes of a default-on encoder behavior change.

**What was shipped at the time**: the full RDOQ machinery
(`_scanChannelValues`/`_tokenRate` extracted as reusable helpers,
`_rdoqBlockChannel`'s walk, `_chooseAcRdoq`'s bootstrap, the real-bits
safety net), `VardctL0Config.enableRdoq`/`rdoqLambdaOverride` (default
`false`/`null` at the time), and `tool/calibrate_rdoq_lambda.dart` — all
correctness-verified (djxl round-trips clean across single-group,
multi-group, multi-LF-group, 16x16-mixed, and combined-with-
`enableRdHfMult` configurations; see `vardct_l0_test.dart`'s "RDOQ
coefficient dropping (opt-in) decodes correctly" and "RDOQ can drop
every AC coefficient in a channel"). This section left two concrete
findings for a future attempt rather than a re-derivation: (1) the
real-bits-only safety net needs a distortion-aware companion, or
`_kRdoqLambda` needs a genuinely distance-aware formula; (2) calibrate
and gate-test across the *whole* distance range a user-facing default
must support, not a single representative point. The follow-up below
picked up exactly there, in the very next session.

### Lossy (VarDCT) encoder — AC-side RDOQ, the fix: `lambda ∝ acScale²`, not `refStep²`

Follow-up session, picked up directly from this section's own two open
findings above. Root cause, derived analytically then **verified
empirically before trusting the derivation** (given the previous
section's own lesson about not trusting a derivation alone):

RDOQ's distortion term, `(w*trueVal)² - (w*oldErr)²` (`w` = the
per-frequency `rawWeight`), is dominated for any non-marginal coefficient
by `(w*trueVal)²` — a *removal* cost, not the rounding-noise term the
`lambda ∝ step²` theorem assumes. `w` scales *proportionally* with
`config.acScale` (exact, not approximate — L2's "scaling only the first
band scales the whole interpolated table uniformly" finding, this
session's spec_notes.md), so `distortionDelta ∝ acScale²`. But `refStep
= scaleFactor[1] / rawWeight8[1][0][1] ∝ 1/acScale` (same `w`-dependence,
inverted), so the old `lambda = kLambda * refStep² ∝ 1/acScale²` — the
*opposite* direction from `distortionDelta`. Their ratio,
`lambda/distortionDelta`, scaled as `acScale⁻⁴` — at `distance=8`
(`acScale=0.125`), a **4096×** compounding mismatch relative to
`distance=1`, which is exactly why the same constant that looked perfect
at one point catastrophically over-dropped coefficients at another: with
`lambda` relatively enormous compared to `distortionDelta`, the walk
readily accepted large-distortion drops for trivial rate savings, exactly
as `distortion + lambda*rate < 0` says to do when `lambda` dominates.

**The fix**: `lambda = kLambda * acScale²` instead of `kLambda *
refStep²` (`_chooseAcRdoq`'s `acScale` parameter replaces `refStep`;
`_kRdoqLambda`'s doc comment has the full derivation). This cancels the
dominant `acScale`-dependence in both terms, leaving the trade-off point
governed mainly by coefficient content and rate — not by `distance`.

**Verified, not just derived — and the first attempt at "verified" was
itself wrong in an instructive way.** A probe with the *old* numeric
constant (`kLambda=5000`) plugged into the *new* formula produced
**catastrophic over-dropping at every distance, including `distance=1`**
(RMSE 3.44→34.8, i.e. an order of magnitude worse) — not a regression in
the fix's direction, but a units error: `acScale²=1.0` at `distance=1`
is ~300,000× larger than `refStep²≈3.24e-6` was, so reusing the old
numeric constant with the new formula produced an *enormous* effective
lambda, not a comparable one. Recalibrating the constant's magnitude
(not just its scaling direction) was still required — a small but real
reminder that even a *correct* formula change needs a fresh sweep, not
just a fresh sign.

**Multi-distance calibration** (`tool/calibrate_rdoq_lambda.dart`,
rewritten to sweep `distance ∈ {0.5, 1.0, 2.0, 4.0, 8.0}` — the direct
fix for the previous section's single-point-calibration gap): found
`_kRdoqLambda = 0.03` safe (no regression beyond a small, bounded RMSE
cost) at **every** distance tested, with the benefit shape itself
informative: real, meaningful wins at low-to-mid distance
(`color_cover`: -8.8% at `distance=0.5`, -4.0% at `distance=1.0`,
RMSE +3.3%/flat respectively), shrinking to a small-but-never-regressing
effect at high distance (-0.1% to +0.0% by `distance=4-8`). This shape
makes sense, not just looks safe: at coarse quantization, plain rounding
already zeroes out most marginal AC content before RDOQ gets a chance to
— there's genuinely less for it to do, not a sign the fix is
under-powered. Real corpus screentone content (`gray_screentone`,
manga-typical) saw tiny wins at essentially zero RMSE cost across the
whole range (all five distances tested). `palette16` (the
recurring-across-every-round low-color synthetic edge case) saw its
largest RMSE cost at `distance=0.5` (+6.7%, for -3.5% size) but nothing
worse — bounded, not catastrophic, and consistent with this same
synthetic pattern's role in every prior round's write-up.

**One incidental finding, out of scope for this fix**: the gradient
banding-protection test's *own baseline* (RDOQ entirely off) already
exceeds its RMSE<1.0 gate at `distance ≥ 4` (measured 1.043 at
`distance=4`, 1.513 at `distance=8`) — a pre-existing property of the L2
adaptive-quant heuristic, since the "adaptive quantization reduces
banding" regression test in `vardct_l0_test.dart` has only ever run at
the implicit default `distance=1.0`. RDOQ makes **no measurable
difference** to this pattern at those distances (byte-identical output
across every `kLambda` tested) — the finding is real and worth a note,
but it isn't something this fix caused or could have caught differently;
it's a gap in the *existing* heuristic's own validation coverage,
left for a future session rather than folded into this one's scope.

**Shipped**: `VardctL0Config.enableRdoq` defaults to **true**,
`_kRdoqLambda = 0.03`. All correctness gates re-verified with the new
default (294 tests green, including the multi-distance
`encoder_lossy_corpus_test.dart` gates and the gradient-banding
regression test at its existing `distance=1.0` scope). Encode-time cost:
roughly 20-40% slower at the sizes benchmarked (e.g. `color_cover`
`distance=1.0`: 811ms → 1115ms) — no regression test exists for this yet,
same caveat as round 4's DC context tree.

### Lossy (VarDCT) encoder — variable-transform selection: bootstrap decision + safety net, on by default

Follow-up session to L3's write-up above, which shipped 16x16 support but
left it **off** by default because `_should16x16` (a pre-quantization,
log-scaled coefficient-magnitude proxy) over-selected 16x16 on manga's two
dominant content types: +20% size on screentone, +31% on line art, despite
picking 16x16 there 50-100% of the time. This session replaces that proxy
and, after the numbers held up, flips the default on.

**The fix, `_decideTransformLayout`**: mirrors `_chooseHfMultRd`'s
already-shipped bootstrap-then-freeze pattern (round 3, above), generalized
from "which `hfMult`" to "which transform type". Quantize the whole image
as all-8x8 first (the bootstrap), build a real AC token/clustering pass
from that to get a frozen Huffman code-length table
(`EntropyCodes.tokenBitLengths()`) and cluster map, then for every
2x2-aligned region compare the real bootstrap cost of its 4 already-
committed 8x8 blocks (`sum(distortion + lambda * _blockRate(...))`) against
a freshly quantized 16x16 candidate's own cost — keeping whichever is
smaller. This soundness argument is identical to `_chooseHfMultRd`'s:
`HfBlockContext.qfThresholds` is empty, so neither `hfMult` nor which
transform type a *different* region picks can shift which cluster a token
routes to, only the values landing in it — so scoring against a frozen
table is a real, not just convenient, comparison. The 16x16 candidate
reuses its region's top-left 8x8 block's own frozen `predicted` non-zero-
count value (`HfCoefficients.getPredictedNonZeroes` depends only on
already-decided west/north grid state, which is identical whether this
region's own footprint ends up 8x8 or 16x16) — exact when no earlier
region has itself swapped to 16x16 yet, an accepted approximation
otherwise, same as `_chooseHfMultRd`'s own documented gap.

**Why this alone wasn't enough, and the whole-image safety net that
followed.** An advisor review (before shipping) pointed out a real gap:
this decision is a real-*estimate* comparison, not RDOQ's real-*assembly*
one — RDOQ earns its on-by-default status specifically by re-encoding for
real before committing any drop, and this fix, as first written, had no
equivalent. Two synthetic patterns clearing a tolerance gate is thin
ground to override manga's "off by default until proven" precedent
(L3, above) on a project whose stated primary use case is manga, where a
real fixture can never be a repo test case. The fix: `_decideTransformLayout`
now returns **two** fully independent candidates — the bootstrap all-8x8
layout (byte-identical to what `enableVariableTransforms: false` alone
would produce) and the decided mixed layout — and `encodeLossyVardctL0`
assembles a real, fully-encoded body for *both* (`_finishEncode`, the
factored-out steps 5.5-7 of the encoder, run once per candidate) and keeps
whichever is genuinely smaller. This is the same "estimates can't resolve
near-ties, verify by real assembly" rule `_chooseAcClustering` and RDOQ
already use elsewhere in this file, applied one level up (per-image
instead of per-block-channel) — and it makes the *combination*
provably never-worse than `enableVariableTransforms: false`, even though
the per-region estimate alone cannot promise that.

**Marginal cost of the safety net is small, not a second full encode.**
The expensive part — DCT + quantization + AC clustering for the all-8x8
layout — is already computed once inside the bootstrap; assembling its
real body costs only one more clustering-header-and-payload write pass
(cheap relative to DCT/quantization). Measured: `color_cover` at
`distance=1.0`, 1088ms (`enableVariableTransforms: false`) vs 1389ms
(`true`, both candidates assembled) — about 1.28x, not 2x.

**A subtle correctness hazard, caught before shipping**: the two
candidates' non-swapped 8x8 cells initially referenced the *same*
`_PlacedBlock` objects (built once by the bootstrap). Since RD-hfMult/RDOQ
mutate `hfMult`/`acInt` in place, running them independently on both
candidate bodies would have let one candidate's mutations leak into the
other's shared cells. Fixed with `_PlacedBlock.copy()` — the mixed-layout
candidate gets independent copies (deep-copying `acInt`, not just the
reference) for every cell it keeps as 8x8, so the two candidates share zero
mutable state.

**Calibration** (`tool/calibrate_transform_lambda.dart`, mirroring
`calibrate_rdoq_lambda.dart`'s multi-distance-sweep methodology from the
previous section — this project's standing lesson about single-point
calibration): swept `kLambda` across `distance ∈ {0.5, 1.0, 2.0, 4.0, 8.0}`
against `color_cover` (photo), a synthetic gradient, and manga-typical
screentone/line-art patterns. `_kTransformRdLambda = 3000.0` (the same
scaling law as `_kRdLambda`, `lambda = kLambda * refStep²` — both trade off
the same weighted-squared-error distortion metric against a bit-rate
estimate) cleared the manga gate (screentone/line-art within 2% of the
`enableVariableTransforms: false` baseline) at **every** distance tested,
while giving real wins elsewhere: `color_cover` -4.3% to -26.7% smaller
(with *better*, not just comparable, RMSE at every point — e.g. -21.4% RMSE
at `distance=8.0`), the synthetic gradient similarly smaller and better-
RMSE, screentone/line-art landing at 0% to -3.1% (i.e. small real wins, not
just "safely flat"). Lower `kLambda` values (100-300) failed the gate at
higher distances (screentone +13.6% at `distance=4.0`, `kLambda=100`) —
too eager to spend bits on 16x16 relative to its rate cost; `3000` sits
near a local optimum, not just a safe floor (higher values, e.g. `30000`,
gave measurably smaller wins on `color_cover` at low distance).

**A mixed-content check** (half smooth gradient, half screentone in one
256x256 image — deliberately not covered by any single-content-type test,
since that's the exact case a per-region decision exists to handle and the
frozen-bootstrap-prediction approximation is most likely to misfire at a
content boundary): the whole-image safety net produced byte-identical
output to `enableVariableTransforms: false` at `distance ∈ {1.0, 2.0, 4.0,
8.0}` (the mixed-layout candidate's estimate turned out not to actually
win once really assembled, so the safety net fell back cleanly) and a
small real win at `distance=0.5` (13605 vs 13611 bytes, RMSE 0.688 vs
0.738) — confirming the never-worse property holds exactly where the
approximation was most likely to be tested, not just on the two
single-content-type patterns the lambda sweep used.

**Shipped**: `VardctL0Config.enableVariableTransforms` defaults to
**true** (flipped from `false`), `_kTransformRdLambda = 3000.0`. Full test
suite green (298 tests, including a rewritten regression test — the old
"default off beats explicitly-on on screentone" assertion inverted to "the
gap is within 2%, both directions" once the fix made explicitly-on
*smaller* than default-off pre-flip). `tool/bench_lossy_vs_cjxl.dart`'s
gap vs `cjxl -e1` on `color_cover` narrowed from 1.52x-2.79x (L4's
measurement) to 1.18x-1.82x across the same distance range — the largest
single improvement to that benchmark's numbers so far, from fixing an
existing, already-implemented transform type's selection rather than
adding a new one. `palette16` improved similarly (1.10x-1.44x, down from
1.16x-1.52x). The remaining gap is unchanged in kind: still only 2 of the
format's 27 transform types and no rate-distortion search over transform
size itself (this fix chooses between two fixed candidates per region, not
a search) — see ROADMAP.md.

### Lossy (VarDCT) encoder — full 27-transform-type support, Tranche A: DCT 32x32

Start of ROADMAP.md's long-standing "full 27-transform-type support" item.
Scoped via `EnterPlanMode` given the size — a research pass (reading
`transform_type.dart`, `dct.dart`, `hf_coefficients.dart`,
`vardct_inverter.dart`, `hf_global.dart`) found the 27 types split cleanly
by how much of the decoder's existing machinery the encoder can reuse:

- **18 types share `TransformMethod.dct`** (plain separable DCT, any
  size/aspect ratio) — `forwardDCT2D`/`inverseDCT2D` (`dct.dart`) are
  already fully generic over any power-of-2 height/width and already
  exercised for all 18 sizes on decode; `getDCTQuantWeights`/
  `getNaturalOrder` are likewise generic and already imported by the
  encoder.
- **9 types** (Hornuss, DCT2x2, DCT4x4, DCT4x8, DCT8x4, AFV0-3) have no
  generic form at all — each is a bespoke, hand-derived transform in
  `vardct_inverter.dart`'s per-method switch, with no shared machinery a
  forward mirror could lean on.
- **6 of the 18 `dct`-method types are "wide" rectangular** and need
  orientation/transpose (`flip`) handling that doesn't exist in the
  encoder at all yet (`_scanChannelValues` hardcodes the square-only
  assumption with a comment saying so).

Three tranches fall out, cheapest-reuse first: **A** (more square DCT
sizes: 32x32, 64x64, 128x128, 256x256), **B** (12 rectangular `dct`-method
types, needs the new flip/orientation layer), **C** (9 bespoke
single-footprint types, needs from-scratch forward derivations). Only
Tranche A's first size, DCT 32x32, was scoped for implementation — proving
the generalized architecture end to end before spending more time on the
rest.

**What had to generalize.** `rawWeight8`/`rawWeight16` were threaded as
two explicit parameters through ~15 call sites with two literal dispatch
points (`block.tt == _tt16 ? rawWeight16 : rawWeight8`) — doesn't scale
past 2 types. Fixed by adding a `rawWeight` field to `_TransformCtx`,
which was *already* keyed by transform type in `ctxByType` and *already*
threaded through every relevant function for context/order lookups — one
more field, not new plumbing. Verified byte-identical output before/after
this refactor against `doc/BENCHMARKS.md`'s recorded numbers (113457
bytes at `color_cover` `distance=1.0`, matched exactly). Scratch buffers
(`scratch8a/8b` + `scratch16a/16b`, 4 params) generalized to one reused,
max-sized pair — `forwardDCT2D`/`inverseDCT2D` only ever touch the
`[0, n) x [0, n)` sub-region a call passes explicitly, so a single 32x32
buffer safely serves 8x8/16x16/32x32 alike.

**DC/LLF inversion, generalized and verified before trusting it.**
`quantizeCandidate`'s DC handling hand-unrolled 16x16's case as a literal
2x2 Hadamard-like closed form (`dc[c*4] = (pre00+pre01+pre10+pre11)/
sd[c]`, etc.) — hardcoded to exactly 4 positions. The decoder's own
`_finalizeLLF` (`hf_coefficients.dart`) builds a block's LLF corner as
`forwardDCT2D(dcPlane, ..., dctSelectHeight, dctSelectWidth, ...)` then
scales by `tt.llfScale` elementwise — for *any* grid size, not just 2x2 —
so the true algebraic inverse (divide by `llfScale`, then `inverseDCT2D`
over the same grid) generalizes cleanly. Verified directly, not assumed:
`test/encode/vardct_forward_test.dart` gained a test constructing a real
DC-plane 4x4 grid (32x32's `dctSelectHeight/Width`), running it through
`_finalizeLLF`'s exact forward construction, then confirming the proposed
inverse recovers the original values — before the encoder's real pipeline
was trusted to rely on it. Switching 16x16 to the same generic path (no
special-casing kept) caused a ~2-byte drift on existing output (a
different floating-point path, not a different answer) — acceptable
since this project's lossy correctness gate is RMSE/max-based, not
bit-exact, unlike the lossless encoder.

**The layout decision: one more quadtree level, and a real safety-net gap
caught before shipping.** `_decideTransformLayout`'s existing 8x8-vs-16x16
decision is exactly a one-level bootstrap-frozen quadtree merge (quantize
everything as 8x8, then for every 2x2-aligned region compare real cost
against a 16x16 candidate). Round 7 adds a second, structurally identical
pass one level up: for every 2x2-aligned 32x32-pixel region (four
already-decided 16x16-or-8x8 candidates), compare their real summed cost
against a candidate 32x32's, reusing the same frozen bootstrap code-length
table (sound for the identical reason the first level's own doc comment
already establishes — transform-type choice never shifts which cluster a
token routes to, only what value lands there).

An end-to-end smoke test (encode with the new level on vs. off, compare
bytes) surfaced a real gap: on `distance=8.0` gradient content, the new
level's own per-region estimate picked a real, if modest, size
*regression* vs. the level-1-only decision (1916 bytes vs. 1817) — still
smaller than plain 8x8, so the *existing* two-candidate safety net
(mixed-layout vs. plain-8x8 bootstrap) wouldn't have caught it. This is
the same "estimates can't resolve near-ties, verify by real assembly"
lesson RDOQ's real-bits check and the first merge level's own outer
safety net both already establish — recurring one level deeper, because
a per-region *estimate* is still only ever a bootstrap-frozen
approximation regardless of how many levels deep it's nested. **Fix**:
extended `_decideTransformLayout`'s return from a 2-candidate to a
2-or-3-candidate tuple (`bootstrapBlocks` always, `level1Blocks` always,
`level2Blocks` only when `enableTransform32`), and `encodeLossyVardctL0`
now assembles a real body for *every* non-null candidate via the existing
`_finishEncode` machinery and keeps the genuinely smallest — reusing the
same real-assembly mechanism the outer level already uses, not a new one.
Re-running the smoke test confirmed the fix: the `distance=8.0` regression
case now correctly falls back to the level-1-only body (1817 bytes)
instead of the worse level-2 result. **Generalizable lesson for any
future N-level merge/cascade in this codebase**: adding a new level on
top of an existing "provably never-worse" safety net needs the new
level's *own* real-assembly comparison against the immediately-prior
level, not just against the original baseline — being not-worse-than-the-
oldest-baseline is a different (weaker) guarantee, and it fails silently
(a bytes regression, not a crash) unless something specifically compares
against the immediately-prior state.

**Calibration** (`tool/calibrate_transform32_lambda.dart`, same
multi-distance methodology as round 6's fix — sweep 0.5-8.0, not one
point). Baseline is level-1-only (`enableVariableTransforms: true,
enableTransform32: false`, this encoder's actual pre-round-7 default),
not plain 8x8, since the question is specifically "does level 2 help
beyond level 1" — matching why level 2 needs its own safety net above.
`_kTransformRdLambda32 = 3000.0` (same value as `_kTransformRdLambda`,
the sweep found no benefit to diverging) clears a manga-neutral-or-better
gate at *every* tested distance:

| distance | color_cover | gradient | screentone (synthetic) | lineArt (synthetic) |
|---|---|---|---|---|
| 0.5 | -5.1%/rmse-0.9% | -7.6% | -0.5% | 0% |
| 1.0 | -1.6%/rmse-1.4% | -0.8% | 0% | 0% |
| 2.0 | -3.2%/rmse-7.1% | -1.3% | 0% | 0% |
| 4.0 | -6.6%/rmse-2.2% | -8.8% | 0% | 0% |
| 8.0 | -9.7%/rmse+0.5% | 0% | 0% | 0% |

Higher `kLambda` values (10000-100000) plateau rather than diverge — a
reassuring sign this constant sits in a stable region, not at a knife's
edge (unlike hfMult's lambda, which needed a scaling-formula fix; this
merge level uses the same rounding-error distortion metric round 6's
constant already validated as correctly `refStep^2`-scaled).

**Real-corpus validation found an even bigger effect than the synthetic
sweep suggested** (`tool/bench_lossy_vs_cjxl.dart`, comparing
`enableTransform32: true` vs. `false`, both through `djxl`): on
`color_cover`, -1.6% to -9.7% smaller at every distance, matching the
synthetic numbers closely. On `gray_screentone` (1536x2200, the corpus'
real manga-page proxy — halftone dots *and* panel borders, speech-bubble
interiors, a solid black polygon) the win is far larger: -7.6% to -16.7%
smaller across `distance` 0.5-4.0, essentially flat at `distance=8.0`.
The synthetic screentone/line-art patterns in the calibration tool are
pure repeating dot/line texture with no flat regions at all — real manga
pages are a *mix* of that texture and large flat areas (panels, bubble
backgrounds), and flat regions are exactly where a bigger transform pays
off most. Concretely, this **flips** the `cjxl -e1` comparison at
`distance=4.0` from worse (1.03x, the pre-round-7 figure in
`doc/BENCHMARKS.md`) to better (0.95x) — a qualitative, not just
quantitative, improvement the synthetic-pattern-only calibration
undersold. No evidence of `doc/spec_notes.md`'s inherited large-DCT
decode-side deviation ("DCT 16x32 and larger") causing problems here:
`djxl` round-trip RMSE and max-diff both tracked expected growth with
`distance` at every measurement, with no anomalous spike specific to
enabling 32x32.

**Encode-time cost, measured before the shipping decision.** The
never-worse guarantee requires a third real `_finishEncode` assembly pass
(bootstrap-only, level-1, level-2) whenever `enableTransform32` fires at
all, and that pass is the actual bottleneck, not the RD search that picks
between them: `gray_screentone` AOT encode time went from ~16-17s to
~24s/page (~40% slower). This cost is paid whenever the feature is on and
32x32 is picked anywhere in the image — which turned out to matter a lot
for the shipping decision below.

**REAL-MANGA VALIDATION REVERSED THE DEFAULT.** Briefly shipped
`enableTransform32` on by default on the strength of the synthetic and
corpus numbers above — then tested against real `manga_samples/` chapter
pages (gitignored, copyrighted, never committed — one B&W screentone-heavy
title, one flat-color "digital colored comics" title, 6 pages total, both
distance=1.0 and distance=4.0, `enableVariableTransforms: true` in both
arms so only the level-2 effect was isolated). The result: **-0.0% to
-0.6%** — a full order of magnitude below every synthetic/corpus figure
above — for the *same* ~40% encode-time cost measured everywhere else (the
level2-skip optimization that avoids the third assembly pass when nothing
merges doesn't help here: 32x32 *does* fire on real pages, just barely
enough to matter). RMSE was unchanged across every page; no correctness
issue, no anomalous large-DCT-deviation spike — this is a value judgment,
not a bug. Root cause: `gray_screentone`'s flat panel/speech-bubble/
solid-black-polygon regions are a more exaggerated proxy for "flat-area
density" than real manga pages actually have — the corpus golden was
designed to *exercise* the feature, not to *represent* typical page
content, and round 7 conflated the two. This is the exact same "synthetic
validation didn't survive contact with real content" pattern already
documented for L3's variable-transforms (screentone/line-art regressed
20-31% on first real testing), RDOQ's lambda scaling (safe at
distance=1.0, roughly doubled RMSE at distance=8.0), and hfMult's banding
blind spot (a proxy metric structurally can't see banding sensitivity) —
now a fourth instance, and a reminder that this project's own corpus
goldens are still synthetic proxies, not a substitute for the real
`manga_samples/` content the decoder's *decode*-side validation already
insists on (see the M0-M7 real-world validation note above).

**Shipped**: the architecture, the never-worse safety net, and the opt-in
knob are all correct and stay. `VardctL0Config.enableTransform32` defaults
to **false** — reverted from a brief on-by-default ship once the real-manga
numbers came in. Full test suite green (306 tests, including a dedicated
capability-regression test that forces the flag on so the feature itself
stays covered even with the default off) with `koni_jxl_flutter`'s suite
also green. See `doc/BENCHMARKS.md` for the updated headline numbers
(reverted to reflect the off default).

### Lossy (VarDCT) encoder — Tranche A completed: 64x64/128x128/256x256, a generalized cascade, and a settled success criterion

Round 7 (above) had briefly conflated two separate questions — "does this
transform type work" and "does it help manga content" — treating a
negative answer to the second as a reason to slow down on the first. The
user surfaced this directly after round 7 shipped: full 27-transform-type
support had been a standing ask across sessions, and it kept looking
unstarted from the outside because each round scoped down to a small
provable slice. Asked explicitly, the answer settled the ambiguity (see
ROADMAP.md, dated 2026-07-05): **full 27-transform-type support is a
completeness goal, not gated on manga ROI.** A type's *existence* —
correct, djxl-verified, never-worse — is unconditional; only its
*default* stays ROI-gated, exactly the split round 7 already used for
32x32. This round finished Tranche A on that basis.

**Generalized the cascade instead of hand-copying three more merge
levels.** Round 7's `_decideTransformLayout` had one hardcoded 8x8-vs-16x16
step plus one hardcoded 16x16-vs-32x32 step; adding 64x64/128x128/256x256
by copying that second step three more times would have tripled the
surface area for the exact class of bug round 7 already found once (a
level's estimate regressing against its immediate predecessor). Instead:
`VardctL0Config.enableTransform32` (bool) became `maxTransformSize` (int:
16/32/64/128/256 — a single depth knob, since a clean N-level loop can't
be driven by N independent booleans), and the second merge step became a
generic loop over `_cascadeSizes = [32, 64, 128, 256]` that stops at
`maxTransformSize`. The loop's correctness argument is structural, not
per-level: `_decideTransformLayout` returns bootstrap always first, and
every later candidate exists only because it beat its own
immediately-prior candidate's *estimate* — so `min(assemble(c).length for
c in candidates) <= assemble(bootstrap).length` holds by construction
regardless of how many levels fire, closing the round-7 gap generically
instead of per-level. A level that finds no merge is skipped as a
candidate, but the cascade still tries the next size up on the unchanged
layout (an intermediate size finding nothing doesn't provably rule out a
bigger jump helping — this project's methodology is to verify by real
assembly, not assume monotonicity). `_kTransformRdLambda32` became
`_kTransformRdLambdaBeyond16`, shared across all four levels beyond 16 —
per the advice below, not recalibrated per size.

**Verification, in order** (matches this project's own stated
methodology): (1) forward/inverse identity + LLF-inversion tests
(`vardct_forward_test.dart`) at all four new sizes' `dctSelectHeight`
grids (8, 16, 32 for 64x64/128x128/256x256, matching 32x32's 4x4 case) —
one parameterized test group instead of four hand-copied ones, mirroring
the cascade's own genericity. All pass at the same tolerances 32x32
used. (2) A dedicated end-to-end correctness test exercising the
edge case no smaller size gets near: a 256x256 candidate exactly fills
one whole *group* (32x32 8x8-cells, the same granularity
`groupsX`/`groupsY` partition the image into), a footprint HfMetadata
placement/entropy-coding had never been asked to handle. Found by
sweeping canvas size and distance with `jxl.encdebug` (not guessed): a
256x256 canvas with a smooth gradient at distance=64 is the minimal
config where the *entire* cascade (8x8→16x16→32x32→64x64→128x128→256x256)
is the real-assembled winner, not just an intermediate candidate tried
and discarded — this is now a permanent regression test. (3) Full suite
green throughout (313 `koni_jxl` tests, `koni_jxl_flutter` unaffected).

**Real-manga sanity check, not a full recalibration.** Advice going in:
bigger transforms had already helped manga *less* than 32x32 (which was
already negligible), so repeating the full multi-distance-sweep-plus-
real-manga dance three more times would mostly re-confirm what round 7
already found, at real time cost. Instead: reuse the shared lambda
constant, verify correctness, and run one quick real-manga check to see
if anything *surprising* shows up before deciding whether deeper
calibration is warranted. It wasn't needed — the same two
`manga_samples/` chapters round 7 used (gitignored, copyrighted, never
committed), `maxTransformSize: 256` vs. `16`, distance 1.0 and 4.0: real
win **-0.1% to -0.6%**, no better than 32x32 alone, for roughly **2x**
encode time (not ~1.4x — four extra cascade levels are now tried per
image instead of one; e.g. one page went from 8.8s to 18.2s at
distance=1.0). No RMSE change, no anomalous large-DCT deviation. Same
conclusion as round 7, reached in one quick check instead of a full
sweep: `VardctL0Config.maxTransformSize` stays at its default of **16**.

**Verified the default path itself didn't regress.** Adding
`_tt64`/`_tt128`/`_tt256` to `_activeTransformTypes` (built unconditionally
every encode call, so their quant-weight tables — including a 256x256
one, 65536 entries per channel — are now always constructed even on the
default `maxTransformSize: 16` path that never uses them) was flagged as
worth measuring, not assuming free, before shipping: an isolated
before/after data point looked suspicious (5% slower at byte-identical
output on one page). A controlled back-to-back check — `git stash` to the
pre-round-8 code, 3 trials each on the same real `manga_samples/` page
and the same corpus golden, same machine, same session — found
byte-identical output both times and no measurable timing difference
(8326-8379ms across both versions on the manga page; 16856-16970ms on the
corpus golden) — the one-time table-construction cost is genuinely
negligible against a multi-second full-image encode, so no gating was
needed. This is the generalizable lesson: a single isolated timing sample
can look like a regression from ordinary system noise — a real A/B on
identical code paths is what actually answers the question, in either
direction (this project has hit the opposite mistake — assuming a change
is free without measuring — often enough that "measure, don't assume" now
cuts both ways).

**Shipped**: 64x64/128x128/256x256 all exist, are correct, and are
covered by tests — completing Tranche A. The default remains 16 (the
same behavior as round 7's shipped state, confirmed unregressed above);
raising it is a deliberate opt-in for content that genuinely has large
flat regions, not a recommended default for manga. Tranches B (12
rectangular types, needs the flip/orientation layer
`_scanChannelValues` and `quantizeCandidate`'s AC loop don't have yet)
and C (9 bespoke single-footprint types, needs from-scratch forward
derivations mirroring `vardct_inverter.dart`'s bespoke inverse code plus
porting `HfGlobal`'s private weight-generation logic into
encoder-callable form — no shared machinery to lean on, closer to a
series of small research tasks than mechanical generalization) remain
fully unscoped. Per the settled criterion above, future work on either
should proceed on completeness grounds regardless of any individual
type's manga ROI — only its default depends on that.

### Lossy (VarDCT) encoder — Tranche B, first slice: DCT 16x8/8x16

**What was already generic vs. what genuinely needed new code.** A
research pass, verified against the current file line-by-line rather
than assumed, found that most of the supporting machinery is *already*
fully generic over rectangular shapes and needed zero changes:
`transform_type.dart` (all 12 Tranche-B types, `flip`, `isVertical`,
`llfScale`, `matrixHeight`/`matrixWidth` already correctly derived by the
existing constructor), `hf_global.dart`'s `getDCTQuantWeights(height,
width, params)` (already independent height/width, and mathematically
symmetric under simultaneous height↔width/x↔y swap — verified the
encoder's own approach of generating the matrix directly in physical
orientation is bit-exact-equivalent to the decoder's
canonical-then-transpose approach), `hf_pass.dart`'s
`getNaturalOrder(orderID)` (already independent `dctSelectHeight`/
`dctSelectWidth` throughout), `hf_metadata.dart`'s `_placeBlock`
(decoder-side raster-scan bin-packing, already arbitrary-aspect-ratio
capable since it has to place real rectangular blocks from real `.jxl`
files), `dct.dart`'s `forwardDCT2D`/`inverseDCT2D` (already take
height/width as fully independent parameters; already unit-tested at
rectangular sizes in `test/vardct/dct_test.dart`), and the decoder's
flip-aware `hf_coefficients.dart`/`vardct_inverter.dart` (already
conformance-tested against real rectangular files). This machinery was
written generically from the start because the decoder always had to
handle every type uniformly — the gap was entirely in the encoder, which
had only ever needed to emit square types until now.

**Three functions collapsed an independent height/width into a single
`n`** — a real bug for any non-square type, silent until now because
every active type had `pixelHeight == pixelWidth`: `computeCoeffBuf`
(buffer allocation and the `forwardDCT2D` call), `quantizeCandidate`'s
AC-quantization loop (its DC/LLF-inversion half was already correctly
`llfH`/`llfW`-independent and needed no change), and `chooseCandidate`'s
AC-energy heuristic loop. Fixed by splitting `tt.pixelHeight`/
`tt.pixelWidth` explicitly everywhere `n` had stood in for both.

**Two functions hardcoded the transposed (`flip=true`) coefficient
access unconditionally** — correct for every square type and for the
"tall" member of every rectangular pair (both are `flip=true`), wrong
for the "wide" member (`flip=false`), which Tranche B is the first work
to ever emit: `_scanChannelValues` (`acData[ox * n + oy]` always, now
`ctx.tt.flip ? acData[ox * n + oy] : acData[oy * n + ox]`) and
`_rdoqBlockChannel` (same pattern across `coeffBufC`/`rawWeightC`
lookups and the `toZero` index). Verified against the decoder's own
`posY2 = (flip ? ox : oy) + ...` swap in `hf_coefficients.dart`. Neither
fix changes behavior for any existing type, since `flip` is always
`true` there.

**The merge cascade needed genuinely new logic, and a design review
caught a real bug before it shipped.** The existing square cascade (one
`stride` value driving both axes) was generalized into a `tryMergeLevel`
closure parameterized by independent `strideY`/`strideX`, reused for
*every* level — the rectangular pre-pass, the always-on 8x8-vs-16x16
decision, and every square `_cascadeSizes` entry — not a parallel
rectangular-only path. This was a correctness requirement, not a style
choice: level 1's old hand-written fast path read directly from the
pristine bootstrap (`blockAt`/`rate8`), which cannot see a layout the
rectangular pre-pass already changed; routing it through the same
`layoutBlockAt`-based closure was the only way to keep it correct once
rectangular can run first.

A design-review pass, before any of this was implemented, specifically
flagged that "merge two same-size squares" was the wrong mental model —
the square cascade already sums real cost over *whatever* distinct
blocks a `seen`-set collects in an aligned region (not necessarily two
equal blocks), and rectangular merging is the same mechanism with a
rectangular region shape. That review also caught, by reasoning through
the geometry rather than by a failing test, that DCT 16x8 and DCT 8x16
**do not nest** — unlike every square-cascade level before them (where
each size is a clean multiple of the previous one), a 16x8 and an 8x16
share at most one cell and neither contains the other. Without a
**containment guard**, a committed 8x16 block could be silently
partially overwritten by a later 16x8 merge attempt that only checks
"is this region's real cost worse than a candidate," never "does this
candidate's footprint actually contain every block I'm about to
replace" — orphaning cells the discarded 8x16 also owned, corrupting the
block list in a way that manifests downstream as a decode failure or
silent placement desync, not a clean error at the merge site itself. The
guard added rejects any merge where a collected block pokes outside the
candidate's own `[by, by+strideY) x [bx, bx+strideX)` footprint. For
every *square* level this guard is a structural no-op (square sizes
always nest cleanly), so it cannot regress Tranche A — confirmed by the
same `git stash` A/B this project used for round 8 (byte-identical
output, comparable timing on the same real manga page and corpus
golden).

Ordering: the rectangular pre-pass (wide 8x16, then tall 16x8) runs on
the bootstrap layout *before* the square 16x16 decision. Every 16x8/8x16
footprint nests cleanly inside exactly one 2x2 16x16-pixel region (it
spans one axis fully and the other partially, always within that
region's bounds), so feeding the rectangular pre-pass's result into the
16x16 level next never presents that level with a partial overlap — the
reverse order would.

**A second real bug was found not by review but by a real end-to-end
encode crashing.** `quantizeCandidate`'s DC/LLF-inversion branch — the
code already confirmed algebraically correct and unit-tested in round
8 — allocated its `inverseDCT2D` scratch buffers (`llfScratchA`/
`llfScratchB`) sized exactly `(llfH, llfW)`. This is correct for every
square type, where `llfH == llfW` always, but `dct.dart`'s
`transposeMatrixInto` writes a `(llfW, llfH)`-shaped intermediate
partway through — which overflows an `(llfH, llfW)`-sized buffer the
moment the grid is genuinely rectangular (16x8's `dctSelect` grid is
2x1). A real encode with `enableRectangularTransforms: true` crashed
with `RangeError (length): Invalid value: Only valid value is 0: 1`
inside `transposeMatrixInto`. Critically, round 8's own identity/
LLF-inversion tests in `vardct_forward_test.dart` did **not** catch this
class of bug when extended to types 6/7 for this round, because those
tests supply their own (correctly max-sized) scratch buffers directly to
`forwardDCT2D`/`inverseDCT2D` — they never exercise `quantizeCandidate`'s
own internal scratch allocation at all. Fixed by sizing
`llfScratchA`/`llfScratchB` to `max(llfH, llfW)` in both axes, matching
the convention this file's outer `scratchA`/`scratchB` and
`test/vardct/dct_test.dart` already use. The lesson: "the formula is
already generic and verified" is not the same claim as "every buffer
this formula touches is sized correctly for the generic case" — the
first was true and tested, the second was true only by coincidence
(every prior type happened to be square) and untested until a real
non-square encode actually ran the code path. `vardct_forward_test.dart`
itself needed the identical fix for the same reason (its own identity
test originally sized scratch to `(ph, pw)` instead of
`max(ph, pw)` in both axes) — caught by the *test* crashing first, before
this was even noticed in production code, which is what led to checking
`quantizeCandidate`'s internal allocation too.

**A third gap was caught by advisor review, after implementation and all
tests were green.** Every test up to that point compared our-decoder
output against `djxl`'s — this cannot catch a semantic coefficient-scan
error in the flip branch, because both decoders parse the *same*
bitstream the *same* way: if the encoder's flip logic scrambled
coefficient placement consistently, both decoders would agree with each
other on the (wrong) reconstruction while both differed sharply from the
original pixels — a decode-vs-djxl check would show near-zero RMSE and
declare success. Since DCT 8x16 (`flip=false`) is the first
non-transposed block this encoder has ever emitted (every prior type,
square or the tall 16x8, is `flip=true`), nothing before this review
exercised that specific branch's semantic correctness at all — only its
non-crashing behavior. Verified manually first (per the review's own
suggestion): encoding the mixed-shape test image with
`enableRectangularTransforms: true` and comparing decode-vs-*original*
RMSE against the `false` (square-only) case gave 2.267 vs. 2.264 — in
the same ballpark, not the order-of-magnitude blowup a real flip bug
would cause. A second, more isolated check (a canvas of pure horizontal
stripes, forcing 100% DCT 8x16 coverage) gave 0.5 vs. 0.433 for
rectangular vs. square-only — again consistent, not blown up. This is
now a permanent regression assertion in the mixed-shape test (a relative
bound, `rectRmse < squareRmse * 2 + 1`, chosen to fail loudly on a real
flip regression while not being a flaky absolute threshold), not just a
one-off manual check that would silently stop mattering the moment
someone touched the flip branch again.

**Verification, in the order it was actually done**: (1) extended round
8's parameterized forward/inverse-identity and LLF-inversion test loop
in `vardct_forward_test.dart` to include types 6/7, fixing that test's
own `n`-collapse and scratch-sizing bugs first (found by the test itself
crashing) — this genuinely exercises the LLF-inversion relationship at a
non-square `dctSelectHeight != dctSelectWidth` grid for the first time.
(2) A mixed-shape integration test in `vardct_l0_test.dart`: a 32x32
canvas split into four quadrants, each engineered to favor a different
shape (horizontal stripes → 8x16, vertical stripes → 16x8, smooth
gradient → square 16x16, noise → plain 8x8), with the exact canvas
size/stripe period/distance found empirically via `jxl.encdebug` tallies
(not guessed) until the *chosen*, real-assembled candidate contained all
four shapes at once and genuinely beat the square-only cascade — not
just the plain bootstrap, which is a weaker claim `enableVariableTransforms:
false` alone would already satisfy. This test asserts, in order: the
size win vs. square-only; the decode-vs-original RMSE relative bound
(the flip-semantics check above); djxl agreement at a tightened
`rmse < 2.0` gate (16x8/8x16 are *not* in the documented "DCT 16x32 and
larger" large-DCT deviation bucket that justifies the looser `<40` bound
Tranche A's biggest sizes use, so the standard project gate applies —
measured ~0.48 at this exact config, comfortable margin). (3) A
multi-group test — not a boundary-*straddle* test, since the merge
cascade's own alignment check (`by % strideY == 0 && bx % strideX == 0`)
already rules straddling out algebraically for every Tranche-B
`dctSelect` dimension (1, 2), both of which divide 32 — but a concrete
check that `_finishEncode`'s group-bucketing (256x256-pixel groups keyed
purely by block origin) correctly handles real rectangular blocks
landing immediately adjacent to a group boundary on both sides, in a
512x32 multi-group canvas, djxl round-tripped at the same tightened gate.
Full suite green throughout (319 tests, up from 313 after round 8).

**Default-path regression check**: the same `git stash` A/B methodology
round 8 used, applied again — 3 trials, same real manga page and corpus
golden, `enableRectangularTransforms` at its default (`false`) before
vs. after this round's changes — found byte-identical output (510690B)
and comparable timing (8434-9700ms both versions), confirming the new
`_tt16x8`/`_tt8x16` entries in `_activeTransformTypes` (built
unconditionally every encode call, same pattern round 8's 64x64/128x128/
256x256 additions already established as cheap) don't regress the
default path.

**A note on what "never-worse" actually covers here**, worth stating
explicitly so a future session extending Tranche B doesn't rediscover it
as a bug: the guarantee `enableRectangularTransforms: true` gets from the
shared candidate list is "never worse than plain 8x8/bootstrap," not
"never worse than square-only" (this flag `false`). With rectangular on,
the 8x8-vs-16x16 level runs on top of whatever the rectangular pre-pass
already decided rather than on the pristine bootstrap — so "16x16
applied to pure bootstrap" (what a square-only run produces) is never
itself a candidate in the rectangular-enabled run's list. This means
enabling rectangular transforms can, in rare cases, produce a file a
byte or two *larger* than a square-only run would have, while still
always beating plain 8x8 — confirmed empirically during this round's own
config sweep: at 32x32/period-4/distance-0.5, rectangular-on chose 730B
against square-only's 729B, both beating the 761B bootstrap. This is an
expected consequence of layering one greedy opt-in decision on top of
another, not a bug, and not worth "fixing" by also assembling a
standalone square-only candidate just to restore a stricter guarantee on
a feature that ships off by default.

**Shipped**: DCT 16x8/8x16 exist, are correct, and are covered by tests
— the first of Tranche B's 12 rectangular types.
`VardctL0Config.enableRectangularTransforms` (new, orthogonal to
`maxTransformSize` — that knob is a square-tier size scale, this is a
separate shape axis, so conflating them would make `maxTransformSize:
16` ambiguous for existing callers) defaults to **false**: existence is
unconditional per the settled criterion, but the default is a separate,
not-yet-evaluated real-content-ROI question — no real-manga check has
been run for this pair yet, unlike every prior size, which followed a
real-manga sanity check before its default was decided. Next: the same
`tryMergeLevel` machinery mechanically extends to the remaining four
"2:1 pair" levels (32x16/16x32, 64x32/32x64, 128x64/64x128,
256x128/128x256 — each formed by merging two adjacent same-size square
blocks from the level below) and the one "4:1 line" case (32x8/8x32 —
merges four same-size 8x8 blocks in a line, since no intermediate
16x8-square exists to pair further; the only 4:1 case in the whole
format, confirmed by checking there is no 64x16/128x32/256x64 type in
the spec).

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
real-world JPEG-transcoded manga page decodes in ~0.25 s (was ~0.3 s before
the per-group block-index fix below). The float
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
get native SIMD. See "Web compile targets" below for a correctness caveat
that applies specifically to dart2js, not dart2wasm.

## Web compile targets: dart2wasm is correct, dart2js is not (and isn't a
   target)

dart2wasm compiles Dart `int` to a real 64-bit Wasm `i64` - identical
semantics to the VM/AOT. Verified end-to-end: `dart compile wasm` on the
full corpus subset used below, run under Node, matches native byte-for-byte
on every lossless file and within RMSE ~0.005 (max per-channel diff of 1)
on the two lossy files tested - ordinary float rounding variance between
platforms' math libraries, not a bug, and far inside the project's own
lossy gate (`rmse < 2.0`).

dart2js is a different story: Dart `int` there is a JS `double`, and
critically **every bitwise operator (`<<`, `>>`, `>>>`, `&`, `|`, `^`)
coerces both operands and the result through a 32-bit int**, mirroring raw
JavaScript's `ToInt32`/`ToUint32` - not just for shift amounts >= 32 (which
at least fails loudly at the literal-compile stage for `0x9e3779b9...`-style
constants), but silently for:
- any *result* that would exceed 2^32, even with a shift amount < 32
  (`240 << 25` truncates to `240 << 25 mod 2^32`);
- any *operand* that is negative - dart2js reinterprets it as its
  unsigned-32-bit two's complement equivalent and never converts back
  (`-5 >> 1` gives 4294967293 there, not -3).

That second point breaks the classic "XOR two ints, negative iff signs
differ" idiom (`(a ^ b) <= 0`) used by the weighted predictor's clamp
condition, and the `lower ^ a ^ b` min/max-via-XOR trick, wherever the
operands are signed channel/error values (which they routinely are - RCT
chroma channels, WP error terms). Combined with the first point corrupting
fixed-point `(a * b) >> k` products once they exceed 2^32 (routine in the
WP prediction's `(1<<24)/k` reciprocal table), this desyncs the entropy
stream deep into decode with no diagnostic at the actual fault site - it
surfaces many symbols later as an unrelated-looking "illegal final modular
state" or a truncated-read exception.

This was found by building a differential oracle
(`tool/web_decode_oracle.dart`; a throwaway base64-embedded variant was used
during the investigation to run under `dart compile js` + Node against real
corpus bytes) and bisecting divergences with per-symbol/per-pixel debug
logging comparing native vs. dart2js output - grep cannot find this class
of bug, since "this operand might be negative" isn't a syntactic pattern
and the unsafe cases are indistinguishable from safe ones (`x & mask`,
`x & 1`, and small fixed shifts on already-bounded values are all fine) by
inspection alone. The following were fixed - correct on every platform,
not just dart2js/dart2wasm - once found:
- `vlc_table.dart`, `entropy_writer.dart`: `1 << 32` used as a sentinel,
  replaced with the literal `0x100000000`.
- `bit_reader.dart`: `readBits`/`peekBits`'s mask for `bits == 32`; the
  core byte-accumulation loop (was `_cache |= byte << cacheBits`, silently
  truncated once `_cache` exceeds 2^32 - rewritten as `_cache += byte *
  (1 << cacheBits)`, arithmetic instead of bitwise, since the byte's bit
  range never overlaps what's already cached); `readU64`/`readIccVarint`'s
  varint shifts; added `wideShl`/`wideShr`/`wideShrSigned` to
  `math_helper.dart` (multiply/divide-based, not `<<`/`>>`) for shift
  amounts or operand magnitudes that can exceed 32 bits.
- `entropy_stream.dart`'s `_readHybridInteger`: token expansion shift can
  reach exactly 32.
- `modular_channel.dart` / `encode/wp_predictor.dart` (the encoder's exact
  mirror): the WP clamp condition's XOR sign-trick and `_clamp3`/
  `_clamp4`'s XOR-based min/max, both rewritten via plain sign/equality
  comparisons; the WP prediction's `(s * reciprocal) >> 24` now goes
  through `wideShrSigned`.
- `image_header.dart`'s `1 << 40` (level > 5 max-pixel-count check).
- `render/noise.dart`'s `XorShiro` (xorshift128+ for the noise feature):
  the *only* dart2js failure that was a hard compile error, not a silent
  runtime one - three 64-bit hex literals aren't exactly representable as
  JS doubles. Rewritten as (hi, lo) `Uint32` pairs throughout; verified
  against the original `Int64List`-backed implementation across 20,000
  random seed pairs x 64 words plus explicit edge seeds (all-bits-set,
  the 2^32 carry boundary), zero mismatches.

None of the above are reachable on dart2wasm (real 64-bit `int`), so they
were latent correctness bugs, not live ones, given dart2wasm is the actual
web target for this project. What was **not** pursued once that was
confirmed: an exhaustive whole-codebase sweep for every remaining
negative-operand bitwise site on dart2js specifically (this class turned
out pervasive, not a short list - each fix found via the corpus oracle
exposed a new failure elsewhere rather than converging). If dart2js support
is ever needed, budget for a dedicated pass with the same oracle, not a
code-reading audit.

Profiling a real manga page's phase timings (`tool/profile_decode.dart -D
jxl.timings=true`) found the AC coefficient entropy-decode phase
(`HfCoefficients`'s constructor: per-block/per-channel ANS context
computation and symbol reads) at 40-47% of total decode time - bigger than
the already-SIMD-optimized dequant+IDCT+CfL stage, and filters (gaborish/
EPF) don't even factor in, since real JPEG-transcoded manga pages ship with
both off. Two fixes, isolated and A/B-measured via `tool/bench_entropy.dart`
(replays one pass-group's decode from pristine section bytes, so identical
bits decode repeatedly without re-parsing the file):
1. `HfCoefficients.getCoefficientContext`'s two `~/` divisions are
   identities whenever `numBlocks == 1` (a single 8x8-or-smaller
   transform) - confirmed via `tool/diag_entropy.dart` that this is true
   for 100% of blocks in real JPEG-transcoded manga content (JPEG's own
   8x8 DCT structure survives transcoding), so the fast path fires on
   essentially every coefficient for the actual workload. Combined with
   `@pragma('vm:prefer-inline')` on `AnsSymbolDistribution.readSymbol` and
   `EntropyStream._readHybridInteger`: ~7.5-14% faster entropy-decode
   phase, ~4-5% faster end-to-end decode.
2. A bigger one: every `HfCoefficients` instance (one per pass-group)
   scanned its LF group's *entire* block list (`meta.nbBlocks`, e.g.
   26800 blocks for a typical page) to find the ~1/35th belonging to it -
   and the same full-list scan-and-skip repeated independently in
   `_dequantizeHFCoefficients`, `_chromaFromLuma`, `_finalizeLLF`, and
   `invertVarDCTGroup`'s two loops (6 sites total). Fixed by
   `HfMetadata.blockIndicesByGroup()`: partitions all blocks into a fixed
   64-bucket layout (`(blockY>>5)*8 + (blockX>>5)`, keyed the same way
   `Frame.groupPosInLFGroup`'s `pos.y/pos.x` already range over [0,8) -
   an LF group is always exactly 8x8 groups) in one O(nbBlocks) pass,
   computed once per LF group and cached, then shared by every pass and
   pass-group. All 6 sites now iterate the precomputed index list instead
   of scanning-and-skipping. Order is preserved by construction (indices
   are appended in ascending original-scan order per bucket), so this is
   a pure enumeration-strategy change, not a behavior change - verified
   bit-exact/RMSE-clean across the full corpus gate (multi-LF-group and
   odd-sized-boundary cases included). Measured a bigger win than the
   fix's own isolated scan-loop microbenchmark predicted (~4% of the
   entropy-decode phase) - the *combined* fix (all 6 sites, not just the
   constructor's) cut real-manga-page decode time 18-24% end-to-end,
   because the standalone reproduction of "just the scan arithmetic"
   didn't capture how much the redundant scan cost *in the context of*
   the surrounding giant function/multiple call sites. Reinforces the
   project's standing lesson: model-based estimates of Dart AOT hot-loop
   cost are unreliable - only an A/B measurement of the real code (before
   vs after, same tool, same inputs) is trustworthy.

Lossless decode was profiled the same way: `MaTree.compactify()` (resolves
channel-index/stream-index/y-dependent tree splits, called once per row of
every channel) unconditionally reallocated a full copy of every non-leaf
node it visited, even nodes whose subtree never tests properties 0-2 at all
- and real learned trees (both this project's own encoder and, empirically,
cjxl's) split almost exclusively on spatial/gradient properties (3+), so in
practice most of a tree gets needlessly recopied on every single row. Fixed
by caching a `needsResolution` bit per node (does this subtree test
properties 0-2 anywhere) and short-circuiting to `return this` when false -
a pure object-identity change, since the caller (`ModularChannel.decode`)
only ever reads fields off the returned tree, never mutates it. Measured
~2-4% faster end-to-end lossless decode across cjxl-encoded corpus files
and a real manga page re-encoded through this project's own encoder
(smaller than the analogous VarDCT redundant-scan fix - lossless decode's
hot loop, particularly the weighted predictor's interior fast path, had
already been heavily optimized in earlier milestones, unlike the VarDCT AC
path which had never been profiled at this granularity before).

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
