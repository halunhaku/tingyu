"""Validate proposed P2 tokens, source mappings, budgets and frozen selection.

This does not render Flutter, apply tokens or approve visual changes.
Run with Python 3, no third-party packages required.
"""
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
repo = root.parents[1]
read_json = lambda p: json.loads(p.read_text(encoding="utf-8-sig"))
tokens = read_json(root / "tokens/voice-archive.v0.1.json")
mapping = read_json(root / "tokens/flutter-mapping.v0.1.json")
decision = read_json(root / "decision-c.json")
errors, contrasts, mappings_checked = [], [], []


def rgba(value):
    value = value.removeprefix("#")
    if len(value) == 6:
        return [1.0] + [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    if len(value) == 8:
        return [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4, 6)]
    raise ValueError("invalid color")


def composite(fg, bg):
    a, *rgb = rgba(fg)
    _, *base = rgba(bg) if isinstance(bg, str) else bg
    return [1.0] + [a * x + (1 - a) * y for x, y in zip(rgb, base)]


def luminance(value):
    channels = (rgba(value) if isinstance(value, str) else value)[1:]
    channels = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in channels]
    return sum(x * y for x, y in zip(channels, [0.2126, 0.7152, 0.0722]))


def expect_contrast(name, fg, bg, minimum):
    a, b = luminance(fg), luminance(bg)
    ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
    contrasts.append({"pair": name, "ratio": round(ratio, 4), "minimum": minimum, "passed": ratio >= minimum})
    if ratio < minimum:
        errors.append(f"contrast: {name} = {ratio:.6f} < {minimum}")


source = (repo / "app/lib/design/tokens/color.dart").read_text(encoding="utf-8")
required_colors = set(re.findall(r"required this\.(\w+)", source.split("final Color canvas")[0]))
for mode, color in tokens["color"].items():
    if set(color) != required_colors:
        errors.append(f"color keys do not match TyColors: {mode}")
    for name, value in color.items():
        if not re.fullmatch(r"#[0-9A-F]{6}(?:[0-9A-F]{2})?", value):
            errors.append(f"invalid hex: {mode}.{name}")
    for surface in ("canvas", "surface", "surfaceSunken", "surfaceRaised", "surfaceOverlay"):
        for state in (None, "surfaceHover", "surfacePressed", "surfaceSelected"):
            bg = color[surface] if state is None else composite(color[state], color[surface])
            suffix = surface + ("+" + state if state else "")
            for text in ("textPrimary", "textSecondary", "textTertiary"):
                expect_contrast(f"{mode}.{text}/{suffix}", color[text], bg, 4.5)
        for text in ("accent", "success", "warning", "danger"):
            expect_contrast(f"{mode}.{text}/{surface}", color[text], color[surface], 4.5)
        expect_contrast(f"{mode}.focus/{surface}", color["focusRing"], color[surface], 3)
        expect_contrast(f"{mode}.controlBoundary/{surface}", color["borderStrong"], color[surface], 3)
        selected = composite(color["surfaceSelected"], color[surface])
        selected_text = tokens["aliases"]["currentTrackText"][mode]
        expect_contrast(f"{mode}.currentTrackText/{surface}+selected", color[selected_text], selected, 4.5)
    for state in ("accent", "accentHover", "accentPressed"):
        expect_contrast(f"{mode}.onAccent/{state}", color["onAccent"], color[state], 4.5)
    expect_contrast(f"{mode}.placeholderIcon", color["textTertiary"], color["coverPlaceholder"], 3)

for group in mapping["groups"]:
    path = repo / group["file"]
    if not path.is_file():
        errors.append(f"missing mapping source: {group['file']}")
        continue
    contents = path.read_text(encoding="utf-8")
    if not re.search(r"\bclass\s+" + re.escape(group["type"]) + r"\b", contents):
        errors.append(f"missing class: {group['type']}")
    if group["members"] == "same":
        selector = group["selector"].split(".")[0]
        names = list(tokens[selector]["light"] if selector == "color" else tokens[selector])
    else:
        names = list(group["members"].values())
    for name in names:
        if not re.search(r"\b" + re.escape(name) + r"\b", contents):
            errors.append(f"missing member: {group['type']}.{name}")
    mappings_checked.append({"selector": group["selector"], "type": group["type"], "source": group["file"], "memberCount": len(names), "check": "lexical source presence, not Dart compile or applied values"})

columns = tokens["table"]["columns"]
gap = tokens["table"]["columnGap"]
remaining = dict(columns)
budgets = {}
for key, removal in (("all", None), ("withoutAlbum", "album"), ("withoutAlbumArtist", "artist"), ("withoutAlbumArtistSource", "source")):
    if removal:
        remaining.pop(removal)
    total = sum(remaining.values()) + (len(remaining) - 1) * gap
    budgets[key] = total
    if total != tokens["table"]["minContentWidth"][key]:
        errors.append(f"table budget: {key}")
for asset in decision["assets"]:
    if hashlib.sha256((root / asset["path"]).read_bytes()).hexdigest().upper() != asset["sha256"]:
        errors.append(f"selected asset changed: {asset['path']}")
if not decision["directionApproved"] or decision["designSystemApproved"]:
    errors.append("approval scope must remain direction-only until user confirms P2")
if tokens["breakpoints"] != {"compactMaxExclusive": 640, "mediumMaxExclusive": 1024}:
    errors.append("breakpoints differ from preserved FormFactor")
for path in (root / "02-design-system.md", root / "01-directions.md"):
    for link in re.findall(r"\]\(([^)]+)\)", path.read_text(encoding="utf-8")):
        link_target = path.parent / link.split("#")[0]
        is_generated_report = link_target.resolve() == (root / "p2-evidence/token-validation.json").resolve()
        if "://" not in link and not is_generated_report and not link_target.exists():
            errors.append(f"broken link: {path.name}: {link}")

report = {"scope": "proposed P2 specification, no Flutter runtime or visual compliance claim", "passed": not errors, "errors": errors, "contrastPairCount": len(contrasts), "contrasts": contrasts, "mappingChecks": mappings_checked, "tableBudgets": budgets, "selectedAssetCount": len(decision["assets"]), "implementationApplied": False}
target = root / "p2-evidence/token-validation.json"
target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"passed": not errors, "errors": errors, "contrastPairs": len(contrasts), "tableBudgets": budgets}, ensure_ascii=True, indent=2))
raise SystemExit(1 if errors else 0)
