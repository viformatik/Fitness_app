import '../legacy.dart';

/// A read-only arithmetic summary of recorded food, not a diet prescription or
/// a model output. It deliberately does not look at default profile targets.
class NutritionInsights {
  final int records, skipped, recordsWithoutMicros, recordsEstimatedMicros;
  final double calories, protein, fat, carbs;

  /// Largest individual recorded portions, not product rankings or a judgement
  /// of whether any food is good, bad, or should be removed.
  final List<FoodEntry> largestEnergyRecords;
  final FoodEntry? largestProteinRecord;

  const NutritionInsights._({
    required this.records,
    required this.skipped,
    required this.recordsWithoutMicros,
    required this.recordsEstimatedMicros,
    required this.calories,
    required this.protein,
    required this.fat,
    required this.carbs,
    required this.largestEnergyRecords,
    required this.largestProteinRecord,
  });

  double share(FoodEntry entry) => calories > 0 ? entry.calories / calories : 0;
}

/// Incremental accumulator: the local overview need not retain every record.
class NutritionInsightsBuilder {
  int _records = 0, _skipped = 0, _withoutMicros = 0, _estimatedMicros = 0;
  double _calories = 0, _protein = 0, _fat = 0, _carbs = 0;
  final List<FoodEntry> _largest = [];
  FoodEntry? _proteinLeader;

  void add(FoodEntry entry) {
    final values = [
      entry.amountGrams,
      entry.caloriesPer100g,
      entry.proteinPer100g,
      entry.fatPer100g,
      entry.carbsPer100g,
      entry.calories,
      entry.protein,
      entry.fat,
      entry.carbs,
    ];
    if (entry.name.trim().isEmpty || values.any((v) => !v.isFinite || v < 0)) {
      _skipped++;
      return;
    }
    // Reject arithmetic overflow rather than presenting an invalid total.
    final next = [
      _calories + entry.calories,
      _protein + entry.protein,
      _fat + entry.fat,
      _carbs + entry.carbs,
    ];
    if (next.any((v) => !v.isFinite)) {
      _skipped++;
      return;
    }
    _records++;
    _calories = next[0];
    _protein = next[1];
    _fat = next[2];
    _carbs = next[3];
    if (entry.micros.isEmpty) _withoutMicros++;
    if (entry.micros.isNotEmpty && entry.microsEstimated) _estimatedMicros++;
    if (entry.calories > 0) {
      _largest.add(entry);
      _largest.sort((a, b) {
        final amount = b.calories.compareTo(a.calories);
        if (amount != 0) return amount;
        final day = a.date.compareTo(b.date);
        return day != 0 ? day : a.name.compareTo(b.name);
      });
      if (_largest.length > 3) _largest.removeLast();
    }
    if (entry.protein > 0 &&
        (_proteinLeader == null || entry.protein > _proteinLeader!.protein)) {
      _proteinLeader = entry;
    }
  }

  NutritionInsights build() => NutritionInsights._(
    records: _records,
    skipped: _skipped,
    recordsWithoutMicros: _withoutMicros,
    recordsEstimatedMicros: _estimatedMicros,
    calories: _calories,
    protein: _protein,
    fat: _fat,
    carbs: _carbs,
    largestEnergyRecords: List.unmodifiable(_largest),
    largestProteinRecord: _proteinLeader,
  );
}

NutritionInsights analyzeRecordedNutrition(Iterable<FoodEntry> records) {
  final builder = NutritionInsightsBuilder();
  for (final entry in records) {
    builder.add(entry);
  }
  return builder.build();
}

/// A user-selected hypothetical future portion, calculated from the recorded
/// per-100-g values. It cannot change any diary entry.
class PortionComparison {
  final double originalGrams, hypotheticalGrams;
  final double caloriesChange, proteinChange, fatChange, carbsChange;
  PortionComparison._({
    required this.originalGrams,
    required this.hypotheticalGrams,
    required this.caloriesChange,
    required this.proteinChange,
    required this.fatChange,
    required this.carbsChange,
  });

  factory PortionComparison.calculate(FoodEntry entry, double hypothetical) {
    if (!hypothetical.isFinite || hypothetical < 0 || hypothetical > 10000) {
      throw ArgumentError('Порция должна быть от 0 до 10 000 г.');
    }
    final source = [
      entry.amountGrams,
      entry.caloriesPer100g,
      entry.proteinPer100g,
      entry.fatPer100g,
      entry.carbsPer100g,
    ];
    if (source.any((value) => !value.isFinite || value < 0)) {
      throw ArgumentError('Не удалось проверить исходные значения порции.');
    }
    final delta = (hypothetical - entry.amountGrams) / 100;
    final result = PortionComparison._(
      originalGrams: entry.amountGrams,
      hypotheticalGrams: hypothetical,
      caloriesChange: entry.caloriesPer100g * delta,
      proteinChange: entry.proteinPer100g * delta,
      fatChange: entry.fatPer100g * delta,
      carbsChange: entry.carbsPer100g * delta,
    );
    if ([
      result.originalGrams,
      result.caloriesChange,
      result.proteinChange,
      result.fatChange,
      result.carbsChange,
    ].any((v) => !v.isFinite)) {
      throw ArgumentError('Не удалось проверить значения порции.');
    }
    return result;
  }
}

/// Arithmetic examples for a *future* meal. These do not assess whether a
/// person should change their intake and can never mutate the recorded entry.
enum PortionExampleKind { smaller, larger, omit }

class PortionExample {
  final PortionExampleKind kind;
  final PortionComparison comparison;
  const PortionExample._(this.kind, this.comparison);
}

List<PortionExample> futurePortionExamples(FoodEntry entry) {
  final grams = entry.amountGrams;
  if (!grams.isFinite || grams <= 0) return const [];
  final targets = <PortionExampleKind, double>{
    PortionExampleKind.smaller: grams * 0.75,
    PortionExampleKind.larger: grams * 1.25,
    PortionExampleKind.omit: 0,
  };
  final result = <PortionExample>[];
  for (final target in targets.entries) {
    // Unrepresentable or oversized alternatives are omitted, not clipped.
    // Never describe an unchanged/underflowed value as a 25% difference.
    if (target.key != PortionExampleKind.omit &&
        (target.value <= 0 || target.value == grams)) {
      continue;
    }
    try {
      result.add(
        PortionExample._(
          target.key,
          PortionComparison.calculate(entry, target.value),
        ),
      );
    } on ArgumentError {
      // Preserve access to other mathematically valid examples, if any.
    }
  }
  return List.unmodifiable(result);
}
