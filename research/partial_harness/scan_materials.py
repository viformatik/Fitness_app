#!/usr/bin/env python3
"""Heuristic credential scan of this research package and reachable Git blobs.

Values are NEVER printed. This is not a personal-data detector, authenticity
check, binary decompiler, OCR, or guarantee that a secret is absent. Run only
against a disposable reconstruction with all bundle refs fetched locally.
"""
from __future__ import annotations
import argparse
import gzip
import re
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
RULES = {
    'google_api_key': re.compile(rb'AIza[0-9A-Za-z_-]{30,}'),
    'provider_secret': re.compile(rb'\b(?:sk-(?:proj-)?|gsk_)[A-Za-z0-9_-]{24,}'),
    'nvidia_secret': re.compile(rb'\bnvapi-[A-Za-z0-9_-]{24,}'),
    'freellmapi_secret': re.compile(rb'\bfreellmapi-[A-Za-z0-9_-]{24,}'),
    'zai_secret': re.compile(rb'\b[0-9a-f]{32}\.[0-9A-Za-z_-]{16,}\b'),
    'supabase_secret': re.compile(rb'\bsb_secret_[A-Za-z0-9_-]{20,}'),
    'private_key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'jwt': re.compile(rb'\beyJ[A-Za-z0-9_-]{16,}\.eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}'),
    'credential_assignment': re.compile(rb'(?i)(?:api[_-]?key|secret[_-]?key|password|upload[_-]?token)\s*[=:]\s*[\"\x27][A-Za-z0-9_+/=-]{24,}[\"\x27]'),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git-repo', type=Path, required=True)
    args = parser.parse_args()
    hits: list[tuple[str, str]] = []
    counts = {'package_plain_or_raw': 0, 'fixture_members_raw': 0, 'patch_decompressed': 0,
              'history_raw': 0, 'history_gzip_unpacked': 0, 'history_binary': 0}
    def examine(label: str, data: bytes, counter: str) -> None:
        counts[counter] += 1
        for name, pattern in RULES.items():
            if pattern.search(data):
                hits.append((label, name))
    for file in sorted(ROOT.rglob('*')):
        if not file.is_file() or file.is_symlink():
            continue
        rel = file.relative_to(ROOT).as_posix()
        if rel in ('verification/scan_materials.log', 'SHA256SUMS') or rel.endswith('.bundle'):
            continue  # Bundle is examined by git cat-file below, not as compressed bytes.
        if rel == 'fixtures/archived_v14_web.tar.gz':
            with tarfile.open(file, 'r:gz') as tf:
                for m in tf.getmembers():
                    if m.isfile():
                        if m.size > 50_000_000:
                            raise RuntimeError('Unexpected fixture size')
                        stream = tf.extractfile(m)
                        if stream is None:
                            raise RuntimeError('Unexpected missing fixture member')
                        examine(rel + ':' + m.name, stream.read(), 'fixture_members_raw')
            continue
        if rel.endswith('.patch.gz'):
            content = gzip.decompress(file.read_bytes())
            if len(content) > 100_000_000:
                raise RuntimeError('Unexpected patch size')
            examine(rel + ':decompressed', content, 'patch_decompressed')
            continue
        if file.stat().st_size > 50_000_000:
            raise RuntimeError('Unexpected package size: ' + rel)
        examine(rel, file.read_bytes(), 'package_plain_or_raw')
    repo = args.git_repo.resolve(strict=True)
    objects = subprocess.check_output(['git','-C',str(repo),'rev-list','--objects','--all']).decode('utf8','surrogateescape').splitlines()
    proc = subprocess.Popen(['git','-C',str(repo),'cat-file','--batch'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
    assert proc.stdin and proc.stdout
    try:
        for row in objects:
            oid, _, name = row.partition(' ')
            proc.stdin.write((oid + '\n').encode('ascii'));proc.stdin.flush()
            header=proc.stdout.readline().split()
            if len(header) != 3 or header[0].decode() != oid:
                raise RuntimeError('Invalid git batch response')
            size = int(header[2])
            if size > 50_000_000:
                raise RuntimeError('Unexpected Git object size')
            content = proc.stdout.read(size)
            if len(content) != size or proc.stdout.read(1) != b'\n':
                raise RuntimeError('Truncated Git object')
            if header[1] != b'blob':
                continue
            label = 'git:' + (name or '<unnamed>') + '@' + oid[:12]
            examine(label,content,'history_raw')
            if b'\0' in content:
                counts['history_binary'] += 1
            if content.startswith(b'\x1f\x8b'):
                decoded=gzip.decompress(content)
                if len(decoded)>50_000_000:
                    raise RuntimeError('Unexpected decompressed history size')
                examine(label + ':gzip',decoded,'history_gzip_unpacked')
    finally:
        proc.stdin.close()
        if proc.wait(timeout=30):
            raise RuntimeError('Git batch failed')
    print('Counts:', counts)
    print('Rules:', ', '.join(RULES))
    if hits:
        print('Potential matches (values suppressed):')
        for label,rule in hits:
            print(label, rule)
        raise SystemExit(1)
    print('No heuristic matches. Binary and compressed encodings, images, screenshots, archives beyond the enumerated layers, personal data and unknown token formats are NOT ruled out.')


if __name__ == '__main__':
    main()
