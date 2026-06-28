#!/usr/bin/env python3
"""
Generate the Deleter app icon — clean and flat:
  · gray-white squircle background (no decoration)
  · a Songti (宋体) serif "D" in Danish red (Dannebrog red), centered
No gradients, bevels, sheen or shadows — just the letter on the tile.
Produces AppIcon_1024.png and an .icns.

The "D" is centered by aligning the glyph's *ink* bounding box (the actual
painted pixels) to the canvas center, so it reads dead-center regardless of
the font's bearings.
"""
import os
import subprocess
import tempfile
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024          # final icon size
SS = 4               # supersample factor (work at 4096, downscale to 1024)
S = SIZE * SS        # working resolution
FONT_PATH = "/System/Library/Fonts/Songti.ttc"
FONT_INDEX = 1       # "Songti SC", "Bold" — formal serif with brush contrast

# Danish red (Dannebrog red, Pantone 186 C) — flat, no gradient.
RED = (200, 16, 46)            # #C8102E
# Flat gray-white background.
BG = (236, 236, 238)           # #ECECEE

OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "release", "v1.0"))


# --------------------------------------------------------------------------- #
# Squircle mask (macOS-style continuous corner)
# --------------------------------------------------------------------------- #
def squircle(size, n=5.0, edge_px=2.0):
    """Superellipse squircle alpha mask (full-bleed, AA edge)."""
    R = size / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    x = (xx - R) / R
    y = (yy - R) / R
    d = np.abs(x) ** n + np.abs(y) ** n     # =1 on boundary, <1 inside
    field = 1.0 - d                          # >0 inside
    g = n * np.maximum(
        np.where(np.abs(x) > 0, np.abs(x) ** (n - 1), 0.0) ** 2 +
        np.where(np.abs(y) > 0, np.abs(y) ** (n - 1), 0.0) ** 2,
        1e-6) ** 0.5
    sdf_px = field / g * R
    a = np.clip(0.5 + sdf_px / edge_px, 0.0, 1.0)
    return (a * 255).astype(np.uint8)


# --------------------------------------------------------------------------- #
# The "D" glyph — ink-centered
# --------------------------------------------------------------------------- #
def glyph_layer(target_h_frac=0.58):
    """Render the Songti "D"; return an L-mode alpha with the ink box centered."""
    lo, hi = int(S * 0.2), int(S * 1.2)
    best = None
    for _ in range(40):
        mid = (lo + hi) // 2
        font = ImageFont.truetype(FONT_PATH, mid, index=FONT_INDEX)
        tmp = Image.new("L", (S, S), 0)
        ImageDraw.Draw(tmp).text((0, 0), "D", font=font, fill=255)
        bbox = tmp.getbbox()
        if bbox is None:
            lo = mid + 1
            continue
        h = bbox[3] - bbox[1]
        if h < target_h_frac * S:
            lo = mid + 1
            best = (mid, bbox, font)
        else:
            hi = mid
    mid, bbox, font = best
    l, t, r, b = bbox
    dx = S / 2.0 - (l + r) / 2.0
    dy = S / 2.0 - (t + b) / 2.0
    alpha = Image.new("L", (S, S), 0)
    ImageDraw.Draw(alpha).text((round(dx), round(dy)), "D", font=font, fill=255)
    return alpha


# --------------------------------------------------------------------------- #
# Compose the icon
# --------------------------------------------------------------------------- #
def make_icon():
    mask_l = squircle(S, n=5.0, edge_px=2.0)

    # Flat gray-white background, full-bleed squircle.
    base = Image.new("RGBA", (S, S), BG + (255,))
    base.putalpha(Image.fromarray(mask_l, mode="L"))

    # Flat red "D", centered.
    d_alpha = glyph_layer(target_h_frac=0.58)
    d_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d_layer.putalpha(d_alpha)
    # Fill the glyph's alpha with flat red.
    red = Image.new("RGBA", (S, S), RED + (0,))
    red.putalpha(d_alpha)
    base.alpha_composite(red)

    final = base.resize((SIZE, SIZE), Image.LANCZOS)
    return final


# --------------------------------------------------------------------------- #
# .icns via iconutil
# --------------------------------------------------------------------------- #
def build_icns(png_1024, out_icns):
    iconset = tempfile.mkdtemp(suffix=".iconset")
    try:
        for s in [16, 32, 64, 128, 256, 512, 1024]:
            p = os.path.join(iconset, f"icon_{s}x{s}.png")
            if s == 1024:
                shutil.copy(png_1024, p)
            else:
                Image.open(png_1024).resize((s, s), Image.LANCZOS).save(p)
            if s <= 512:
                s2 = s * 2
                Image.open(png_1024).resize((s2, s2), Image.LANCZOS).save(
                    os.path.join(iconset, f"icon_{s}x{s}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_icns], check=True)
    finally:
        shutil.rmtree(iconset, ignore_errors=True)


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    icon = make_icon()
    png_path = os.path.join(OUT_DIR, "AppIcon_1024.png")
    icon.save(png_path)
    print(f"saved png: {png_path}")

    # verify the red D is centered
    import numpy as np
    r, g, b, _ = icon.split()
    r = np.asarray(r); g = np.asarray(g); b = np.asarray(b)
    red_mask = (r.astype(int) - g.astype(int) > 80) & (r.astype(int) - b.astype(int) > 80)
    ys, xs = np.where(red_mask)
    print(f"  D ink bbox: x[{xs.min()}..{xs.max()}] y[{ys.min()}..{ys.max()}]")
    print(f"  D center = ({xs.mean():.2f}, {ys.mean():.2f}); canvas center = (512, 512)")
    print(f"  offset   = ({xs.mean()-512:+.2f}, {ys.mean()-512:+.2f}) px")

    icns_path = os.path.join(OUT_DIR, "Deleter.icns")
    build_icns(png_path, icns_path)
    print(f"saved icns: {icns_path}")
