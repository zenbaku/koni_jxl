# CLAUDE.md — development playbook for koni_jxl

Pure-Dart JPEG XL decoder monorepo (pub workspace). Goal: render `.jxl`
in Dart/Flutter with zero native dependencies; primary use case is manga
readers. Feature-complete for that purpose (milestones M0–M7 done, plus
animation and splines).

## Layout

- `packages/koni_jxl` — decoder + lossless encoder core, zero runtime
  deps.
  `lib/src/`: `io/` (BitReader, container), `entropy/` (prefix + ANS +
  LZ77 + hybrid-uint), `modular/` (lossless: MA trees, predictors,
  RCT/palette/squeeze), `vardct/` (lossy: DCTs, dequant, CfL, orders),
  `frame/` (frame loop, TOC, LfGlobal, patches, splines), `encode/`
  (headers/entropy/modular writers — every writer mirrors a reader in
  this repo; when touching one, keep them in lockstep), `render/`
  (blend, filters, noise, upsample, transpose), `color/` (XYB, transfer
  functions), `util/` (ImageBuffer = row-based planes, math).
- `packages/koni_jxl_flutter` — `JxlImageProvider`, `decodeJxlToUiImage`,
  `decodeJxlAnimation`/`JxlAnimationView`, `decodeJxlProgressive`/
  `JxlProgressiveImage`; `example/` gallery app.
- `doc/spec_notes.md` — **the deviations ledger.** Every known difference
  vs libjxl or vs jxlatte lives here. Update it whenever behavior
  deviates or a deviation is fixed.
- `tool/` (repo root) — `gen_corpus.py` (regenerates the test corpus into
  gitignored `third_party/corpus`; needs `cjxl`/`djxl` 0.11.x from brew),
  `check_jxl_info.py` (header gate vs `jxlinfo`).
- `packages/koni_jxl/tool/` — dev tools: `profile_decode.dart` (phase
  timings; compile with `-Djxl.timings=true`), `bench_dct.dart`,
  `bench_simd.dart`, `anim_dump.dart` (frames → PAM;
  `-Djxl.framedebug=true` prints frame headers).
- `third_party/` (all gitignored): `jxlatte/` (MIT Java reference clone),
  `conformance/` (official testcases), `corpus/` (generated).
- `manga_samples/` — user's copyrighted CBZs. **Never commit. Never add
  fixtures derived from them to the repo.**

## Commands

```bash
dart analyze                                   # must be clean
dart format packages/koni_jxl packages/koni_jxl_flutter
(cd packages/koni_jxl && dart test)            # ~200 tests incl. gates
(cd packages/koni_jxl_flutter && flutter test)
(cd packages/koni_jxl_flutter/example && flutter test)
```

Gates auto-skip when `cjxl`/`djxl` or `third_party/corpus` /
`third_party/conformance` are missing — a green run on a machine without
them proves less than it looks like. This machine has everything.

## Methodology (this is what made the project work)

1. **Port jxlatte near-verbatim first**, quirks and all; do not "clean
   up" fixed-point arithmetic while porting. Big constant tables are
   extracted from the Java source by python scripts into generated
   `.dart` files, never hand-typed.
2. **Gate everything against djxl**: bit-exact compares for lossless,
   `rmse < 2.0` and `max < 48` (8-bit) for lossy. Never relax the
   lossless bit-exactness gates.
   Encoder gates are round-trips: our encode must decode bit-exact
   through BOTH our decoder and djxl.
3. **When output differs from djxl, run jxlatte itself** before
   debugging (`javac -d out $(find java -name '*.java')`, main class
   `com.traneptora.jxlatte.JXLatte`). Identical deviation → inherited;
   document in `doc/spec_notes.md`. Different → our port bug.
4. jxlatte has real bugs — two found and fixed so far (patch blend-mode
   remap; splines rendered with spline 0's coefficients). When beyond
   jxlatte's capabilities (multi-frame animation), djxl alone is ground
   truth. When fixing, verify against djxl and record it in spec_notes.
5. Java → Dart semantics: `int/2` → `~/`, `>>>` on non-negatives → `>>`,
   Dart ints wrap like Java longs (64-bit).

## Performance rules (Dart AOT, hard-won)

- **Never derive a hot-loop `List<Float32List>` from a nested generic
  container** (`List<List<Float32List>>[c]`) inside the hot function —
  costs 5–20×. Pass per-channel row lists as direct parameters from a
  call site where the concrete class is statically known.
- Typed-data *views* (`sublistView`) are a different class than real
  `Float32List` → megamorphic call sites. Planes are row-based
  (`ImageBuffer.floatRows`) for this reason.
- No allocations in per-pixel loops (a `[a, b, c]` literal per pixel cost
  30% of lossless decode once). No records/iterators in pixel loops.
  `math.pow` returns `num` — `.toDouble()` it.
- Float32x4 SIMD is real NEON/SSE under AOT **if** vectors stay in
  locals, storage is `Float32x4List` views (16-byte alignment), and you
  never touch `Int32x4` — its masks box; use float-arithmetic masks
  (e.g. `(v.abs() - 1).clamp(0, 1)` for integer-valued lanes).
  `shuffleMix` does 4×4 transposes in 8 ops; `.scale(double)` applies
  scalar constants without splats. dart2js emulates SIMD (slow web).
- **Measure before optimizing**: per-case timing inside a switch, A/B
  microbenchmarks (copy the loop into a standalone tool, morph one
  difference at a time), `const bool.fromEnvironment` skips to bisect.
  Assumptions here have been wrong repeatedly (DCT2 looked hot, was
  0.2 ms; 64×64 DCTs were 127 ms).
- Reference numbers (3.4MP page, Apple Silicon, single-thread AOT):
  lossless 60–410 ms; lossy 0.33–0.50 s; real CBZ page ~0.29 s. If a
  change regresses these noticeably, find out why.
- Isolate parallelism was evaluated and deferred (see spec_notes).

## Conventions

- `dart format` before committing; analyzer must be clean.
- Commit messages: imperative summary line, body explains what/why with
  measured numbers when perf-related.
- Corpus changes go through `tool/gen_corpus.py` (reproducible), never
  hand-placed files; `MANIFEST.sha256` is regenerated by the script.
- Tests follow the existing gate idiom: `PnmImage.parse` +
  `channelAsInts` compares, `skip:` when tools/corpus absent.
- Version is `0.1.0-dev`; both packages pass `pub publish --dry-run`.
  Publishing requires the owner's pub.dev account — never publish
  autonomously.

## Remaining known gaps (throw `JxlUnsupportedException`)

Spot-color rendering, JPEG bitstream reconstruction, float (HDR) sample
formats, ICC-driven output transforms. None block the manga use case.
Known slow path: EPF pass 0 (epfIterations == 3, rare) is scalar; an
11MP triple-pass progressive photo takes ~6.5 s.
