#!/usr/bin/env python3
"""Unpack ONLY the pinned public +14 test shell into a new directory.

This is a static program fixture, NOT a diary or a release. No network access.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import tarfile

ARCHIVE_SHA = '457e5da0b9d7da6d55e29c712428b52a84d8b626a4c7af39a3501cdcb4d5ae02'
PINS = {
    'index.html': '372da5582453a954bd327d53074aa0c2695e7c5dc655fd9521ab6631ea22cd05',
    'main.dart.js': 'fbe81cc44f9d747592ebe7c2a687fe137c46a853d5f680c04bc442a3db489c11',
    'fitness_worker.js': 'c82632c6495999fcca11ee3eaad2b56a44c48432fa1ec65384aefd2896750a49',
    'flutter_bootstrap.js': '9ef3946a6c312dc35f5f7814b136fb9b1cd0e1c5ec5701752a46baec2f03b2f6',
    'version.json': '52ecc8aa6294dfcdf190c4fd7082f326a4deba8d5cd158413e52bad3f57aba0d',
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, default=here.parent / 'fixtures/archived_v14_web.tar.gz')
    parser.add_argument('--output', type=Path, required=True, help='a nonexistent directory')
    args = parser.parse_args()
    archive = args.archive.expanduser().resolve(strict=True)
    if not archive.is_file() or digest(archive) != ARCHIVE_SHA:
        raise SystemExit('Fixture archive SHA mismatch; no files extracted')
    target = args.output.expanduser().absolute()
    if target.exists() or target.is_symlink() or not target.parent.is_dir():
        raise SystemExit('Output must be a nonexistent directory with an existing parent')
    with tarfile.open(archive, 'r:gz') as tf:
        members = tf.getmembers()
        if len(members) > 250 or sum(m.size for m in members) > 80_000_000:
            raise SystemExit('Unexpected fixture size')
        seen: set[str] = set()
        for member in members:
            p = PurePosixPath(member.name)
            if p.is_absolute() or '..' in p.parts or not (member.isdir() or member.isfile()):
                raise SystemExit('Unsafe tar member')
            if str(p) == '.':
                continue
            if str(p) in seen:
                raise SystemExit('Duplicate tar member')
            seen.add(str(p))
        target.mkdir(mode=0o700)
        for member in members:
            relative = PurePosixPath(member.name)
            if str(relative) == '.':
                continue
            destination = target.joinpath(*relative.parts)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = tf.extractfile(member)
                if source is None:
                    raise RuntimeError('Missing tar content')
                with source, destination.open('xb') as out:
                    shutil.copyfileobj(source, out)
    for name, expected in PINS.items():
        if digest(target / name) != expected:
            raise SystemExit('Extracted fixture mismatch: ' + name)
    print('Pinned public +14 fixture unpacked:', target)
    print('Static synthetic fixture only: no diary, no publication, no app upgrade.')


if __name__ == '__main__':
    main()
