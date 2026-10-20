import sys
import os
from PIL import Image, ImageDraw, ImageFont

PALETTE = [
    (240, 240, 240), (242, 178, 51), (229, 127, 216), (153, 178, 242),
    (222, 222, 108), (127, 204, 25), (242, 178, 204), (76, 76, 76),
    (153, 153, 153), (76, 153, 178), (178, 102, 229), (51, 102, 204),
    (127, 102, 76), (87, 166, 78), (204, 76, 76), (25, 25, 25),
]
CW, CH = 8, 14
FONT = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 11)


def render(path, out):
    with open(path, encoding="latin-1") as f:
        head = f.readline().split()
        w, h = int(head[1]), int(head[2])
        rows = [f.readline().rstrip("\n") for _ in range(h * 3)]
    text, fg, bg = rows[:h], rows[h:2 * h], rows[2 * h:]
    img = Image.new("RGB", (w * CW + 8, h * CH + 8), (60, 60, 60))
    d = ImageDraw.Draw(img)
    for y in range(h):
        for x in range(w):
            b = PALETTE[int(bg[y][x], 16)]
            px, py = 4 + x * CW, 4 + y * CH
            d.rectangle([px, py, px + CW - 1, py + CH - 1], fill=b)
            ch = text[y][x]
            if ch != " ":
                d.text((px, py), ch, font=FONT, fill=PALETTE[int(fg[y][x], 16)])
    img.save(out)


if __name__ == "__main__":
    src = sys.argv[1]
    for name in sorted(os.listdir(src)):
        if name.endswith(".scr"):
            render(os.path.join(src, name), os.path.join(src, name[:-4] + ".png"))
