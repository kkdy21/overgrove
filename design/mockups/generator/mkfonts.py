"""Builds local static instances of the macOS system fonts for the mockup renderer.

rsvg-convert (pango + fontconfig) cannot pick SF Pro's Medium/Semibold weights or SF Mono from the
variable system fonts, so this writes `.fonts/` with fixed weights under private family names
("OG Sans", "OG Mono") and a fonts.conf that points at them. macOS only. The generated fonts are
for local rendering and text measuring; they are git-ignored and must not be committed.
"""
import os, sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '.fonts')
SANS = '/System/Library/Fonts/SFNS.ttf'
MONO = '/System/Library/Fonts/SFNSMono.ttf'
SANS_WEIGHTS = ((400, 'Regular'), (500, 'Medium'), (600, 'Semibold'), (700, 'Bold'))
MONO_WEIGHTS = ((400, 'Regular'), (600, 'Semibold'))


def instance(src, dst, family, style, weight, axes):
    font = instancer.instantiateVariableFont(TTFont(src), axes, inplace=False)
    name = font['name']
    for rec in list(name.names):
        if rec.nameID in (1, 2, 3, 4, 6, 16, 17, 21, 22, 25):
            name.removeNames(nameID=rec.nameID)
    ps = f"{family.replace(' ', '')}-{style}"
    for nid, val in ((1, family), (2, style), (3, ps), (4, f'{family} {style}'), (6, ps), (16, family), (17, style)):
        name.setName(val, nid, 3, 1, 0x409)
        name.setName(val, nid, 1, 0, 0)
    font['OS/2'].usWeightClass = weight
    font['OS/2'].fsSelection = (font['OS/2'].fsSelection & ~0b1100001) | (0b100000 if weight >= 700 else 0b1000000 if weight == 400 else 0)
    font['head'].macStyle = 1 if weight >= 700 else 0
    if 'STAT' in font:
        del font['STAT']
    font.save(dst)


def main():
    if sys.platform != 'darwin' or not os.path.exists(SANS):
        sys.exit('mkfonts.py needs macOS system fonts (SFNS.ttf, SFNSMono.ttf)')
    os.makedirs(OUT, exist_ok=True)
    jobs = [(SANS, 'OG Sans', 'OGSans', w, s, {'wdth': 100, 'opsz': 17, 'GRAD': 400, 'wght': w}) for w, s in SANS_WEIGHTS]
    jobs += [(MONO, 'OG Mono', 'OGMono', w, s, {'wght': w}) for w, s in MONO_WEIGHTS]
    for src, family, stem, weight, style, axes in jobs:
        dst = os.path.join(OUT, f'{stem}-{style}.ttf')
        if not os.path.exists(dst):
            instance(src, dst, family, style, weight, axes)
    with open(os.path.join(OUT, 'fonts.conf'), 'w') as f:
        f.write('<?xml version="1.0"?>\n<!DOCTYPE fontconfig SYSTEM "fonts.dtd">\n<fontconfig>\n'
                f'  <dir>{OUT}</dir>\n  <dir>/System/Library/Fonts</dir>\n  <dir>/Library/Fonts</dir>\n'
                f'  <cachedir>{OUT}/cache</cachedir>\n</fontconfig>\n')


if __name__ == '__main__':
    main()
