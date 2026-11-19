#!/usr/bin/env python3
"""Draws Resources/AppIcon.png (1024x1024): Buddy's robot head on a macOS-style tile.

Requires Pillow. Run from the repository root: python3 scripts/make_icon.py
"""
from PIL import Image, ImageDraw, ImageFilter

SCALE = 2  # draw large, then downsample for smooth edges
SIZE = 1024 * SCALE


def s(v):
    return int(v * SCALE)


def vertical_gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGBA", size)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        draw.line([(0, y), (w, y)], fill=color)
    return img


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def main():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Tile with drop shadow
    tile_box = (s(100), s(100), s(924), s(924))
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (tile_box[0], tile_box[1] + s(18), tile_box[2], tile_box[3] + s(18)), radius=s(185), fill=(0, 0, 0, 110)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s(22))))
    tile = vertical_gradient((SIZE, SIZE), (92, 108, 255), (40, 200, 220))
    canvas.paste(tile, (0, 0), rounded_mask((SIZE, SIZE), tile_box, s(185)))

    draw = ImageDraw.Draw(canvas)
    cx = SIZE // 2

    # Antenna
    draw.rounded_rectangle((cx - s(12), s(205), cx + s(12), s(300)), radius=s(12), fill=(225, 230, 240))
    draw.ellipse((cx - s(38), s(160), cx + s(38), s(236)), fill=(255, 214, 90))

    # Ears
    for x in (s(222), s(758)):
        draw.rounded_rectangle((x, s(450), x + s(44), s(610)), radius=s(18), fill=(70, 220, 235))

    # Head with soft shadow
    head_box = (s(250), s(285), s(774), s(745))
    head_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(head_shadow).rounded_rectangle(
        (head_box[0], head_box[1] + s(16), head_box[2], head_box[3] + s(16)), radius=s(150), fill=(0, 0, 0, 90)
    )
    canvas.alpha_composite(head_shadow.filter(ImageFilter.GaussianBlur(s(16))))
    head = vertical_gradient((SIZE, SIZE), (255, 255, 255), (214, 220, 232))
    canvas.paste(head, (0, 0), rounded_mask((SIZE, SIZE), head_box, s(150)))
    draw = ImageDraw.Draw(canvas)

    # Face screen
    draw.rounded_rectangle((s(312), s(345), s(712), s(690)), radius=s(105), fill=(16, 21, 40))

    # Glowing eyes and smile
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    eye_color = (120, 245, 255, 255)
    for x in (s(420), s(604)):
        glow_draw.rounded_rectangle((x - s(38), s(430), x + s(38), s(540)), radius=s(38), fill=eye_color)
    glow_draw.arc((s(440), s(520), s(584), s(640)), start=20, end=160, fill=eye_color, width=s(22))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(s(14))))
    canvas.alpha_composite(glow)

    # Cheeks
    draw = ImageDraw.Draw(canvas)
    for x in (s(360), s(664)):
        draw.ellipse((x - s(26), s(575), x + s(26), s(615)), fill=(255, 120, 160, 120))

    icon = canvas.resize((1024, 1024), Image.LANCZOS)
    icon.save("Resources/AppIcon.png")
    print("Wrote Resources/AppIcon.png")


if __name__ == "__main__":
    main()
