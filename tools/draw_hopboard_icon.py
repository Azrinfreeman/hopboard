"""Draw the Hopboard icon locally. Requires Pillow and NumPy; no network calls."""

from pathlib import Path
import math

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps


OUT = Path(__file__).resolve().parents[1] / "assets" / "branding"
SIZE = 2048
SCALE = SIZE / 1024
IVORY = (242, 247, 249)


def rgb(l, c, h):
    """OKLCH to sRGB. Palette values below stay inside the sRGB gamut."""
    a, b = c * math.cos(math.radians(h)), c * math.sin(math.radians(h))
    ll, mm, ss = (l + .3963377774*a + .2158037573*b)**3, (l - .1055613458*a - .0638541728*b)**3, (l - .0894841775*a - 1.291485548*b)**3
    channels = np.array([4.0767416621*ll - 3.3077115913*mm + .2309699292*ss,
                         -1.2684380046*ll + 2.6097574011*mm - .3413193965*ss,
                         -.0041960863*ll - .7034186147*mm + 1.707614701*ss])
    channels = np.where(channels <= .0031308, 12.92*channels, 1.055*np.maximum(channels, 0)**(1/2.4)-.055)
    return tuple(np.clip(np.rint(channels*255), 0, 255).astype(int))


def squircle(box, exponent=4.5):
    """Smooth superellipse, an Apple-inspired shape, not Apple's exact mask."""
    x, y, w, h = box
    points = []
    for t in np.linspace(0, 2*math.pi, 1600, endpoint=False):
        cs, sn = math.cos(t), math.sin(t)
        points.append(((x + w/2 + w/2*math.copysign(abs(cs)**(2/exponent), cs))*SCALE,
                       (y + h/2 + h/2*math.copysign(abs(sn)**(2/exponent), sn))*SCALE))
    mask = Image.new("L", (SIZE, SIZE))
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def rounded(draw, box, radius, fill):
    draw.rounded_rectangle(tuple(round(v*SCALE) for v in box), radius=round(radius*SCALE), fill=fill)


def symbol():
    mask = Image.new("L", (SIZE, SIZE))
    d = ImageDraw.Draw(mask)
    # Staggered clipboards and their shared bridge form an H / handoff silhouette.
    for x, y in [(258, 350), (546, 244)]:
        rounded(d, (x, y, x+220, y+382), 52, 255)
        rounded(d, (x+39, y+39, x+181, y+343), 20, 0)
        rounded(d, (x+71, y-18, x+149, y+48), 21, 255)
    rounded(d, (448, 473, 576, 523), 16, 255)
    return mask


def background(dark=False):
    # Interpolate perceptual lightness; keep hue fixed to avoid muddy midpoints.
    im = Image.new("RGBA", (SIZE, SIZE))
    d = ImageDraw.Draw(im)
    for y in range(SIZE):
        t = y/(SIZE-1)
        l = (.38 - .12*t) if dark else (.57 - .12*t)
        c = .065 if dark else .105
        d.line((0, y, SIZE, y), fill=(*rgb(l, c, 242), 255))
    return im


def icon(dark=False, full_bleed=False):
    bg = background(dark)
    silhouette = symbol()
    if not full_bleed:
        mask = squircle((48, 48, 928, 928))
        bg.putalpha(mask)
        # Restrained edge highlight, with the same light source as symbol shadows.
        edge = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(7)))
        bg.alpha_composite(Image.composite(Image.new("RGBA", bg.size, (214, 237, 250, 45)), Image.new("RGBA", bg.size), edge))
    shadow = Image.new("RGBA", bg.size)
    soft = Image.new("L", bg.size)
    soft.paste(silhouette, (0, round(12*SCALE)))
    soft = soft.filter(ImageFilter.GaussianBlur(13*SCALE)).point(lambda a: int(a*.17))
    shadow.paste((8, 28, 48, 255), mask=soft)
    bg.alpha_composite(shadow)
    bg.alpha_composite(Image.composite(Image.new("RGBA", bg.size, (*IVORY, 255)), Image.new("RGBA", bg.size), silhouette))
    return bg.resize((1024, 1024), Image.Resampling.LANCZOS)


def contrast(a, b):
    def lum(color):
        vals = [v/255 for v in color]
        linear = [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in vals]
        return sum(v*w for v, w in zip(linear, [.2126, .7152, .0722]))
    la, lb = sorted([lum(a), lum(b)])
    return (lb+.05)/(la+.05)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    light, dark = icon(), icon(dark=True)
    light.save(OUT / "hopboard-icon-v2.png")
    dark.save(OUT / "hopboard-icon-v2-dark.png")
    icon(full_bleed=True).convert("RGB").save(OUT / "hopboard-icon-v2-full-bleed.png")
    light.save(OUT / "hopboard-icon-v2.ico", sizes=[(n, n) for n in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
    mark = Image.new("RGBA", (SIZE, SIZE), (*IVORY, 0))
    mark.putalpha(symbol())
    mark.resize((1024, 1024), Image.Resampling.LANCZOS).save(OUT / "hopboard-mark-v2.png")
    panels = []
    for color, source in [((237, 241, 244), light), ((27, 33, 40), dark)]:
        panel = Image.new("RGB", (600, 640), color)
        panel.paste(source.resize((440, 440), Image.Resampling.LANCZOS), (80, 32), source.resize((440, 440), Image.Resampling.LANCZOS))
        x = 170
        for n in (16, 32, 48, 64):
            small = source.resize((n, n), Image.Resampling.LANCZOS)
            panel.paste(small, (x, 540-n//2), small)
            x += n+24
        panels.append(panel)
    preview = Image.new("RGB", (1200, 640))
    preview.paste(panels[0], (0, 0))
    preview.paste(panels[1], (600, 0))
    preview.save(OUT / "hopboard-icon-v2-preview.png")
    gray = ImageOps.grayscale(light).convert("RGBA")
    gray.putalpha(light.getchannel("A"))
    gray.save(OUT / "hopboard-icon-v2-grayscale.png")
    min_contrast = contrast(IVORY, rgb(.57, .105, 242))
    assert min_contrast >= 3, min_contrast
    for file in OUT.glob("hopboard-*-v2*.png"):
        with Image.open(file) as check:
            check.verify()
    with Image.open(OUT / "hopboard-icon-v2.ico") as check:
        assert len(check.ico.sizes()) == 9
    print(f"Saved icon assets to {OUT}")
    print(f"Conservative symbol/background contrast: {min_contrast:.2f}:1")
    print("PNG decoding and all 9 ICO sizes verified.")
