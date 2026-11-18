#!/usr/bin/env python3
"""Generate the offline regional milk catalog from a reviewable source table.

The generated Dart list is compiled into the app, so the quick "add food"
search works offline on the first launch. Values are per 100 g. `quality: label`
means the macros come from a published product/brand table; `quality: typical`
means an estimate by fat percentage and must be checked against the package.
Micronutrients are generic milk estimates, not package laboratory values.
"""
from __future__ import annotations
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT_DART = ROOT / 'lib/smart/regional_foods.dart'
OUT_JSON = ROOT / 'tools/data/regional_dairy.json'
SOURCE = 'Региональные молочные продукты'

# Sources are public web pages consulted on 2026-10-27. Exact product pages are
# preferred; generic tables are used only for typical fat-percentage estimates.
SOURCES = {
    'sel_05': ('Селянське 0,5%, официальная страница производителя', 'https://www.loostdorf.com/ru/our-brands/moloko-ultrapasteryzovane-selyanske-05-zhyru-900/'),
    'sel_10': ('Селянське 1,0%, официальная страница производителя', 'https://www.loostdorf.com/ru/our-brands/moloko-selyanske-1-5-900/'),
    'sel_15': ('Селянське Особливе 1,5%, официальная страница производителя', 'https://www.loostdorf.com/ru/our-brands/uht-semi-skimmed-milk-1-5-fat-selianske-osoblyve-950-g/'),
    'sel_25': ('Селянське 2,5%, официальная страница производителя', 'https://www.loostdorf.com/ru/our-brands/moloko-selyanske-2-5-900/'),
    'sel_32': ('Селянське 3,2%, официальная страница производителя', 'https://www.loostdorf.com/ru/our-brands/moloko-selyanske-3-2-900/'),
    'sel_lf': ('Селянське безлактозное 2,5%, официальная страница', 'https://www.loostdorf.com/ru/our-brands/moloko-pitne-bezlaktozne-ultrapasterizovane-25-zhiru-tm-selyanske-950g/'),
    'sel_hp': ('Селянське высокобелковое 0,5%, Союз молочных предприятий Украины', 'https://uadairy.com/linijka-tm-selyanske-popovnylasya-molokom-iz-vysokym-umistom-bilka/'),
    'sel_25_bar': ('Селянське 2,5%, каталог с штрихкодом и БЖУ', 'https://listex.info/uk/product/moloko-25-selyanske-900g'),
    'sel_32_bar': ('Селянське 3,2%, каталог METRO с БЖУ', 'https://metro.zakaz.ua/ru/products/moloko-selianske-900g-ukrayina--04820003481554/'),
    'blagodat': ('Молочная Благодать, таблица БЖУ бренда', 'https://health-diet.ru/base_of_food/food_102273/'),
    'blagoda_tmk': ('Благода, Парканский мясо-молочный комбинат (Фиальт-Агро)', 'https://novostipmr.com/ru/news/18-07-20/molochnaya-blagoda-vkusno-kak-ranshe'),
    'generic': ('Типовой состав молока разной жирности', 'https://huday.ru/pitanie/kalorijnost/moloko-kalorijnost-belki-zhiry-uglevody.html'),
    'generic2': ('Типовой состав молока 2,5% с витаминами и минералами', 'https://kalinbaza.ru/sostav-moloka-belki-zhiry-uglevody-i-vitaminy-na-100-g'),
    'off_domik': ('Домик в деревне 3,2% (Open Food Facts)', 'https://world.openfoodfacts.org/product/4690228109713/'),
    'off_stancia': ('Станция молочная 3,2% (Open Food Facts)', 'https://ru.openfoodfacts.org/product/4607028308796/'),
    'off_36': ('36 копеек 3,2% (Open Food Facts)', 'https://world.openfoodfacts.org/product/4600657410960/'),
    'off_molkom': ('Молком (Open Food Facts)', 'https://kz.openfoodfacts.org/product/4870007490380/'),
}

BRAND_ALIASES = {
    'Селянське': 'Селянське Селянское Selyanske Selianske Люстдорф Lyustdorf',
    'Благода (Фиальт-Агро)': 'Благода Фиальт-Агро Парканы Blagoda Fialt-Agro Parkany',
    'Молочная Благодать': 'Молочная Благодать Molochnaya Blagodat Благода',
    'Домик в деревне': 'Домик в деревне Domik v derevne',
    'Простоквашино': 'Простоквашино Prostokvashino',
    'Станция молочная': 'Станция молочная Stantsiya molochnaya',
    '36 копеек': '36 копеек 36 kopeek',
    'Молком': 'Молком Molkom',
    'На здоров’я': 'На здоровья Na zdorovya',
    None: 'молоко milk коровье',
}

# (brand, fat label, kcal, protein, fat_g, carbs, source key, quality, category, keywords, barcode, extra note)
ITEMS = [
    # Generic milk fat ladder: first-class Russian names, not English USDA leftovers.
    (None, '0%', 34, 3.0, 0.1, 4.9, 'generic', 'typical', 'Молоко', 'обезжиренное снятое skim nonfat 0 0.0', None, ''),
    (None, '0,5%', 35, 3.0, 0.5, 4.7, 'generic', 'typical', 'Молоко', '0.5 05 полпроцента lowfat', None, ''),
    (None, '1%', 42, 3.0, 1.0, 4.7, 'generic', 'typical', 'Молоко', '1.0 один процент lowfat', None, ''),
    (None, '1,5%', 44, 3.0, 1.5, 4.7, 'blagodat', 'label', 'Молоко', '1.5 полтора процента', None, ''),
    (None, '2%', 50, 3.3, 2.0, 4.8, 'generic', 'typical', 'Молоко', '2.0 два процента reduced fat', None, ''),
    (None, '2,5%', 52, 2.8, 2.5, 4.7, 'sel_25', 'label', 'Молоко', '2.5 два с половиной', '4820003481547', ''),
    (None, '3%', 57, 2.9, 3.0, 4.7, 'generic', 'typical', 'Молоко', '3.0 три процента', None, ''),
    (None, '3,2%', 58, 2.8, 3.2, 4.7, 'sel_32', 'label', 'Молоко', '3.2 три два целое', '4820003481554', ''),
    (None, '3,5%', 64, 3.2, 3.5, 4.8, 'generic', 'typical', 'Молоко', '3.5 цельное whole', None, ''),
    (None, '3,7%', 64, 3.28, 3.66, 4.65, 'generic', 'typical', 'Молоко', '3.7 цельное фермерское producer', None, ''),
    (None, '4%', 67, 2.9, 4.0, 4.7, 'generic', 'typical', 'Молоко', '4.0 четыре процента', None, ''),
    (None, '6%', 84, 3.0, 6.0, 4.7, 'generic', 'typical', 'Молоко', '6.0 шесть процентов жирное', None, ''),
    (None, 'топлёное 1%', 40, 3.0, 1.0, 4.8, 'generic', 'typical', 'Молоко топлёное', 'топленое baked 1.0', None, ''),
    (None, 'топлёное 2,5%', 53, 2.9, 2.5, 4.7, 'generic', 'typical', 'Молоко топлёное', 'топленое baked 2.5', None, ''),
    (None, 'топлёное 3,2%', 60, 2.9, 3.2, 4.7, 'generic', 'typical', 'Молоко топлёное', 'топленое baked 3.2', None, ''),
    (None, 'топлёное 4%', 67, 3.0, 4.0, 4.7, 'blagodat', 'label', 'Молоко топлёное', 'топленое baked 4.0', None, ''),
    (None, 'топлёное 6%', 84, 3.0, 6.0, 4.7, 'generic', 'typical', 'Молоко топлёное', 'топленое baked 6.0', None, ''),
    (None, 'безлактозное 2,5%', 52, 2.8, 2.5, 4.7, 'sel_lf', 'label', 'Молоко безлактозное', 'без лактозы lactose free 2.5', None, ''),
    (None, 'высокобелковое 0,5%', 41, 4.5, 0.5, 4.7, 'sel_hp', 'label', 'Молоко высокобелковое', 'протеин protein high 4.5 0.5', None, 'Калорийность рассчитана по БЖУ.'),
    (None, 'козье 4,2%', 67, 3.0, 4.2, 4.5, 'generic', 'typical', 'Молоко козье', 'goat коза 4.2', None, ''),

    # Exact published line: ТМ «Селянське».
    ('Селянське', '0,5%', 35, 3.0, 0.5, 4.7, 'sel_05', 'label', 'Молоко', '0.5 900г', None, ''),
    ('Селянське', '1%', 39.4, 2.9, 1.0, 4.7, 'sel_10', 'label', 'Молоко', '1.0 900г', None, ''),
    ('Селянське', '1,5%', 44, 3.0, 1.5, 4.7, 'sel_15', 'label', 'Молоко', '1.5 Особливе 950г', None, ''),
    ('Селянське', '2,5%', 52, 2.8, 2.5, 4.7, 'sel_25_bar', 'label', 'Молоко', '2.5 900г Особливе', '4820003481547', ''),
    ('Селянське', '3,2%', 58, 2.8, 3.2, 4.7, 'sel_32_bar', 'label', 'Молоко', '3.2 900г Родинне', '4820003481554', ''),
    ('Селянське', 'безлактозное 2,5%', 52, 2.8, 2.5, 4.7, 'sel_lf', 'label', 'Молоко безлактозное', 'без лактозы lactose free 950г', None, ''),
    ('Селянське', 'высокобелковое 0,5%', 41, 4.5, 0.5, 4.7, 'sel_hp', 'label', 'Молоко высокобелковое', 'протеин high protein 4.5', None, 'Калорийность рассчитана по БЖУ.'),
    ('Селянське', 'детское 2,5%', 52, 2.8, 2.5, 4.7, 'sel_25', 'label', 'Молоко', 'Малюкам детям 900г', None, ''),

    # Local PMR / nearby brands. Exact package values were not found, so these
    # are explicitly marked as estimates by fat percentage.
    ('Благода (Фиальт-Агро)', '1,5%', 44, 3.0, 1.5, 4.7, 'blagoda_tmk', 'typical', 'Молоко', '1.5 ТМК', None, ''),
    ('Благода (Фиальт-Агро)', '2,5%', 52, 2.8, 2.5, 4.7, 'blagoda_tmk', 'typical', 'Молоко', '2.5 ТМК', None, ''),
    ('Благода (Фиальт-Агро)', '3,2%', 58, 2.8, 3.2, 4.7, 'blagoda_tmk', 'typical', 'Молоко', '3.2 ТМК', None, ''),
    ('Благода (Фиальт-Агро)', '3,5%', 64, 3.2, 3.5, 4.8, 'blagoda_tmk', 'typical', 'Молоко', '3.5 ТМК', None, ''),
    ('Благода (Фиальт-Агро)', 'топлёное 4%', 67, 3.0, 4.0, 4.7, 'blagoda_tmk', 'typical', 'Молоко топлёное', 'топленое baked 4.0 ТМК', None, ''),
    ('Благода (Фиальт-Агро)', 'топлёное 6%', 84, 3.0, 6.0, 4.7, 'blagoda_tmk', 'typical', 'Молоко топлёное', 'топленое baked 6.0 ТМК', None, ''),

    # Published brand tables / Open Food Facts entries.
    ('Молочная Благодать', '1,5%', 44, 3.0, 1.5, 4.7, 'blagodat', 'label', 'Молоко', '1.5', None, ''),
    ('Молочная Благодать', '2,5%', 53, 2.8, 2.5, 4.7, 'blagodat', 'label', 'Молоко', '2.5', None, ''),
    ('Молочная Благодать', '3,2%', 60, 3.0, 3.2, 4.7, 'blagodat', 'label', 'Молоко', '3.2', None, ''),
    ('Молочная Благодать', 'топлёное 4%', 67, 3.0, 4.0, 4.7, 'blagodat', 'label', 'Молоко топлёное', 'топленое baked', None, ''),
    ('Молочная Благодать', 'кефир 1%', 37, 3.0, 1.0, 3.9, 'blagodat', 'label', 'Кисломолочные напитки', 'кефир kefir', None, ''),
    ('Молочная Благодать', 'кефир 2,5%', 50, 3.0, 2.5, 3.9, 'blagodat', 'label', 'Кисломолочные напитки', 'кефир kefir', None, ''),
    ('Молочная Благодать', 'ряженка 2,5%', 50, 3.0, 2.5, 3.9, 'blagodat', 'label', 'Кисломолочные напитки', 'ряженка ryazhenka', None, ''),
    ('Молочная Благодать', 'простокваша 4%', 64, 3.0, 4.0, 4.1, 'blagodat', 'label', 'Кисломолочные напитки', 'простокваша', None, ''),
    ('Домик в деревне', '3,2%', 60, 3.0, 3.2, 4.7, 'off_domik', 'label', 'Молоко', 'ультрапастеризованное', '4690228109713', ''),
    ('Простоквашино', '2,5%', 52, 2.8, 2.5, 4.7, 'generic', 'typical', 'Молоко', 'ультрапастеризованное', None, ''),
    ('Простоквашино', '3,2%', 58, 2.8, 3.2, 4.7, 'generic', 'typical', 'Молоко', 'ультрапастеризованное', None, ''),
    ('Станция молочная', '3,2%', 60, 3.0, 3.2, 4.7, 'off_stancia', 'label', 'Молоко', 'пастеризованное 1.5л', '4607028308796', ''),
    ('36 копеек', '3,2%', 60, 3.0, 3.2, 4.7, 'off_36', 'label', 'Молоко', 'пастеризованное 873мл', '4600657410960', ''),
    ('Молком', '3,2%', 58, 3.0, 3.2, 4.7, 'off_molkom', 'typical', 'Молоко', 'Казахстан', '4870007490380', ''),
    ('На здоров’я', '0,5%', 35, 2.8, 0.5, 4.7, 'generic', 'typical', 'Молоко', '0.5 950г', None, ''),
]


def micros_for(fat: float) -> dict[str, float]:
    values = {
        'sugars': 4.7,
        'saturatedFat': round(fat * 0.65, 2),
        'unsaturatedFat': round(fat * 0.30, 2),
        'sodium': 50.0,
        'potassium': 146.0,
        'calcium': 120.0,
        'magnesium': 14.0,
        'zinc': 0.4,
        'vitaminA': 22.0,
        'vitaminC': 1.3,
        'riboflavin': 0.15,
        'vitaminB12': 0.4,
    }
    return {k: float(v) for k, v in values.items()}


def q(value) -> str:
    return json.dumps('' if value is None else str(value), ensure_ascii=False)


def nullable_q(value) -> str:
    return 'null' if value is None else json.dumps(str(value), ensure_ascii=False)


def dart_double(value) -> str:
    text = repr(float(value))
    return text if '.' in text or 'e' in text else f'{text}.0'


def make_record(row):
    brand, fat_label, kcal, protein, fat_g, carbs, source_key, quality, category, extra_kw, barcode, extra_note = row
    source_title, source_url = SOURCES[source_key]
    if brand:
        name = f'Молоко «{brand}» {fat_label}'
    elif fat_label.startswith(('топлёное', 'безлактозное', 'высокобелковое', 'козье')):
        name = f'Молоко {fat_label}'
    else:
        name = f'Молоко коровье {fat_label} (типовое)'
    aliases = BRAND_ALIASES.get(brand, '')
    fat_tokens = fat_label.replace(',', '.').replace('%', '').replace('топлёное', 'топленое')
    fat_key = 'fat' + str(int(round(float(fat_g) * 10))).zfill(2)
    keywords = ' '.join(filter(None, [
        'молоко milk коровье', brand or '', aliases, fat_label,
        fat_label.replace(',', '.'), fat_label.replace(',', ''),
        fat_tokens, fat_key, 'жирность', extra_kw,
    ]))
    if quality == 'label':
        note = 'По опубликованной пищевой ценности; сверьте упаковку.'
    else:
        note = 'Ориентировочно по жирности; точные белок/углеводы сверьте с упаковкой.'
    note += ' Микронутриенты — ориентир по обычному молоку.'
    if extra_note:
        note += ' ' + extra_note
    note += f' Источник: {source_title}.'
    urls = [source_url]
    if quality == 'typical' and source_key == 'blagoda_tmk':
        urls.append(SOURCES['generic'][1])
    return {
        'name': name,
        'calories': float(kcal),
        'protein': float(protein),
        'fat': float(fat_g),
        'carbs': float(carbs),
        'micros': micros_for(float(fat_g)),
        'category': category,
        'source': SOURCE,
        'brand': brand,
        'barcode': barcode,
        'note': note,
        'sourceUrl': ' | '.join(urls),
        'keywords': keywords,
        'quality': quality,
        'sourceKey': source_key,
    }


def main():
    records = [make_record(row) for row in ITEMS]
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps({
        'version': 1,
        'generatedBy': 'tools/build_regional_foods.py',
        'sourceLabel': SOURCE,
        'sources': [{'id': k, 'title': v[0], 'url': v[1]} for k, v in SOURCES.items()],
        'count': len(records),
        'items': records,
    }, ensure_ascii=False, indent=2), encoding='utf-8')

    lines = [
        '// GENERATED FILE — DO NOT EDIT BY HAND.',
        '// Regenerate with: python3 tools/build_regional_foods.py',
        "import '../legacy.dart';",
        "import 'engine.dart';",
        '',
        '/// Curated regional milk products with fat percentage and brand names.',
        '/// Values are per 100 g. See tools/data/regional_dairy.json for sources.',
        'const List<FoodItem> regionalDairyFoods = <FoodItem>[',
    ]
    for r in records:
        micro_literal = ', '.join(
            f"{q(k)}: {dart_double(v)}" for k, v in r['micros'].items()
        )
        lines.append('  FoodItem(')
        for field in ['name', 'calories', 'protein', 'fat', 'carbs']:
            value = r[field]
            lines.append(f'    {dart_double(value) if isinstance(value, float) else q(value)},')
        lines.append(f"    const <String, double>{{{micro_literal}}},")
        for field in ['category', 'source', 'brand', 'barcode', 'note', 'sourceUrl', 'keywords']:
            if field == 'source':
                lines.append('    regionalDairySource,')
            elif field in ('brand', 'barcode'):
                lines.append(f'    {nullable_q(r[field])},')
            else:
                lines.append(f'    {q(r[field])},')
        lines.append('  ),')
    lines.append('];')
    lines.append('')
    OUT_DART.write_text('\n'.join(lines), encoding='utf-8')
    print(f'Wrote {len(records)} regional foods to {OUT_DART} and {OUT_JSON}')


if __name__ == '__main__':
    main()
