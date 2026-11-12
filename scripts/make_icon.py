"""Generate our simple waveform app icon with Pillow (development only)."""
from pathlib import Path
from PIL import Image, ImageDraw
import json

root = Path(__file__).resolve().parents[1] / "LocalTunes/Resources/Assets.xcassets/AppIcon.appiconset"
root.mkdir(parents=True, exist_ok=True)
image = Image.new("RGB", (1024, 1024), (15, 22, 24))
draw = ImageDraw.Draw(image)
for y in range(1024):
    t = y / 1023
    draw.line((0, y, 1024, y), fill=(int(22 - 12*t), int(38 - 19*t), int(37 - 16*t)))
heights = [140, 280, 440, 600, 380, 230, 120]
for i, height in enumerate(heights):
    x = 225 + i * 90
    draw.rounded_rectangle((x, 512-height/2, x+44, 512+height/2), radius=22, fill=(174, 248, 110))
image.save(root / "AppIcon.png")
(root / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2))
