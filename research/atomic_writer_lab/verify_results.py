#!/usr/bin/env python3
"""Offline consistency checks for the checked-in synthetic lab reports.

Does not start a browser, test a real diary, establish authorship or prove safety.
"""
from __future__ import annotations

import collections
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(condition: bool, label: str) -> None:
    if not condition:
        raise SystemExit('FAIL: ' + label)
    print('PASS:', label)


def main() -> None:
    manifest = HERE / 'v14_fixture_manifest.json'
    check(sha(manifest) == '211dd5c74938f4b1e0b105aef08f050112e7832a210e79d8b25b79eead34c0c2',
          'pinned fixture manifest checksum')
    pins = json.loads(manifest.read_text())['files']
    check(len(pins) == 27, 'manifest contains 27 individual pinned fixture files')
    model_source = sha(HERE / 'synthetic_idb_probe.cjs')
    archived_source = sha(HERE / 'archived_v14_mixed_probe.cjs')
    for engine in ('chromium', 'firefox'):
        model = json.loads((HERE / 'results' / f'{engine}_initial.json').read_text())
        check(model['engine'] == engine and model['sourceSha256'] == model_source and
              model['status'] == 'PASS_WITH_REPRODUCED_RISKS_NOT_A_RELEASE', engine + ' model source/status')
        counts = collections.Counter(t['status'] for t in model['tests'])
        check(counts == {'PASS': 5, 'RISK_REPRODUCED': 4}, engine + ' model statuses')
        by_name = {t['name']: t['details'] for t in model['tests']}
        observed = by_name['two synthetic atomic writers preserve both increments in ten sampled rounds']['observed']
        mixed = by_name['stale synthetic legacy-style write can erase an atomic writer action']
        check(observed == [750] * 10 and mixed['afterLegacy'] == 500 and
              mixed['expectedForThreeActions'] == 750, engine + ' model numerical observations')
        isolation = model['networkIsolation']
        check(isolation['uid'] != 0 and isolation['interfaces'] == ['lo'] and
              isolation['routes4'] == isolation['routes6'] == 0 and isolation['allRoutesLoopbackOnly'],
              engine + ' model recorded isolation')

        archived = json.loads((HERE / 'results' / f'{engine}_archived_mixed_v1.json').read_text())
        check(archived['engine'] == engine and archived['sourceSha256'] == archived_source and
              archived['status'] == 'PASS_WITH_REPRODUCED_RISK_NOT_A_RELEASE', engine + ' archived source/status')
        check(len(archived['checks']) == 7 and all(x['status'] == 'PASS' for x in archived['checks']) and
              len(archived['risks']) == 1 and archived['risks'][0]['status'] == 'RISK_REPRODUCED',
              engine + ' archived report statuses')
        risk = archived['risks'][0]['values']
        check(risk['seed'] == 250 and risk['syntheticAtomicAdd'] == 250 and risk['oldUiAdd'] == 250 and
              risk['expected'] == 750 and risk['actual'] == 500 and risk['oldWriteCommitted'],
              engine + ' archived risk numbers and commit')
        loaded = {x['page']: x for x in archived['loaded']}
        check(archived['pinnedFixtureFiles'] == 27 and archived['mainSha256'] == pins['main.dart.js'] and
              archived['workerSha256'] == pins['fitness_worker.js'] and
              all(loaded[p]['sha256'] == pins['main.dart.js'] for p in
                  ('old-tab', 'atomic-observer-tab', 'reopened-old-tab')) and
              loaded['atomic-observer-tab']['fromServiceWorker'] and loaded['reopened-old-tab']['fromServiceWorker'],
              engine + ' archived main/worker evidence')
        isolation = archived['networkIsolation']
        check(isolation['uid'] != 0 and isolation['interfaces'] == ['lo'] and
              isolation['routes4'] == isolation['routes6'] == 0 and isolation['allRoutesLoopbackOnly'],
              engine + ' archived run recorded isolation')
    initial = json.loads((HERE / 'attempts' / 'chromium_archived_mixed_initial.json').read_text())
    check(initial['status'] == 'FAIL_OR_INCOMPLETE_NOT_A_RELEASE' and
          initial['sourceSha256'] == sha(HERE / 'attempts' / 'archived_v14_mixed_probe_initial.cjs') and
          any(x['name'] == 'old page starts with zero synthetic water' and x['status'] == 'FAIL'
              for x in initial['checks']), 'first failing assumption and its source retained')
    print('Integrity only: no browser, archive, diary, IndexedDB, cloud, network or deployment accessed.')


if __name__ == '__main__':
    main()
