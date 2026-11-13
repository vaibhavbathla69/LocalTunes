"""Export the selected LocalTunes pixel artwork as an iPhone app icon.

Requires Pillow for development only. The generated master and its prompt live
in branding/ so rebuilding the icon never recreates the retired waveform mark.
"""
import json
from pathlib import Path

from PIL import Image


def main():
    project = Path(__file__).resolve().parents[1]
    master = project / "branding/LocalTunes-Pixel-Icon.png"
    output = project / "LocalTunes/Resources/Assets.xcassets/AppIcon.appiconset"
    with Image.open(master) as source:
        if source.width != source.height:
            raise ValueError("The app icon master must be square")
        if "A" in source.getbands() and source.getchannel("A").getextrema() != (255, 255):
            raise ValueError("The app icon must be fully opaque")
        icon = source.convert("RGB").resize((1024, 1024), Image.Resampling.NEAREST)
    output.mkdir(parents=True, exist_ok=True)
    icon.save(output / "AppIcon.png")
    catalog = {
        "images": [{
            "filename": "AppIcon.png", "idiom": "universal",
            "platform": "ios", "size": "1024x1024",
        }],
        "info": {"author": "xcode", "version": 1},
    }
    (output / "Contents.json").write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
    brand = output.parent / "BrandMark.imageset"
    brand.mkdir(parents=True, exist_ok=True)
    icon.resize((256, 256), Image.Resampling.NEAREST).save(brand / "BrandMark.png")
    (brand / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "BrandMark.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
