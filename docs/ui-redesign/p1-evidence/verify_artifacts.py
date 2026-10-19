"""只验证P1交付物完整性，不替代视觉/交互验收。仅需Python标准库。"""
import hashlib
import json
import re
import struct
from pathlib import Path

root = Path(__file__).resolve().parents[1]
errors = []
expected = {
    f"directions/{direction}/{scene}.png"
    for direction in "abc"
    for scene in ("desktop-library", "desktop-player", "mobile-library", "mobile-player")
}
assets = json.loads((root / "directions/asset-manifest.json").read_text(encoding="utf-8-sig"))
actual = {asset["file"] for asset in assets}
if actual != expected:
    errors.append("图稿集合与三方向四场景不一致")
for asset in assets:
    path = root / asset["file"]
    if not path.is_file():
        errors.append(f"缺失图稿: {asset['file']}")
        continue
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest().upper() != asset["sha256"]:
        errors.append(f"哈希不一致: {asset['file']}")
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        errors.append(f"不是PNG: {asset['file']}")
    elif struct.unpack(">II", data[16:24]) != (asset["width"], asset["height"]):
        errors.append(f"尺寸不一致: {asset['file']}")
fixture = json.loads((root / "directions/fixture.json").read_text(encoding="utf-8"))
if len(fixture["tracks"]) != 12 or sum(album["count"] for album in fixture["albums"]) != 12:
    errors.append("元数据夹具歌曲/专辑总数不一致")
current = next(track for track in fixture["tracks"] if track["id"] == fixture["currentTrack"])
if not 0 <= fixture["positionSeconds"] < current["durationSeconds"]:
    errors.append("固定播放时刻超出当前曲时长")
for document in (root / "01-directions.md", root / "01-visual-review.md", root / "p1-evidence/research-notes.md"):
    for target in re.findall(r"\]\(([^)]+)\)", document.read_text(encoding="utf-8")):
        if "://" not in target and not (document.parent / target.split("#")[0]).exists():
            errors.append(f"本地链接不存在: {document.name} -> {target}")
result = {"scope": "P1交付物完整性校验，非视觉或Flutter测试", "images": len(assets), "hashes_and_dimensions_checked": True, "local_markdown_links_checked": True, "errors": errors, "passed": not errors}
print(json.dumps(result, ensure_ascii=False, indent=2))
raise SystemExit(1 if errors else 0)
