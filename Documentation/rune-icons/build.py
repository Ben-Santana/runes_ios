#!/usr/bin/env python3
"""The Runes icon set: 20 glyphs in Lucide's box (24 units, 1.5 stroke, round caps and joins).

Every glyph is stroke-only path data, so it drops into LucideIcon / IconStroke unchanged.
Run `python3 build.py` to write svg/*.svg, runes.json and specimen.html next to this file.

Grammar
  stave  a full-height vertical line: a finger
  bead   a solid dot: one moment of contact
  ring   an open circle: contact that lasts. Held up for a hold, fallen for a release
  arc    anything that moves
A second, shorter stave to the left means the gesture is on the middle finger.
"""
import json, pathlib

HERE = pathlib.Path(__file__).parent
STROKE = 1.5


def n(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def ring(cx, cy, r):
    return f"M{n(cx - r)} {n(cy)}a{n(r)} {n(r)} 0 1 0 {n(2 * r)} 0a{n(r)} {n(r)} 0 1 0 {n(-2 * r)} 0Z"


def bead(cx, cy):
    # Two stroked circles cover a solid disc of radius 2 without needing a fill.
    return [ring(cx, cy, 1.25), ring(cx, cy, 0.5)]


def stave(x, y1=4, y2=20):
    return f"M{n(x)} {n(y1)}V{n(y2)}"


SHORT = stave(8.5, 9, 20)  # the index finger, standing beside the middle one
I, M = 12, 15.5            # stave positions: index alone, middle beside the short stave


def tap(x):        return [stave(x), *bead(x, 12)]
def double(x):     return [stave(x), *bead(x, 8.5), *bead(x, 15.5)]
# Hold and release are one rune in two states: the ring is held up at the head of the stave,
# and falls to its foot when the finger lets go. UP and DOWN are the ring's two centres.
UP, DOWN, R = 7, 17, 3
def hold(x):       return [ring(x, UP, R), stave(x, UP + R, 20)]
def release(x):    return [stave(x, 4, DOWN - R), ring(x, DOWN, R)]


def falling(x, extra=(), size=56):
    """The hold rune, animated: lifted on hold, dropped on release. Loops for the specimen."""
    t = 'dur="3.2s" repeatCount="indefinite" calcMode="spline" keyTimes="0;0.4;0.47;0.9;1" keySplines="0 0 1 1;0.6 0 1 0.9;0 0 1 1;0.2 0 0 1"'
    v = lambda a, b: f'values="{a};{a};{b};{b};{a}"'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            f'stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round">'
            + "".join(f'<path d="{d}"/>' for d in extra)
            + f'<circle cx="{n(x)}" cy="{UP}" r="{R}"><animate attributeName="cy" {v(UP, DOWN)} {t}/></circle>'
            f'<line x1="{n(x)}" x2="{n(x)}" y1="4" y2="4"><animate attributeName="y2" {v(4, DOWN - R)} {t}/></line>'
            f'<line x1="{n(x)}" x2="{n(x)}" y1="{UP + R}" y2="20"><animate attributeName="y1" {v(UP + R, 20)} {t}/></line></svg>')


RUNES = [
    # name, title, group, meaning, paths
    ("tap-index", "Tap index", "gesture", "A stave with one bead: the finger touches once.", tap(I)),
    ("tap-middle", "Tap middle", "gesture", "The same touch on the taller, second stave.", [SHORT, *tap(M)]),
    ("double-tap-index", "Double tap index", "gesture", "Two beads, two touches.", double(I)),
    ("double-tap-middle", "Double tap middle", "gesture", "Two touches on the second stave.", [SHORT, *double(M)]),
    ("hold-index", "Hold index", "gesture", "A ring held up at the head of the stave.", hold(I)),
    ("hold-middle", "Hold middle", "gesture", "A ring held up on the second stave.", [SHORT, *hold(M)]),
    ("release-index", "Release index", "gesture", "The same ring, fallen to the foot: the hold let go.", release(I)),
    ("release-middle", "Release middle", "gesture", "The second stave lets its ring fall.", [SHORT, *release(M)]),
    ("swipe-up", "Swipe up", "gesture", "A stave under an arc: the way it travels.", ["M12 20V4", "M6 8A6.5 6.5 0 0 1 18 8"]),
    ("swipe-down", "Swipe down", "gesture", "", ["M12 4V20", "M6 16A6.5 6.5 0 0 0 18 16"]),
    ("swipe-left", "Swipe left", "gesture", "", ["M20 12H4", "M8 6A6.5 6.5 0 0 0 8 18"]),
    ("swipe-right", "Swipe right", "gesture", "", ["M4 12H20", "M16 6A6.5 6.5 0 0 1 16 18"]),
    ("rotation", "Rotation", "gesture", "A bead carried round an open orbit: the wrist turns.", ["M12 5A7 7 0 1 1 5 12", *bead(5, 12)]),
    ("movement", "Movement", "gesture", "Three ways out from one point: the hand moves in space.", ["M12 13.5V5", "M12 13.5L5 17.5", "M12 13.5L19 17.5", *bead(12, 13.5)]),
    ("air", "Air shape", "gesture", "A line that loops and lands: a shape traced in the air.", ["M4 16C9 16 15.5 12.5 15.5 8.5A3.5 3.5 0 0 0 8.5 8.5C8.5 12.5 13.5 16 17.5 16", *bead(19, 16)]),
    ("home", "Home", "everyday", "An arch with someone in it.", ["M5 20V11A7 7 0 0 1 19 11V20", *bead(12, 15)]),
    ("music", "Music", "everyday", "A stave that carries a note.", ["M12 17.5V5", "M12 5A4 4 0 0 1 16 9", *bead(10, 17.5)]),
    ("light", "Light", "everyday", "A ring that gives off four rays.", [ring(12, 12, 4), "M12 2.5V4.5", "M12 19.5V21.5", "M2.5 12H4.5", "M19.5 12H21.5"]),
    ("time", "Time", "everyday", "Two bowls meeting at a point.", ["M5 4H19", "M5 20H19", "M5 4A7 8 0 0 0 19 4", "M5 20A7 8 0 0 1 19 20"]),
    ("voice", "Voice", "everyday", "A bead that sends two arcs outward.", ["M11.36 7.4A6 6 0 0 1 11.36 16.6", "M15.28 4.22A11 11 0 0 1 15.28 19.78", *bead(7.5, 12)]),
]


def svg(paths, size=24, extra=""):
    d = "".join(paths)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"{extra}><path d="{d}"/></svg>')


def specimen():
    def cell(r):
        name, title, group, meaning, paths = r
        return f'<figure><div class="glyph">{svg(paths, 56)}</div><figcaption><b>{title}</b><span>{meaning}</span></figcaption></figure>'

    gestures = "".join(cell(r) for r in RUNES if r[2] == "gesture")
    everyday = "".join(cell(r) for r in RUNES if r[2] == "everyday")
    row = lambda s: "".join(f'<span>{svg(r[4], s)}</span>' for r in RUNES)
    parts = [("Stave", "A finger.", [stave(12)]), ("Bead", "A touch.", bead(12, 12)), ("Ring", "A touch that lasts. It falls when let go.", [ring(12, 12, 3)]),
             ("Arc", "Anything that moves.", ["M6 8A6.5 6.5 0 0 1 18 8"]), ("Second stave", "The middle finger.", [SHORT, stave(M)])]
    grammar = "".join(f'<figure><div class="glyph">{svg(p, 40)}</div><figcaption><b>{t}</b><span>{m}</span></figcaption></figure>' for t, m, p in parts)
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Runes icon set</title><style>
:root{{--paper:#fff;--ink:#191919;--muted:#696969;--rule:#e8e8e8;--soft:#fafafa}}
@media (prefers-color-scheme:dark){{:root:not([data-theme=light]){{--paper:#0b0b0c;--ink:#ededed;--muted:#8e8e8e;--rule:#262628;--soft:#141416}}}}
:root[data-theme=dark]{{--paper:#0b0b0c;--ink:#ededed;--muted:#8e8e8e;--rule:#262628;--soft:#141416}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:15px/1.45 Geist,-apple-system,system-ui,sans-serif}}
main{{max-width:1040px;margin:0 auto;padding:56px 20px 72px}}
h1{{font-size:28px;font-weight:500;letter-spacing:-.6px;margin:0 0 6px}}p.lede{{color:var(--muted);margin:0;max-width:60ch}}
h2{{font-size:14px;font-weight:500;margin:44px 0 0;padding-bottom:10px;border-bottom:1px solid var(--rule);display:flex;justify-content:space-between}}
h2 small{{font-weight:400;font-size:12px;color:var(--muted)}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}}
figure{{margin:0;padding:22px 14px 18px 0;border-bottom:1px solid var(--rule)}}
.glyph{{height:72px;display:flex;align-items:center}}
figcaption b{{display:block;font-weight:500;font-size:14px}}figcaption span{{display:block;font-size:12px;color:var(--muted);min-height:34px}}
.row{{display:flex;flex-wrap:wrap;gap:6px 14px;padding:16px 0;border-bottom:1px solid var(--rule);align-items:center}}.row span{{display:flex}}
.row i{{font-style:normal;font-size:12px;color:var(--muted);width:44px}}
.invert{{background:var(--ink);color:var(--paper);border-radius:8px;padding:16px 14px;border:0;margin-top:16px}}.invert i{{color:inherit;opacity:.6}}
</style></head><body><main>
<h1>Runes</h1><p class="lede">Twenty glyphs built from four strokes. Each one is drawn in a 24-unit box at a 1.5 stroke with round ends, so it sits beside the app's existing icons.</p>
<h2>Grammar <small>4 strokes, 1 rule</small></h2><div class="grid">{grammar}</div>
<h2>Gestures <small>15</small></h2><div class="grid">{gestures}</div>
<h2>Hold and release <small>one rune, two states</small></h2><div class="grid">
<figure><div class="glyph">{falling(I)}</div><figcaption><b>Index</b><span>Held up, then dropped on release.</span></figcaption></figure>
<figure><div class="glyph">{falling(M, [SHORT])}</div><figcaption><b>Middle</b><span>The same fall on the second stave.</span></figcaption></figure></div>
<h2>Everyday <small>5</small></h2><div class="grid">{everyday}</div>
<h2>In use <small>the sizes the app draws</small></h2>
<div class="row"><i>24</i>{row(24)}</div><div class="row"><i>18</i>{row(18)}</div><div class="row"><i>15</i>{row(15)}</div>
<div class="row invert"><i>24</i>{row(24)}</div>
</main></body></html>"""


if __name__ == "__main__":
    (HERE / "svg").mkdir(exist_ok=True)
    for name, title, group, meaning, paths in RUNES:
        (HERE / "svg" / f"{name}.svg").write_text(svg(paths) + "\n")
    (HERE / "runes.json").write_text(json.dumps(
        [{"name": r[0], "title": r[1], "group": r[2], "meaning": r[3], "paths": r[4]} for r in RUNES], indent=1) + "\n")
    (HERE / "specimen.html").write_text(specimen())
    print("wrote", len(RUNES), "runes")
