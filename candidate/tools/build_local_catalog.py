#!/usr/bin/env python3
"""Build the offline PMR catalog from reviewed, separately identified rows.

An enterprise directory does NOT establish that a given branded SKU exists.
Do not generate a cartesian product of producer names and food templates.
Published ТХК macros are retained as published; historical milk entries use
explicitly labelled legacy category estimates, not package measurements.
Unreported micronutrients stay missing. No user data is read or rewritten.
"""
from __future__ import annotations
import json
import math
import pathlib
import re
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT_DART = ROOT / 'lib/smart/local_catalog.dart'
OUT_JSON = ROOT / 'tools/data/pmr_catalog.json'
TIRHLEB = ROOT / 'tools/data/tirhleb_products.json'
HISTORICAL_LIST = 'https://liktv.org/v-pridnestrove-ustanovlena-predelnaja-roznichnaja-cena-na-molochnuju-produkciju/'
TMK_SITE = 'https://tmk-moloko.ru/about.php'
BLAGODA_SITE = 'https://blagoda.md/contacts'

# Only the existence of these producer/fat combinations is supported by the
# linked historical 2022 list; the nutritional values were not on that list.
# They are deliberately approximate generic values inherited from the previous
# local catalog, not claims about an individual package or current inventory.
HISTORICAL_MILKS = (
    ('ТМК', 'ОАО «Тираспольский молочный комбинат» (ТМК)', '2,5%', 52, 2.8, 2.5, 4.7,
     'тмк тираспольский молочный комбинат молоко fat25', TMK_SITE),
    ('ТМК', 'ОАО «Тираспольский молочный комбинат» (ТМК)', '3,2%', 58, 2.8, 3.2, 4.7,
     'тмк тираспольский молочный комбинат молоко fat32', TMK_SITE),
    ('Динисалл', 'ООО «Динисалл»', '2,5%', 52, 2.8, 2.5, 4.7,
     'динисалл парканы благода blagoda молоко fat25', BLAGODA_SITE),
    ('Динисалл', 'ООО «Динисалл»', '3,2%', 58, 2.8, 3.2, 4.7,
     'динисалл парканы благода blagoda молоко fat32', BLAGODA_SITE),
    ('Племжив Агроэлит', 'ООО «Племжив агроэлит»', '2,5%', 52, 2.8, 2.5, 4.7,
     'племжив агроэлит молоко fat25', None),
)
CYRILLIC = re.compile(r'[А-Яа-яЁёІіЇїЄєҐґ]')
LATIN = re.compile(r'[A-Za-z]')


def category_for_tirhleb(name: str) -> str:
    n = name.lower()
    if any(k in n for k in ('вода', 'напиток', 'квас', 'лимонад', 'компот', 'сок')):
        return 'Напитки'
    if any(k in n for k in ('торт', 'пирожное', 'печенье', 'пряник', 'маффин', 'кекс', 'рулет', 'кулич', 'тарталет')):
        return 'Кондитерские изделия'
    return 'Хлеб и выпечка'


def q(value: object) -> str:
    return json.dumps(value, ensure_ascii=False)


def dart_double(value: object) -> str:
    return repr(float(value))


def record(name: str, cal: float, protein: float, fat: float, carbs: float,
           category: str, brand: str, url: str, note: str, keywords: str,
           quality: str) -> dict:
    values = (cal, protein, fat, carbs)
    if not CYRILLIC.search(name) or LATIN.search(name):
        raise ValueError('Display names must contain Cyrillic and no Latin letters')
    if not all(isinstance(x, (int, float)) and math.isfinite(x) and x >= 0 for x in values):
        raise ValueError(f'Invalid nutrition values: {name}')
    if not all(urlparse(u.strip()).scheme == 'https' for u in url.split(' | ')):
        raise ValueError(f'Invalid provenance URL: {name}')
    return {'name': name, 'calories': float(cal), 'protein': float(protein), 'fat': float(fat),
            'carbs': float(carbs), 'micros': {}, 'category': category, 'source': 'Продукция ПМР',
            'brand': brand, 'barcode': None, 'note': note, 'sourceUrl': url,
            'keywords': keywords, 'quality': quality}


def records() -> list[dict]:
    rows = json.loads(TIRHLEB.read_text(encoding='utf8'))
    if not isinstance(rows, list) or not rows:
        raise ValueError('ТХК review table is empty or invalid')
    result = []
    for row in rows:
        name = row['name'].strip()
        url = row['sourceUrl']
        if urlparse(url).hostname not in ('www.tirhleb.com', 'tirhleb.com'):
            raise ValueError(f'Unexpected ТХК source: {name}')
        cal, protein, fat, carbs = (row[k] for k in ('calories', 'protein', 'fat', 'carbs'))
        derived = 4 * (protein + carbs) + 9 * fat
        note = ('По официальному каталогу ТХК: опубликованные КБЖУ на 100 г. '
                'Микронутриенты не указаны. Сверьте упаковку.')
        if abs(cal - derived) > max(10, derived * .07):
            # This is a rough screening criterion, not a claim that a label is
            # invalid: fibre and rounding can change energy calculations.
            note += (' Калорийность заметно отличается от грубой оценки по БЖУ; '
                     'проверьте этикетку.')
        brand = 'ЗАО «Тираспольский хлебокомбинат» (ТХК)'
        category = category_for_tirhleb(name)
        keywords = f'тхк thk тираспольский хлебокомбинат пмр {brand} {name} {category}'
        result.append(record(name, cal, protein, fat, carbs, category, brand, url, note, keywords, 'published'))
    for short, brand, fat_label, cal, protein, fat, carbs, keywords, producer_url in HISTORICAL_MILKS:
        name = f'Молоко {short} {fat_label} (историческая позиция)'
        note = ('Ориентировочно: КБЖУ — типовая старая оценка для молока такой жирности, '
                'не данные упаковки этого производителя. Сверьте упаковку. '
                'Наименование и жирность встречаются в перечне 2022 года; '
                'актуальный ассортимент и конкретная торговая марка не подтверждены. '
                'Микронутриенты неизвестны.')
        sources = f'{HISTORICAL_LIST} | {producer_url}' if producer_url else HISTORICAL_LIST
        result.append(record(name, cal, protein, fat, carbs, 'Молочные продукты', brand,
                             sources, note, f'{keywords} {fat_label} пмр приднестровье', 'historical_estimate'))
    names = [r['name'].lower() for r in result]
    if len(names) != len(set(names)):
        raise ValueError('Duplicate catalog display name')
    return result


def main() -> None:
    items = records()
    OUT_JSON.write_text(json.dumps({
        'version': 2, 'generatedBy': 'tools/build_local_catalog.py', 'sourceLabel': 'Продукция ПМР',
        'count': len(items), 'publishedCount': sum(r['quality'] == 'published' for r in items),
        'historicalEstimateCount': sum(r['quality'] == 'historical_estimate' for r in items),
        'notice': 'Исторические позиции не подтверждают текущий ассортимент. Права на источники нужно проверить до публикации.',
        'items': items,
    }, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    lines = ['// GENERATED FILE — DO NOT EDIT BY HAND.',
             '// Regenerate with: python3 tools/build_local_catalog.py',
             "import '../legacy.dart';", "import 'engine.dart';", '',
             '/// Reviewed PMR listings; historical estimates are labelled.',
             '/// Unknown micronutrients are omitted. See tools/data/pmr_catalog.json.',
             'const List<FoodItem> localCatalogFoods = <FoodItem>[']
    for r in items:
        lines.extend(['  FoodItem(', f'    {q(r["name"])},'])
        lines.extend(f'    {dart_double(r[k])},' for k in ('calories', 'protein', 'fat', 'carbs'))
        lines.extend(['    const <String, double>{},', f'    {q(r["category"])},', '    pmrSource,',
                      f'    {q(r["brand"])},', '    null,', f'    {q(r["note"])},',
                      f'    {q(r["sourceUrl"])},', f'    {q(r["keywords"])},', '  ),'])
    lines.extend(['];', ''])
    OUT_DART.write_text('\n'.join(lines), encoding='utf8')
    print(f'Wrote {len(items)} reviewed PMR listings; no generated producer/template combinations.')


if __name__ == '__main__':
    main()
