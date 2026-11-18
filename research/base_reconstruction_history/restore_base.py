#!/usr/bin/env python3
"""Restore the EARLY, not-release source tree from the included bundle+patch.

Offline only. Creates a previously nonexistent directory; never modifies an
existing app directory, diary, service, or cloud. It does NOT recreate lost
archive 003, the later food-search client, handler v2 or actor-budget SQL v2.
"""
from __future__ import annotations
import argparse
import gzip
import hashlib
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
BUNDLE = HERE / 'fitness_smart_synthetic_preview_restored_candidate.bundle'
PATCH = HERE / 'fitness_smart_local_clear_checkpoint_browser_WIP_NOT_RELEASE.patch.gz'
BUNDLE_SHA = 'da094330d3cead7c8ebc6559bf56be8a5f2a00d42caf6fa17b47e6039e984e73'
PATCH_SHA = 'd5432d0f4a56ce0e4ed6301f7ee28f732cd6827a92f34fd1ef0102b2b24f45d1'
HEAD = '3098ed03bc4e606f656f26dde31dd4ed66d8999d'
TREE = 'd14edfc73ffa2308968e9e72ce11bb5a274b00f7'


def sha(file: Path) -> str:
    return hashlib.sha256(file.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True, help='a NONEXISTENT new directory')
    args = parser.parse_args()
    dest = args.destination.expanduser().absolute()
    if dest.exists() or dest.is_symlink() or not dest.parent.is_dir():
        raise SystemExit('Destination must not exist; its parent must exist')
    if not BUNDLE.is_file() or not PATCH.is_file() or sha(BUNDLE) != BUNDLE_SHA or sha(PATCH) != PATCH_SHA:
        raise SystemExit('Bundle or patch hash mismatch; no restore attempted')
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')
    def git(*cmd: str, cwd: Path | None = None, data: bytes | None = None) -> str:
        r = subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *cmd], cwd=cwd, input=data,
                           env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return r.stdout.decode('utf8', errors='replace').strip()
    # '--' prevents destination/bundle values from being treated as options.
    git('clone', '--no-checkout', '--', str(BUNDLE), str(dest))
    git('checkout', '--detach', HEAD, cwd=dest)
    git('bundle', 'verify', str(BUNDLE), cwd=dest)
    data = gzip.decompress(PATCH.read_bytes())
    git('apply', '--index', '--check', '-', cwd=dest, data=data)
    git('apply', '--index', '-', cwd=dest, data=data)
    tree = git('write-tree', cwd=dest)
    if tree != TREE:
        raise RuntimeError('Unexpected tree: ' + tree)
    git('fsck', '--full', '--no-reflogs', cwd=dest)
    print('Early staged source tree restored to:', dest)
    print('Git tree:', tree, '(verified)')
    print('Not a complete reconstruction of lost 003; NOT a release or diary backup.')
    print('Changes from the patch are staged, not committed; do not deploy.')


if __name__ == '__main__':
    main()
