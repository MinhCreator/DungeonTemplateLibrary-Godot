#!/usr/bin/env python3
"""Generate seamless PBR terrain textures with Imagen 4.

For each surface we ask Imagen for a flat, top-down, evenly-lit albedo with no
baked shadows (shadows come from the engine). The raw result is not tileable, so
we fix the four edges with a margin cross-fade (only a thin border is touched,
the interior detail is preserved) and then derive a tangent-space normal map
from luminance via Sobel. Albedo + normal per surface; roughness stays in-shader.
"""
import base64
import json
import os
import sys
import time
import urllib.request

import numpy as np
from PIL import Image

API_KEY = os.environ["GEMINI_API_KEY"]
MODEL = "imagen-4.0-generate-001"
URL = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:predict?key={API_KEY}"
OUT = "/home/krazy/Documents/GitHub/godot-projects/DungeonTemplateLibrary-Godot/assets/textures/terrain"
SIZE = 1024

# Phrased as a plain overhead photograph. Deliberately avoids the words
# texture / PBR / albedo / map / seamless / diagram, which make Imagen draw
# annotated "material sheet" graphics with garbled label text baked in.
STYLE = ("A high-resolution close-up photograph taken from directly overhead "
         "looking straight down, the surface completely fills the frame, soft "
         "even overcast daylight, no harsh shadows, sharp focus, natural color. "
         "Absolutely no text, no letters, no numbers, no labels, no watermark, "
         "no border, no people, no objects.")

SURFACES = {
    "sand":   f"Extreme close-up macro photograph of dry pale fine sand grains with faint ripples, the sand fills the entire frame edge to edge, no horizon, no sky, no water, no people, no objects. {STYLE}",
    "grass":  f"Lush green lawn meadow grass with tiny daisies and small bare dirt patches. {STYLE}",
    "rock":   f"Rugged grey granite rock surface with cracks, fractures and patches of lichen. {STYLE}",
    "snow":   f"Fresh clean white snow with gentle wind drifts and fine sparkling grain. {STYLE}",
    "dirt":   f"Bare packed brown earth trail ground with small embedded pebbles. {STYLE}",
    "gravel": f"A uniform dense bed of many small evenly-sized grey crushed stone pebbles filling the entire frame edge to edge, all stones small and similar size. {STYLE}",
}


def imagen(prompt: str) -> Image.Image:
    body = json.dumps({
        "instances": [{"prompt": prompt}],
        "parameters": {"sampleCount": 1, "aspectRatio": "1:1"},
    }).encode()
    req = urllib.request.Request(URL, data=body,
                                 headers={"Content-Type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = json.load(r)
            b64 = data["predictions"][0]["bytesBase64Encoded"]
            import io
            return Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGB")
        except Exception as e:
            print(f"  retry {attempt+1}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("imagen failed after retries")


def make_tileable(a: np.ndarray, margin: int) -> np.ndarray:
    """Cross-fade opposing edges so the tile wraps. Only `margin` px per side
    are modified; the interior is untouched."""
    a = a.astype(np.float32)
    for axis in (0, 1):
        n = a.shape[axis]
        m = min(margin, n // 4)
        # Outermost pixel of each side ramps fully to the pair-average (t=1),
        # fading to no change (t=0) `m` px in — so both edges converge.
        t = np.linspace(0.0, 1.0, m, dtype=np.float32)
        shp = [1, 1, 1]
        shp[axis] = m
        lead = np.swapaxes(a, axis, 0)[:m]            # near index 0
        trail = np.swapaxes(a, axis, 0)[n - m:][::-1]  # near last, flipped to pair
        avg = 0.5 * (lead + trail)
        tt = t.reshape(-1, *([1] * (a.ndim - 1)))
        new_lead = lead * (1.0 - tt) + avg * tt
        new_trail = trail * (1.0 - tt) + avg * tt
        sw = np.swapaxes(a, axis, 0)
        sw[:m] = new_lead
        sw[n - m:] = new_trail[::-1]
        a = np.swapaxes(sw, 0, axis)
    return np.clip(a, 0, 255).astype(np.uint8)


def normal_from_albedo(rgb: np.ndarray, strength: float = 2.2) -> np.ndarray:
    """Tangent-space normal map (OpenGL +Y) from luminance treated as height.
    Sobel gradients via np.roll keep it tileable."""
    lum = (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1]
           + 0.114 * rgb[..., 2]).astype(np.float32) / 255.0
    gx = (np.roll(lum, -1, 1) - np.roll(lum, 1, 1)) * 0.5
    gy = (np.roll(lum, -1, 0) - np.roll(lum, 1, 0)) * 0.5
    nx, ny, nz = -gx * strength, -gy * strength, np.ones_like(lum)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx * inv, ny * inv, nz * inv], -1)
    return ((n * 0.5 + 0.5) * 255.0).clip(0, 255).astype(np.uint8)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, prompt in SURFACES.items():
        alb_path = os.path.join(OUT, f"{name}_albedo.png")
        nrm_path = os.path.join(OUT, f"{name}_normal.png")
        if os.path.exists(alb_path) and os.path.exists(nrm_path):
            print(f"skip {name} (exists)")
            continue
        print(f"generating {name} ...")
        img = imagen(prompt)
        if img.size != (SIZE, SIZE):
            img = img.resize((SIZE, SIZE), Image.LANCZOS)
        arr = make_tileable(np.asarray(img), margin=int(SIZE * 0.10))
        Image.fromarray(arr).save(alb_path)
        Image.fromarray(normal_from_albedo(arr)).save(nrm_path)
        print(f"  wrote {alb_path} + {nrm_path}")
    print("done")


if __name__ == "__main__":
    main()
