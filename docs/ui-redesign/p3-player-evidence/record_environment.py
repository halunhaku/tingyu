"""Record fixture/screenshot hashes without changing Golden baselines."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
evidence = Path(__file__).resolve().parent
files = list(evidence.rglob('*.png')) + [root / 'app/tool/fixtures/voice-archive-cover.png']
fonts = list((root / 'app').glob('assets/**/*.ttf'))
fonts += [p for name in ['msyh.ttc', 'msyhbd.ttc', 'segoeui.ttf'] if (p := Path('C:/Windows/Fonts') / name).exists()]
def entry(path):
    return {'path': str(path.relative_to(root)) if path.is_relative_to(root) else str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
data = {
    'flutter': '3.47.2', 'dart': '3.13.2', 'platform': 'Windows', 'dpiScale': 1.5,
    'fixture': 'app/tool/voice_archive_preview.dart', 'fixtureProgressSeconds': 84,
    'desktopClientPixels': [1898, 1024], 'mobileClientPixels': [585, 1266],
    'goldenUpdated': False,
    'coverGeneration': {'tool': 'image_gen.imagegen', 'reference': 'directions/c/desktop-player.png',
        'promptSummary': 'Original square photographic album cover: quiet pale sea, isolated dark rock, warm hazy sky; no text, logos or UI.'},
    'files': [entry(p) for p in files], 'fonts': [entry(p) for p in fonts],
}
(evidence / 'environment-and-assets.json').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'Recorded {len(files)} images and {len(fonts)} font files.')
