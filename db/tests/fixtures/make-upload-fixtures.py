#!/usr/bin/env python3
"""The pictures test 16 uploads. Run once; the files sit beside this script.

Each is awkward in one particular way, because the converter's job is to deal
with exactly these:

  phone.jpg     4032 by 3024, stored sideways with EXIF orientation 6 (as a
                phone does it) and a GPS position in the metadata
  alpha.png     1600 by 900 with a transparent half
  mid.jpg       1000 by 700: allowed, and said to be on the small side
  small.jpg     640 by 480: refused as too small for a banner
  fake.jpg      a text file with a picture's name
  drawing.svg   an SVG, refused whatever it contains
  photo.heic    the first bytes of an iPhone HEIC
"""
from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).parent

def gradient(w, h, mode='RGB'):
    im = Image.new(mode, (w, h))
    d = ImageDraw.Draw(im)
    for y in range(0, h, 8):
        c = (40 + y * 180 // h, 60, 200 - y * 150 // h)
        d.rectangle([0, y, w, y + 8], fill=c + ((255,) if mode == 'RGBA' else ()))
    d.ellipse([w // 4, h // 4, w // 2, h // 2], fill=(230, 30, 40) + ((255,) if mode == 'RGBA' else ()))
    return im

# Stored 4032 wide and 3024 high, flagged "rotate 90 clockwise to display".
# Displayed correctly it is 3024 wide and 4032 high.
im = gradient(4032, 3024)
ex = Image.Exif()
ex[0x0112] = 6                                        # Orientation
ex[0x010F] = 'TestCam'                                # Make
gps = {1: 'N', 2: (52.0, 48.0, 30.0), 3: 'W', 4: (1.0, 38.0, 15.0)}
ex[0x8825] = gps                                      # GPSInfo
im.save(HERE / 'phone.jpg', quality=70, exif=ex.tobytes())

a = gradient(1600, 900, 'RGBA')
ImageDraw.Draw(a).rectangle([800, 0, 1600, 900], fill=(0, 0, 0, 0))
a.save(HERE / 'alpha.png')

gradient(1000, 700).save(HERE / 'mid.jpg', quality=80)
gradient(640, 480).save(HERE / 'small.jpg', quality=80)
(HERE / 'fake.jpg').write_text('This is not a picture.\n')
(HERE / 'drawing.svg').write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900">'
    '<script>alert(1)</script><rect width="1600" height="900" fill="red"/></svg>')
(HERE / 'photo.heic').write_bytes(b'\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic' + b'\x00' * 64)
print('written to', HERE)
