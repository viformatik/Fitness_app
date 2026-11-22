#!/usr/bin/env python3
"""Seal ONLY candidate/build/web for a disposable loopback experiment.

Not a signature, backup, production migration, or release-packaging tool.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

from stamp_web_cache import verify_required_font

CANDIDATE = Path(__file__).resolve().parents[1]
ID_TOKEN = b'__SYNTHETIC_SHELL_ID__'
MANIFEST_TOKEN = b'__SYNTHETIC_MANIFEST_SHA256__'
MANIFEST = 'candidate-shell-manifest.json'
WORKER = 'fitness_worker.js'
GUARD = 'fitness_tab_guard.js'
REQUIRED = {
    'index.html', GUARD, 'flutter_bootstrap.js', 'main.dart.js', 'version.json',
    'manifest.json', 'icons/Icon-192.png', 'assets/FontManifest.json',
    'assets/fonts/fallback/Roboto-Regular.ttf', 'canvaskit/canvaskit.js',
    'canvaskit/canvaskit.wasm', WORKER,
}
SAFE_PATH = re.compile(r'[A-Za-z0-9._/-]+\Z')


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def seal(directory: Path) -> tuple[str, str, int]:
    if not directory.is_dir() or (directory / MANIFEST).exists():
        raise ValueError('Expected a fresh build without an existing manifest')
    verify_required_font(directory)
    files: dict[str, bytes] = {}
    for file in sorted(directory.rglob('*')):
        if file.is_symlink():
            raise ValueError('Symlinks are not permitted')
        if not file.is_file() or file.name == '.last_build_id':
            continue
        rel = file.relative_to(directory).as_posix()
        if not SAFE_PATH.fullmatch(rel) or any(p in {'', '.', '..'} for p in rel.split('/')):
            raise ValueError(f'Unsafe asset path: {rel!r}')
        files[rel] = file.read_bytes()
    missing = REQUIRED - files.keys()
    if missing:
        raise ValueError(f'Incomplete build: {sorted(missing)}')
    guard, worker = files[GUARD], files[WORKER]
    if guard.count(ID_TOKEN) != 1 or worker.count(ID_TOKEN) != 1 or worker.count(MANIFEST_TOKEN) != 1:
        raise ValueError('Expected fresh unstamped guard and worker')
    seed = b''.join(name.encode() + b'\0' + digest(data).encode() + b'\n'
                    for name, data in sorted(files.items()))
    shell_id = digest(seed)[:24]
    guard = guard.replace(ID_TOKEN, shell_id.encode())
    files[GUARD] = guard
    manifest = {'schema': 1, 'id': shell_id,
                'files': {name: digest(data) for name, data in sorted(files.items()) if name != WORKER}}
    encoded = (json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n').encode()
    manifest_hash = digest(encoded)
    worker = worker.replace(ID_TOKEN, shell_id.encode()).replace(MANIFEST_TOKEN, manifest_hash.encode())
    # Manifest written last: interruption is an invalid build, not a shell to use.
    (directory / GUARD).write_bytes(guard)
    (directory / WORKER).write_bytes(worker)
    (directory / MANIFEST).write_bytes(encoded)
    return shell_id, manifest_hash, len(manifest['files'])


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 tools/stamp_synthetic_shell.py build/web')
    target = Path(sys.argv[1]).resolve()
    if target != (CANDIDATE / 'build' / 'web').resolve():
        raise SystemExit('Refusing to alter anything except candidate/build/web')
    try:
        shell_id, manifest_hash, count = seal(target)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f'Synthetic shell sealing failed: {exc}') from exc
    print(f'synthetic shell {shell_id}: {count} files, manifest sha256 {manifest_hash}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
