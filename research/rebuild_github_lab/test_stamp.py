#!/usr/bin/env python3
"""Pure-Python synthetic seal tests. Does not run Flutter or any browser."""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = ROOT / 'candidate'
sys.path.insert(0, str(CANDIDATE / 'tools'))
from stamp_synthetic_shell import REQUIRED, seal  # noqa: E402


def populate(directory: Path) -> None:
    for relative in REQUIRED:
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b'synthetic fixture')
    (directory / 'fitness_tab_guard.js').write_bytes((CANDIDATE / 'web/fitness_tab_guard.js').read_bytes())
    (directory / 'fitness_worker.js').write_bytes((CANDIDATE / 'web/fitness_worker.js').read_bytes())
    (directory / 'assets/fonts/fallback/Roboto-Regular.ttf').write_bytes(
        (CANDIDATE / 'fonts/fallback/Roboto-Regular.ttf').read_bytes()
    )
    (directory / 'assets/FontManifest.json').write_text(json.dumps([
        {'family': 'Roboto', 'fonts': [{'asset': 'fonts/fallback/Roboto-Regular.ttf'}]}
    ]), encoding='utf-8')


class SyntheticStampTests(unittest.TestCase):
    def test_seal_matches_every_asset_and_refuses_second_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix='fitness_synthetic_') as temp:
            directory = Path(temp); populate(directory)
            shell_id, manifest_hash, count = seal(directory)
            data = (directory / 'candidate-shell-manifest.json').read_bytes()
            manifest = json.loads(data)
            self.assertEqual(hashlib.sha256(data).hexdigest(), manifest_hash)
            self.assertEqual(manifest['id'], shell_id)
            self.assertEqual(len(manifest['files']), count)
            for name, expected in manifest['files'].items():
                self.assertEqual(hashlib.sha256((directory / name).read_bytes()).hexdigest(), expected, name)
            worker = (directory / 'fitness_worker.js').read_text()
            guard = (directory / 'fitness_tab_guard.js').read_text()
            self.assertIn(shell_id, worker); self.assertIn(shell_id, guard); self.assertIn(manifest_hash, worker)
            self.assertNotIn('__SYNTHETIC_SHELL_ID__', guard)
            with self.assertRaises(ValueError): seal(directory)

    def test_identical_inputs_have_identical_seal(self) -> None:
        with tempfile.TemporaryDirectory(prefix='fitness_a_') as a, tempfile.TemporaryDirectory(prefix='fitness_b_') as b:
            first, second = Path(a), Path(b); populate(first); populate(second)
            self.assertEqual(seal(first), seal(second))

    def test_missing_asset_does_not_write_manifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix='fitness_missing_') as temp:
            directory = Path(temp); populate(directory); (directory / 'main.dart.js').unlink()
            with self.assertRaises(ValueError): seal(directory)
            self.assertFalse((directory / 'candidate-shell-manifest.json').exists())

    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix='fitness_link_') as temp:
            directory = Path(temp); populate(directory)
            (directory / 'extra-link').symlink_to(directory / 'main.dart.js')
            with self.assertRaises(ValueError): seal(directory)
            self.assertFalse((directory / 'candidate-shell-manifest.json').exists())

    def test_cli_refuses_an_arbitrary_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix='fitness_refuse_') as temp:
            result = subprocess.run([sys.executable, str(CANDIDATE / 'tools/stamp_synthetic_shell.py'), temp],
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Refusing to alter anything except', result.stderr)
            self.assertFalse((Path(temp) / 'candidate-shell-manifest.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
