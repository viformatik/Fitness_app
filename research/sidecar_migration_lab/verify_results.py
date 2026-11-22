#!/usr/bin/env python3
"""Verify consistency of the SAVED synthetic reports, not browser execution.

Hashes are not signatures; matching this script does not prove that the test
ran, prove a migration safe, or validate real user data.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHELL_ID = '61df14df8d6cda5d432178f1'
MANIFEST_SHA = '76858f52d978096883b39e9e02f2319ff4358c01a1cf5d5506a92c608618f8aa'
MAIN_SHA = 'bb7bb7e16dec86349dc965b51cb646e6e661468dbe8e0733c79541f5e12fa1b0'
GUARD_SHA = '7514fd11ebfc0680a07e3af663c8038e2390c6a829c5def3a565c54b647f8dd2'
EXPECTED_RISKS = {
    'raw staging includes a fake private marker and is not a privacy-filtered export',
    'two committed writes returning to the same value are invisible to a snapshot comparison',
    'after a matching snapshot, a nonparticipating old writer commits while the Web Lock is held',
    'the candidate sidecar also contains the fake private marker',
    'sidecar staging does not repair the existing candidate v2 rollback incompatibility',
}
REQUIRED_CHECKS = {
    'real diary name is refused before any database open',
    'missing source is refused without creating source or destination',
    'a staged sidecar is copied while the old v1 connection remains open',
    'an injected abort follows request success and reports no commit',
    'aborted transaction leaves both sidecar records and metadata empty; source is unchanged',
    'overlapping synthetic writer is deferred until the paired readonly snapshot completes',
    'two concurrent stagers cannot overwrite one another',
    'source and sidecar matched before the late old-writer experiment',
    'real synthetic-candidate Hive data stages without any source write transaction',
    'staged candidate values preserve the exact synthetic water and food payload',
    'a later synthetic application write makes the staged snapshot mismatch',
    'every loaded candidate main script matches the sealed synthetic build',
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_report(report: dict, engine: str, source_sha: str, lab_sha: str) -> list[str]:
    errors: list[str] = []

    def require(condition: bool, label: str) -> None:
        if not condition:
            errors.append(label)

    require(isinstance(report, dict), 'report must be an object')
    if not isinstance(report, dict):
        return errors
    require(report.get('status') == 'PASS_WITH_REPRODUCED_RISKS_NOT_A_RELEASE', 'status')
    require(report.get('engine') == engine, 'engine')
    require(isinstance(report.get('browserVersion'), str) and bool(report['browserVersion']), 'browser version')
    require(report.get('sourceSha256') == source_sha, 'probe SHA')
    require(report.get('snapshotLabSha256') == lab_sha, 'snapshot module SHA')
    require(report.get('candidateId') == SHELL_ID, 'synthetic shell ID')
    require(report.get('candidateManifestSha256') == MANIFEST_SHA, 'synthetic manifest SHA')
    require(report.get('candidateMainSha256') == MAIN_SHA, 'synthetic main SHA')
    require(report.get('candidateGuardSha256') == GUARD_SHA, 'synthetic guard SHA')
    iso = report.get('networkIsolation')
    require(isinstance(iso, dict), 'isolation record')
    if isinstance(iso, dict):
        require(type(iso.get('uid')) is int and iso['uid'] > 0, 'non-root UID')
        require(iso.get('interfaces') == ['lo'], 'loopback-only interfaces')
        require(iso.get('routes4') == 0 and iso.get('routes6') == 0, 'no external main routes')
        require(iso.get('allRoutesLoopbackOnly') is True, 'all routes loopback only')
    checks = report.get('checks')
    require(isinstance(checks, list) and len(checks) == 27, '27 checks')
    if isinstance(checks, list):
        require(all(isinstance(x, dict) and x.get('status') == 'PASS' for x in checks), 'all checks pass')
        names = [x.get('name') for x in checks if isinstance(x, dict)]
        valid_names = [name for name in names if isinstance(name, str)]
        require(len(valid_names) == len(checks), 'valid check names')
        require(len(set(valid_names)) == len(valid_names), 'unique check names')
        require(REQUIRED_CHECKS.issubset(set(valid_names)), 'required checks present')
    risks = report.get('risks')
    require(isinstance(risks, list) and len(risks) == 5, '5 risks')
    if isinstance(risks, list):
        require(all(isinstance(x, dict) and x.get('status') == 'RISK_REPRODUCED' for x in risks), 'all risks reproduced')
        names = [x.get('name') for x in risks if isinstance(x, dict)]
        valid_names = [name for name in names if isinstance(name, str)]
        require(len(valid_names) == len(risks), 'valid risk names')
        require(len(set(valid_names)) == len(valid_names) and set(valid_names) == EXPECTED_RISKS, 'expected risk names')
    loaded = report.get('loaded')
    require(isinstance(loaded, list) and bool(loaded), 'candidate main loaded')
    if isinstance(loaded, list) and loaded:
        require(all(isinstance(x, dict) and x.get('sha256') == MAIN_SHA for x in loaded), 'loaded main SHA')
    limitations = report.get('limitations')
    require(isinstance(limitations, list) and len(limitations) >= 7, 'limitations recorded')
    return errors


def main() -> int:
    source_sha = sha256(HERE / 'sidecar_probe.cjs')
    lab_sha = sha256(HERE / 'snapshot_lab.js')
    reports = {}
    for engine in ('chromium', 'firefox'):
        path = HERE / 'attempts' / f'{engine}_interleaving.json'
        try:
            report = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, json.JSONDecodeError) as exc:
            print(f'FAIL {engine}: unreadable report: {type(exc).__name__}')
            return 1
        errors = verify_report(report, engine, source_sha, lab_sha)
        if errors:
            print(f'FAIL {engine}: {", ".join(errors)}')
            return 1
        reports[engine] = report
        print(f'PASS {engine} {report["browserVersion"]}: 27 checks, 5 reproduced risks; source and build IDs match')
    if {x['name'] for x in reports['chromium']['checks']} != {x['name'] for x in reports['firefox']['checks']}:
        print('FAIL: browsers have different check sets')
        return 1
    print('Report consistency only; this is not a release, a signature, or proof of a safe migration.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
