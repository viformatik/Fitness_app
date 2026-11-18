import 'engine.dart';

/// Additions are stored separately from food: they do not silently create
/// zero-calorie food or alter portion-weight coverage of micronutrients.
const supplementUnits = <String, String>{
  'g': 'г',
  'mg': 'мг',
  'mcg': 'мкг',
  'iu': 'МЕ',
  'tablet': 'табл.',
  'capsule': 'капс.',
  'serving': 'порция',
  'ml': 'мл',
};
const supplementStrengthUnits = <String, String>{
  'g': 'г',
  'mg': 'мг',
  'mcg': 'мкг',
  'iu': 'МЕ',
};
const discreteSupplementUnits = <String>{'tablet', 'capsule', 'serving', 'ml'};
const supplementNutrientKeys = <String>[...vitaminKeys, ...mineralKeys];
const _microgramKeys = <String>{
  'selenium',
  'biotin',
  'vitaminA',
  'vitaminD',
  'vitaminK',
  'folate',
  'vitaminB12',
};

String supplementKindLabel(String key) => switch (key) {
  'creatine' => 'Креатин',
  'other' => 'Другое / комплекс',
  _ => microLabels[key] ?? key,
};

/// A daily record, not a dosing recommendation. Quantity is exactly what the
/// user confirms. For tablets/capsules, optional strength is per one unit.
/// compositionPerUnit is explicit label/user data per one recorded unit.
class SupplementEntry {
  final String id, name, unit, nutrientKey, strengthUnit, source;
  final double quantity;
  final double? strength;
  final Map<String, double> compositionPerUnit;
  final DateTime date;

  const SupplementEntry({
    required this.id,
    required this.name,
    required this.quantity,
    required this.unit,
    required this.nutrientKey,
    required this.date,
    this.strength,
    this.strengthUnit = '',
    this.compositionPerUnit = const {},
    this.source = 'manual',
  });

  Json toJson() => {
    'id': id,
    'name': name,
    'quantity': quantity,
    'unit': unit,
    'nutrientKey': nutrientKey,
    'date': date.toIso8601String(),
    if (strength != null) 'strength': strength,
    if (strengthUnit.isNotEmpty) 'strengthUnit': strengthUnit,
    'compositionPerUnit': compositionPerUnit,
    'source': source,
  };

  factory SupplementEntry.fromJson(Json raw) {
    final date = raw['date'] is String ? DateTime.tryParse(raw['date']) : null;
    final quantity = raw['quantity'];
    final strength = raw['strength'];
    final composition = raw['compositionPerUnit'] ?? const {};
    if (raw['id'] is! String ||
        (raw['id'] as String).isEmpty ||
        (raw['id'] as String).length > 200 ||
        raw['name'] is! String ||
        (raw['name'] as String).trim().isEmpty ||
        (raw['name'] as String).length > 200 ||
        quantity is! num ||
        !quantity.isFinite ||
        quantity <= 0 ||
        quantity > 1000000 ||
        raw['unit'] is! String ||
        !supplementUnits.containsKey(raw['unit']) ||
        raw['nutrientKey'] is! String ||
        !{
          ...supplementNutrientKeys,
          'creatine',
          'other',
        }.contains(raw['nutrientKey']) ||
        date == null ||
        composition is! Map ||
        (strength != null &&
            (strength is! num ||
                !strength.isFinite ||
                strength <= 0 ||
                strength > 100000000)) ||
        (strength != null &&
            !supplementStrengthUnits.containsKey(raw['strengthUnit'])) ||
        (raw['source'] != null && !['manual', 'ai'].contains(raw['source']))) {
      throw const FormatException('Некорректная запись добавки');
    }
    final clean = <String, double>{};
    for (final e in composition.entries) {
      if (e.key is! String ||
          !supplementNutrientKeys.contains(e.key) ||
          e.value is! num ||
          !(e.value as num).isFinite ||
          (e.value as num) < 0 ||
          (e.value as num) > 100000000) {
        throw const FormatException('Некорректный состав добавки');
      }
      clean[e.key as String] = (e.value as num).toDouble();
    }
    return SupplementEntry(
      id: raw['id'] as String,
      name: (raw['name'] as String).trim(),
      quantity: quantity.toDouble(),
      unit: raw['unit'] as String,
      nutrientKey: raw['nutrientKey'] as String,
      date: date,
      strength: strength == null ? null : (strength as num).toDouble(),
      strengthUnit: raw['strengthUnit'] is String ? raw['strengthUnit'] : '',
      compositionPerUnit: clean,
      source: raw['source'] == 'ai' ? 'ai' : 'manual',
    );
  }

  /// Only explicit quantities are used. An IU conversion is well-defined here
  /// solely for ordinary vitamin D: 1 microgram = 40 IU (NIH ODS). IU for A/E
  /// depends on the chemical form and is intentionally not guessed.
  (double, String)? get effectiveDose {
    if (supplementStrengthUnits.containsKey(unit)) return (quantity, unit);
    if (discreteSupplementUnits.contains(unit) &&
        strength != null &&
        supplementStrengthUnits.containsKey(strengthUnit)) {
      return (quantity * strength!, strengthUnit);
    }
    return null;
  }

  double? get creatineGrams {
    if (nutrientKey != 'creatine') return null;
    final dose = effectiveDose;
    if (dose == null) return null;
    return switch (dose.$2) {
      'g' => dose.$1,
      'mg' => dose.$1 / 1000,
      'mcg' => dose.$1 / 1000000,
      _ => null,
    };
  }

  Map<String, double> get microTotals {
    final result = <String, double>{
      for (final e in compositionPerUnit.entries) e.key: e.value * quantity,
    };
    if (!supplementNutrientKeys.contains(nutrientKey) ||
        result.containsKey(nutrientKey))
      return result;
    final dose = effectiveDose;
    if (dose == null) return result;
    final value = dose.$1;
    final unit = dose.$2;
    // Vitamin A needs RAE and the form matters. Use only explicitly entered
    // composition in µg RAE rather than silently equating arbitrary µg or IU.
    if (nutrientKey == 'vitaminA') return result;
    if (unit == 'iu') {
      final form = name.toLowerCase().replaceAll(RegExp(r'[\s()\-–]'), '');
      final nonstandardD =
          form.contains('25oh') ||
          form.contains('25гидрокси') ||
          form.contains('25hydroxy') ||
          form.contains('кальцифедиол') ||
          form.contains('calcifediol');
      if (nutrientKey == 'vitaminD' && !nonstandardD)
        result[nutrientKey] = value / 40;
      return result;
    }
    final micrograms = switch (unit) {
      'g' => value * 1000000,
      'mg' => value * 1000,
      'mcg' => value,
      _ => null,
    };
    if (micrograms == null) return result;
    result[nutrientKey] = _microgramKeys.contains(nutrientKey)
        ? micrograms
        : micrograms / 1000;
    return result;
  }
}

Map<String, double> supplementMicroTotals(Iterable<SupplementEntry> entries) {
  final totals = <String, double>{};
  for (final entry in entries) {
    for (final item in entry.microTotals.entries) {
      totals[item.key] = (totals[item.key] ?? 0) + item.value;
    }
  }
  return totals;
}

/// AI may leave unknown dose/unit blank. It must never invent a dose; saving is
/// disabled until the user has entered/confirmed a positive explicit amount.
List<Json> validateAiSupplements(Object? raw) {
  if (raw is! List || raw.length > 30) {
    throw const FormatException('AI вернул некорректный список добавок.');
  }
  return raw.map((row) {
    if (row is! Map ||
        row['name'] is! String ||
        (row['name'] as String).trim().isEmpty ||
        (row['name'] as String).length > 200) {
      throw const FormatException('Не удалось проверить название добавки.');
    }
    final quantity = row['quantity'];
    final strength = row['strength'];
    if (quantity != null &&
        (quantity is! num ||
            !quantity.isFinite ||
            quantity < 0 ||
            quantity > 1000000)) {
      throw const FormatException('Проверьте количество добавки.');
    }
    if (strength != null &&
        (strength is! num ||
            !strength.isFinite ||
            strength < 0 ||
            strength > 100000000)) {
      throw const FormatException('Проверьте дозировку добавки.');
    }
    final unit = supplementUnits.containsKey(row['unit'])
        ? row['unit'] as String
        : '';
    final strengthUnit =
        supplementStrengthUnits.containsKey(row['strengthUnit'])
        ? row['strengthUnit'] as String
        : '';
    final nutrientKey =
        {
          ...supplementNutrientKeys,
          'creatine',
          'other',
        }.contains(row['nutrientKey'])
        ? row['nutrientKey'] as String
        : 'other';
    final note = row['assumptions'] is String
        ? row['assumptions'] as String
        : '';
    return <String, dynamic>{
      'name': (row['name'] as String).trim(),
      'quantity': quantity is num ? quantity.toDouble() : 0.0,
      'unit': unit,
      'nutrientKey': nutrientKey,
      'strength': strength is num && strength > 0 ? strength.toDouble() : null,
      'strengthUnit': strengthUnit,
      'assumptions': note.substring(0, note.length.clamp(0, 1000)),
      'compositionPerUnit': <String, double>{},
    };
  }).toList();
}

/// A photo of a label cannot establish that, or how much, was consumed.
List<Json> prepareAiSupplementReview(
  Object? raw, {
  required bool hasTakenDescription,
}) {
  final rows = validateAiSupplements(raw);
  return hasTakenDescription
      ? rows
      : rows
            .map((e) => <String, dynamic>{...e, 'quantity': 0.0, 'unit': ''})
            .toList();
}
