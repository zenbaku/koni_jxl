# Benchmarks

Concrete, reproducible numbers for decode speed and compression efficiency,
plus the exact commands used to produce them. Every table below was
freshly regenerated for this revision, not carried over from an older one.
If you see a mismatch between this file and a prose claim elsewhere
(READMEs, `ROADMAP.md`), this file wins; it's the one with a rerunnable
command attached.

## Measured on

- Apple M1 (MacBook Pro, 4P+4E cores), macOS Darwin 25.2.0, single-threaded
- Dart SDK 3.12.1, **AOT-compiled** (`dart compile exe`) — not because
  AOT is always faster (it isn't; see the encode-time surprise below),
  but because it's how this codec actually ships on every real target
  (Flutter mobile/desktop). `dart run` (JIT) numbers can differ
  substantially in either direction and aren't reported here.
- libjxl (`cjxl`/`djxl`) v0.11.2
- Corpus: `tool/gen_corpus.py`'s synthetic images (1536x2200 "page"-sized
  content, plus a few smaller edge cases) — regenerate with
  `python3 tool/gen_corpus.py` from the repo root (needs `cjxl`/`djxl` on
  `PATH`)

Everything here uses the synthetic corpus, not `manga_samples/` (the user's
copyrighted CBZs, gitignored and never redistributed) — so every number is
independently reproducible from a clean checkout. Real-chapter numbers are
called out separately at the bottom, clearly labeled as non-reproducible.

## Decode speed

```
(cd packages/koni_jxl && dart compile exe tool/bench_decode.dart -o /tmp/bench_decode && /tmp/bench_decode)
```

Times are the median of 10 runs after 3 warmup iterations (see
`tool/bench_decode.dart`'s `--reps`/`--warmup` flags). The `djxl` column
times `Process.runSync` end to end — it includes process fork/exec and PPM
file I/O, a fixed cost that's a much larger fraction of djxl's very fast
decodes than of ours, so the `ours/djxl` ratio *understates* djxl's actual
decode-only speed. Files under 0.1 MP are skipped (too small for a stable
throughput number).

```
file                                 dims        MPix  mode      ours ms   ours MP/s  djxl ms  ours/djxl
alpha_page_d0_e7.jxl                 512x768      0.39  lossless     40.2        9.8     28.1        1.4
color_cover_d0.5_e7.jxl              1024x1536    1.57  lossy       213.2        7.4     44.0        4.8
color_cover_d0_e7.jxl                1024x1536    1.57  lossless    747.6        2.1    261.9        2.9
color_cover_d1.0_e7.jxl              1024x1536    1.57  lossy       241.7        6.5     47.2        5.1
color_cover_d2.0_e7.jxl              1024x1536    1.57  lossy       250.6        6.3     46.5        5.4
gray16_gradient_d0_e7.jxl            768x1100     0.84  lossless     79.7       10.6     42.1        1.9
gray_gradient_d0.5_e7.jxl            1536x2200    3.38  lossy       283.8       11.9     65.7        4.3
gray_gradient_d1.0_e7.jxl            1536x2200    3.38  lossy       383.2        8.8     76.8        5.0
gray_gradient_d2.0_e7.jxl            1536x2200    3.38  lossy       404.3        8.4     79.6        5.1
gray_screentone_d0.5_e7.jxl          1536x2200    3.38  lossy       303.7       11.1     71.8        4.2
gray_screentone_d0_e7.jxl            1536x2200    3.38  lossless    350.2        9.7    137.8        2.5
gray_screentone_d1.0_e7.jxl          1536x2200    3.38  lossy       404.9        8.3     96.1        4.2
gray_screentone_d2.0_e7.jxl          1536x2200    3.38  lossy       428.1        7.9    101.6        4.2
palette16_d0_e7.jxl                  512x512      0.26  lossless     10.9       24.1     22.0        0.5
```

Takeaways:

- **Lossless decode speed is dominated by content, not size.**
  `gray_screentone` (manga-style halftone/line-art, `screentone_page()` in
  `gen_corpus.py`) decodes losslessly at 350 ms/3.38 MP, but `color_cover`
  (smooth synthetic RGB gradients, 1.57 MP — under half the pixel count)
  takes over twice as long in absolute terms (748 ms) because smooth
  continuous-tone content pushes the weighted predictor and context
  modeling far harder than halftone/line art does. The manga use case this
  project targets looks like `gray_screentone`, not `color_cover`.
- Lossy decode across the corpus's 3.4 MP pages lands in the 0.28–0.43 s
  range at effort 7, consistent with `CLAUDE.md`'s "0.33–0.50 s"
  reference number.
- `palette16` decodes fastest by a wide margin (10.9 ms, 24 MP/s) — small
  palette content is cheap for both this decoder and djxl.

## Lossless compression vs. `cjxl`

```
(cd packages/koni_jxl && dart compile exe tool/bench_lossless_vs_cjxl.dart -o /tmp/bench_lossless && /tmp/bench_lossless)
```

This tool also decodes its own output and asserts it matches the source
pixels exactly before printing anything — a correctness regression can't
silently masquerade as a size win here. "vs koni_jxl" is this encoder's
size as a percentage of that row's `cjxl` size: under 100% means koni_jxl
is already smaller than that effort. Sizes are deterministic (JIT/AOT
doesn't change encoded bytes); `encode-ms` is AOT here — see the note
below the table on why that isn't the fastest way to run this specific
benchmark.

```
=== alpha_page_d0_e7.pam (512x768, 4ch, 8-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl     1313      100.0%     1778
  cjxl -e1     2290       57.3%       19
  cjxl -e3      845      155.4%       53
  cjxl -e7      797      164.7%      148
  cjxl -e9      644      203.9%      408

=== color_cover_d0_e7.ppm (1024x1536, 3ch, 8-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl   544919      100.0%     5284
  cjxl -e1   945349       57.6%       22
  cjxl -e3   675291       80.7%      195
  cjxl -e7   195510      278.7%     1575
  cjxl -e9    55319      985.0%    10709

=== gray16_gradient_d0_e7.pgm (768x1100, 1ch, 16-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl      840      100.0%     1443
  cjxl -e1   637119        0.1%       16
  cjxl -e3   111108        0.8%       44
  cjxl -e7    98123        0.9%      148
  cjxl -e9    15861        5.3%     3685

=== gray_screentone_d0_e7.pgm (1536x2200, 1ch, 8-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl     7602      100.0%     3031
  cjxl -e1   270467        2.8%       36
  cjxl -e3  1134149        0.7%      137
  cjxl -e7    40488       18.8%      470
  cjxl -e9    22348       34.0%     3021

=== palette16_d0_e7.ppm (512x512, 3ch, 8-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl      931      100.0%     1275
  cjxl -e1     1434       64.9%       16
  cjxl -e3     2154       43.2%       40
  cjxl -e7      800      116.4%       98
  cjxl -e9      741      125.6%      315
```

> **⚠️ Two comparison pitfalls, both learned the hard way (2026-07-08).**
> **(1) Match the effort/format.** The synthetic `gray_screentone` "beats
> `cjxl -e9`" figure is content-specific — that pattern is *regular and
> periodic*, which the gated LZ77 matcher exploits; don't generalize it to
> "always beats cjxl". **(2) Compare lossless to lossless.** On a *fair*
> like-for-like test — 14 real scanned manga pages (1200×1707 grayscale, from
> a private set), all encoders run losslessly on the **same decoded pixels** —
> this encoder totals **95.4% of an optimized grayscale PNG (i.e. ~4.6%
> smaller) and 104.9% of `cjxl -e7` (~4.9% larger)**. It is competitive. An
> earlier draft of this note wrongly reported "~2× larger than PNG": that
> compared this encoder's *lossless* output against the source files, which
> turned out to be **lossy JPEGs misnamed `.png`** — no lossless encoder can
> beat a lossy JPEG on size, and the mismatch (plus 1-channel-vs-3-channel)
> produced a bogus 2× that does not exist on a lossless-vs-lossless basis.

Takeaways:

- **On the *synthetic* halftone pattern (`gray_screentone`), this encoder beats
  every `cjxl` effort level, including `-e9`** (19% of `cjxl -e7`'s size, 34% of
  `-e9`'s) — content-specific (see pitfall 1 above): the pattern's regularity is
  what the LZ77 matcher exploits, so this is a ceiling, not a typical result.
  Three lossless rounds compound here (all in doc/spec_notes.md): the per-image
  hybrid-uint config choice (~3.9%), per-leaf predictor selection (−24.6%), and
  a deeper, gated LZ77 matcher (−46.5%, the largest lever, since LZ77 wins on
  *repetitive* content).
  `cjxl -e3` is not a meaningful comparison point for this image — `cjxl`'s
  own effort levels are **not monotonic in size** on this synthetic
  halftone pattern (verified independently: `-e1` 270 KB, `-e2` 507 KB,
  `-e3` 1134 KB, `-e5` 124 KB, `-e7` 40 KB, `-e9` 22 KB — `-e3` is the
  single worst effort level, over 4x larger than `-e1`). Don't cite a
  "beats cjxl -e3" number for this content; it's an artifact of `cjxl`,
  not a meaningful bar.
- **On real manga content, lossless-vs-lossless, this encoder is competitive:**
  ~4.6% smaller than optimized grayscale PNG and ~4.9% larger than `cjxl -e7`
  across 14 real pages (see pitfall 2). The residual ~5% gap to `cjxl` is a
  genuine modeling gap (its learned per-context RD search over predictors is
  more thorough than this encoder's fixed heuristics), but it is a few percent,
  not a chasm. Note this says nothing about whether re-encoding *saves space*:
  real manga is distributed as lossy JPEG, and no lossless encoder (koni, cjxl,
  or PNG) beats a lossy JPEG on file size — that is lossless-vs-lossy physics,
  not an encoder weakness.
- On smooth synthetic gradients (`color_cover`, `gray16_gradient`) this
  encoder is competitive with `cjxl -e1`/`-e3` but well behind `-e7`/`-e9`
  — libjxl's real rate-distortion search over predictors and context
  models pays off on continuous-tone content in a way this encoder's
  fixed-heuristic tree learning doesn't yet match. `gray16_gradient`'s
  860-byte result is a synthetic-content artifact (a purely formulaic
  16-bit ramp with near-zero residual under this encoder's predictor) —
  not representative of real 16-bit photo content, included for
  transparency rather than as a claim.
- `alpha_page` and `palette16` sit in between: smaller than `cjxl -e1`,
  larger than `-e3` and up.
- **Surprise: AOT is slower than JIT for `encode-ms` here.** A same-machine
  `dart run` of this tool gives `color_cover` 3.1 s, not the 4.4 s shown
  above — the reverse of the decode table, where AOT won. Each encode is
  one long cold call, not a warmed-up loop, which likely explains it: its
  hot inner loops probably run long enough within that single call for
  the JIT to profile and tier them up mid-flight, while default
  `dart compile exe` has no profile-guided optimization to draw on — but
  that's a hypothesis, not something this tool measured directly. Both
  figures are real and independently reproducible; AOT is reported here
  only for consistency with the decode table and with how this library
  actually ships (Flutter mobile/desktop is always AOT).

## Lossless vs. PNG and `cjxl` on real images (`test-images/png`)

The corpus above is synthetic. This is the fair, real-image, lossless-vs-
lossless check on the public [`test-images/png`](https://github.com/test-images/png)
`202105` set (18 × 400×400 PNGs, already `FileOptimizer`-optimized), all
encoders run on the *same decoded pixels*:

```
git clone --depth 1 https://github.com/test-images/png.git
cd png/202105 && for f in *.png; do magick "$f" "${f%.png}.ppm"; done
dart run tool/bench_lossless_png.dart png/202105     # koni + cjxl + source PNG
```

Results split cleanly by content type (bytes; % is koni's size vs that baseline;
round-trip bit-exact on all 18):

```
category                 koni      PNG    cjxl-e7   koni/PNG  koni/cjxl
photos + illustration  463069   584147   447681       79%      103%
web/UI screenshots     259886   259207   237030      100%      110%
solid-color swatches    65248    17321    74743      377%       87%
TOTAL                  788203   860675   759454       92%      104%
```

Takeaways:

- **On real photographic/illustration content this encoder is strong:** ~21%
  smaller than optimized PNG and within ~3% of `cjxl -e7` (`pg-couplevn` 70% of
  PNG, `ia-forrest` 77%). This is the meaningful lossless case, and the earlier
  lossless-optimization rounds pay off here.
- **Solid-color swatches: koni loses ~3.8× to PNG but *beats* `cjxl` (87%).**
  A 400×400 solid colour is ~1.9 KB as a palette PNG but ~7–8 KB in *any* JXL —
  fixed container/modular-header overhead on trivial content, shared by `cjxl`,
  not a koni-specific weakness.
- **Flat web/UI graphics — was the one real weakness, now largely closed.** The
  worst case, `web-booking` (a flat UI screenshot, 738 colours), went from koni
  30 KB (2.66× PNG, 2.15× `cjxl`) to **15.6 KB** (1.37× PNG, 1.11× `cjxl`) once
  the palette transform was allowed above 256 colours and chosen by a
  try-both-keep-smaller decision (see doc/spec_notes.md). The web/UI category as
  a whole went 106%→**100%** of PNG and 116%→**110%** of `cjxl`, with **zero
  regression** elsewhere (palette is only kept where it actually wins). The
  residual gap to `cjxl` on this category is its stronger LZ/context handling of
  the palette-index channel — the next lever if pursued.

## Lossy compression vs. `cjxl`

```
(cd packages/koni_jxl && dart compile exe tool/bench_lossy_vs_cjxl.dart -o /tmp/bench_lossy && /tmp/bench_lossy <golden.ppm/pgm>)
```

No arguments defaults to `color_cover`/`palette16`; pass
`../../third_party/corpus/golden/gray_screentone_d0_e7.pgm` explicitly for
the manga-style case. RMSE is computed by decoding both encoders' output
through `djxl` and comparing to the true source pixels (`cjxl`'s own RMSE
column shows `NaN` for grayscale sources in this tool — a pre-existing
gap in the PNM round-trip for single-channel `djxl` output, not a decode
failure; size-ratio is unaffected since it comes from the file directly).

```
=== gray_screentone_d0_e7.pgm (1536x2200) — manga-style ===
distance  encoder    bytes   size-ratio  rmse    encode-ms
  0.5     koni_jxl  1291275      0.81x    0.79    17850
  0.5     cjxl -e1  1593598      1.00x     NaN      109
  1.0     koni_jxl  1050127      0.83x    1.50    17698
  1.0     cjxl -e1  1259603      1.00x     NaN      109
  2.0     koni_jxl   912676      0.94x    3.05    17039
  2.0     cjxl -e1   966259      1.00x     NaN      103
  4.0     koni_jxl   723901      1.03x    6.05    16886
  4.0     cjxl -e1   702533      1.00x     NaN      101
  8.0     koni_jxl   553928      1.31x   10.72    16744
  8.0     cjxl -e1   423540      1.00x     NaN       99

=== color_cover_d0_e7.ppm (1024x1536) — smooth/photographic ===
distance  encoder    bytes   size-ratio  rmse    encode-ms
  1.0     koni_jxl   113455      1.52x    1.53     5991
  1.0     cjxl -e1    74624      1.00x    2.70       54
  1.0     cjxl -e7    49577      0.66x    1.39      787
```

(Full output, including `-e7` rows for every distance and the `palette16`
case, comes straight from the command above.)

Takeaways:

- On manga-style content at `distance` 0.5–2.0, this encoder already beats
  `cjxl -e1` (0.81–0.94x its size, at comparable or better RMSE) —
  `cjxl -e1` is the fair speed-matched comparison, since this encoder has
  no rate-distortion search over encoding modes. Past `distance` 2.0 the
  gap flips (1.03x at 4.0, 1.31x at 8.0): the RDOQ/quantization heuristics
  were tuned in the low-to-mid range where manga pages are actually
  encoded. `cjxl -e7`'s real RD search is smaller everywhere by a wide
  margin (0.37–0.54x) — the headroom `ROADMAP.md` tracks. **DCT 32x32**
  (`VardctL0Config.enableTransform32`, see `doc/spec_notes.md`) **can**
  flip the `distance=4.0` case to 0.95x on this specific corpus image (it
  has unusually large flat panel/speech-bubble regions) — but it defaults
  **off**, because testing against real `manga_samples/` chapter pages
  found the actual win there is -0.0% to -0.6%, not the -7.6% to -16.7%
  this corpus image suggests, for the same ~40% encode-time cost. The
  table above reflects the shipped default (`enableTransform32: false`);
  see the "Real-world manga chapters" section below for the numbers that
  decided this.
- On smooth/photographic content the gap to even `-e1` is larger
  (1.5x at `distance=1.0`) — consistent with the lossless table's finding
  that continuous-tone content is this encoder's weakest case relative to
  libjxl.
- Our own encode time (~18 s/page here, AOT) is far slower than
  `cjxl -e1` (~0.1 s) and even `cjxl -e7` (~1.5-2 s). Some of the gap to
  `cjxl` is intrinsic (pure Dart vs. libjxl's hand-optimized, SIMD-heavy
  C++ encoder; no multi-threading here yet), but not all of it is fairly
  chargeable to "Dart vs. C++": as the lossless table's AOT-vs-JIT note
  shows, this specific one-shot-call workload runs faster under a plain
  `dart run` (JIT) than AOT on this machine, so don't read the absolute
  encode-ms figures here as a language-speed verdict — the size and RMSE
  columns are the load-bearing numbers in this table. (Enabling
  `enableTransform32` adds a further ~40% on top of these figures — see
  `doc/spec_notes.md` for why that trade isn't on by default.)

## Real-world manga chapters (not reproducible from this repo)

Validated on commercially-distributed CBZ chapters in `manga_samples/`
(the user's copyrighted content — gitignored, never committed, no
fixtures derived from it are added to the repo). These numbers can't be
regenerated by anyone else and are recorded here only for context, not as
a claim to verify:

- 34/34 pages decode within a max pixel difference of 1/255 vs. `djxl`
- A real JPEG-transcoded manga page decodes in ~0.25–0.29 s
  single-threaded (see `doc/spec_notes.md`'s "Performance status")
- The lossless encoder's real-page compression ratio and "~0.3-1 s/page"
  timing (previously cited in the top-level README) predate this file and
  weren't independently reverified here; treat the corpus numbers above
  as the current, reproducible source of truth for compression and timing
  comparisons. The one real-content check attempted for this pass doesn't
  support reverifying that figure directly: `manga_samples/` only has
  JPEG-transcoded (lossy-source) pages, and re-encoding *those* pixels
  losslessly (`tool/reencode_lossless.dart`, AOT) took 8.7 s for a 3.4 MP
  page — but that's a much harder input than a typical clean scan (it's
  full of JPEG quantization noise the encoder's context model has to
  spend bits on), so it isn't a fair stand-in for "a real manga page"
  either. Take the "~0.3-1 s/page" figure as unverified until someone
  benchmarks against a clean (non-JPEG-transcoded) manga source.
- **`VardctL0Config.enableTransform32`'s default was decided here, not on
  the corpus.** The lossy `gray_screentone`/`color_cover` corpus numbers
  above (with `enableTransform32: true`) looked like a clear win — up to
  -16.7% smaller at distance 0.5-4.0 — enough to briefly ship it on by
  default (see `doc/spec_notes.md`). Testing against 6 real
  `manga_samples/` pages (a B&W screentone-heavy chapter and a flat-color
  "digital colored comics" chapter, both at distance 1.0 and 4.0, with
  `enableVariableTransforms: true` in both arms to isolate just the
  level-2 effect) found the real win is **-0.0% to -0.6%** — an order of
  magnitude smaller — for the same ~40% encode-time cost measured on the
  corpus. RMSE was unchanged; this reverted the default to **off**. The
  corpus' `gray_screentone` golden overstates how much flat-region content
  (panels, speech bubbles) real manga pages actually contain relative to
  halftone/line-art texture — a synthetic proxy built to *exercise* a
  feature isn't the same as one that *represents* typical content, and
  this is the concrete number that distinction cost.
- **`enableRectangularTransforms`/`enableBespokeTransforms` real-manga ROI
  (round 17, `tool/bench_manga_roi.dart`, reproducible against these
  specific CBZ files though not by anyone else — 12 pages spread across
  both chapters, 2 distances, 144 encodes total, zero RMSE regressions):**

  ```
  combo                 grand-total-bytes   vs. baseline   avg encode-time
  baseline                     10057372         (base)          1.00x
  +rect                        10029111         -0.28%          2.22x
  +bespoke                     10034779         -0.22%          4.32x
  +rect+bespoke                 9995928         -0.61%          5.10x
  +32                          10004324         -0.53%          1.42x
  +32+rect+bespoke              9971114         -0.86%          6.10x
  ```

  `+32` alone reproduces the DCT32x32 finding above almost exactly
  (-0.53% vs. -0.0% to -0.6%) on an independent, larger page sample — a
  cross-check that this repeatable harness measures the same thing that
  earlier one-off process did. The best combo found (-0.86%, 6.1x encode
  time) doesn't clear the bar either, for the same reason: real but small
  relative to the encode-time cost. One real, previously-unmeasured risk
  surfaced: `+bespoke` alone made one specific real page (the shortest,
  sparsest page in the B&W chapter) **worse** by +4-5%, not just neutral
  — see `doc/spec_notes.md`'s round 17 entry for the full write-up. At
  the time, combining `+bespoke` with `+rect` appeared to route around
  this specific case (-0.11%/-0.58%, a real recovery) — **round 18
  (below) found this recovery was an accident of the old code's
  processing order, not a durable property of the feature.** All
  defaults remain **off**.

- **Round 18: made the same knobs' underlying decision genuinely joint
  (not a greedy sequential chain) — real bugs fixed, real-manga ROI got
  *worse*, not better** (`doc/spec_notes.md`'s round 18 entry has the
  full root-cause analysis):

  ```
  combo               round 17    round 18    encode-time (r17 -> r18)
  baseline               (base)      (base)      1.00x  ->  1.00x
  +rect                  -0.28%      -0.20%      2.22x  ->  2.03x
  +bespoke               -0.22%      -0.20%      4.32x  ->  2.45x
  +rect+bespoke          -0.61%      -0.29%      5.10x  ->  3.50x
  +32                    -0.53%      -0.53%      1.42x  ->  1.43x
  +32+rect+bespoke       -0.86%      -0.51%      6.10x  ->  4.49x
  ```

  `baseline`/`+32` are bit-for-bit unchanged (neither touches the
  rewritten code) — every combo that *does* touch it got real encode-time
  wins (as designed: collapsing up to ~14 real-assembled candidates down
  to ~2) but a real compression regression. The Naruto page-017 case is
  numerically identical to round 17 for `+bespoke` alone (+4.04%/+5.39%,
  confirming the regression itself was never caused by the ordering
  artifact round 18 fixes) but `+rect+bespoke` no longer recovers it
  (identical bytes to `+bespoke` alone, both distances) — the old code's
  recovery depended on its rectangular pre-pass running *before* bespoke
  and claiming some cells first (making them structurally unreachable to
  a later bespoke pass), an accident of processing order that a more
  principled Level-0-then-Level-1 separation of concerns can't reproduce.
  This round's own pre-stated success criterion (shrink the page-017
  regression, improve the aggregate wins) was not met. All defaults
  remain **off** — this doesn't change either way, though it does temper
  expectations for what a bottom-up *sequence* of joint levels can
  recover vs. a genuinely unified one (see ROADMAP.md).
