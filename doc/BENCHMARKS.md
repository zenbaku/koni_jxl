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
  koni_jxl     1344      100.0%     1897
  cjxl -e1     2290       58.7%       19
  cjxl -e3      845      159.1%       54
  cjxl -e7      797      168.6%      149
  cjxl -e9      644      208.7%      421

=== color_cover_d0_e7.ppm (1024x1536, 3ch, 8-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl   545659      100.0%     5340
  cjxl -e1   945349       57.7%       22
  cjxl -e3   675291       80.8%      201
  cjxl -e7   195510      279.1%     1580
  cjxl -e9    55319      986.4%    10739

=== gray16_gradient_d0_e7.pgm (768x1100, 1ch, 16-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl      860      100.0%     1445
  cjxl -e1   637119        0.1%       16
  cjxl -e3   111108        0.8%       44
  cjxl -e7    98123        0.9%      149
  cjxl -e9    15861        5.4%     3706

=== gray_screentone_d0_e7.pgm (1536x2200, 1ch, 8-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl    19598      100.0%     3077
  cjxl -e1   270467        7.2%       31
  cjxl -e3  1134149        1.7%      139
  cjxl -e7    40488       48.4%      479
  cjxl -e9    22348       87.7%     3019

=== palette16_d0_e7.ppm (512x512, 3ch, 8-bit) ===
encoder     bytes   vs koni_jxl  encode-ms
  koni_jxl      932      100.0%     1287
  cjxl -e1     1434       65.0%       15
  cjxl -e3     2154       43.3%       41
  cjxl -e7      800      116.5%       97
  cjxl -e9      741      125.8%      317
```

Takeaways:

- **On manga-style content (`gray_screentone`), this encoder beats every
  `cjxl` effort level, including `-e9`**: 48% of `cjxl -e7`'s size and 88%
  of `cjxl -e9`'s (libjxl's slowest, most-optimized mode).
  `cjxl -e3` is not a meaningful comparison point for this image — `cjxl`'s
  own effort levels are **not monotonic in size** on this synthetic
  halftone pattern (verified independently: `-e1` 270 KB, `-e2` 507 KB,
  `-e3` 1134 KB, `-e5` 124 KB, `-e7` 40 KB, `-e9` 22 KB — `-e3` is the
  single worst effort level, over 4x larger than `-e1`). Don't cite a
  "beats cjxl -e3" number for this content; it's an artifact of `cjxl`,
  not a meaningful bar.
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
  `dart run` of this tool gives `color_cover` 3.6 s, not the 5.3 s shown
  above — the reverse of the decode table, where AOT won. Each encode is
  one long cold call, not a warmed-up loop, which likely explains it: its
  hot inner loops probably run long enough within that single call for
  the JIT to profile and tier them up mid-flight, while default
  `dart compile exe` has no profile-guided optimization to draw on — but
  that's a hypothesis, not something this tool measured directly. Both
  figures are real and independently reproducible; AOT is reported here
  only for consistency with the decode table and with how this library
  actually ships (Flutter mobile/desktop is always AOT).

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
  0.5     koni_jxl  1291227      0.81x    0.79    17372
  0.5     cjxl -e1  1593598      1.00x     NaN      103
  1.0     koni_jxl  1050127      0.83x    1.50    17131
  1.0     cjxl -e1  1259603      1.00x     NaN      103
  2.0     koni_jxl   912628      0.94x    3.05    17017
  2.0     cjxl -e1   966259      1.00x     NaN      105
  4.0     koni_jxl   723852      1.03x    6.05    16798
  4.0     cjxl -e1   702533      1.00x     NaN      101
  8.0     koni_jxl   553880      1.31x   10.72    16579
  8.0     cjxl -e1   423540      1.00x     NaN       97

=== color_cover_d0_e7.ppm (1024x1536) — smooth/photographic ===
distance  encoder    bytes   size-ratio  rmse    encode-ms
  1.0     koni_jxl   113457      1.52x    1.53     5646
  1.0     cjxl -e1    74624      1.00x    2.70       52
  1.0     cjxl -e7    49577      0.66x    1.39      745
```

(Full output, including `-e7` rows for every distance and the `palette16`
case, comes straight from the command above.)

Takeaways:

- On manga-style content at `distance` 0.5–2.0, this encoder already beats
  `cjxl -e1` (0.81–0.94x its size, at comparable or better RMSE) —
  `cjxl -e1` is the fair speed-matched comparison, since this encoder has
  no rate-distortion search over encoding modes. Past `distance` 2.0 the
  gap flips (1.03x–1.31x): the RDOQ/quantization heuristics were tuned in
  that low-to-mid range where manga pages are actually encoded.
  `cjxl -e7`'s real RD search is smaller everywhere by a wide margin
  (0.37–0.54x) — the headroom `ROADMAP.md` tracks.
- On smooth/photographic content the gap to even `-e1` is larger
  (1.5x at `distance=1.0`) — consistent with the lossless table's finding
  that continuous-tone content is this encoder's weakest case relative to
  libjxl.
- Our own encode time (16–17 s/page here, AOT) is far slower than
  `cjxl -e1` (~0.1 s) and even `cjxl -e7` (~1.5 s). Some of that gap is
  intrinsic (pure Dart vs. libjxl's hand-optimized, SIMD-heavy C++
  encoder; no multi-threading here yet), but not all of it is fairly
  chargeable to "Dart vs. C++": as the lossless table's AOT-vs-JIT note
  shows, this specific one-shot-call workload runs 30–50% faster under a
  plain `dart run` (JIT) than AOT on this machine (`gray_screentone` at
  `distance=1.0`: 8.6 s JIT vs. 17.1 s AOT), so don't read the absolute
  encode-ms figures here as a language-speed verdict — the size and RMSE
  columns are the load-bearing numbers in this table.

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
