import 'dart:math';
import 'dart:convert';

typedef Json = Map<String, dynamic>;

/// Local Cyrillic product sources. PMR goods are prioritized over generic rows.
const regionalDairySource = 'Региональные молочные продукты';
const pmrSource = 'Продукция ПМР';
const onlineBrandSource = 'Онлайн-каталог брендов';

double number(Object? value, [double fallback = 0]) =>
    value is num && value.isFinite ? value.toDouble() : fallback;

/// Small vitamin quantities must not round to a misleading zero.
String formatNutrient(num value) {
  final n = value.toDouble();
  if (n == 0) return '0';
  if (n.abs() < 0.001) return n.toStringAsPrecision(3);
  final decimals = n.abs() < 1
      ? 3
      : n.abs() < 10
      ? 2
      : 1;
  return n.toStringAsFixed(decimals).replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Null/missing means unknown, NEVER zero. Nutrients are per 100 g.
const microLabels = <String, String>{
  'fiber': 'Клетчатка, г',
  'sugars': 'Сахара всего, г',
  'saturatedFat': 'Насыщенные жиры, г',
  'unsaturatedFat': 'Ненасыщенные жиры, г',
  'sodium': 'Натрий, мг',
  'potassium': 'Калий, мг',
  'iron': 'Железо, мг',
  'calcium': 'Кальций, мг',
  'magnesium': 'Магний, мг',
  'zinc': 'Цинк, мг',
  'selenium': 'Селен, мкг',
  'vitaminA': 'Витамин A, мкг RAE',
  'vitaminC': 'Витамин C, мг',
  'vitaminD': 'Витамин D, мкг',
  'vitaminE': 'Витамин E, мг',
  'vitaminK': 'Витамин K, мкг',
  'thiamin': 'Витамин B1, мг',
  'riboflavin': 'Витамин B2, мг',
  'niacin': 'Витамин B3, мг',
  'pantothenicAcid': 'Витамин B5, мг',
  'vitaminB6': 'Витамин B6, мг',
  'biotin': 'Витамин B7, мкг',
  'folate': 'Фолаты, мкг',
  'vitaminB12': 'Витамин B12, мкг',
};

/// General adult reference values, not a personal medical recommendation.
const microReference = <String, double>{
  'fiber': 25,
  'sugars': 90,
  'saturatedFat': 20,
  'unsaturatedFat': 30,
  'sodium': 2000,
  'potassium': 3500,
  'iron': 14,
  'calcium': 1000,
  'magnesium': 400,
  'zinc': 12,
  'selenium': 55,
  'vitaminA': 900,
  'vitaminC': 90,
  'vitaminD': 15,
  'vitaminE': 15,
  'vitaminK': 120,
  'thiamin': 1.4,
  'riboflavin': 1.6,
  'niacin': 18,
  'pantothenicAcid': 5,
  'vitaminB6': 1.8,
  'biotin': 30,
  'folate': 400,
  'vitaminB12': 2.4,
};

const vitaminKeys = <String>[
  'vitaminA',
  'vitaminC',
  'vitaminD',
  'vitaminE',
  'vitaminK',
  'thiamin',
  'riboflavin',
  'niacin',
  'pantothenicAcid',
  'vitaminB6',
  'biotin',
  'folate',
  'vitaminB12',
];
const mineralKeys = <String>[
  'sodium',
  'potassium',
  'iron',
  'calcium',
  'magnesium',
  'zinc',
  'selenium',
];
const otherMicroKeys = <String>[
  'fiber',
  'sugars',
  'saturatedFat',
  'unsaturatedFat',
];

class MacroBudget {
  final double protein, fat, carbs;
  const MacroBudget(this.protein, this.fat, this.carbs);
  double get calories => protein * 4 + fat * 9 + carbs * 4;
  MacroBudget operator +(MacroBudget other) => MacroBudget(
    protein + other.protein,
    fat + other.fat,
    carbs + other.carbs,
  );
}

class MetabolicSettings {
  final int age;
  final bool male, useKatch, automatic, adaptMacros;
  final double bodyFat, activity, goalDelta;
  const MetabolicSettings({
    this.age = 30,
    this.male = true,
    this.useKatch = false,
    this.automatic = false,
    this.adaptMacros = false,
    this.bodyFat = 20,
    this.activity = 1.2,
    this.goalDelta = 0,
  });
  factory MetabolicSettings.fromJson(Json j) => MetabolicSettings(
    age: (j['age'] as num?)?.toInt() ?? 30,
    male: j['male'] != false,
    useKatch: j['useKatch'] == true,
    automatic: j['automatic'] == true,
    adaptMacros: j['adaptMacros'] == true,
    bodyFat: number(j['bodyFat'], 20),
    activity: number(j['activity'], 1.2),
    goalDelta: number(j['goalDelta']),
  );
  Json toJson() => {
    'age': age,
    'male': male,
    'useKatch': useKatch,
    'automatic': automatic,
    'adaptMacros': adaptMacros,
    'bodyFat': bodyFat,
    'activity': activity,
    'goalDelta': goalDelta,
  };
  double bmr(double weight, double height) {
    if (age < 18 ||
        age > 100 ||
        weight <= 0 ||
        height <= 0 ||
        !weight.isFinite ||
        !height.isFinite ||
        bodyFat < 3 ||
        bodyFat > 65) {
      throw ArgumentError('Проверьте возраст, рост, вес и процент жира');
    }
    return useKatch
        ? 370 + 21.6 * weight * (1 - bodyFat / 100)
        : 10 * weight + 6.25 * height - 5 * age + (male ? 5 : -161);
  }

  double baseTarget(double weight, double height) {
    if (activity < 1.1 || activity > 2 || goalDelta < -500 || goalDelta > 500) {
      throw ArgumentError('Некорректный коэффициент активности или цель');
    }
    return max(1200, bmr(weight, height) * activity + goalDelta);
  }

  // Fractions are shares of ENERGY, then converted to grams using 4/9/4.
  static MacroBudget workoutBonus(int calories, String type) {
    if (calories < 0) throw ArgumentError('Отрицательный расход');
    final (p, c, f) = switch (type) {
      'strength' => (0.4, 0.4, 0.2),
      'cardio' => (0.2, 0.6, 0.2),
      _ => (0.3, 0.5, 0.2),
    };
    return MacroBudget(calories * p / 4, calories * f / 9, calories * c / 4);
  }
}

class MicroTotal {
  final double value, coverage;
  const MicroTotal(this.value, this.coverage);
}

/// Weight coverage is shown, because unknown vitamins cannot be treated as absent.
Map<String, MicroTotal> aggregateMicros(Iterable<Json> entries) {
  final list = entries.toList();
  final allWeight = list.fold(0.0, (sum, e) => sum + number(e['amountGrams']));
  return {
    for (final key in microLabels.keys)
      key: (() {
        var total = 0.0, knownWeight = 0.0;
        for (final e in list) {
          final micros = (e['micros'] as Map?) ?? {};
          final amount = number(e['amountGrams']);
          if (micros[key] is num) {
            knownWeight += amount;
            total += number(micros[key]) * amount / 100;
          }
        }
        return MicroTotal(total, allWeight > 0 ? knownWeight / allWeight : 0);
      })(),
  };
}

/// Transparent experimental score, NOT official Nutri-Score, not a health diagnosis.
/// Require >=80% weight coverage of all four inputs before issuing any score.
int? dietScore(Map<String, MicroTotal> m) {
  const keys = ['fiber', 'saturatedFat', 'sodium', 'sugars'];
  if (keys.any((k) => (m[k]?.coverage ?? 0) < .8)) return null;
  final fiber = (m['fiber']!.value / 25).clamp(0, 1);
  final sodium = (m['sodium']!.value / 2000).clamp(0, 2);
  final saturated = (m['saturatedFat']!.value / 20).clamp(0, 2);
  final sugars = (m['sugars']!.value / 90).clamp(0, 2);
  return (60 +
          40 * fiber -
          15 * max(0, sodium - 1) -
          15 * max(0, saturated - 1) -
          10 * max(0, sugars - 1))
      .round()
      .clamp(1, 100);
}

/// Conservative document merge: simultaneous divergent changes require a decision.
enum MergeDecision { unchanged, push, pull, conflict }

MergeDecision decideMerge(
  Object? baseline,
  Object? local,
  Object? remote,
  bool Function(Object?, Object?) equal,
) {
  if (equal(local, remote)) return MergeDecision.unchanged;
  if (equal(local, baseline)) return MergeDecision.pull;
  if (equal(remote, baseline)) return MergeDecision.push;
  return MergeDecision.conflict;
}

String csvCell(Object? value) {
  var text = value?.toString() ?? '';
  // Prevent spreadsheet-formula injection from user/AI names.
  if (RegExp(r'^[\s]*[=+\-@\t\r]').hasMatch(text)) text = "'$text";
  return '"${text.replaceAll('"', '""')}"';
}

String exportCsv(Json data) {
  // The CSV importer requires at least one document. Do not offer a header-
  // only file that appears to be a backup but cannot be restored. JSON can
  // still represent an empty diary, subject to its own import validation.
  if (data.isEmpty) {
    throw const FormatException(
      'Нет записей для CSV. Выберите JSON или добавьте запись.',
    );
  }
  final out = <List<Object?>>[
    [
      'record_type',
      'day',
      'id',
      'name',
      'grams',
      'calories',
      'protein_g',
      'fat_g',
      'carbs_g',
      ...microLabels.keys,
      'value',
      'unit',
      'raw_json',
    ],
  ];
  // Include every storage document as a raw row: lossless machine-readable backup.
  for (final entry in data.entries) {
    out.add([
      'document',
      '',
      entry.key,
      '',
      '',
      '',
      '',
      '',
      '',
      ...List.filled(microLabels.length, ''),
      '',
      '',
      jsonEncode(entry.value),
    ]);
    dynamic raw = entry.value;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        continue;
      }
    }
    if (entry.key.startsWith('water_intake_') ||
        entry.key.startsWith('steps_')) {
      final water = entry.key.startsWith('water_intake_');
      out.add([
        water ? 'water' : 'steps',
        entry.key.substring(water ? 13 : 6),
        entry.key,
        '',
        '',
        '',
        '',
        '',
        '',
        ...List.filled(microLabels.length, ''),
        raw,
        water ? 'ml' : 'steps',
        '',
      ]);
      continue;
    }
    if (raw is! List) continue;
    if (entry.key == 'weight_entries' ||
        entry.key.startsWith('workout_entries_')) {
      final weight = entry.key == 'weight_entries';
      for (final e in raw.whereType<Map>()) {
        out.add([
          weight ? 'weight' : 'workout',
          (e['date'] as String? ?? '').split('T').first,
          e['id'],
          weight ? 'Вес' : e['type'],
          '',
          weight ? '' : e['caloriesBurned'],
          '',
          '',
          '',
          ...List.filled(microLabels.length, ''),
          weight ? e['weight'] : e['durationMinutes'],
          weight ? 'kg' : 'min',
          jsonEncode(e),
        ]);
      }
      continue;
    }
    if (entry.key.startsWith('supplement_entries_')) {
      for (final e in raw.whereType<Map>()) {
        out.add([
          'supplement',
          entry.key.substring('supplement_entries_'.length),
          e['id'],
          e['name'],
          '',
          '',
          '',
          '',
          '',
          ...List.filled(microLabels.length, ''),
          e['quantity'],
          e['unit'],
          jsonEncode(e),
        ]);
      }
      continue;
    }
    if (!entry.key.startsWith('food_entries_')) continue;
    for (final e in raw.whereType<Map>()) {
      final grams = number(e['amountGrams']);
      double portion(String key) => number(e[key]) * grams / 100;
      final micros = e['micros'] as Map? ?? {};
      out.add([
        'food',
        entry.key.substring(13),
        e['id'],
        e['name'],
        grams,
        portion('caloriesPer100g'),
        portion('proteinPer100g'),
        portion('fatPer100g'),
        portion('carbsPer100g'),
        ...microLabels.keys.map(
          (k) => micros[k] is num ? number(micros[k]) * grams / 100 : '',
        ),
        '',
        '',
        '',
      ]);
    }
  }
  return '\uFEFF${out.map((row) => row.map(csvCell).join(',')).join('\r\n')}';
}
