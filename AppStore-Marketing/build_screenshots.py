#!/usr/bin/env python3
"""
Builds the 6 Nomva App Store marketing screenshots.

Source screenshots live in /Users/jerrycrews/Documents/Projects/Nomva/screenshots/
Final 1320x2868 PNGs are written to /Users/jerrycrews/Documents/Projects/Nomva/AppStore-Marketing/output/
"""

from __future__ import annotations

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Output canvas size. Apple's "iPhone 6.5 Display" required size is 1284 x 2778
# (also accepts 1242 x 2688). For newer 6.9" listings use 1320 x 2868.
CANVAS_W, CANVAS_H = 1284, 2778

# Layout (scaled to canvas height so it works at multiple resolutions)
TEXT_TOP_PAD = int(CANVAS_H * 0.038)
TEXT_BLOCK_HEIGHT = int(CANVAS_H * 0.188)
PHONE_TARGET_HEIGHT = int(CANVAS_H * 0.690)  # tall edge BEFORE rotation
PHONE_ROTATION = -7                          # degrees; negative = top-left lean
PHONE_CORNER_RADIUS_SRC = 90                 # iPhone screen corner radius (at native px)
BEZEL_THICKNESS = 18                         # black frame around the screen
BEZEL_OUTER_RADIUS = PHONE_CORNER_RADIUS_SRC + BEZEL_THICKNESS

# Colors (Nomva theme — pulled from NomvaUI.swift)
WARM_TOP = (255, 246, 232)       # #FFF6E8 cream
MIST_BOTTOM = (245, 247, 255)    # #F5F7FF mist
ORANGE = (252, 148, 41)          # #FC9429
ORANGE_DEEP = (245, 117, 31)     # #F5751F
PEACH = (255, 209, 153)          # #FFD199
MINT = (215, 240, 225)           # mint
HEAD_COLOR = (78, 30, 6)         # deep warm brown
SUB_COLOR = (140, 80, 30)        # warm muted

SRC_DIR = Path("/sessions/keen-elegant-maxwell/mnt/Nomva/screenshots")
OUT_DIR = Path("/sessions/keen-elegant-maxwell/mnt/Nomva/AppStore-Marketing/output")
OUT_DIR.mkdir(parents=True, exist_ok=True)

FONT_HEAD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_SUB = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

SCREENSHOTS = [
    {
        "out": "01_hero_ai_chat.png",
        "src": "Simulator Screenshot - iPhone 17 Pro Max - 2026-04-21 at 23.17.37.png",
        "headline": "Log meals\nby chatting.",
        "sub": "No more searching food databases. Just say what you ate.",
    },
    {
        "out": "02_macros_daily_log.png",
        "src": "Simulator Screenshot - iPhone 17 Pro Max - 2026-04-21 at 23.16.35.png",
        "headline": "Hit your macros.\nEvery single day.",
        "sub": "Calories, protein, carbs, and fat in one live snapshot.",
    },
    {
        "out": "03_nutrition_detail.png",
        "src": "Simulator Screenshot - iPhone 17 Pro Max - 2026-04-21 at 23.16.41.png",
        "headline": "Every macro.\nEvery micro.",
        "sub": "Calories, protein, fiber, sodium — all against your goals.",
    },
    {
        "out": "04_weight_trend.png",
        "src": "Simulator Screenshot - iPhone 17 Pro Max - 2026-04-21 at 23.17.22.png",
        "headline": "See the trend.\nNot the noise.",
        "sub": "Smoothed weekly averages cut through daily weight swings.",
    },
    {
        "out": "05_weight_insights.png",
        "src": "Simulator Screenshot - iPhone 17 Pro Max - 2026-04-21 at 23.17.27.png",
        "headline": "Know if you're\nactually losing.",
        "sub": "Real-time velocity tells you when to push and when to hold.",
    },
    {
        "out": "06_integrations.png",
        "src": "Simulator Screenshot - iPhone 17 Pro Max - 2026-04-21 at 23.17.33.png",
        "headline": "Apple Health,\nGarmin, iCloud.",
        "sub": "Your training auto-adjusts your calorie goal. Synced. Private.",
    },
]


def vertical_gradient(w: int, h: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    """Diagonal-feeling vertical gradient between two colors."""
    base = Image.new("RGB", (1, h), top)
    px = base.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        px[0, y] = (r, g, b)
    return base.resize((w, h))


def add_orb(canvas: Image.Image, center: tuple[int, int], radius: int, color: tuple[int, int, int], alpha: int, blur: int) -> None:
    """Soft glowing blob to add depth, matching NomvaScreenBackground."""
    orb = Image.new("RGBA", (radius * 2, radius * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(orb)
    d.ellipse((0, 0, radius * 2, radius * 2), fill=(*color, alpha))
    orb = orb.filter(ImageFilter.GaussianBlur(blur))
    cx, cy = center
    canvas.alpha_composite(orb, (cx - radius, cy - radius))


def build_background() -> Image.Image:
    bg = vertical_gradient(CANVAS_W, CANVAS_H, WARM_TOP, MIST_BOTTOM).convert("RGBA")
    add_orb(bg, (CANVAS_W + 100, -80), 540, PEACH, 110, 90)
    add_orb(bg, (-200, CANVAS_H - 200), 520, MINT, 90, 90)
    return bg


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    """Single-channel mask with rounded corners."""
    mask = Image.new("L", size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def make_phone(screenshot_path: Path) -> Image.Image:
    """
    Take a 1320x2868 iPhone simulator screenshot and wrap it in a black bezel
    with rounded corners. Output preserves alpha so the bezel sits cleanly.
    """
    src = Image.open(screenshot_path).convert("RGBA")
    # Round the screen corners to match iPhone hardware
    screen_mask = rounded_mask(src.size, PHONE_CORNER_RADIUS_SRC)
    rounded_screen = Image.new("RGBA", src.size, (0, 0, 0, 0))
    rounded_screen.paste(src, (0, 0), screen_mask)

    # Black bezel
    w, h = src.size
    bw = w + BEZEL_THICKNESS * 2
    bh = h + BEZEL_THICKNESS * 2
    bezel = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    d = ImageDraw.Draw(bezel)
    d.rounded_rectangle((0, 0, bw, bh), radius=BEZEL_OUTER_RADIUS, fill=(18, 18, 20, 255))
    bezel.alpha_composite(rounded_screen, (BEZEL_THICKNESS, BEZEL_THICKNESS))

    # Resize to target tall edge while keeping aspect
    scale = PHONE_TARGET_HEIGHT / bh
    new_w = int(bw * scale)
    new_h = int(bh * scale)
    bezel = bezel.resize((new_w, new_h), Image.LANCZOS)
    return bezel


def add_phone_with_shadow(canvas: Image.Image, phone: Image.Image, center_xy: tuple[int, int], rotation: float) -> None:
    rotated = phone.rotate(rotation, resample=Image.BICUBIC, expand=True)

    # Soft drop shadow — derived from phone alpha
    shadow_pad = 60
    sw, sh = rotated.size
    shadow_canvas = Image.new("RGBA", (sw + shadow_pad * 2, sh + shadow_pad * 2), (0, 0, 0, 0))
    alpha = rotated.split()[-1]
    shadow_layer = Image.new("RGBA", rotated.size, (0, 0, 0, 0))
    shadow_layer.putalpha(alpha.point(lambda v: int(v * 0.40)))
    shadow_canvas.alpha_composite(shadow_layer, (shadow_pad, shadow_pad))
    shadow_canvas = shadow_canvas.filter(ImageFilter.GaussianBlur(36))

    cx, cy = center_xy
    sx = cx - shadow_canvas.size[0] // 2 + 8
    sy = cy - shadow_canvas.size[1] // 2 + 28
    canvas.alpha_composite(shadow_canvas, (sx, sy))

    px = cx - sw // 2
    py = cy - sh // 2
    canvas.alpha_composite(rotated, (px, py))


def wrap_lines(text: str) -> list[str]:
    return [line.strip() for line in text.split("\n") if line.strip()]


def fit_font_size(lines: list[str], font_path: str, max_w: int, start_size: int, min_size: int, d: ImageDraw.ImageDraw) -> int:
    """Largest font size from start_size down to min_size where every line fits within max_w."""
    for size in range(start_size, min_size - 1, -2):
        font = ImageFont.truetype(font_path, size)
        ok = True
        for line in lines:
            bbox = d.textbbox((0, 0), line, font=font)
            if bbox[2] - bbox[0] > max_w:
                ok = False
                break
        if ok:
            return size
    return min_size


def draw_text_block(canvas: Image.Image, headline: str, sub: str) -> None:
    d = ImageDraw.Draw(canvas)

    max_text_w = CANVAS_W - 140  # leave 70px on each side
    sub_font_size = int(CANVAS_H * 0.0175)
    sub_font = ImageFont.truetype(FONT_SUB, sub_font_size)

    head_lines = wrap_lines(headline)
    start_size = int(CANVAS_H * 0.046)
    min_size = int(CANVAS_H * 0.029)
    head_font_size = fit_font_size(head_lines, FONT_HEAD, max_text_w, start_size=start_size, min_size=min_size, d=d)
    head_font = ImageFont.truetype(FONT_HEAD, head_font_size)

    y = TEXT_TOP_PAD
    line_gap = 18
    for line in head_lines:
        bbox = d.textbbox((0, 0), line, font=head_font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        x = (CANVAS_W - tw) // 2
        d.text((x, y), line, font=head_font, fill=(*HEAD_COLOR, 255))
        y += th + line_gap

    # Sub-headline (single line, wrap if too wide)
    sub_lines = wrap_sub(sub, sub_font, CANVAS_W - 200, d)
    y += 26
    for line in sub_lines:
        bbox = d.textbbox((0, 0), line, font=sub_font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        x = (CANVAS_W - tw) // 2
        d.text((x, y), line, font=sub_font, fill=(*SUB_COLOR, 255))
        y += th + 12


def wrap_sub(text: str, font: ImageFont.FreeTypeFont, max_w: int, d: ImageDraw.ImageDraw) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current: list[str] = []
    for w in words:
        trial = " ".join(current + [w])
        bbox = d.textbbox((0, 0), trial, font=font)
        if bbox[2] - bbox[0] > max_w and current:
            lines.append(" ".join(current))
            current = [w]
        else:
            current.append(w)
    if current:
        lines.append(" ".join(current))
    return lines


def render_one(cfg: dict) -> Path:
    canvas = build_background()
    draw_text_block(canvas, cfg["headline"], cfg["sub"])

    phone = make_phone(SRC_DIR / cfg["src"])
    # Center the phone in the bottom 60% of the canvas
    cx = CANVAS_W // 2
    cy = TEXT_TOP_PAD + TEXT_BLOCK_HEIGHT + (CANVAS_H - TEXT_TOP_PAD - TEXT_BLOCK_HEIGHT) // 2 + 30
    add_phone_with_shadow(canvas, phone, (cx, cy), PHONE_ROTATION)

    out_path = OUT_DIR / cfg["out"]
    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


def main() -> None:
    for cfg in SCREENSHOTS:
        path = render_one(cfg)
        print(f"  wrote {path.name}")
    print(f"\nAll {len(SCREENSHOTS)} screenshots written to {OUT_DIR}")


if __name__ == "__main__":
    main()
