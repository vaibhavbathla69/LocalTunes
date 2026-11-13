"""Generate synthetic test audio only. Requires soundfile and mutagen on the developer's machine."""
import math
from pathlib import Path
import soundfile as sf
from mutagen.flac import FLAC

folder = Path(__file__).resolve().parent.parent / "LocalTunesTests" / "Fixtures"
folder.mkdir(exist_ok=True)
for index, amplitude in enumerate([0.25, 0.6], 1):
    target = folder / f"tone{index}.flac"
    samples = [amplitude * math.sin(2 * math.pi * (220 + index * 110) * n / 44100) for n in range(4 * 44100)]
    sf.write(target, samples, 44100, format="FLAC", subtype="PCM_16")
    tags = FLAC(target)
    for key, value in {"TITLE": f"FLAC tone {index}", "ARTIST": "Synthetic Artist", "ALBUM": "FLAC Album",
                       "GENRE": "Test", "TRACKNUMBER": f"{index}/2", "DISCNUMBER": "1/1", "DATE": "2024-04-12",
                       "LYRICS": "[00:00.00]Synthetic fixture"}.items():
        tags[key] = value
    tags.save()
