import 'dart:convert';
import '../legacy.dart';
import 'activity_trends.dart';
import 'gym_models.dart';
import 'nutrition_insights.dart';
import 'sleep.dart';
import 'supplements.dart';

/// A read-only summary of the local journal. Unknown days are not zeros.
/// No document IDs, account identifiers, free-form notes, profile or photos
/// are copied into the payload. Every statistic covers the selected period;
/// only the explicitly labelled top-name lists are limited.
const journalSections = <String>[
  'food',
  'water',
  'steps',
  'training',
  'weight',
  'supplements',
];

const journalSectionLabels = <String, String>{
  'food': 'Питание',
  'water': 'Вода',
  'steps': 'Шаги',
  'training': 'Тренировки и зал',
  'weight': 'Вес',
  'supplements': 'Добавки',
};

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
int _days(DateTime a, DateTime b) =>
    DateTime.utc(
      b.year,
      b.month,
      b.day,
    ).difference(DateTime.utc(a.year, a.month, a.day)).inDays +
    1;

bool _inRange(DateTime d, DateTime first, DateTime last) {
  final key = dayKey(d);
  return key.compareTo(dayKey(first)) >= 0 && key.compareTo(dayKey(last)) <= 0;
}

DateTime? _keyDate(String key, String prefix) {
  if (!key.startsWith(prefix)) return null;
  final s = key.substring(prefix.length);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return null;
  final d = DateTime.tryParse(s);
  return d != null && dayKey(d) == s ? _day(d) : null;
}

dynamic _decode(Object? raw) {
  if (raw is String) return jsonDecode(raw);
  return raw;
}

double _round(num n) => (n * 1000).round() / 1000;
bool _validNumber(num n) => n.isFinite && n >= 0;

String _cleanName(String name) {
  final clean = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length <= 80 ? clean : clean.substring(0, 80);
}

List<Map<String, dynamic>> _topNames(Map<String, int> counts, int max) {
  final rows = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return [
    for (final e in rows.take(max)) {'name': e.key, 'count': e.value},
  ];
}

/// Per-exercise aggregate, restricted to actual recorded sets. Pull-up weight
/// can mean assistance or added load, so it is deliberately not mixed in.
class _GymStats {
  final String name;
  int sets = 0, setsWithReps = 0, totalReps = 0, setsWithWeight = 0;
  double? minWeight, maxWeight, lastWeight;
  DateTime? lastWeightAt;
  _GymStats(this.name);

  void add(GymSet set) {
    sets++;
    if (set.reps != null) {
      setsWithReps++;
      totalReps += set.reps!;
    }
    if (!set.isPullup && set.weightKg != null) {
      final kg = set.weightKg!;
      setsWithWeight++;
      if (minWeight == null || kg < minWeight!) minWeight = kg;
      if (maxWeight == null || kg > maxWeight!) maxWeight = kg;
      if (lastWeightAt == null || set.recordedAt.isAfter(lastWeightAt!)) {
        lastWeightAt = set.recordedAt;
        lastWeight = kg;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'sets': sets,
    'setsWithReps': setsWithReps,
    'totalReps': totalReps,
    'setsWithWeight': setsWithWeight,
    if (minWeight != null) 'minWeightKg': _round(minWeight!),
    if (maxWeight != null) 'maxWeightKg': _round(maxWeight!),
    if (lastWeight != null) 'lastWeightKg': _round(lastWeight!),
  };
}

class _ManualExerciseStats {
  final String name;
  int entries = 0,
      entriesWithSetsAndReps = 0,
      totalRepsKnown = 0,
      entriesWithWeight = 0;
  double? minWeight, maxWeight;
  _ManualExerciseStats(this.name);
  void add(int? sets, int? reps, double? weight) {
    entries++;
    if (sets != null && reps != null) {
      entriesWithSetsAndReps++;
      totalRepsKnown += sets * reps;
    }
    if (!isPullupName(name) && weight != null) {
      entriesWithWeight++;
      if (minWeight == null || weight < minWeight!) minWeight = weight;
      if (maxWeight == null || weight > maxWeight!) maxWeight = weight;
    }
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'entries': entries,
    'entriesWithSetsAndReps': entriesWithSetsAndReps,
    'totalRepsKnown': totalRepsKnown,
    'entriesWithWeight': entriesWithWeight,
    if (minWeight != null) 'minWeightKg': _round(minWeight!),
    if (maxWeight != null) 'maxWeightKg': _round(maxWeight!),
  };
}

class JournalOverview {
  final DateTime first, last;
  final int periodDays;
  final int unreadableDocuments;
  final Map<String, Map<String, dynamic>> sections;

  /// Local-only calculated details. Never included in [request].
  final NutritionInsights foodInsights;

  /// Local-only. Sleep is deliberately not part of the legacy AI contract.
  final SleepRangeSummary sleep;

  /// Local-only daily series; never included in [request].
  final ActivitySeries stepsTrend, sleepTrend;

  const JournalOverview({
    required this.first,
    required this.last,
    required this.periodDays,
    required this.unreadableDocuments,
    required this.sections,
    required this.foodInsights,
    required this.sleep,
    required this.stepsTrend,
    required this.sleepTrend,
  });

  /// Send only the sections deliberately selected in the review UI. A new map
  /// is produced each time so no hidden diary documents can travel with it.
  Map<String, dynamic> request(Set<String> selected, String question) {
    final clean = question.trim();
    if (selected.isEmpty ||
        selected.any((key) => !journalSections.contains(key))) {
      throw ArgumentError('Выберите хотя бы один раздел.');
    }
    if (clean.length > 800) throw ArgumentError('Вопрос длиннее 800 символов.');
    return {
      'firstDay': dayKey(first),
      'lastDay': dayKey(last),
      'periodDays': periodDays,
      'question': clean,
      'unreadableDocuments': unreadableDocuments,
      'sections': {
        for (final key in journalSections)
          if (selected.contains(key)) key: sections[key]!,
      },
    };
  }
}

/// Construct a stable, bounded payload from a synchronous snapshot of the
/// persisted app documents. This function is deterministic and read-only.
JournalOverview summarizeJournal(
  Map<String, dynamic> documents,
  DateTime from,
  DateTime to,
) {
  final first = _day(from), last = _day(to);
  if (first.isAfter(last)) throw ArgumentError('Начало периода позже конца.');
  final periodDays = _days(first, last);
  if (periodDays < 1 || periodDays > 37000) {
    throw ArgumentError('Слишком большой период.');
  }
  final foodDays = <String>{}, workoutDays = <String>{};
  final foodInsights = NutritionInsightsBuilder();
  final foodNames = <String, int>{}, exerciseNames = <String, int>{};
  final gymExerciseStats = <String, _GymStats>{};
  final manualExerciseStats = <String, _ManualExerciseStats>{};
  final supplementNames = <String, int>{};
  final microTotals = <String, double>{}, microKnown = <String, int>{};
  final supplementMicros = <String, double>{},
      supplementKnown = <String, int>{};
  var foodEntries = 0, foodWithMicros = 0, estimatedMicros = 0;
  var calories = 0.0, protein = 0.0, fat = 0.0, carbs = 0.0;
  var waterDays = 0, waterMl = 0, stepDays = 0, steps = 0;
  var manualWorkouts = 0,
      manualMinutes = 0,
      manualCalories = 0,
      manualBudgetCalories = 0;
  var gymStarted = 0, gymFinished = 0, gymSets = 0;
  var cardioEntries = 0, cardioKnownDistance = 0;
  var cardioMinutes = 0.0, cardioDistance = 0.0;
  var supplements = 0, unreadable = 0, knownCreatineRecords = 0;
  var creatineGrams = 0.0;
  final pullupTests = <GymSet>[];
  final weights = <WeightEntry>[];

  // Sorting makes previews, model inputs and stale-snapshot checks stable.
  final keys = documents.keys.toList()..sort();
  for (final key in keys) {
    try {
      final foodDate = _keyDate(key, 'food_entries_');
      if (foodDate != null && _inRange(foodDate, first, last)) {
        final raw = _decode(documents[key]);
        if (raw is! List) throw const FormatException('food');
        final rows = raw
            .map((e) => FoodEntry.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        if (rows.any(
          (e) =>
              dayKey(e.date) != dayKey(foodDate) ||
              ![
                e.amountGrams,
                e.calories,
                e.protein,
                e.fat,
                e.carbs,
              ].every(_validNumber),
        )) {
          throw const FormatException('food date or values');
        }
        if (rows.isNotEmpty) foodDays.add(dayKey(foodDate));
        for (final row in rows) {
          foodInsights.add(row);
          foodEntries++;
          calories += row.calories;
          protein += row.protein;
          fat += row.fat;
          carbs += row.carbs;
          final name = _cleanName(row.name);
          if (name.isNotEmpty) foodNames[name] = (foodNames[name] ?? 0) + 1;
          if (row.micros.isNotEmpty) foodWithMicros++;
          if (row.microsEstimated && row.micros.isNotEmpty) estimatedMicros++;
          for (final micro in row.micros.entries) {
            microTotals[micro.key] =
                (microTotals[micro.key] ?? 0) +
                micro.value * row.amountGrams / 100;
            microKnown[micro.key] = (microKnown[micro.key] ?? 0) + 1;
          }
        }
        continue;
      }
      final waterDate = _keyDate(key, 'water_intake_');
      if (waterDate != null && _inRange(waterDate, first, last)) {
        final n = documents[key];
        if (n is! int || n < 0) throw const FormatException('water');
        waterDays++;
        waterMl += n;
        continue;
      }
      final stepDate = _keyDate(key, 'steps_');
      if (stepDate != null && _inRange(stepDate, first, last)) {
        final n = documents[key];
        if (n is! int || n < 0 || n > maxChartStepsPerDay) {
          throw const FormatException('steps');
        }
        stepDays++;
        steps += n;
        continue;
      }
      final workoutDate = _keyDate(key, 'workout_entries_');
      if (workoutDate != null && _inRange(workoutDate, first, last)) {
        final raw = _decode(documents[key]);
        if (raw is! List) throw const FormatException('workouts');
        final rows = raw
            .map(
              (e) => WorkoutEntry.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        if (rows.any(
          (e) =>
              dayKey(e.date) != dayKey(workoutDate) ||
              e.durationMinutes < 0 ||
              e.caloriesBurned < 0,
        )) {
          throw const FormatException('workout date or values');
        }
        for (final row in rows) {
          workoutDays.add(dayKey(workoutDate));
          manualWorkouts++;
          manualMinutes += row.durationMinutes;
          manualCalories += row.caloriesBurned;
          manualBudgetCalories += row.budgetCalories;
          for (final exercise in row.details?.exercises ?? []) {
            final name = _cleanName(exercise.name);
            if (name.isNotEmpty) {
              exerciseNames[name] = (exerciseNames[name] ?? 0) + 1;
              manualExerciseStats
                  .putIfAbsent(name, () => _ManualExerciseStats(name))
                  .add(exercise.sets, exercise.reps, exercise.weightKg);
            }
          }
        }
        continue;
      }
      final supplementDate = _keyDate(key, 'supplement_entries_');
      if (supplementDate != null && _inRange(supplementDate, first, last)) {
        final raw = _decode(documents[key]);
        if (raw is! List) throw const FormatException('supplements');
        final rows = raw
            .map(
              (e) =>
                  SupplementEntry.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        if (rows.any((e) => dayKey(e.date) != dayKey(supplementDate))) {
          throw const FormatException('supplement date');
        }
        for (final row in rows) {
          supplements++;
          final name = _cleanName(row.name);
          if (name.isNotEmpty)
            supplementNames[name] = (supplementNames[name] ?? 0) + 1;
          for (final micro in row.microTotals.entries) {
            supplementMicros[micro.key] =
                (supplementMicros[micro.key] ?? 0) + micro.value;
            supplementKnown[micro.key] = (supplementKnown[micro.key] ?? 0) + 1;
          }
          final creatine = row.creatineGrams;
          if (creatine != null) {
            knownCreatineRecords++;
            creatineGrams += creatine;
          }
        }
        continue;
      }
      if (key == 'weight_entries') {
        final raw = _decode(documents[key]);
        if (raw is! List) throw const FormatException('weights');
        final rows = raw
            .map(
              (e) => WeightEntry.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        if (rows.any((e) => !_validNumber(e.weight)))
          throw const FormatException('weight');
        weights.addAll(rows.where((e) => _inRange(e.date, first, last)));
        continue;
      }
      if (key.startsWith(gymSessionPrefix)) {
        final raw = _decode(documents[key]);
        if (raw is! Map) throw const FormatException('gym');
        final session = GymSession.fromJson(Map<String, dynamic>.from(raw));
        if (!_inRange(session.startedAt, first, last)) continue;
        workoutDays.add(dayKey(session.startedAt));
        gymStarted++;
        if (session.completed) gymFinished++;
        gymSets += session.setCount;
        for (final set in session.allSets) {
          final name = _cleanName(set.exerciseName);
          if (name.isNotEmpty) {
            exerciseNames[name] = (exerciseNames[name] ?? 0) + 1;
            gymExerciseStats.putIfAbsent(name, () => _GymStats(name)).add(set);
          }
          if (set.isComparableTest) pullupTests.add(set);
        }
        for (final cardio in session.cardio) {
          cardioEntries++;
          cardioMinutes += cardio.minutes;
          if (cardio.distanceKm != null) {
            cardioKnownDistance++;
            cardioDistance += cardio.distanceKm!;
          }
        }
      }
    } catch (_) {
      // Do not silently call malformed data zero; expose the incomplete count.
      unreadable++;
    }
  }
  weights.sort((a, b) => a.date.compareTo(b.date));
  pullupTests.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  final orderedMicros = microTotals.keys.toList()..sort();
  final orderedSupplementMicros = supplementMicros.keys.toList()..sort();
  final orderedGymExercises = gymExerciseStats.values.toList()
    ..sort((a, b) {
      final count = b.sets.compareTo(a.sets);
      return count == 0 ? a.name.compareTo(b.name) : count;
    });
  final orderedManualExercises = manualExerciseStats.values.toList()
    ..sort((a, b) {
      final count = b.entries.compareTo(a.entries);
      return count == 0 ? a.name.compareTo(b.name) : count;
    });
  return JournalOverview(
    first: first,
    last: last,
    periodDays: periodDays,
    unreadableDocuments: unreadable,
    foodInsights: foodInsights.build(),
    sleep: summarizeSleep(documents, first, last),
    stepsTrend: buildActivitySeries(
      documents,
      first,
      last,
      ActivityMetric.steps,
    ),
    sleepTrend: buildActivitySeries(
      documents,
      first,
      last,
      ActivityMetric.sleep,
    ),
    sections: {
      'food': {
        'daysWithRecords': foodDays.length,
        'records': foodEntries,
        'caloriesTotal': _round(calories),
        'proteinTotalG': _round(protein),
        'fatTotalG': _round(fat),
        'carbsTotalG': _round(carbs),
        'recordsWithMicronutrients': foodWithMicros,
        'recordsWithEstimatedMicronutrients': estimatedMicros,
        'micronutrients': {
          for (final key in orderedMicros)
            key: {
              'knownRecords': microKnown[key],
              'total': _round(microTotals[key]!),
            },
        },
        'commonFoodsUpTo10': _topNames(foodNames, 10),
        'uniqueFoodNames': foodNames.length,
      },
      'water': {'recordedDays': waterDays, 'totalMl': waterMl},
      'steps': {'recordedDays': stepDays, 'totalSteps': steps},
      'training': {
        'daysWithRecords': workoutDays.length,
        'manualWorkouts': manualWorkouts,
        'manualMinutes': manualMinutes,
        'manualCaloriesBurnedTotal': manualCalories,
        'manualCaloriesAddedToBudget': manualBudgetCalories,
        'manualExercisesUpTo10': [
          for (final e in orderedManualExercises.take(10)) e.toJson(),
        ],
        'manualUniqueExerciseNames': manualExerciseStats.length,
        'gymSessionsStarted': gymStarted,
        'gymSessionsFinished': gymFinished,
        'gymRecordedSets': gymSets,
        'gymExercisesUpTo10': [
          for (final e in orderedGymExercises.take(10)) e.toJson(),
        ],
        'gymUniqueExerciseNames': gymExerciseStats.length,
        'gymCardioEntries': cardioEntries,
        'gymCardioMinutes': _round(cardioMinutes),
        'gymCardioKnownDistanceEntries': cardioKnownDistance,
        'gymCardioDistanceKm': _round(cardioDistance),
        'commonExerciseNamesUpTo10': _topNames(exerciseNames, 10),
        'uniqueExerciseNames': exerciseNames.length,
        'comparablePullupTests': pullupTests.length,
        if (pullupTests.isNotEmpty) 'firstPullupReps': pullupTests.first.reps,
        if (pullupTests.isNotEmpty) 'lastPullupReps': pullupTests.last.reps,
      },
      'weight': {
        'measurements': weights.length,
        if (weights.isNotEmpty) 'firstKg': _round(weights.first.weight),
        if (weights.isNotEmpty) 'lastKg': _round(weights.last.weight),
      },
      'supplements': {
        'records': supplements,
        'commonNamesUpTo10': _topNames(supplementNames, 10),
        'uniqueNames': supplementNames.length,
        'knownMicronutrients': {
          for (final key in orderedSupplementMicros)
            key: {
              'knownRecords': supplementKnown[key],
              'total': _round(supplementMicros[key]!),
            },
        },
        'knownCreatineRecords': knownCreatineRecords,
        'knownCreatineTotalG': _round(creatineGrams),
      },
    },
  );
}

Future<JournalOverview> loadJournalOverview(
  StorageService store,
  DateTime first,
  DateTime last,
) async {
  await store.pendingMutations;
  // Strings and numbers are immutable; obtain them together before parsing.
  return summarizeJournal(store.local.snapshot(), first, last);
}
