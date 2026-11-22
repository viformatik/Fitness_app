#!/usr/bin/env python3
"""Build a small reviewed offline milk catalog, not an inventory guarantee.

Generic rows are openly labelled legacy estimates with no invented brand,
barcode or micronutrients. Branded rows use specific published product data;
community data can be wrong. Historical user diary entries are never read.
"""
from __future__ import annotations
import json
import math
import pathlib
import re
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT_DART = ROOT / 'lib/smart/regional_foods.dart'
OUT_JSON = ROOT / 'tools/data/regional_dairy.json'
OFF = 'https://world.openfoodfacts.org/product/'
OFF_TERMS = 'https://world.openfoodfacts.org/terms-of-use'
RETAIL_CONFLICT = 'https://happypen.com.ua/p-moloko-950ml-05-dlitelnogo-xraneniya-ultrapasterizovannoe-na-zdorove'

# Unbranded examples inherited from the former local table. These are not
# package measurements and no precise reference for every value is established.
# (Russian name, kcal, protein, fat, carbohydrate, category, search aliases)
GENERIC = (
    ('Молоко коровье 0–0,1% (типовое)', 34, 3.0, 0.1, 4.9, 'Молоко', '0% обезжиренное'),
    ('Молоко коровье 0,5% (типовое)', 35, 3.0, 0.5, 4.7, 'Молоко', '0.5'),
    ('Молоко коровье 1% (типовое)', 42, 3.0, 1.0, 4.7, 'Молоко', '1.0'),
    ('Молоко коровье 1,5% (типовое)', 44, 3.0, 1.5, 4.7, 'Молоко', '1.5'),
    ('Молоко коровье 2% (типовое)', 50, 3.3, 2.0, 4.8, 'Молоко', '2.0'),
    ('Молоко коровье 2,5% (типовое)', 52, 2.8, 2.5, 4.7, 'Молоко', '2.5'),
    ('Молоко коровье 3% (типовое)', 57, 2.9, 3.0, 4.7, 'Молоко', '3.0'),
    ('Молоко коровье 3,2% (типовое)', 58, 2.8, 3.2, 4.7, 'Молоко', '3.2'),
    ('Молоко коровье 3,5% (типовое)', 64, 3.2, 3.5, 4.8, 'Молоко', '3.5'),
    ('Молоко коровье 3,7% (типовое)', 64, 3.28, 3.66, 4.65, 'Молоко', '3.7'),
    ('Молоко коровье 4% (типовое)', 67, 2.9, 4.0, 4.7, 'Молоко', '4.0'),
    ('Молоко коровье 6% (типовое)', 84, 3.0, 6.0, 4.7, 'Молоко', '6.0'),
    ('Молоко топлёное 1% (типовое)', 40, 3.0, 1.0, 4.8, 'Молоко топлёное', 'топленое'),
    ('Молоко топлёное 2,5% (типовое)', 53, 2.9, 2.5, 4.7, 'Молоко топлёное', 'топленое'),
    ('Молоко топлёное 3,2% (типовое)', 60, 2.9, 3.2, 4.7, 'Молоко топлёное', 'топленое'),
    ('Молоко топлёное 4% (типовое)', 67, 3.0, 4.0, 4.7, 'Молоко топлёное', 'топленое'),
    ('Молоко топлёное 6% (типовое)', 84, 3.0, 6.0, 4.7, 'Молоко топлёное', 'топленое'),
    ('Молоко безлактозное 2,5% (типовое)', 52, 2.8, 2.5, 4.7, 'Молоко безлактозное', 'без лактозы'),
    ('Молоко высокобелковое 0,5% (типовое)', 41, 4.5, 0.5, 4.7, 'Молоко высокобелковое', 'протеин'),
    ('Молоко козье 4,2% (типовое)', 67, 3.0, 4.2, 4.5, 'Молоко козье', 'коза'),
)

# Branded entries have a specific product source. OFF values are crowdsourced,
# not guaranteed, and disputed figures are explicit. Codes 4607028308796 and
# 4600657410960 are excluded: OFF reports their values per 100 ml, while the
# diary presently stores portions in grams and no density is known.
# (name, kcal, protein, fat, carbs, brand, barcode, URL, note, keywords, quality)
PUBLISHED = (
    ('Молоко ультрапастеризованное «Селянське» 2,5%, 900 г', 52, 2.8, 2.5, 4.7,
     'Селянське', '4820003481547', OFF+'4820003481547', '', 'селянське селянское selyanske selianske люстдорф', 'off'),
    ('Молоко ультрапастеризованное «Селянське» 3,2%, 900 г', 58, 2.8, 3.2, 4.7,
     'Селянське', '4820003481554', OFF+'4820003481554', '', 'селянське селянское selyanske selianske люстдорф', 'off'),
    ('Молоко «Домик в деревне» 3,2%', 60, 3.0, 3.2, 4.7,
     'Домик в деревне', '4690228109713', OFF+'4690228109713', '', 'домик в деревне', 'off'),
    ('Молоко «На здоровье» 0,5% (сверьте КБЖУ)', 35, 3.0, 0.5, 4.7,
     'На здоровье', '4820003488461', OFF+'4820003488461 | '+RETAIL_CONFLICT,
     'Источники противоречат друг другу: в другом описании 37 ккал и 2,8 г белка на 100 г. '
     'Указаны значения Open Food Facts, обязательно сверьте эту упаковку.', 'на здоровье', 'off_disputed'),
    ('Молоко ультрапастеризованное «Простоквашино» 2,5%, 950 мл', 53, 2.9, 2.5, 4.8,
     'Простоквашино', None, 'https://prostokvashino.ru/product/moloko-ultrapasterizovannoe-2-5-950-ml/',
     '', 'простоквашино', 'manufacturer'),
    ('Молоко пастеризованное «Простоквашино» 3,2%, 1,4 л', 59, 2.9, 3.2, 4.7,
     'Простоквашино', None, 'https://prostokvashino.ru/product/moloko-pasterizovannoe-3-2--1-4-l/',
     '', 'простоквашино', 'manufacturer'),
    ('Молоко «Молочная Благодать» 1,5% (Россия)', 44, 3.0, 1.5, 4.7,
     'Молочная Благодать', None, 'https://health-diet.ru/base_of_food/sostav/168537.php',
     'Российская марка, не приднестровская «Благода».', 'молочная благодать', 'third_party'),
    ('Молоко «Молочная Благодать» 2,5% (Россия)', 53, 2.8, 2.5, 4.7,
     'Молочная Благодать', None, 'https://health-diet.ru/base_of_food/sostav/168519.php',
     'Российская марка, не приднестровская «Благода».', 'молочная благодать', 'third_party'),
    ('Молоко «Молочная Благодать» 3,2% (Россия)', 60, 3.0, 3.2, 4.7,
     'Молочная Благодать', None, 'https://health-diet.ru/base_of_food/sostav/102281.php',
     'Российская марка, не приднестровская «Благода».', 'молочная благодать', 'third_party'),
)


def q(value: object) -> str:
    return json.dumps(value, ensure_ascii=False)


def record(name: str, cal: float, protein: float, fat: float, carbs: float, category: str,
           brand: str | None, barcode: str | None, url: str | None, note: str,
           aliases: str, quality: str) -> dict:
    if not re.search(r'[А-Яа-яЁёІіЇїЄєҐґ]', name) or re.search(r'[A-Za-z]', name):
        raise ValueError('Display names must contain Cyrillic and no Latin letters')
    if not all(isinstance(x, (int, float)) and math.isfinite(x) and x >= 0 for x in (cal, protein, fat, carbs)):
        raise ValueError(f'Invalid nutrition values: {name}')
    if barcode is not None and not re.fullmatch(r'\d{8}|\d{13}|\d{14}', barcode):
        raise ValueError(f'Invalid barcode: {name}')
    if url is not None and not all(urlparse(x.strip()).scheme == 'https' for x in url.split(' | ')):
        raise ValueError(f'Invalid source URL: {name}')
    fat_key = 'fat' + str(int(round(float(fat) * 10))).zfill(2)
    keywords = ' '.join(filter(None, (name, aliases, barcode or '', fat_key, 'молоко жирность')))
    return {'name': name, 'calories': float(cal), 'protein': float(protein), 'fat': float(fat),
            'carbs': float(carbs), 'micros': {}, 'category': category, 'source': 'Региональные молочные продукты',
            'brand': brand, 'barcode': barcode, 'note': note, 'sourceUrl': url, 'keywords': keywords, 'quality': quality}


def records() -> list[dict]:
    result = []
    for name, cal, protein, fat, carbs, category, aliases in GENERIC:
        result.append(record(name, cal, protein, fat, carbs, category, None, None, None,
            'Ориентировочно: типовые КБЖУ из прежней справочной базы, не данные конкретной марки. '
            'Источник точных значений не подтверждён; сверьте упаковку. Микронутриенты неизвестны.', aliases, 'legacy_estimate'))
    for name, cal, protein, fat, carbs, brand, barcode, url, extra, aliases, quality in PUBLISHED:
        if quality.startswith('off'):
            note = ('Данные Open Food Facts (ODbL/DBCL), внесённые сообществом: возможны ошибки. '
                    'Сверьте упаковку. Микронутриенты не подтверждены.')
        elif quality == 'third_party':
            note = ('По стороннему справочнику на 100 г; актуальность не подтверждена. '
                    'Сверьте упаковку. Микронутриенты не подтверждены.')
        else:
            note = ('По опубликованной странице производителя на 100 г. '
                    'Сверьте именно эту упаковку. Микронутриенты не подтверждены.')
        if extra:
            note += ' ' + extra
        result.append(record(name, cal, protein, fat, carbs, 'Молоко', brand, barcode, url, note, aliases, quality))
    names = [x['name'].lower() for x in result]
    codes = [x['barcode'] for x in result if x['barcode']]
    if len(names) != len(set(names)) or len(codes) != len(set(codes)):
        raise ValueError('Duplicate name or barcode')
    return result


def main() -> None:
    items = records()
    OUT_JSON.write_text(json.dumps({
        'version': 2, 'generatedBy': 'tools/build_regional_foods.py',
        'sourceLabel': 'Региональные молочные продукты', 'count': len(items),
        'openFoodFactsTerms': OFF_TERMS,
        'notice': 'Типовые значения приблизительные; права на данные других источников требуют проверки до выпуска.',
        'items': items,
    }, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    lines = ['// GENERATED FILE — DO NOT EDIT BY HAND.',
             '// Regenerate with: python3 tools/build_regional_foods.py',
             "import '../legacy.dart';", "import 'engine.dart';", '',
             '/// Milk entries with individually labelled provenance or generic estimates.',
             '/// Unreported micronutrients are omitted. See tools/data/regional_dairy.json.',
             'const List<FoodItem> regionalDairyFoods = <FoodItem>[']
    for r in items:
        lines.extend(['  FoodItem(', f'    {q(r["name"])},'])
        lines.extend(f'    {float(r[k])!r},' for k in ('calories', 'protein', 'fat', 'carbs'))
        lines.extend(['    const <String, double>{},', f'    {q(r["category"])},', '    regionalDairySource,',
                      f'    {q(r["brand"])},', f'    {q(r["barcode"])},', f'    {q(r["note"])},',
                      f'    {q(r["sourceUrl"])},', f'    {q(r["keywords"])},', '  ),'])
    lines.extend(['];', ''])
    OUT_DART.write_text('\n'.join(lines), encoding='utf8')
    print(f'Wrote {len(items)} reviewed/labelled regional milk entries.')


if __name__ == '__main__':
    main()
