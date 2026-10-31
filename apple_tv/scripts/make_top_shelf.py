#!/usr/bin/env python3
"""Lines up the Radio Crestin logo and wordmark in the Apple TV Top Shelf
images with the first icon of the Home screen dock.

The four Top Shelf PNGs live in the app's AppIcon brand assets
(RadioCrestinTV/Resources/Assets.xcassets/AppIcon.brandassets): the wide
image (2320 x 720 and @2x), the one tvOS 27 shows, and the regular one
(1920 x 720 and @2x). Each is a dark, dithered gradient with the brand
block (logo and wordmark) on the left. tvOS draws the wide image with its
left edge off screen, which cut the logo off, so the block starts at 362 pt
in the wide image and at 162 pt in the regular one, 200 pt narrower on each
side: on screen it starts where the dock's first icon does.

For each image the script finds the block (the pixels more than 6 levels
off their row's background), moves it to that position on the same rows,
and fills the area it leaves with the same rows' background taken from the
empty right side, so the dither and the gradient stay unbroken. The PNG
keeps its mode and its sRGB and eXIf chunks. An image whose block is in
place already is left alone, so running the script again changes nothing.

Run it after replacing a Top Shelf image with a new export, from anywhere:

    python3 apple_tv/scripts/make_top_shelf.py           # rewrites in place
    python3 apple_tv/scripts/make_top_shelf.py --check   # exit 1 if any
                                                         # image would change

Needs Pillow: pip3 install Pillow.
"""
import argparse
import sys
from collections import Counter
from pathlib import Path

from PIL import Image, PngImagePlugin

BRAND_ASSETS = (Path(__file__).resolve().parent.parent / "RadioCrestinTV"
                / "Resources" / "Assets.xcassets" / "AppIcon.brandassets")

# Image, its scale, and where the block's left edge goes, in points.
IMAGES = [
    ("Top Shelf Image Wide.imageset/topshelf-wide.png", 1, 362),
    ("Top Shelf Image Wide.imageset/topshelf-wide@2x.png", 2, 362),
    ("Top Shelf Image.imageset/topshelf.png", 1, 162),
    ("Top Shelf Image.imageset/topshelf@2x.png", 2, 162),
]

# A pixel this many levels off its row's background belongs to the block.
THRESHOLD = 6
# The block is moved with this much of its surroundings (points), so its
# faint anti-aliased edge goes with it.
MARGIN_PT = 3
# The background that fills the vacated area comes from this far (pixels)
# inside the right edge, where no image has content.
RIGHT_INSET_PX = 40


def find_block(image):
    """The block's bounding box (x0, y0, x1, y1, inclusive), in pixels."""
    rgb = image.convert("RGB")
    px = rgb.load()
    width, height = rgb.size
    x0, y0, x1, y1 = width, height, -1, -1
    for y in range(height):
        row = [px[x, y] for x in range(width)]
        background = Counter(row).most_common(1)[0][0]
        for x, pixel in enumerate(row):
            if max(abs(c - b) for c, b in zip(pixel, background)) > THRESHOLD:
                x0, y0 = min(x0, x), min(y0, y)
                x1, y1 = max(x1, x), max(y1, y)
    if x1 < 0:
        sys.exit("no brand block found")
    return x0, y0, x1, y1


def moved(image, block, new_x0, margin):
    """`image` with `block` moved right (or left) so it starts at `new_x0`."""
    x0, y0, x1, y1 = block
    width, height = image.size
    bx0, by0 = max(0, x0 - margin), max(0, y0 - margin)
    bx1, by1 = min(width, x1 + 1 + margin), min(height, y1 + 1 + margin)
    dx = new_x0 - x0
    piece = image.crop((bx0, by0, bx1, by1))
    # Same rows, far right: background in both the old and new layouts.
    fill_x0 = width - RIGHT_INSET_PX - (bx1 - bx0)
    if fill_x0 <= bx1 + dx:
        sys.exit("the background source overlaps the moved block")
    fill = image.crop((fill_x0, by0, fill_x0 + (bx1 - bx0), by1))
    result = image.copy()
    result.paste(fill, (bx0, by0))
    result.paste(piece, (bx0 + dx, by0))
    return result


def save(image, original, path):
    """Saves `image` as a PNG with `original`'s sRGB and eXIf chunks."""
    info = PngImagePlugin.PngInfo()
    if "srgb" in original.info:
        info.add(b"sRGB", bytes([original.info["srgb"]]))
    options = {"pnginfo": info, "optimize": True}
    if "exif" in original.info:
        options["exif"] = original.info["exif"]
    image.save(path, **options)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--check", action="store_true",
        help="change nothing; exit 1 if any image would change")
    parser.add_argument(
        "--assets", type=Path, default=BRAND_ASSETS,
        help="the AppIcon.brandassets folder (default: the app's)")
    args = parser.parse_args()

    outdated = []
    for name, scale, left_pt in IMAGES:
        path = args.assets / name
        image = Image.open(path)
        image.load()
        block = find_block(image)
        new_x0 = left_pt * scale
        if block[0] == new_x0:
            print(f"{name}: block already at {left_pt} pt")
            continue
        outdated.append(name)
        print(f"{name}: block at x {block[0]} px moves to {new_x0} px")
        if not args.check:
            save(moved(image, block, new_x0, MARGIN_PT * scale), image, path)
    if args.check and outdated:
        sys.exit(1)


if __name__ == "__main__":
    main()
