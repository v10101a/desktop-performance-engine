"""Draw the app icon and build assets/AppIcon.icns.

    python3 tools/make_icon.py

The pixelface on the show's blue — the artwork the drop puts on the desktop (cue 7),
squared off as an icon. The ground is the artwork's OWN field colour sampled from the
file, the same `#001FFD` `build_face_desktop` uses in the generator, so the face has no
visible edge where it sits on the tile.

Drawn at every size macOS asks for rather than downscaled from one bitmap. Scaling up is
NEAREST — it is pixel art, and every other appearance of it in the show is hard-edged —
but scaling DOWN is an area average: the face's strokes are a few source pixels wide, and
nearest-neighbour at 16pt drops whole features (an eye loses half its X). Averaged, they
survive as lighter blue, which is what a 16pt icon can carry anyway.

Requires Pillow and `iconutil` (ships with macOS).
"""
import os, shutil, subprocess
from PIL import Image

# The artwork's own field colour, sampled from assets/pixelface.jpg — NOT the signature
# #020AF5. A shade off, and the shade that makes the paste seamless.
GROUND = (0, 31, 253)
FACE = "assets/pixelface.jpg"
# The face's width as a fraction of the tile. It is wider than it is tall and its ink
# runs to all four edges, so the ceiling here is the corner radius: at 0.84 the outer
# corner of each eye still sits inside the rounded corner's arc, and by ~0.92 the eyes
# are crowding it. Set for the Dock rather than for a 512pt preview — the face wants the
# presence at 32pt, where the margin a smaller share buys is just lost blue.
FACE_SHARE = 0.84

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SIZES = [16, 32, 128, 256, 512]


def draw(size, src):
    """One icon at `size`px. Everything is a fraction of size — no fixed pixels."""
    s = size
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # The rounded tile, in the artwork's own blue.
    tile = Image.new("RGBA", (s, s), GROUND + (255,))
    mask = Image.new("L", (s * 4, s * 4), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s * 4 - 1, s * 4 - 1],
                                           radius=s * 4 * 0.22, fill=255)
    tile.putalpha(mask.resize((s, s), Image.LANCZOS))   # 4x then down: clean arcs
    im.alpha_composite(tile)

    w = max(1, round(s * FACE_SHARE))
    h = max(1, round(src.height * w / src.width))
    # Up: NEAREST, it is pixel art. Down: BOX, or the strokes vanish. See the docstring.
    face = src.resize((w, h), Image.NEAREST if w >= src.width else Image.BOX)
    im.alpha_composite(face.convert("RGBA"), ((s - w) // 2, (s - h) // 2))
    return im


def main():
    src = Image.open(os.path.join(ROOT, FACE)).convert("RGB")
    iconset = os.path.join(ROOT, "build", "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset, exist_ok=True)

    # iconutil wants both the 1x and 2x file for each logical size.
    for pt in SIZES:
        draw(pt, src).save(os.path.join(iconset, f"icon_{pt}x{pt}.png"))
        draw(pt * 2, src).save(os.path.join(iconset, f"icon_{pt}x{pt}@2x.png"))

    out = os.path.join(ROOT, "assets", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    print(f"wrote {os.path.normpath(out)}")
    # A flat PNG too, handy for READMEs and posters.
    png = os.path.join(ROOT, "assets", "app_icon.png")
    draw(1024, src).save(png)
    print(f"wrote {os.path.normpath(png)}")


if __name__ == "__main__":
    main()
