#!/usr/bin/env python3
"""Offline catalog integrity tests; no network, account or diary is accessed."""
from __future__ import annotations
import collections
import importlib.util
import json
import pathlib
import tempfile
import unittest
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


local = load('build_local_catalog')
dairy = load('build_regional_foods')


class CatalogIntegrity(unittest.TestCase):
    def test_generated_datasets_are_deterministic(self):
        for module in (local, dairy):
            expected_dart = module.OUT_DART.read_bytes()
            expected_json = module.OUT_JSON.read_bytes()
            with tempfile.TemporaryDirectory(prefix='catalog_test_', dir=ROOT / 'checks') as name:
                old_dart, old_json = module.OUT_DART, module.OUT_JSON
                try:
                    module.OUT_DART = pathlib.Path(name) / 'generated.dart'
                    module.OUT_JSON = pathlib.Path(name) / 'generated.json'
                    module.main()
                    self.assertEqual(module.OUT_DART.read_bytes(), expected_dart)
                    self.assertEqual(module.OUT_JSON.read_bytes(), expected_json)
                finally:
                    module.OUT_DART, module.OUT_JSON = old_dart, old_json

    def test_every_thk_value_is_an_exact_transcription_of_the_input_table(self):
        source = json.loads(local.TIRHLEB.read_text(encoding='utf8'))
        records = local.records()
        published = [row for row in records if row['quality'] == 'published']
        self.assertEqual((len(source), len(published)), (94, 94))
        for old, row in zip(source, published):
            for field in ('name', 'calories', 'protein', 'fat', 'carbs', 'sourceUrl'):
                self.assertEqual(row[field], old[field], (old['name'], field))
            self.assertIn(urlparse(row['sourceUrl']).hostname, ('tirhleb.com', 'www.tirhleb.com'))
            self.assertEqual(row['micros'], {})
            self.assertIn('Сверьте упаковку', row['note'])
        app = next(row for row in published if row['name'] == 'Хлеб "Аппетитный"')
        self.assertEqual(app['calories'], 187)
        self.assertIn('отличается от грубой оценки', app['note'])

    def test_historic_pmr_not_a_cartesian_product(self):
        records = local.records()
        historic = [row for row in records if row['quality'] == 'historical_estimate']
        self.assertEqual(len(historic), 5)
        self.assertEqual({(r['brand'], r['fat']) for r in historic}, {
            ('ОАО «Тираспольский молочный комбинат» (ТМК)', 2.5),
            ('ОАО «Тираспольский молочный комбинат» (ТМК)', 3.2),
            ('ООО «Динисалл»', 2.5), ('ООО «Динисалл»', 3.2),
            ('ООО «Племжив агроэлит»', 2.5),
        })
        for row in historic:
            self.assertIn('историческая позиция', row['name'])
            self.assertIn('2022 года', row['note'])
            self.assertIn('не данные упаковки', row['note'])
            self.assertIn('актуальный ассортимент', row['note'])
            self.assertIn('liktv.org/', row['sourceUrl'])
            self.assertIsNone(row['barcode'])
            self.assertEqual(row['micros'], {})
        self.assertNotIn('Арбуз [Агро-Фрукт]', {r['name'] for r in records})
        self.assertNotIn('Сосиски [Акватир]', {r['name'] for r in records})

    def test_dairy_estimates_sources_and_barcodes(self):
        rows = dairy.records()
        counts = collections.Counter(row['quality'] for row in rows)
        self.assertEqual(counts, {'legacy_estimate': 20, 'off': 3, 'off_disputed': 1,
                                  'manufacturer': 2, 'third_party': 3})
        generic = [r for r in rows if r['quality'] == 'legacy_estimate']
        for row in generic:
            self.assertIn('(типовое)', row['name'])
            self.assertIn('Ориентировочно', row['note'])
            self.assertIn('Источник точных значений не подтверждён', row['note'])
            self.assertIsNone(row['brand']); self.assertIsNone(row['barcode']); self.assertIsNone(row['sourceUrl'])
        codes = [r['barcode'] for r in rows if r['barcode'] is not None]
        self.assertEqual(len(codes), len(set(codes)))
        self.assertEqual(set(codes), {'4820003481547','4820003481554','4690228109713','4820003488461'})
        for code in codes:
            self.assertEqual(len(code), 13)
            digit = (10 - sum(int(d) * (3 if i % 2 == 0 else 1)
                              for i, d in enumerate(code[-2::-1])) % 10) % 10
            self.assertEqual(digit, int(code[-1]))
        disputed = next(r for r in rows if r['barcode'] == '4820003488461')
        self.assertIn('противоречат', disputed['note'])
        self.assertIn('37 ккал', disputed['note'])
        for row in rows:
            self.assertEqual(row['micros'], {})
            self.assertTrue(local.CYRILLIC.search(row['name']))
            self.assertFalse(local.LATIN.search(row['name']))
            self.assertIn('сверьте', row['note'].lower())
            if row['quality'].startswith('off'):
                self.assertIn('Open Food Facts', row['note'])
                self.assertIn('ODbL/DBCL', row['note'])
                self.assertIn(row['barcode'], row['sourceUrl'])

    def test_declared_outputs_stay_in_catalog_directories(self):
        # Structural check of declared output paths, not an I/O sandbox.
        for module in (local, dairy):
            self.assertEqual(module.OUT_DART.parent, ROOT / 'lib' / 'smart')
            self.assertEqual(module.OUT_JSON.parent, ROOT / 'tools' / 'data')
            self.assertTrue(module.records())


if __name__ == '__main__':
    unittest.main(verbosity=2)
