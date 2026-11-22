#!/usr/bin/env python3
"""Negative tests for report consistency checks; no browser or diary is opened."""
import copy
import json
import unittest
from pathlib import Path

import verify_results as verifier

HERE = Path(__file__).resolve().parent


class SavedReportVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source_sha = verifier.sha256(HERE / 'sidecar_probe.cjs')
        cls.lab_sha = verifier.sha256(HERE / 'snapshot_lab.js')
        cls.reports = {
            engine: json.loads((HERE / 'attempts' / f'{engine}_interleaving.json').read_text())
            for engine in ('chromium', 'firefox')
        }

    def errors(self, report, engine='chromium'):
        return verifier.verify_report(report, engine, self.source_sha, self.lab_sha)

    def test_recorded_reports_match_current_sources(self):
        for engine, report in self.reports.items():
            with self.subTest(engine=engine):
                self.assertEqual(self.errors(report, engine), [])

    def test_non_object_is_rejected(self):
        self.assertIn('report must be an object', self.errors([]))

    def test_wrong_probe_or_module_hash_is_rejected(self):
        for field in ('sourceSha256', 'snapshotLabSha256'):
            with self.subTest(field=field):
                report = copy.deepcopy(self.reports['chromium'])
                report[field] = 'wrong'
                self.assertTrue(self.errors(report))

    def test_wrong_build_and_loaded_script_are_rejected(self):
        report = copy.deepcopy(self.reports['chromium'])
        report['candidateId'] = 'wrong'
        report['loaded'][0]['sha256'] = 'wrong'
        self.assertIn('synthetic shell ID', self.errors(report))
        self.assertIn('loaded main SHA', self.errors(report))

    def test_missing_or_failed_check_is_rejected(self):
        report = copy.deepcopy(self.reports['chromium'])
        report['checks'][0]['status'] = 'FAIL'
        report['checks'].pop()
        self.assertIn('27 checks', self.errors(report))
        self.assertIn('all checks pass', self.errors(report))

    def test_duplicate_or_malformed_check_name_is_rejected(self):
        report = copy.deepcopy(self.reports['chromium'])
        report['checks'][1]['name'] = report['checks'][0]['name']
        self.assertIn('unique check names', self.errors(report))
        report['checks'][1]['name'] = {'not': 'a name'}
        self.assertIn('valid check names', self.errors(report))

    def test_missing_or_mislabelled_risk_is_rejected(self):
        report = copy.deepcopy(self.reports['chromium'])
        report['risks'][0]['status'] = 'PASS'
        report['risks'].pop()
        self.assertIn('5 risks', self.errors(report))
        self.assertIn('all risks reproduced', self.errors(report))

    def test_network_and_privilege_fail_closed(self):
        report = copy.deepcopy(self.reports['chromium'])
        report['networkIsolation']['interfaces'].append('eth0')
        report['networkIsolation']['uid'] = 0
        self.assertIn('loopback-only interfaces', self.errors(report))
        self.assertIn('non-root UID', self.errors(report))

    def test_wrong_engine_or_overstated_release_status_is_rejected(self):
        report = copy.deepcopy(self.reports['chromium'])
        report['status'] = 'PRODUCTION_READY'
        self.assertIn('status', self.errors(report))
        self.assertIn('engine', self.errors(report, 'firefox'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
