import sys
from PIL import Image

out_path = sys.argv[1]
ims = [Image.open(p) for p in sys.argv[2:]]
w = sum(i.width for i in ims) + 6 * (len(ims) - 1)
h = max(i.height for i in ims)
out = Image.new("RGB", (w, h), (255, 255, 255))
x = 0
for i in ims:
    out.paste(i, (x, 0))
    x += i.width + 6
out.save(out_path)
