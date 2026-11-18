#!/usr/bin/env python3
"""Stamp a built Flutter web worker from its version.json, never the sources.

Usage: python3 tools/stamp_web_cache.py build/web
Run after every web build and before packaging/deploying the built directory.
This does not publish anything or modify the diary. A changed worker lets the
browser install the new, separate offline shell before it discards the old one.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?\Z")
BUILD = re.compile(r"[0-9]+\Z")
CACHE = re.compile(r"^const CACHE_NAME = 'fitness-smart-shell-[A-Za-z0-9.-]+';$", re.M)
FONT_ASSET = 'fonts/fallback/Roboto-Regular.ttf'
FONT_SHA256 = '79e851404657dac2106b3d22ad256d47824a9a5765458edb72c9102a45816d95'


def verify_required_font(directory: Path) -> None:
    """Refuse to stamp a shell that cannot render Cyrillic after first offline reload."""
    manifest = json.loads((directory / 'assets' / 'FontManifest.json').read_text(encoding='utf-8'))
    if not isinstance(manifest, list) or not any(
        isinstance(family, dict) and family.get('family') == 'Roboto'
        and isinstance(family.get('fonts'), list)
        and any(isinstance(font, dict) and font.get('asset') == FONT_ASSET
                for font in family['fonts'])
        for family in manifest
    ):
        raise ValueError('Required Roboto font missing from FontManifest.json')
    font = (directory / 'assets' / FONT_ASSET).read_bytes()
    if hashlib.sha256(font).hexdigest() != FONT_SHA256:
        raise ValueError('Required Roboto font is missing, damaged, or unexpectedly changed')


def stamp(directory: Path) -> str:
    directory = directory.resolve()
    if directory == (REPO / 'web').resolve():
        raise ValueError('Refusing to modify the source web/ directory')
    version_file, worker = directory / 'version.json', directory / 'fitness_worker.js'
    data = json.loads(version_file.read_text(encoding='utf-8'))
    version, build = data.get('version'), data.get('build_number')
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError('Invalid version in version.json')
    if not isinstance(build, str) or not BUILD.fullmatch(build):
        raise ValueError('Invalid build_number in version.json')
    source = worker.read_text(encoding='utf-8')
    matches = list(CACHE.finditer(source))
    if len(matches) != 1:
        raise ValueError('Expected exactly one Fitness Smart shell cache declaration')
    verify_required_font(directory)
    cache = f'fitness-smart-shell-{version}-{build}'
    updated = CACHE.sub(f"const CACHE_NAME = '{cache}';", source, count=1)
    if updated != source:
        tmp = worker.with_name(worker.name + '.stamp-tmp')
        try:
            tmp.write_text(updated, encoding='utf-8')
            tmp.replace(worker)
        finally:
            tmp.unlink(missing_ok=True)
    return cache


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 tools/stamp_web_cache.py BUILD_WEB_DIRECTORY')
    try:
        print(stamp(Path(sys.argv[1])))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f'Offline shell stamping failed: {exc}') from exc
