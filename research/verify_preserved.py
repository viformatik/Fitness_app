#!/usr/bin/env python3
"""Validate preserved synthetic report structure and pinned worker, offline only.

This is an integrity/consistency check, not a browser test, source authentication,
proof of privacy, or release gate. It does not access a diary, IndexedDB, or network.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKER_SHA = 'c82632c6495999fcca11ee3eaad2b56a44c48432fa1ec65384aefd2896750a49'
OLD_JS_SHA = 'fbe81cc44f9d747592ebe7c2a687fe137c46a853d5f680c04bc442a3db489c11'


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit('FAIL: ' + message)
    print('PASS:', message)


def main() -> None:
    worker = HERE / 'fixtures' / 'archived_v14_fitness_worker.js'
    require(hashlib.sha256(worker.read_bytes()).hexdigest() == WORKER_SHA,
            'archived worker has the pinned SHA-256')
    source_hashes = set()
    for engine in ('chromium', 'firefox'):
        path = HERE / 'available_results' / f'race_{engine}_initial.json'
        report = json.loads(path.read_text(encoding='utf8'))
        require(report['engine'] == engine and
                report['status'] == 'PARTIAL_SYNTHETIC_KNOWN_RISKS_NOT_A_RELEASE',
                engine + ' report identifies the expected non-release experiment')
        require(len(report['checks']) == 14 and
                all(x['status'] == 'PASS' for x in report['checks']) and
                len(report['risks']) == 2 and
                all(x['status'] == 'RISK_REPRODUCED' for x in report['risks']) and
                report['failures'] == [], engine + ' report contains 14 PASS, 2 risks, 0 failures')
        network = report['observations']['networkIsolation']
        require(network['uid'] != 0 and network['interfaces'] == ['lo'] and
                network['routes4'] == network['routes6'] == 0,
                engine + ' recorded a non-root loopback-only namespace')
        seq = report['observations']['sequence']
        values = lambda name: [row[1] for row in seq[name]['water']]
        require(values('seed') == [250] and values('afterTabA') == [500] and
                values('afterTabB') == [500] and
                seq['expectedForThreeSeparateActions'] == 750 and seq['actual'] == 500,
                engine + ' records the synthetic 750-versus-500 lost action')
        loaded = {row['page']: row for row in report['loaded']}
        require(report['pinnedFixtureSha256']['fitness_worker.js'] == WORKER_SHA and
                report['pinnedFixtureSha256']['main.dart.js'] == OLD_JS_SHA and
                all(loaded[name]['sha256'] == OLD_JS_SHA and loaded[name]['serviceWorker']
                    for name in ('old-tab-A', 'old-tab-B', 'offline-reopen')),
                engine + ' records the pinned old code and worker-controlled pages')
        source_hashes.add(report['sourceSha256'])
    require(len(source_hashes) == 1, 'both reports record the same harness hash')
    print('NOT A REPRODUCTION: the old browser harness and full archived build are not included.')
    print('No browser, diary, database, network, deployment, or migration was used.')


if __name__ == '__main__':
    main()
