#!/usr/bin/env python3
"""Slice the original PNG drawings into registration-aligned sprite frames."""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Sources" / "RestABit" / "Assets"
CANVAS_WIDTH = 576
CANVAS_HEIGHT = 448
BODY_CENTER = 288
GROUND = 413


def slice_sheet(path, poses, ground=GROUND, columns=3, rows=2, lift=None, scale=1):
    info = subprocess.check_output(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "json", path]
    )
    dimensions = json.loads(info)["streams"][0]
    width, height = dimensions["width"], dimensions["height"]
    filters = []
    if scale != 1:
        width, height = round(width * scale), round(height * scale)
        filters = ["-vf", f"scale={width}:{height}:flags=lanczos"]
    rgba = subprocess.check_output(
        ["ffmpeg", "-v", "error", "-i", path, "-frames:v", "1",
         *filters, "-pix_fmt", "rgba", "-f", "rawvideo", "-"]
    )
    for index, (name, body_x) in enumerate(poses):
        if name is None:
            continue
        col, row = index % columns, index // columns
        left, right = col * width // columns, (col + 1) * width // columns
        top, bottom = row * height // rows, (row + 1) * height // rows
        occupied = [(x, y) for y in range(top, bottom) for x in range(left, right)
                    if rgba[(y * width + x) * 4 + 3] > 24]
        if not occupied:
            raise ValueError(f"{name}: artwork has no visible pixels")
        dx = BODY_CENTER - round(body_x * width)
        dy = ground - (lift or {}).get(name, 0) - max(y for _, y in occupied)
        min_x = max(left, min(x for x, _ in occupied) - 10)
        max_x = min(right, max(x for x, _ in occupied) + 11)
        min_y = max(top, min(y for _, y in occupied) - 10)
        max_y = min(bottom, max(y for _, y in occupied) + 11)
        if not (0 <= min_x + dx < max_x + dx <= CANVAS_WIDTH
                and 0 <= min_y + dy < max_y + dy <= CANVAS_HEIGHT):
            raise ValueError(f"{name}: drawing exceeds the registered canvas")
        canvas = bytearray(CANVAS_WIDTH * CANVAS_HEIGHT * 4)
        for y in range(min_y, max_y):
            start = (y * width + min_x) * 4
            destination = ((y + dy) * CANVAS_WIDTH + min_x + dx) * 4
            count = (max_x - min_x) * 4
            canvas[destination:destination + count] = rgba[start:start + count]
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba",
             "-s", f"{CANVAS_WIDTH}x{CANVAS_HEIGHT}", "-i", "-",
             "-vf", "scale=344:-1:flags=lanczos", "-frames:v", "1",
             str(ASSETS / f"{name}.png")], input=canvas, check=True
        )


slice_sheet(ROOT / "Support" / "Art" / "primary.png", [
    ("peek", 0.162), ("run", 0.500), ("gather", 0.818),
    ("brake", 0.139), ("look", 0.493), (None, 0.824),
])
extra = ROOT / "Support" / "Art" / "gestures.png"
if extra.is_file():
    slice_sheet(extra, [
        ("stand", 0.155), ("lookBack", 0.495), (None, 0.822),
        ("step", 0.161), ("stretch", 0.494), ("land", 0.820),
    ])

slice_sheet(ROOT / "Support" / "Art" / "blink.png", [
    ("blinkOpen", 0.1855), ("blinkHalf", 0.5091), ("blinkClosed", 0.8327),
    ("blinkCrouch", 0.1895), ("blinkAir", 0.5098), ("blinkLand", 0.8346),
], ground=432)

slice_sheet(ROOT / "Support" / "Art" / "forward.png", [
    ("frontLeft", 0.157), ("frontGather", 0.408), ("frontRight", 0.659), ("frontStand", 0.909),
    ("rearLeft", 0.140), ("rearGather", 0.393), ("rearRight", 0.644), ("rearStand", 0.895),
], columns=4, lift={"frontGather": 22, "rearGather": 48})

slice_sheet(ROOT / "Support" / "Art" / "rear-turn.png", [
    ("rearTurnStart", 0.167), ("rearTurnMiddle", 0.500), ("rearLook", 0.838),
], rows=1, scale=0.56)

slice_sheet(ROOT / "Support" / "Art" / "drink.png", [
    ("drinkLower", 0.135), ("drinkSip", 0.469), ("drinkSwallow", 0.800),
], rows=1, scale=0.74)

subprocess.run(["ffmpeg", "-v", "error", "-y",
                "-i", ROOT / "Support" / "Art" / "pond.png",
                "-vf", "crop=iw:315:0:391,scale=1140:-1:flags=lanczos",
                "-frames:v", "1", str(ASSETS / "pond.png")], check=True)

subprocess.run(["ffmpeg", "-v", "error", "-y",
                "-i", ROOT / "Support" / "Art" / "pelvic-forest.png",
                "-vf", "crop=1774:668:0:210,scale=800:-1:flags=lanczos",
                "-frames:v", "1", "-pix_fmt", "rgba", str(ASSETS / "pelvicForest.png")], check=True)

practice_assets = ASSETS / "PelvicPractice"
practice_assets.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="restabit-art-") as temp:
    scratch = Path(temp)
    animator = scratch / "animate-practice"
    subprocess.run(["swiftc", "-O", "-module-cache-path", scratch / "modules",
                    ROOT / "script" / "animate_practice.swift", "-o", animator], check=True)
    for variant in ("curl", "low", "sway"):
        sequence = scratch / variant
        sequence.mkdir()
        drawing = ROOT / "Support" / "Art" / f"pelvic-tail-{variant}.png"
        subprocess.run([animator, variant, drawing, sequence], check=True)
        subprocess.run(["img2webp", "-d", "40", "-lossless", "-m", "6", "-min_size",
                        *sorted(sequence.glob("frame-*.png")), "-o", practice_assets / f"{variant}.webp"], check=True)
