# Lossy (VarDCT) encoder — implementation plan

Goal: `JxlEncoder.encodeLossy(pixels, ..., distance: d)` producing a real
VarDCT JPEG XL stream that djxl decodes within an RMSE/max threshold of
the source. This makes koni_jxl a complete codec (we already decode
VarDCT and encode lossless modular).

This is the inverse of the entire VarDCT decode pipeline. It is a large,
multi-session build, so it is phased (L0–L4). Each phase has a concrete
gate. The decoder is the reference for every bitstream field and every
transform — **the rule for the whole project holds: every encoder writer
mirrors a specific decoder reader; when in doubt, read the reader.**

---

## The pipeline to invert

Decode (what we already have) → Encode (what we build), stage by stage:

| Decode stage | Encode inverse | Decoder ref |
|---|---|---|
| XYB → linear RGB (opsin inverse) | RGB → XYB (opsin forward) | `color/opsin_inverse.dart` |
| dequantize coefficients | quantize (divide by weights, round) | `vardct/dequant`, quant weight tables |
| inverse DCT per varblock | forward DCT per varblock | `vardct/dct.dart` |
| CfL: add Y-scaled chroma back | CfL: choose X/B-from-Y multipliers | `vardct/lf_channel_correlation.dart` |
| read HF coeffs (context model) | tokenize + entropy-code HF coeffs | `vardct/hf_coefficients.dart`, `hf_block_context.dart` |
| read LF (DC) image | build + code the DC (LF) image | `vardct/lf_coefficients.dart` |
| read quantizer / HfGlobal | write quantizer / HfGlobal | `vardct/hf_global.dart` |
| transform-type per block (HfMeta) | choose + write transform types | `vardct/hf_metadata.dart`, `transform_type.dart` |
| Gaborish / EPF smoothing | disable (L0–L2) or account for (L3) | `render/filters.dart` |

Analysis the encoder adds (no decode counterpart): quantization choice
(rate control + adaptive quant field), block-size/transform selection,
and CfL coefficient search. This is where perceptual quality lives.

---

## Bitstream structure to emit (VarDCT frame)

Mirror `frame/frame.dart` decode order. Differences from the lossless
modular frame we already emit:

- **Frame header**: `encoding = vardct` (not modular). Filters: Gaborish
  and EPF **off** initially. (Study `frame/frame_header.dart`.)
- **Section/TOC layout**: `1 + numLfGroups + 1 + numGroups*numPasses`
  entries — LfGlobal, one per LF group, HfGlobal, then one pass-group per
  (pass, group). We currently emit empty LF/HfGlobal for modular; for
  VarDCT they carry real data.
- **LfGlobal (VarDCT)**: patches/splines/noise flags (all off), LF
  channel-correlation (CfL) defaults or values, LF dequant, the global
  modular sub-stream (for the LF image if not XYB-DC-in-VarDCT), quantizer.
  Read `frame/lf_global.dart` VarDCT branch.
- **LfGroup**: the DC/LF coefficients, the HF-metadata (transform types +
  per-block quant multipliers + CfL per block), the block context map.
  Read `frame/frame.dart` `_decodeLfGroups` and `vardct/hf_metadata.dart`.
- **HfGlobal**: quantizer params, the HF-pass coefficient-order
  permutations, and the HF coefficient histograms/context model.
  Read `vardct/hf_global.dart` and `hf_pass.dart`.
- **PassGroup**: the HF coefficients per group, entropy-coded with the
  block context model. Read `vardct/hf_coefficients.dart`.

Reuse from the lossless encoder: `BitWriter`, the header writers, the
entropy encoder (`EntropyCodes` — prefix + ANS), coefficient tokenization
via `tokenizeHybrid`. The HF coefficient **context model** is VarDCT-
specific (non-zero counts drive contexts) and must be mirrored exactly
from `hf_coefficients.dart` / `hf_block_context.dart`.

---

## Phases

### L0 — minimal valid stream (correctness only)
- RGB→XYB forward transform (exact inverse of `opsin_inverse`; verify by
  round-tripping XYB→RGB→XYB on random pixels).
- Forward 8×8 DCT only (transform type 0 everywhere; no block-size
  search). Derive from `dct.dart`'s inverse; unit-test forward∘inverse ==
  identity.
- Uniform quantization from a single global quant step; quantize LF (DC)
  and HF coefficients; round to ints.
- Write the full VarDCT frame: header, LfGlobal, LfGroups (DC + trivial
  HfMeta: all 8×8, uniform quant multiplier, zero CfL), HfGlobal (default
  order, histograms over the actual coefficients), pass-groups (HF coeffs).
- Filters off. Single pass. Start with a **single-group** small image.
- **Gate**: djxl decodes it without error; measure round-trip RMSE/max vs
  source. Quality will be poor — correctness is the bar. Also decode with
  our own decoder and confirm it agrees with djxl.

### L1 — rate control + coefficient model
- Map a `distance` parameter to the quantizer the way libjxl does (LF vs
  HF quant weights per channel and frequency; study the dequant weight
  tables). Get the DC image handling and LF/HF split exactly right.
- Correct HF coefficient context model (non-zero prediction, LF context,
  block context) so token sizes match what the decoder expects and files
  are competitively sized at a quality.
- Multi-group / multi-LF-group support (drop the single-group restriction).
- **Gate**: round-trip RMSE monotonically improves with smaller distance;
  size at a fixed distance within a sane factor of cjxl at the same
  distance.

### L2 — perceptual quantization
- Adaptive quant field: per-block quant multiplier from a masking /
  activity heuristic (approximate libjxl's adaptive quantization). This is
  the biggest quality lever.
- Chroma-from-luma: per-block X-from-Y and B-from-Y multipliers chosen to
  minimize the chroma residual; write them in HfMeta; account for them in
  quantization.
- **Gate**: at matched distance, RMSE/butteraugli-proxy meaningfully
  better than L1; visually reasonable.

### L3 — transform selection + filters
- Variable block sizes: choose among the 27 varblock transforms per region
  by a rate-distortion heuristic (start with a small subset: 8×8, 16×16,
  32×32, maybe DCT with a flat-region → larger-block rule).
- Enable Gaborish and EPF, with the encoder pre-compensating (or accepting
  the smoothing). Study how libjxl decides.
- **Gate**: approaches cjxl quality/size at matched distance on the
  benchmark set.

### L4 — API, Flutter, gates, docs
- `JxlEncoder.encodeLossy(pixels, {width, height, distance, ...})` and a
  `JxlImage` variant; Flutter `encodeJxlLossy...` helper (background
  isolate).
- A lossy round-trip gate suite (our encode → djxl decode → RMSE/max
  thresholds; plus our-decoder agreement) across the corpus.
- Benchmarks vs cjxl at matched distances; README/CHANGELOG/spec_notes.

---

## Verification strategy

- **Forward-transform unit tests first**: XYB round-trip and forward-DCT ∘
  inverse-DCT == identity (within float tolerance) before any bitstream
  work. These catch the math bugs cheaply.
- **Bitstream gates via djxl**: every phase's primary gate is our encode →
  djxl decode. If djxl errors, the bitstream is malformed; if it decodes
  but RMSE is huge, the quantization/coefficient math is wrong.
- **Cross-check our decoder**: our VarDCT decoder must decode our lossy
  output and agree with djxl (they should be bit-identical up to the
  documented large-DCT deviation, which L0–L2 avoid by staying ≤ 8×8).
- Reuse the corpus + the existing lossy gate idiom (`rmse < 2.0`,
  `max < 48` at 8-bit) but reversed (we produce the file).

---

## Key risks / open questions

- **Coefficient context model fidelity**: the HF context model is the
  fiddliest part; getting non-zero-count contexts exactly right is
  essential for djxl to decode. Budget time to mirror
  `hf_coefficients.dart` precisely.
- **Quantizer semantics**: libjxl's distance→quant mapping and the
  per-frequency quant weight tables are intricate. L0 sidesteps with a
  crude uniform quant; L1 must get this right for competitiveness.
- **XYB forward exactness**: the opsin forward must invert the decoder's
  opsin inverse closely enough that round-trip error is quantization-only.
- **Encode speed**: analysis (transform selection, CfL search, adaptive
  quant) can be slow; keep L0–L1 simple and optimize later.
- **Scope creep**: resist implementing all 27 transforms at once. L0 is
  8×8-only on purpose.

---

## Reference files to study before L0

- `frame/frame.dart` — VarDCT decode order, section layout, LfGroup/Pass.
- `frame/frame_header.dart` — the VarDCT frame-header fields.
- `frame/lf_global.dart` — VarDCT LfGlobal (quantizer, CfL, LF dequant).
- `vardct/hf_global.dart`, `vardct/hf_pass.dart` — quantizer + orders +
  histograms.
- `vardct/hf_metadata.dart`, `vardct/transform_type.dart` — transform
  types, per-block quant/CfL.
- `vardct/hf_coefficients.dart`, `vardct/hf_block_context.dart` — the HF
  coefficient context model (mirror exactly).
- `vardct/lf_coefficients.dart` — the DC/LF image.
- `vardct/dct.dart` — the DCTs (invert for the forward transform).
- `color/opsin_inverse.dart` — invert for RGB→XYB.
- `encode/` — everything reusable: BitWriter, headers, entropy encoder.
