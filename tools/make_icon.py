#!/usr/bin/env python3
"""Draws the app icon (1024 x 1024, no alpha) and writes it into both asset catalogs.

A near-black square, a bold bone arrow, and a stripe of the nine station colours from Palette.swift.
Nothing is loaded from outside this file. Run: python3 tools/make_icon.py  (needs Pillow)
"""
import json
import os
from PIL import Image, ImageDraw

SIZE = 1024
INK = 0x0B0B0F
BONE = 0xF2EEE3
# Palette.swift swatches in race order: run (ice), skierg, sled push, sled pull, burpee, row, farmers, lunges, wall balls.
STRIPE = [0xA9DDF2, 0x22C7E8, 0xDE45A8, 0x7C4DDB, 0xA6E22E, 0x14998A, 0xF2A516, 0xF0644F, 0xE8337F]


def rgb(h):
    return ((h >> 16) & 255, (h >> 8) & 255, h & 255)


def draw():
    img = Image.new("RGB", (SIZE, SIZE), rgb(INK))
    d = ImageDraw.Draw(img)
    top, bottom = 600, 800
    for i, hexv in enumerate(STRIPE):
        d.rectangle([round(i * SIZE / 9), top, round((i + 1) * SIZE / 9) - 1, bottom - 1], fill=rgb(hexv))
    # A bold arrow pointing right: shaft and head, centred above the stripe.
    cy = 330
    d.rectangle([180, cy - 60, 600, cy + 60], fill=rgb(BONE))
    d.polygon([(560, cy - 170), (860, cy), (560, cy + 170)], fill=rgb(BONE))
    return img


def write(img, root):
    for folder, platform in (("iOS", "ios"), ("Watch", "watchos")):
        out = os.path.join(root, folder, "Assets.xcassets", "AppIcon.appiconset")
        os.makedirs(out, exist_ok=True)
        img.save(os.path.join(out, "icon-1024.png"), optimize=False)
        with open(os.path.join(out, "Contents.json"), "w") as f:
            json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}],
                       "info": {"author": "xcode", "version": 1}}, f, indent=2, sort_keys=True)
            f.write("\n")
        with open(os.path.join(root, folder, "Assets.xcassets", "Contents.json"), "w") as f:
            json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    write(draw(), os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
