#!/usr/bin/env python3
"""M0 gate: compare `dart run bin/jxl_info.dart` output against libjxl's
`jxlinfo` for every .jxl file passed on the command line (or the full
conformance corpus by default)."""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DART_CLI = ROOT / "packages/koni_jxl/bin/jxl_info.dart"

# jxlinfo prints the codestream (pre-orientation) size on its first line.
FIRST_LINE = re.compile(
    r"JPEG XL (image|animation), (\d+)x(\d+), (lossy|\(possibly\) lossless), "
    r"(\d+)-bit (?:float \(\d+ exponent bits\) )?(Grayscale|RGB|CMY)"
    r"((?:\+\w+)*)"
)


def jxlinfo_fields(path):
    out = subprocess.run(["jxlinfo", str(path)], capture_output=True, text=True)
    m = FIRST_LINE.search(out.stdout)
    if not m:
        return None
    kind, w, h, loss, bits, space, extras = m.groups()
    return {
        "animated": kind == "animation",
        "encoded_dimensions": f"{w}x{h}",
        "xyb_encoded": loss == "lossy",
        "bits_per_sample": int(bits),
        "grayscale": space == "Grayscale",
        "alpha": "+Alpha" in extras,
    }


def dart_fields(path):
    out = subprocess.run(
        ["dart", "run", str(DART_CLI), str(path)],
        capture_output=True, text=True, cwd=ROOT,
    )
    if out.returncode != 0:
        return {"error": out.stderr.strip()}
    fields = {}
    for line in out.stdout.splitlines():
        if ":" in line and line.startswith("  "):
            k, v = line.strip().split(":", 1)
            fields[k.strip()] = v.strip()
    # Sanity-check the oriented size is the transpose for orientation 5-8.
    ew, eh = map(int, fields["encoded_dimensions"].split("x"))
    w, h = map(int, fields["dimensions"].split("x"))
    transposed = int(fields["orientation"]) > 4
    if (w, h) != ((eh, ew) if transposed else (ew, eh)):
        return {"error": f"oriented size {w}x{h} inconsistent with "
                f"encoded {ew}x{eh}, orientation {fields['orientation']}"}
    return {
        "animated": fields["animated"] == "true",
        "encoded_dimensions": fields["encoded_dimensions"],
        "xyb_encoded": fields["xyb_encoded"] == "true",
        "bits_per_sample": int(fields["bits_per_sample"].split()[0]),
        "grayscale": fields["color_channels"] == "1",
        "alpha": fields["alpha"] == "true",
    }


def main():
    files = [Path(a) for a in sys.argv[1:]]
    if not files:
        files = sorted(
            (ROOT / "third_party/conformance/testcases").glob("*/input.jxl"))
    failures = 0
    for f in files:
        ref = jxlinfo_fields(f)
        if ref is None:
            print(f"SKIP {f} (jxlinfo did not report a parseable first line)")
            continue
        got = dart_fields(f)
        if "error" in got:
            print(f"FAIL {f}: dart error: {got['error']}")
            failures += 1
            continue
        diffs = {k: (ref[k], got[k]) for k in ref if ref[k] != got[k]}
        if diffs:
            print(f"FAIL {f}: {diffs}")
            failures += 1
        else:
            print(f"OK   {f.parent.name}")
    print(f"\n{failures} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
