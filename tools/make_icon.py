"""Draw the app icon and build assets/AppIcon.icns.

    python3 tools/make_icon.py

A BSOD-blue tile with a little white window on it, pink traffic lights, and one pink
glitch bar tearing through — the piece in one square. Drawn at every size macOS asks
for rather than downscaled from one bitmap, so the 16pt version stays legible.

Requires Pillow and `iconutil` (ships with macOS).
"""
import os, shutil, subprocess
from PIL import Image, ImageDraw

BLUE = (0, 120, 215)      # BSOD blue
PINK = (255, 45, 149)
WHITE = (242, 244, 254)
INK = (11, 14, 22)

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def draw(size):
    """One icon at `size`px. Everything is a fraction of size — no fixed pixels."""
    s = size
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    # rounded tile
    r = s * 0.22
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=BLUE)

    # the window: a white sheet with a title bar
    wx0, wy0 = s * 0.17, s * 0.24
    wx1, wy1 = s * 0.83, s * 0.72
    wr = max(1, s * 0.035)
    d.rounded_rectangle([wx0, wy0, wx1, wy1], radius=wr, fill=WHITE)

    bar_h = (wy1 - wy0) * 0.26
    d.rounded_rectangle([wx0, wy0, wx1, wy0 + bar_h * 2], radius=wr, fill=(214, 216, 228))
    d.rectangle([wx0, wy0 + bar_h, wx1, wy0 + bar_h * 2], fill=(214, 216, 228))
    d.rectangle([wx0, wy0 + bar_h, wx1, wy1 - wr], fill=WHITE)

    # traffic lights, all pink — the tell that this window is not yours
    dot = bar_h * 0.36
    cx = wx0 + bar_h * 0.62
    for i in range(3):
        d.ellipse([cx - dot / 2, wy0 + bar_h / 2 - dot / 2,
                   cx + dot / 2, wy0 + bar_h / 2 + dot / 2], fill=PINK)
        cx += dot * 1.7

    # content: two ink lines, then the glitch tears the rest away
    if s >= 32:
        lx0, lx1 = wx0 + (wx1 - wx0) * 0.10, wx0 + (wx1 - wx0) * 0.72
        ly = wy0 + bar_h * 1.9
        lh = max(1, s * 0.022)
        for i, w in enumerate([1.0, 0.62]):
            d.rounded_rectangle([lx0, ly, lx0 + (lx1 - lx0) * w, ly + lh],
                                radius=lh / 2, fill=INK)
            ly += lh * 2.6

    # the glitch: a pink bar shoved sideways, running past the window's edge
    gy0 = wy0 + (wy1 - wy0) * 0.62
    gh = (wy1 - wy0) * 0.17
    d.rectangle([s * 0.06, gy0, s * 0.94, gy0 + gh], fill=PINK)
    d.rectangle([s * 0.30, gy0 + gh, s * 0.70, gy0 + gh * 1.45], fill=(255, 130, 200))
    return im


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    iconset = os.path.join(root, "build", "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset, exist_ok=True)

    # iconutil wants both the 1x and 2x file for each logical size.
    for pt in [16, 32, 128, 256, 512]:
        draw(pt).save(os.path.join(iconset, f"icon_{pt}x{pt}.png"))
        draw(pt * 2).save(os.path.join(iconset, f"icon_{pt}x{pt}@2x.png"))

    out = os.path.join(root, "assets", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    print(f"wrote {os.path.normpath(out)}")
    # A flat PNG too, handy for READMEs and posters.
    png = os.path.join(root, "assets", "app_icon.png")
    draw(1024).save(png)
    print(f"wrote {os.path.normpath(png)}")


if __name__ == "__main__":
    main()
