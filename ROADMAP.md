# koni_jxl roadmap

Direction and deferred work. The decoder is feature-complete for the manga
use case and both packages are published at 0.1.0; the lossless encoder
beats `cjxl -e3` on real manga pages. This file tracks what's next.

Status legend: 🔲 not started · 🔨 in progress · ✅ done (kept here for
context until it ships in a release).

---

## Headline: lossy (VarDCT) encoding — "a true codec"

Today we decode lossy (VarDCT) and encode lossless (modular). Encoding
lossy makes koni_jxl a complete JPEG XL codec. This is a large project —
roughly the inverse of the entire lossy decode pipeline — so it's phased.
Every phase gates the same way the decoder does, but reversed: **our
encode → djxl decode → within an RMSE/max threshold of the source**, and
our own decoder must agree with djxl.

The decoder already gives us most of the hard reference material: the DCTs
(we invert them; the forward transforms share structure), the quant-weight
tables, XYB color, CfL math, coefficient orders, and the entropy encoder
from the lossless work. What the encoder adds is the *analysis* side —
choosing quantization, block sizes, and CfL — which is where perceptual
quality lives.

- 🔲 **L0 — minimal valid stream.** RGB→XYB forward (inverse of
  `opsin_inverse`), forward 8×8 DCT everywhere (no block-size selection),
  uniform quantization from a single distance parameter, no CfL, Gaborish
  and EPF disabled, default coefficient order, entropy-coded with the
  existing ANS/prefix encoder. Goal: a file djxl decodes at all, with a
  measured round-trip RMSE. Quality will be poor; correctness is the bar.
- 🔲 **L1 — rate control + coefficient model.** Map `distance` to quant
  the way libjxl does; get the DC image, LF/HF split, and the HF
  coefficient context model (non-zero counts, LF context, block context)
  exactly right so sizes are competitive at a given quality.
- 🔲 **L2 — perceptual quantization.** Adaptive quant field (per-block
  multipliers from a masking/heuristic model) and chroma-from-luma
  (per-block X-from-Y and B-from-Y that minimize residual). This is the
  jump from "works" to "looks good at a given bitrate."
- 🔲 **L3 — transform selection + filters.** Variable block sizes (choose
  among the 27 varblock transforms per region by a rate-distortion
  heuristic), and enable Gaborish/EPF with the encoder accounting for
  them. Approaches cjxl quality.
- 🔲 **L4 — API + gates.** `JxlEncoder.encodeLossy(..., distance:)`,
  Flutter helper, a lossy round-trip gate suite, benchmarks vs cjxl at
  matched distances.

Open question to settle before L0: target the **VarDCT** path (the real
lossy format, big but correct) vs a **lossy-modular** shortcut (quantize
then encode with the existing modular encoder — far less work, worse
quality, still "lossy"). The plan above assumes VarDCT.

---

## Lossless encoder refinements

Smaller levers on top of the current learned-tree + WP + ANS/LZ77 encoder.

- 🔲 **Predictor-selection heuristic.** The encoder runs both predictor
  pipelines (gradient and weighted) fully and keeps the smaller — ~2×
  encode time. Compare the two learned trees' training entropy first and
  run only the winner's full pipeline (Pass B + assembly). Roughly halves
  encode time for a sub-percent size risk.
- 🔲 **Larger hybrid split exponent for WP.** WP residuals have larger
  magnitudes, so the fixed `HybridIntegerConfig(4,1,0)` spends many extra
  bits. A larger split (fewer extra bits, bigger token alphabet) likely
  helps WP-chosen images; measure and pick per image.
- 🔲 **Delta palette.** The decoder supports delta-palette entries; the
  encoder only emits plain palettes. Would help near-flat color art.
- 🔲 **Per-leaf predictor selection.** The learned tree currently uses one
  predictor for all leaves. Letting each leaf pick gradient vs WP (vs
  others) is closer to what cjxl does and stacks with property 15.
- 🔲 **Better LZ77 matcher.** The current greedy hash-chain is basic;
  lazy matching / longer chains would help the (rare) repetitive cases
  where LZ77 already wins.

---

## Decoder gaps (documented, throw `JxlUnsupportedException`)

None block the manga use case; listed for completeness.

- 🔲 **ICC-driven output transform.** XYB/enum-transfer output is done;
  files whose color is described only by an embedded ICC profile are
  decoded as sRGB. A full ICC transform would fix the one documented
  `progressive` conformance tone-curve deviation.
- 🔲 **Spot-color rendering.** Spot-color extra channels.
- 🔲 **JPEG bitstream reconstruction.** Reconstruct the original JPEG from
  a JPEG-transcoded `.jxl` (needs the jbrd box + JPEG serialization).
- 🔲 **Float (HDR) sample formats.** 16/32-bit float output samples.

---

## Performance & infrastructure

- 🔲 **EPF pass-0 SIMD.** The `epfIterations == 3` path (rare) is scalar;
  an 11 MP triple-pass progressive photo takes ~6.5 s. Vectorize it.
- 🔲 **Isolate parallelism.** Evaluated and deferred (shared-nothing →
  re-parse or bulk copies; poor ROI at current single-thread speeds).
  Revisit if very large images or batch decoding become a use case.
- 🔲 **Downscaled decode.** A `decodeScaled(1/2, 1/4)` API (cheaper than
  decode-then-resize) for library grid/thumbnail views.
