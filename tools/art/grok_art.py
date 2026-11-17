#!/usr/bin/env python3
"""Grok art helpers: generate game art with the Grok Imagine API and drop it into the game.

Each game has a config at art/<game>/helpers.json holding:
  style      - the look, pasted into every prompt
  helpers    - standing instructions per helper (Tilt Artist, Character Studio, ...)
  assets     - every file the game can use: name, size, transparent or not, prompt,
               and optionally "match": another asset whose approved image is used as a reference

Setup (once):
  pip3 install pillow
  echo 'XAI_API_KEY=your-key-here' > .env      # in the repo root; .env is git-ignored

Commands (run from the repo root):
  python3 tools/art/grok_art.py list     --game tilt
  python3 tools/art/grok_art.py prompt   --game tilt --asset marble_r     # copy into the Grok app (no API key needed)
  python3 tools/art/grok_art.py generate --game tilt --asset marble_r --variations 3
  python3 tools/art/grok_art.py approve  --game tilt --asset marble_r --pick 2
  python3 tools/art/grok_art.py generate --game tilt --missing --variations 2

generate  saves candidates to art/<game>/candidates/<asset>_v1.png, _v2.png ... (look at them in Finder)
approve   keeps one: saves the original to art/<game>/originals/, removes the background if the
          asset is transparent, resizes it, writes games/<game>/assets/<asset>.png, and logs it.
Cost: about $0.04 per image generated (more for reference-image edits).
"""
import argparse
import base64
import datetime
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
API = "https://api.x.ai/v1"
MODEL = "grok-imagine-image-2.0"


# ------------------------------------------------------------------ helpers

def load_key():
    key = os.environ.get("XAI_API_KEY")
    env = ROOT / ".env"
    if not key and env.exists():
        for line in env.read_text().splitlines():
            if line.strip().startswith("XAI_API_KEY="):
                key = line.split("=", 1)[1].strip().strip('"').strip("'")
    if not key:
        sys.exit("No API key. Create one at console.x.ai and put XAI_API_KEY=... in the .env file in the repo root.")
    return key


def load_config(game):
    path = ROOT / "art" / game / "helpers.json"
    if not path.exists():
        sys.exit(f"Missing {path}")
    return json.loads(path.read_text())


def find_asset(cfg, name):
    for a in cfg["assets"]:
        if a["name"] == name:
            return a
    sys.exit(f"Unknown asset '{name}'. Run the list command to see names.")


def build_prompt(cfg, asset):
    helper = cfg["helpers"][asset.get("helper", "Artist")]
    parts = [helper.strip(), "Style: " + cfg["style"].strip(), "Make this: " + asset["prompt"].strip()]
    if asset.get("transparent"):
        key_color = asset.get("key_color", cfg.get("key_color", "pure bright green (#00FF00)"))
        parts.append("Plain flat solid " + key_color +
                     " background filling the whole frame, nothing else in the background, no shadow on it.")
    if asset.get("match"):
        parts.append("Match the attached reference image exactly in style, lighting, size and shape; "
                     "change only what this request asks for.")
    return "\n\n".join(parts)


def post(key, path, body):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"_error": e.code, "_body": e.read().decode(errors="replace")}


def image_bytes(item):
    if item.get("b64_json"):
        return base64.b64decode(item["b64_json"])
    with urllib.request.urlopen(item["url"], timeout=180) as r:
        return r.read()


def data_url(path):
    return "data:image/png;base64," + base64.b64encode(Path(path).read_bytes()).decode()


def approved_original(game, name):
    p = ROOT / "art" / game / "originals" / f"{name}.png"
    return p if p.exists() else None


# ------------------------------------------------------------------ image processing

def remove_background(img, tolerance=60):
    """Remove a flat key-color background (green or magenta) and clean the edge.

    1. Flood-fill from the image edges: pixels close to the background color become transparent.
    2. Edge pixels that are a blend of object and background become partly transparent.
    3. Color spill (green or magenta tint) is removed from the remaining edge pixels.
    4. The outline is trimmed by one pixel and softened slightly.
    """
    from PIL import Image, ImageFilter
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

    def dist(c):
        return sum(abs(c[i] - bg[i]) for i in range(3))

    removed = bytearray(w * h)
    seen = bytearray(w * h)
    stack = [(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)] + \
            [(0, y) for y in range(h)] + [(w - 1, y) for y in range(h)]
    while stack:
        x, y = stack.pop()
        i = y * w + x
        if seen[i]:
            continue
        seen[i] = 1
        if dist(px[x, y]) > tolerance:
            continue
        removed[i] = 1
        px[x, y] = (0, 0, 0, 0)
        if x > 0: stack.append((x - 1, y))
        if x < w - 1: stack.append((x + 1, y))
        if y > 0: stack.append((x, y - 1))
        if y < h - 1: stack.append((x, y + 1))

    # Which channels make up the key color? (green: G; magenta: R and B)
    strong = [i for i in range(3) if bg[i] > 150]
    weak = [i for i in range(3) if i not in strong]

    # Pixels within 4 px of the removed area: fade blended ones and remove spill.
    near = bytearray(w * h)
    frontier = [i for i in range(w * h) if removed[i]]
    for _ in range(4):
        nxt = []
        for i in frontier:
            x, y = i % w, i // w
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if 0 <= nx < w and 0 <= ny < h:
                    j = ny * w + nx
                    if not removed[j] and not near[j]:
                        near[j] = 1
                        nxt.append(j)
        frontier = nxt
    for i in range(w * h):
        if not near[i]:
            continue
        x, y = i % w, i // w
        r, g, b, a = px[x, y]
        c = [r, g, b]
        d = dist(c)
        if d < tolerance * 3:
            a = int(a * max(0.0, (d - tolerance) / (tolerance * 2)))
        if strong and weak and d < tolerance * 4:  # only blended pixels, so real greens/magentas survive
            limit = max(c[k] for k in weak)
            for k in strong:
                c[k] = min(c[k], limit)
        px[x, y] = (c[0], c[1], c[2], a)

    alpha = img.getchannel("A").filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.6))
    img.putalpha(alpha)
    return img


def fit(img, size, transparent):
    from PIL import Image
    tw, th = size
    if transparent:
        box = img.getbbox()
        if box:
            img = img.crop(box)
        scale = min(tw * 0.92 / img.width, th * 0.92 / img.height)
        img = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)
        canvas = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
        canvas.paste(img, ((tw - img.width) // 2, (th - img.height) // 2), img)
        return canvas
    # Cover-crop for backgrounds and tiles.
    scale = max(tw / img.width, th / img.height)
    img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
    left, top = (img.width - tw) // 2, (img.height - th) // 2
    return img.crop((left, top, left + tw, top + th)).convert("RGB")


# ------------------------------------------------------------------ commands

def cmd_list(args):
    cfg = load_config(args.game)
    print(f"{'asset':22} {'size':10} {'helper':18} status")
    for a in cfg["assets"]:
        done = (ROOT / "games" / args.game / "assets" / f"{a['name']}.png").exists()
        cands = list((ROOT / "art" / args.game / "candidates").glob(f"{a['name']}_v*.png"))
        status = "in game" if done else (f"{len(cands)} candidate(s)" if cands else "-")
        print(f"{a['name']:22} {str(a['size'][0]) + 'x' + str(a['size'][1]):10} {a.get('helper', ''):18} {status}")


def cmd_prompt(args):
    """Print the full prompt for an asset, to paste into the Grok app (no API key needed)."""
    cfg = load_config(args.game)
    asset = find_asset(cfg, args.asset)
    out_dir = ROOT / "art" / args.game / "candidates"
    out_dir.mkdir(parents=True, exist_ok=True)
    existing = len(list(out_dir.glob(f"{asset['name']}_v*.png")))
    print("=" * 70)
    print(build_prompt(cfg, asset))
    print("=" * 70)
    print(f"Aspect ratio: {'9:16 portrait' if asset['size'][1] > asset['size'][0] else '1:1 square'}")
    if asset.get("match"):
        ref = approved_original(args.game, asset["match"])
        print(f"Attach this reference image in Grok: {ref.relative_to(ROOT) if ref else '(approve ' + asset['match'] + ' first)'}")
    print("Generate it in the Grok app, download the one you like, then run:")
    print(f"  python3 tools/art/grok_art.py approve --game {args.game} --asset {asset['name']} --file ~/Downloads/<file name>")
    (out_dir / f"{asset['name']}_prompt.txt").write_text(build_prompt(cfg, asset) + "\n")


def generate_one(key, cfg, game, asset, variations):
    prompt = build_prompt(cfg, asset)
    out_dir = ROOT / "art" / game / "candidates"
    out_dir.mkdir(parents=True, exist_ok=True)
    portrait = asset["size"][1] > asset["size"][0]
    body = {"model": MODEL, "prompt": prompt, "n": variations,
            "aspect_ratio": "9:16" if portrait else "1:1"}
    ref = approved_original(game, asset["match"]) if asset.get("match") else None
    if asset.get("match") and not ref:
        print(f"  note: '{asset['match']}' isn't approved yet, so {asset['name']} is generated without a reference.")
    if ref:
        body["image"] = {"url": data_url(ref), "type": "image_url"}
        result = post(key, "/images/edits", body)
    else:
        result = post(key, "/images/generations", body)
    if "_error" in result and result["_error"] == 400:
        # Some optional fields may not be accepted; retry with the basics only.
        for k in ("aspect_ratio", "n"):
            body.pop(k, None)
        result = post(key, "/images/edits" if ref else "/images/generations", body)
    if "_error" in result:
        sys.exit(f"API error {result['_error']}: {result['_body'][:500]}")
    items = result.get("data", [])
    existing = len(list(out_dir.glob(f"{asset['name']}_v*.png")))
    for i, item in enumerate(items, start=1):
        path = out_dir / f"{asset['name']}_v{existing + i}.png"
        path.write_bytes(image_bytes(item))
        print(f"  saved {path.relative_to(ROOT)}")
    (out_dir / f"{asset['name']}_prompt.txt").write_text(prompt + "\n")


def cmd_generate(args):
    cfg = load_config(args.game)
    key = load_key()
    if args.missing:
        names = [a["name"] for a in cfg["assets"]
                 if not (ROOT / "games" / args.game / "assets" / f"{a['name']}.png").exists()]
    else:
        names = [args.asset]
    for name in names:
        print(f"Generating {name} ...")
        generate_one(key, cfg, args.game, find_asset(cfg, name), args.variations)


def cmd_approve(args):
    from PIL import Image
    cfg = load_config(args.game)
    asset = find_asset(cfg, args.asset)
    if args.file:
        cand = Path(os.path.expanduser(args.file))
        source = f"Grok app ({cand.name})"
        if not cand.exists():
            sys.exit(f"File not found: {cand}")
    else:
        cand = ROOT / "art" / args.game / "candidates" / f"{asset['name']}_v{args.pick}.png"
        source = f"Grok Imagine ({MODEL}) v{args.pick}"
        if not cand.exists():
            sys.exit(f"No candidate {cand.relative_to(ROOT)}. Save an image from Grok there, "
                     f"or pass the downloaded file with --file ~/Downloads/<name>.")
    originals = ROOT / "art" / args.game / "originals"
    originals.mkdir(parents=True, exist_ok=True)
    img = Image.open(cand)
    img.convert("RGBA").save(originals / f"{asset['name']}.png")  # keep the original (as PNG)
    if asset.get("transparent"):
        img = remove_background(img, args.tolerance)
    img = fit(img, asset["size"], asset.get("transparent", False))
    dest = ROOT / "games" / args.game / "assets" / f"{asset['name']}.png"
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest)
    log = ROOT / "art" / args.game / "LOG.md"
    if not log.exists():
        log.write_text("# Art log\n\n| Date | Asset | Source | Helper | Prompt |\n| --- | --- | --- | --- | --- |\n")
    with log.open("a") as f:
        f.write(f"| {datetime.date.today()} | {asset['name']} | {source} | "
                f"{asset.get('helper', '')} | {asset['prompt'].replace('|', '/')} |\n")
    print(f"Approved {asset['name']} -> {dest.relative_to(ROOT)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list"); p.add_argument("--game", required=True); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("prompt"); p.add_argument("--game", required=True); p.add_argument("--asset", required=True)
    p.set_defaults(fn=cmd_prompt)
    p = sub.add_parser("generate"); p.add_argument("--game", required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--asset"); g.add_argument("--missing", action="store_true")
    p.add_argument("--variations", type=int, default=3); p.set_defaults(fn=cmd_generate)
    p = sub.add_parser("approve"); p.add_argument("--game", required=True); p.add_argument("--asset", required=True)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--pick", type=int, help="number of a candidate in art/<game>/candidates/")
    src.add_argument("--file", help="any image file, e.g. one downloaded from the Grok app (png, jpg, webp)")
    p.add_argument("--tolerance", type=int, default=60, help="background removal strength (raise if edges remain)")
    p.set_defaults(fn=cmd_approve)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
