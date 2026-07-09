#!/usr/bin/env python3
"""Generates the local test corpus: deterministic synthetic manga-style
source images, a cjxl settings matrix, and djxl golden outputs.

Everything lands under third_party/corpus/ (gitignored); a sha256 manifest is
written so drift is detectable. Requires Pillow and cjxl/djxl on PATH.

Usage: python3 tool/gen_corpus.py [--quick]
  --quick: skip effort 9 and the lossy matrix (fast iteration)
"""

import hashlib
import math
import random
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "third_party" / "corpus"
SRC = CORPUS / "src"
JXL = CORPUS / "jxl"
GOLD = CORPUS / "golden"

QUICK = "--quick" in sys.argv

EXPECTED_CJXL_VERSION = "v0.11.2"


def check_tools():
    out = subprocess.run(["cjxl", "--version"], capture_output=True, text=True)
    if EXPECTED_CJXL_VERSION not in out.stdout + out.stderr:
        sys.exit(f"cjxl {EXPECTED_CJXL_VERSION} required, got: {out.stdout}")


# --- synthetic sources ----------------------------------------------------

def screentone_page(w, h):
    """Halftone dots, panel borders, speech bubbles: manga line-art proxy."""
    img = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(img)
    rng = random.Random(42)
    # panels
    for (x0, y0, x1, y1) in [(20, 20, w - 20, h // 3), (20, h // 3 + 20, w // 2 - 10, h - 20),
                             (w // 2 + 10, h // 3 + 20, w - 20, h - 20)]:
        d.rectangle([x0, y0, x1, y1], outline=0, width=6)
    # halftone screentone regions with varying dot pitch
    for (rx0, ry0, rx1, ry1, pitch, r) in [
            (40, 40, w - 40, h // 3 - 20, 8, 2),
            (40, h // 3 + 40, w // 2 - 30, h - 40, 6, 2),
            (w // 2 + 30, h // 3 + 40, w - 40, h // 2, 10, 3)]:
        y = ry0
        row = 0
        while y < ry1:
            x = rx0 + (pitch // 2 if row % 2 else 0)
            while x < rx1:
                d.ellipse([x - r, y - r, x + r, y + r], fill=96)
                x += pitch
            y += pitch
            row += 1
    # speech bubbles
    for (cx, cy, rw, rh) in [(w // 4, h // 6, 180, 100), (3 * w // 4, h // 2, 160, 90)]:
        d.ellipse([cx - rw, cy - rh, cx + rw, cy + rh], fill=255, outline=0, width=4)
        # fake text lines
        for i in range(4):
            ty = cy - rh // 2 + i * (rh // 4)
            d.line([cx - rw // 2, ty, cx + rw // 2 - rng.randint(0, rw // 2), ty],
                   fill=0, width=3)
    # hard black areas
    d.polygon([(w - 300, h - 400), (w - 60, h - 500), (w - 100, h - 100)], fill=0)
    return img


def gradient_page(w, h):
    """Smooth gradients: exercises squeeze/lossy paths."""
    img = Image.new("L", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            v = 128 + 90 * math.sin(x / 97.0) * math.cos(y / 71.0)
            v += 30 * math.sin((x + y) / 211.0)
            px[x, y] = max(0, min(255, int(v)))
    return img


def color_cover(w, h):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            r = int(127 + 120 * math.sin(x / 83.0 + y / 191.0))
            g = int(127 + 120 * math.sin(y / 67.0))
            b = int(127 + 120 * math.cos((x - y) / 131.0))
            px[x, y] = (r & 0xFF, g & 0xFF, b & 0xFF)
    d = ImageDraw.Draw(img)
    d.rectangle([w // 8, h // 8, 7 * w // 8, 3 * h // 8], outline=(0, 0, 0), width=8)
    d.ellipse([w // 4, h // 2, 3 * w // 4, 7 * h // 8], fill=(255, 255, 255),
              outline=(0, 0, 0), width=5)
    return img


def gray16_page(w, h):
    img = Image.new("I;16", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = (x * 65535 // max(1, w - 1) + y * 31) & 0xFFFF
    return img


def alpha_page(w, h):
    img = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([w // 8, h // 8, 7 * w // 8, 7 * h // 8], fill=(40, 40, 40, 255))
    d.rectangle([w // 3, h // 3, 2 * w // 3, 2 * h // 3], fill=(200, 30, 30, 128))
    return img


def palette_page(w, h):
    rng = random.Random(7)
    colors = [(rng.randrange(256), rng.randrange(256), rng.randrange(256))
              for _ in range(14)] + [(0, 0, 0), (255, 255, 255)]
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)
    for i in range(120):
        c = colors[rng.randrange(16)]
        x, y = rng.randrange(w), rng.randrange(h)
        d.rectangle([x, y, x + rng.randrange(10, 120), y + rng.randrange(10, 120)],
                    fill=c)
    return img


def make_sources():
    SRC.mkdir(parents=True, exist_ok=True)
    full = (1536, 2200) if not QUICK else (512, 736)
    pages = {
        "gray_screentone": screentone_page(*full),
        "gray_gradient": gradient_page(*full),
        "color_cover": color_cover(1024 if not QUICK else 384,
                                   1536 if not QUICK else 576),
        "gray16_gradient": gray16_page(768, 1100),
        "alpha_page": alpha_page(512, 768),
        "palette16": palette_page(512, 512),
    }
    tone = pages["gray_screentone"]
    pages["screentone_256"] = tone.crop((40, 40, 296, 296))
    pages["odd_1x1"] = tone.crop((100, 100, 101, 101))
    pages["odd_3x5"] = tone.crop((100, 100, 103, 105))
    pages["odd_255x257"] = tone.crop((40, 40, 295, 297))
    pages["odd_257x255"] = tone.crop((40, 40, 297, 295))
    for name, img in pages.items():
        img.save(SRC / f"{name}.png")
    return sorted(pages.keys())


# --- cjxl matrix ----------------------------------------------------------

def encode(src_name, out_name, args):
    src = SRC / f"{src_name}.png"
    out = JXL / f"{out_name}.jxl"
    cmd = ["cjxl", str(src), str(out), "--quiet"] + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"ENCODE FAIL {out_name}: {r.stderr.strip().splitlines()[-1:]}")
        return None
    return out


def decode_golden(jxl_path, has_alpha, lossy, gray16=False):
    stem = jxl_path.stem
    if has_alpha:
        ext = "pam"
    elif lossy:
        ext = "pfm"
    else:
        ext = "pgm" if "gray" in stem or "screentone" in stem or "odd" in stem else "ppm"
    out = GOLD / f"{stem}.{ext}"
    r = subprocess.run(["djxl", str(jxl_path), str(out), "--quiet"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"DECODE FAIL {stem}: {r.stderr.strip().splitlines()[-1:]}")


def main():
    check_tools()
    make_sources()
    JXL.mkdir(parents=True, exist_ok=True)
    GOLD.mkdir(parents=True, exist_ok=True)

    jobs = []  # (src, outname, args, has_alpha, lossy)
    efforts_full = [1, 2, 3, 5, 7] + ([] if QUICK else [9])

    for src in ["gray_screentone", "color_cover"]:
        for e in efforts_full:
            jobs.append((src, f"{src}_d0_e{e}", ["-d", "0", "-e", str(e)], False, False))
    for e in [1, 3, 7]:
        jobs.append(("gray16_gradient", f"gray16_gradient_d0_e{e}",
                     ["-d", "0", "-e", str(e)], False, False))
        jobs.append(("alpha_page", f"alpha_page_d0_e{e}",
                     ["-d", "0", "-e", str(e)], True, False))
    for e in [3, 7]:
        jobs.append(("palette16", f"palette16_d0_e{e}",
                     ["-d", "0", "-e", str(e)], False, False))
    for src in ["screentone_256", "odd_1x1", "odd_3x5", "odd_255x257", "odd_257x255"]:
        for e in [1, 3, 5, 7]:
            jobs.append((src, f"{src}_d0_e{e}", ["-d", "0", "-e", str(e)], False, False))

    # targeted lossless variants on the small screentone
    variants = {
        "nocolorspace": ["--modular_colorspace=0"],
        "nopalette": ["--modular_palette_colors=0"],
        "palette64": ["--modular_palette_colors=64"],
        "extraprops": ["-E", "3"],
        "noextraprops": ["-E", "0"],
        "groupsize0": ["--modular_group_size=0"],
        "groupsize3": ["--modular_group_size=3"],
        "responsive": ["--responsive=1"],
        "container": ["--container=1"],
    }
    for vname, vargs in variants.items():
        jobs.append(("screentone_256", f"screentone_256_d0_e5_{vname}",
                     ["-d", "0", "-e", "5"] + vargs, False, False))
    jobs.append(("gray_screentone", "gray_screentone_d0_e5_container",
                 ["-d", "0", "-e", "5", "--container=1"], False, False))
    # A large responsive (Squeeze) lossless file: unlike the 256x256
    # screentone responsive variant (whose whole pyramid fits in the global
    # section), this one is big enough to push its high-frequency Squeeze
    # residuals into pass groups, exercising the decoder's low-res Squeeze
    # downscale path (which skips exactly those pass groups).
    jobs.append(("color_cover", "color_cover_d0_e5_responsive",
                 ["-d", "0", "-e", "5", "--responsive=1"], False, False))

    if not QUICK:
        for src in ["gray_screentone", "gray_gradient", "color_cover"]:
            for d in ["0.5", "1.0", "2.0"]:
                for e in [1, 3, 7]:
                    jobs.append((src, f"{src}_d{d}_e{e}",
                                 ["-d", d, "-e", str(e)], False, True))
        jobs.append(("gray_gradient", "gray_gradient_d1_e7_nofilters",
                     ["-d", "1.0", "-e", "7", "--gaborish=0", "--epf=0"],
                     False, True))
        jobs.append(("color_cover", "color_cover_d1_e7_nofilters",
                     ["-d", "1.0", "-e", "7", "--gaborish=0", "--epf=0"],
                     False, True))
        jobs.append(("color_cover", "color_cover_d1_e7_noise",
                     ["-d", "1.0", "-e", "7", "--photon_noise_iso=3200"],
                     False, True))
        jobs.append(("color_cover", "color_cover_d1.0_e5_progdc1",
                     ["-d", "1.0", "-e", "5", "--progressive_dc=1"],
                     False, True))
        jobs.append(("gray_screentone", "gray_screentone_d1.0_e5_progdc2",
                     ["-d", "1.0", "-e", "5", "--progressive_dc=2"],
                     False, True))

    # Animated fixture: 4 distinct full frames, GIF -> lossless JXL, with
    # per-frame PPM references for the bit-exact animation gate.
    anim_frames = []
    for i in range(4):
        im = Image.new("RGB", (64, 48), (i * 60, 255 - i * 60, 128))
        d = ImageDraw.Draw(im)
        d.rectangle([8 + i * 10, 8, 24 + i * 10, 24], fill=(255, 255, 0))
        d.ellipse([30, 20 + i * 4, 50, 40 + i * 4], fill=(0, 0, 255))
        anim_frames.append(im)
        with open(GOLD / f"anim_frame_{i}.ppm", "wb") as f:
            f.write(b"P6\n64 48\n255\n" + im.tobytes())
    gif = SRC / "anim.gif"
    anim_frames[0].save(gif, save_all=True, append_images=anim_frames[1:],
                        duration=100, loop=0, disposal=1)
    subprocess.run(["cjxl", str(gif), str(JXL / "anim_d0.jxl"),
                    "-d", "0", "--quiet"], check=True)

    print(f"{len(jobs)} encode jobs...")
    for i, (src, outname, args, has_alpha, lossy) in enumerate(jobs):
        out = encode(src, outname, args)
        if out:
            decode_golden(out, has_alpha, lossy)
        if (i + 1) % 20 == 0:
            print(f"  {i + 1}/{len(jobs)}")

    # manifest
    lines = []
    for f in sorted(list(JXL.glob("*.jxl")) + list(GOLD.glob("*"))):
        digest = hashlib.sha256(f.read_bytes()).hexdigest()
        lines.append(f"{digest}  {f.relative_to(CORPUS)}")
    (CORPUS / "MANIFEST.sha256").write_text("\n".join(lines) + "\n")
    print(f"done: {len(list(JXL.glob('*.jxl')))} jxl files, manifest written")


if __name__ == "__main__":
    main()
