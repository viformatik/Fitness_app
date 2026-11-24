// ============================================================================
// FITNESS TRACKER — единый файл main.dart
// Отслеживание питания, тренировок и веса.
// Modern Dark Premium: Material 3, контент до 600 px по центру,
// глубокий тёмный фон, изумрудный акцент, локальное хранилище
// (shared_preferences), графики fl_chart.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'smart/engine.dart' as smart;
import 'smart/local_catalog.dart';
import 'smart/local_store.dart';
import 'smart/csv_reader.dart' show importCsv;
import 'smart/mobile_extras.dart';
import 'smart/remote.dart';
import 'smart/regional_foods.dart';
import 'smart/russian_product_names.dart';
import 'smart/recipe_guard.dart';
import 'smart/lossless_json.dart';
import 'smart/food_guard.dart';
import 'smart/weight_guard.dart';
import 'smart/supplements.dart';
import 'smart/sleep.dart';
import 'smart/workout_calc.dart';
import 'smart/workout_ui.dart';
import 'smart/gym_models.dart';
import 'smart/gym_ui.dart';
import 'smart/ai_actions.dart';
import 'smart/ai_preferences.dart' show AiConsent;
import 'smart/ai_drafts.dart' show friendlyAiError, mergeMicronutrientEstimates;
import 'smart/ui.dart';
import 'smart/home_simple.dart';
import 'smart/journal_overview_ui.dart';
import 'smart/catalog_ui.dart' show FoodCatalogScreen;
import 'smart/section_screens.dart';
import 'smart/preview_banner.dart';
import 'smart/startup_recovery.dart';
import 'smart/user_profile.dart';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:timezone/timezone.dart' as tz;

export 'smart/user_profile.dart' show UserProfile;

// ============================================================================
// ХЕЛПЕРЫ
// ============================================================================

double? parseNutritionNumber(String text) {
  final value = double.tryParse(text.trim().replaceAll(',', '.'));
  return value != null && value.isFinite && value >= 0 ? value : null;
}

double goalProgress(num consumed, num target) =>
    target > 0 ? consumed / target : 0.0;

// Local food CAS compares every serialized value, but map insertion order is
// not a data change (reading a food normalizes micronutrient key order).
Object? _orderedJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _orderedJson(value[key])};
  }
  if (value is List) return value.map(_orderedJson).toList();
  return value;
}

bool sameFoodSnapshot(FoodEntry a, FoodEntry b) =>
    jsonEncode(_orderedJson(a.toJson())) ==
    jsonEncode(_orderedJson(b.toJson()));

/// Immutable local-only evidence of every food record used for one analysis.
/// IDs never need to leave the device. It can be checked in the mutation queue
/// immediately before a reviewed one-day write.
class FoodRangeSnapshot {
  static const int maxEntries = 60;
  final DateTime firstDay, lastDay;
  final List<FoodEntry> entries;

  FoodRangeSnapshot({
    required DateTime firstDay,
    required DateTime lastDay,
    required List<FoodEntry> entries,
  }) : firstDay = DateTime(firstDay.year, firstDay.month, firstDay.day),
       lastDay = DateTime(lastDay.year, lastDay.month, lastDay.day),
       entries = List.unmodifiable(
         entries.map((entry) {
           final copy = FoodEntry.fromJson(entry.toJson());
           return copy.copyWith(micros: Map.unmodifiable(copy.micros));
         }),
       ) {
    final from = dayKey(this.firstDay), to = dayKey(this.lastDay);
    if (from.compareTo(to) > 0 ||
        entries.length > maxEntries ||
        entries.any(
          (entry) =>
              dayKey(entry.date).compareTo(from) < 0 ||
              dayKey(entry.date).compareTo(to) > 0,
        )) {
      throw ArgumentError('Некорректный снимок выбранного периода.');
    }
  }

  /// Advance the expected snapshot only by a write that has already succeeded.
  /// Never read a new baseline from storage here: unrelated concurrent edits
  /// must continue to invalidate any remaining AI suggestions.
  FoodRangeSnapshot afterReviewedDay({
    required DateTime date,
    required Map<String, FoodEntry?> changes,
    required List<FoodEntry> additions,
  }) {
    final target = dayKey(date);
    if (target.compareTo(dayKey(firstDay)) < 0 ||
        target.compareTo(dayKey(lastDay)) > 0 ||
        additions.any((entry) => dayKey(entry.date) != target) ||
        changes.values.whereType<FoodEntry>().any(
          (entry) => dayKey(entry.date) != target,
        )) {
      throw ArgumentError('Изменение находится вне снимка периода.');
    }
    final knownIds = entries
        .where((entry) => dayKey(entry.date) == target)
        .map((entry) => entry.id)
        .toSet();
    if (changes.keys.any((id) => !knownIds.contains(id))) {
      throw StateError('Снимок не содержит изменённой записи.');
    }
    final dayEntries = <FoodEntry>[];
    for (final entry in entries.where(
      (entry) => dayKey(entry.date) == target,
    )) {
      if (!changes.containsKey(entry.id)) {
        dayEntries.add(entry);
      } else if (changes[entry.id] != null) {
        dayEntries.add(changes[entry.id]!);
      }
    }
    dayEntries.addAll(additions);
    final remainingIds = dayEntries.map((entry) => entry.id).toSet();
    if (remainingIds.length != dayEntries.length) {
      throw StateError('В снимке повторяется идентификатор записи.');
    }
    final next = <FoodEntry>[];
    var inserted = false;
    for (final entry in entries) {
      final key = dayKey(entry.date);
      if (!inserted && key.compareTo(target) >= 0) {
        next.addAll(dayEntries);
        inserted = true;
      }
      if (key != target) next.add(entry);
    }
    if (!inserted) next.addAll(dayEntries);
    return FoodRangeSnapshot(
      firstDay: firstDay,
      lastDay: lastDay,
      entries: next,
    );
  }
}

String formatGrams(num value) =>
    value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

Map<String, double> readMicros(Object? value) {
  if (value is! Map) return {};
  return {
    for (final key in smart.microLabels.keys)
      if (value[key] is num &&
          (value[key] as num).isFinite &&
          (value[key] as num) >= 0)
        key: (value[key] as num).toDouble(),
  };
}

DateTime foodTime(DateTime? date) {
  final now = DateTime.now(), day = date ?? DateTime.now();
  return DateTime(
    day.year,
    day.month,
    day.day,
    now.hour,
    now.minute,
    now.second,
  );
}

final Random _rnd = Random();

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch}_${_rnd.nextInt(1 << 31)}';

// ============================================================================
// МОДЕЛИ
// ============================================================================

enum MealType { breakfast, lunch, snack, dinner, preWorkout, postWorkout }

extension MealTypeExtension on MealType {
  String get label {
    switch (this) {
      case MealType.breakfast:
        return 'Завтрак';
      case MealType.lunch:
        return 'Обед';
      case MealType.snack:
        return 'Перекус';
      case MealType.dinner:
        return 'Ужин';
      case MealType.preWorkout:
        return 'До тренировки';
      case MealType.postWorkout:
        return 'После тренировки';
    }
  }

  IconData get icon {
    switch (this) {
      case MealType.breakfast:
        return Icons.breakfast_dining;
      case MealType.lunch:
        return Icons.lunch_dining;
      case MealType.snack:
        return Icons.cookie;
      case MealType.dinner:
        return Icons.dinner_dining;
      case MealType.preWorkout:
        return Icons.fitness_center;
      case MealType.postWorkout:
        return Icons.bolt;
    }
  }
}

enum WorkoutType { strength, cardio, strengthCardio }

extension WorkoutTypeExtension on WorkoutType {
  String get label {
    switch (this) {
      case WorkoutType.strength:
        return 'Силовая';
      case WorkoutType.cardio:
        return 'Кардио';
      case WorkoutType.strengthCardio:
        return 'Силовая + Кардио';
    }
  }

  IconData get icon {
    switch (this) {
      case WorkoutType.strength:
        return Icons.fitness_center;
      case WorkoutType.cardio:
        return Icons.directions_run;
      case WorkoutType.strengthCardio:
        return Icons.sports_gymnastics;
    }
  }

  Color get color {
    switch (this) {
      case WorkoutType.strength:
        return Colors.deepOrange;
      case WorkoutType.cardio:
        return Colors.blue;
      case WorkoutType.strengthCardio:
        return Colors.purple;
    }
  }
}

class FoodEntry {
  final String id;
  final String name;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double fatPer100g;
  final double carbsPer100g;
  final Map<String, double> micros;
  final bool microsEstimated;
  final double amountGrams;
  final MealType mealType;
  final DateTime date;
  final DateTime loggedAt;
  final bool timeKnown;

  FoodEntry({
    String? id,
    required this.name,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.fatPer100g,
    required this.carbsPer100g,
    this.micros = const {},
    this.microsEstimated = false,
    required this.amountGrams,
    required this.mealType,
    DateTime? date,
    DateTime? loggedAt,
    this.timeKnown = true,
  }) : id = id ?? newId(),
       date = date ?? DateTime.now(),
       loggedAt = loggedAt ?? foodTime(date);

  double get calories => caloriesPer100g * amountGrams / 100;
  double get protein => proteinPer100g * amountGrams / 100;
  double get fat => fatPer100g * amountGrams / 100;
  double get carbs => carbsPer100g * amountGrams / 100;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'caloriesPer100g': caloriesPer100g,
    'proteinPer100g': proteinPer100g,
    'fatPer100g': fatPer100g,
    'carbsPer100g': carbsPer100g,
    'micros': micros,
    'microsEstimated': microsEstimated,
    'amountGrams': amountGrams,
    'mealType': mealType.index,
    'date': date.toIso8601String(),
    'loggedAt': loggedAt.toIso8601String(),
    'timeKnown': timeKnown,
  };

  factory FoodEntry.fromJson(Map<String, dynamic> json) => FoodEntry(
    id: json['id'] as String?,
    name: json['name'] as String,
    caloriesPer100g: (json['caloriesPer100g'] as num).toDouble(),
    proteinPer100g: (json['proteinPer100g'] as num).toDouble(),
    fatPer100g: (json['fatPer100g'] as num).toDouble(),
    carbsPer100g: (json['carbsPer100g'] as num).toDouble(),
    micros: readMicros(json['micros']),
    microsEstimated: json['microsEstimated'] == true,
    amountGrams: (json['amountGrams'] as num).toDouble(),
    mealType: MealType.values[json['mealType'] as int],
    date: DateTime.parse(json['date'] as String),
    loggedAt:
        DateTime.tryParse(json['loggedAt'] as String? ?? '') ??
        DateTime.parse(json['date'] as String),
    timeKnown: json['timeKnown'] == true,
  );

  FoodEntry copyWith({
    String? name,
    double? caloriesPer100g,
    double? proteinPer100g,
    double? fatPer100g,
    double? carbsPer100g,
    Map<String, double>? micros,
    bool? microsEstimated,
    double? amountGrams,
    MealType? mealType,
    DateTime? date,
    DateTime? loggedAt,
    bool? timeKnown,
  }) => FoodEntry(
    id: id,
    name: name ?? this.name,
    caloriesPer100g: caloriesPer100g ?? this.caloriesPer100g,
    proteinPer100g: proteinPer100g ?? this.proteinPer100g,
    fatPer100g: fatPer100g ?? this.fatPer100g,
    carbsPer100g: carbsPer100g ?? this.carbsPer100g,
    micros: micros ?? this.micros,
    microsEstimated: microsEstimated ?? this.microsEstimated,
    amountGrams: amountGrams ?? this.amountGrams,
    mealType: mealType ?? this.mealType,
    date: date ?? this.date,
    loggedAt: loggedAt ?? this.loggedAt,
    timeKnown: timeKnown ?? this.timeKnown,
  );
}

/// The exact day document and displayed entry when a food editor is opened.
class FoodEditSnapshot {
  final Object? document;
  final String day;
  final String entryId;
  final String fingerprint;
  FoodEditSnapshot(this.document, FoodEntry original)
    : day = dayKey(original.date),
      entryId = original.id,
      fingerprint = jsonEncode(_orderedJson(original.toJson()));
}

class FoodDaySnapshot {
  final Object? document;
  final String day;
  final Map<String, String> fingerprints;
  FoodDaySnapshot(this.document, DateTime date, List<FoodEntry> entries)
    : day = dayKey(date),
      fingerprints = Map.unmodifiable({
        for (final entry in entries)
          entry.id: jsonEncode(_orderedJson(entry.toJson())),
      });
}

FoodEntry _freezeFood(FoodEntry entry) => FoodEntry.fromJson(
  Map<String, dynamic>.from(jsonDecode(jsonEncode(entry.toJson())) as Map),
);

class WeightEntry {
  final String id;
  final double weight;
  final DateTime date;
  final String? note;

  WeightEntry({String? id, required this.weight, DateTime? date, this.note})
    : id = id ?? newId(),
      date = date ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'weight': weight,
    'date': date.toIso8601String(),
    'note': note,
  };

  factory WeightEntry.fromJson(Map<String, dynamic> json) => WeightEntry(
    id: json['id'] as String?,
    weight: (json['weight'] as num).toDouble(),
    date: DateTime.parse(json['date'] as String),
    note: json['note'] as String?,
  );

  WeightEntry copyWith({double? weight, DateTime? date, String? note}) =>
      WeightEntry(
        id: id,
        weight: weight ?? this.weight,
        date: date ?? this.date,
        note: note ?? this.note,
      );
}

/// The exact document and displayed item at the time an editor is opened.
class WeightEditSnapshot {
  final Object? document;
  final String? entryId;
  final String? fingerprint;
  WeightEditSnapshot(this.document, WeightEntry? original)
    : entryId = original?.id,
      fingerprint = original == null ? null : _weightFingerprint(original);
}

String _weightFingerprint(WeightEntry entry) =>
    jsonEncode(_orderedJson(entry.toJson()));

/// A history write may succeed even if the separately stored profile did not.
/// In that case it must not be reported as a failed write or retried as a new
/// measurement. The warning is displayed instead.
class WeightChangeResult {
  final String? warning;
  const WeightChangeResult({this.warning});
}

class WorkoutEntry {
  final String id;
  final WorkoutType type;
  final int durationMinutes;
  final int caloriesBurned;
  final DateTime date;
  final String? note;

  /// Null for legacy entries; their previous calorie accounting stays unchanged.
  final WorkoutDetails? details;

  WorkoutEntry({
    String? id,
    required this.type,
    required this.durationMinutes,
    required this.caloriesBurned,
    DateTime? date,
    this.note,
    this.details,
  }) : id = id ?? newId(),
       date = date ?? DateTime.now();

  int get budgetCalories =>
      (caloriesBurned * (details?.budgetPercent ?? 100) / 100).round();
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.index,
    'durationMinutes': durationMinutes,
    'caloriesBurned': caloriesBurned,
    'date': date.toIso8601String(),
    'note': note,
    if (details != null) 'details': details!.toJson(),
  };

  factory WorkoutEntry.fromJson(Map<String, dynamic> json) {
    final details = json['details'] == null
        ? null
        : WorkoutDetails.fromJson(
            Map<String, dynamic>.from(json['details'] as Map),
          );
    final entry = WorkoutEntry(
      id: json['id'] as String?,
      type: WorkoutType.values[json['type'] as int],
      durationMinutes: json['durationMinutes'] as int,
      caloriesBurned: json['caloriesBurned'] as int,
      date: DateTime.parse(json['date'] as String),
      note: json['note'] as String?,
      details: details,
    );
    if (details != null && details.minutes != entry.durationMinutes) {
      throw const FormatException(
        'Длительность этапов не совпадает с тренировкой.',
      );
    }
    return entry;
  }
}

/// Ключ дня в формате `2026-10-25` — используется для истории и хранилища.
String dayKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Ранее добавленный продукт (для быстрого повторного добавления)
/// или избранный продукт.
class QuickFood {
  final String name;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double fatPer100g;
  final double carbsPer100g;
  final Map<String, double> micros;
  final bool microsEstimated;

  /// Порция, с которой продукт добавляли в прошлый раз.
  final double grams;
  final MealType mealType;
  final DateTime lastUsed;
  final bool favorite;

  QuickFood({
    required this.name,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.fatPer100g,
    required this.carbsPer100g,
    this.micros = const {},
    this.microsEstimated = false,
    required this.grams,
    required this.mealType,
    DateTime? lastUsed,
    this.favorite = false,
  }) : lastUsed = lastUsed ?? DateTime.now();

  String get key => '${name.toLowerCase()}|${mealType.index}';

  FoodEntry toEntry({DateTime? date}) => FoodEntry(
    name: name,
    caloriesPer100g: caloriesPer100g,
    proteinPer100g: proteinPer100g,
    fatPer100g: fatPer100g,
    carbsPer100g: carbsPer100g,
    micros: micros,
    microsEstimated: microsEstimated,
    amountGrams: grams,
    mealType: mealType,
    date: date,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'caloriesPer100g': caloriesPer100g,
    'proteinPer100g': proteinPer100g,
    'fatPer100g': fatPer100g,
    'carbsPer100g': carbsPer100g,
    'micros': micros,
    'microsEstimated': microsEstimated,
    'grams': grams,
    'mealType': mealType.index,
    'lastUsed': lastUsed.toIso8601String(),
    'favorite': favorite,
  };

  factory QuickFood.fromJson(Map<String, dynamic> json) => QuickFood(
    name: json['name'] as String,
    caloriesPer100g: (json['caloriesPer100g'] as num).toDouble(),
    proteinPer100g: (json['proteinPer100g'] as num).toDouble(),
    fatPer100g: (json['fatPer100g'] as num).toDouble(),
    carbsPer100g: (json['carbsPer100g'] as num).toDouble(),
    micros: readMicros(json['micros']),
    microsEstimated: json['microsEstimated'] == true,
    grams: (json['grams'] as num?)?.toDouble() ?? 100,
    mealType: MealType.values[(json['mealType'] as int?) ?? 0],
    lastUsed:
        DateTime.tryParse(json['lastUsed'] as String? ?? '') ?? DateTime.now(),
    favorite: json['favorite'] as bool? ?? false,
  );

  QuickFood copyWith({
    String? name,
    double? caloriesPer100g,
    double? proteinPer100g,
    double? fatPer100g,
    double? carbsPer100g,
    Map<String, double>? micros,
    bool? microsEstimated,
    double? grams,
    MealType? mealType,
    DateTime? lastUsed,
    bool? favorite,
  }) => QuickFood(
    name: name ?? this.name,
    caloriesPer100g: caloriesPer100g ?? this.caloriesPer100g,
    proteinPer100g: proteinPer100g ?? this.proteinPer100g,
    fatPer100g: fatPer100g ?? this.fatPer100g,
    carbsPer100g: carbsPer100g ?? this.carbsPer100g,
    micros: micros ?? this.micros,
    microsEstimated: microsEstimated ?? this.microsEstimated,
    grams: grams ?? this.grams,
    mealType: mealType ?? this.mealType,
    lastUsed: lastUsed ?? this.lastUsed,
    favorite: favorite ?? this.favorite,
  );
}

/// Ингредиент и исходная масса. Масса готового блюда задаётся отдельно.
class RecipeIngredient {
  final String name;
  final double grams;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double fatPer100g;
  final double carbsPer100g;
  final Map<String, double> micros;
  final bool microsEstimated;

  const RecipeIngredient({
    required this.name,
    required this.grams,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.fatPer100g,
    required this.carbsPer100g,
    this.micros = const {},
    this.microsEstimated = false,
  });

  factory RecipeIngredient.fromFood(FoodItem food, double grams) =>
      RecipeIngredient(
        name: food.name,
        grams: grams,
        caloriesPer100g: food.calories,
        micros: food.micros,
        microsEstimated: food.microsEstimated,
        proteinPer100g: food.protein,
        fatPer100g: food.fat,
        carbsPer100g: food.carbs,
      );

  double get calories => caloriesPer100g * grams / 100;
  double get protein => proteinPer100g * grams / 100;
  double get fat => fatPer100g * grams / 100;
  double get carbs => carbsPer100g * grams / 100;

  Map<String, dynamic> toJson() => {
    'name': name,
    'grams': grams,
    'caloriesPer100g': caloriesPer100g,
    'proteinPer100g': proteinPer100g,
    'fatPer100g': fatPer100g,
    'carbsPer100g': carbsPer100g,
    'micros': micros,
    'microsEstimated': microsEstimated,
  };

  factory RecipeIngredient.fromJson(Map<String, dynamic> json) =>
      RecipeIngredient(
        name: json['name'] as String,
        grams: (json['grams'] as num).toDouble(),
        caloriesPer100g: (json['caloriesPer100g'] as num).toDouble(),
        proteinPer100g: (json['proteinPer100g'] as num).toDouble(),
        fatPer100g: (json['fatPer100g'] as num).toDouble(),
        carbsPer100g: (json['carbsPer100g'] as num).toDouble(),
        micros: readMicros(json['micros']),
        microsEstimated: json['microsEstimated'] == true,
      );
}

/// Собственный рецепт из нескольких ингредиентов.
class Recipe {
  final String id;
  final String name;
  final List<RecipeIngredient> ingredients;
  final int servings;
  final double? cookedWeight;

  Recipe({
    String? id,
    required this.name,
    required this.ingredients,
    this.servings = 1,
    this.cookedWeight,
  }) : id = id ?? newId();

  double get totalGrams => ingredients.fold(0.0, (sum, i) => sum + i.grams);
  double get totalCalories =>
      ingredients.fold(0.0, (sum, i) => sum + i.calories);
  double get totalProtein => ingredients.fold(0.0, (sum, i) => sum + i.protein);
  double get totalFat => ingredients.fold(0.0, (sum, i) => sum + i.fat);
  double get totalCarbs => ingredients.fold(0.0, (sum, i) => sum + i.carbs);

  double get outputWeight =>
      cookedWeight != null && cookedWeight! > 0 ? cookedWeight! : totalGrams;
  Map<String, double> get microsPer100g => {
    for (final key in smart.microLabels.keys)
      if (ingredients.isNotEmpty &&
          ingredients.every((i) => i.micros.containsKey(key)) &&
          outputWeight > 0)
        key:
            ingredients.fold(
              0.0,
              (sum, i) => sum + i.micros[key]! * i.grams / 100,
            ) *
            100 /
            outputWeight,
  };
  double get caloriesPer100g =>
      outputWeight > 0 ? totalCalories * 100 / outputWeight : 0;
  double get proteinPer100g =>
      outputWeight > 0 ? totalProtein * 100 / outputWeight : 0;
  double get fatPer100g => outputWeight > 0 ? totalFat * 100 / outputWeight : 0;
  double get carbsPer100g =>
      outputWeight > 0 ? totalCarbs * 100 / outputWeight : 0;

  /// Масса одной порции.
  double get servingGrams =>
      servings > 0 ? outputWeight / servings : outputWeight;

  /// Калорийность одной порции.
  double get servingCalories => servings > 0 ? totalCalories / servings : 0;

  FoodItem toFoodItem() => FoodItem(
    name,
    caloriesPer100g,
    proteinPer100g,
    fatPer100g,
    carbsPer100g,
    microsPer100g,
    'Основные продукты',
    'База Fitness Smart',
    null,
    null,
    null,
    null,
    '',
    ingredients.any((i) => i.microsEstimated),
  );

  FoodEntry toEntry(double grams, MealType mealType, {DateTime? date}) =>
      FoodEntry(
        name: name,
        caloriesPer100g: caloriesPer100g,
        proteinPer100g: proteinPer100g,
        fatPer100g: fatPer100g,
        carbsPer100g: carbsPer100g,
        micros: microsPer100g,
        microsEstimated: ingredients.any((i) => i.microsEstimated),
        amountGrams: grams,
        mealType: mealType,
        date: date,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'servings': servings,
    'cookedWeight': cookedWeight,
    'ingredients': ingredients.map((i) => i.toJson()).toList(),
  };

  factory Recipe.fromJson(Map<String, dynamic> json) => Recipe(
    id: json['id'] as String?,
    name: json['name'] as String,
    servings: json['servings'] as int? ?? 1,
    cookedWeight: (json['cookedWeight'] as num?)?.toDouble(),
    ingredients: (json['ingredients'] as List<dynamic>? ?? [])
        .map((i) => RecipeIngredient.fromJson(i as Map<String, dynamic>))
        .toList(),
  );

  Recipe copyWith({
    String? name,
    List<RecipeIngredient>? ingredients,
    int? servings,
    double? cookedWeight,
  }) => Recipe(
    id: id,
    name: name ?? this.name,
    ingredients: ingredients ?? this.ingredients,
    servings: servings ?? this.servings,
    cookedWeight: cookedWeight ?? this.cookedWeight,
  );
}

/// Captured when an editor opens, before any asynchronous work. The raw list
/// protects all recipes, while the fingerprint also detects a stale UI model.
class RecipeEditSnapshot {
  final Object? document;
  final String? recipeId;
  final String? recipeFingerprint;
  RecipeEditSnapshot(this.document, Recipe? original)
    : recipeId = original?.id,
      recipeFingerprint = original == null
          ? null
          : _recipeFingerprint(original);
}

String _recipeFingerprint(Recipe recipe) =>
    jsonEncode(_orderedJson(recipe.toJson()));

/// Агрегированная статистика одного дня — для графиков и календаря привычек.
class DayLog {
  final DateTime date;

  /// Exact sum of recorded food, rounded only by a view when displaying it.
  final double calories;
  final bool workoutDone;
  final int water;
  final int steps;

  /// Presence is separate from the numeric value: a recorded zero is not an
  /// absent measurement. These are derived in memory, not stored/migrated.
  final bool hasFoodRecord;
  final bool hasWaterRecord;
  final bool hasStepsRecord;

  const DayLog({
    required this.date,
    this.calories = 0,
    this.workoutDone = false,
    this.water = 0,
    this.steps = 0,
    this.hasFoodRecord = false,
    this.hasWaterRecord = false,
    this.hasStepsRecord = false,
  });

  bool get hasActivity =>
      hasFoodRecord || workoutDone || water > 0 || steps > 0;

  DayLog copyWith({
    double? calories,
    bool? workoutDone,
    int? water,
    int? steps,
    bool? hasFoodRecord,
    bool? hasWaterRecord,
    bool? hasStepsRecord,
  }) => DayLog(
    date: date,
    calories: calories ?? this.calories,
    workoutDone: workoutDone ?? this.workoutDone,
    water: water ?? this.water,
    steps: steps ?? this.steps,
    hasFoodRecord: hasFoodRecord ?? this.hasFoodRecord,
    hasWaterRecord: hasWaterRecord ?? this.hasWaterRecord,
    hasStepsRecord: hasStepsRecord ?? this.hasStepsRecord,
  );
}

/// Настройки локальных напоминаний.
class ReminderSettings {
  final bool waterEnabled;
  final int waterEveryHours;
  final bool lunchEnabled;
  final int lunchHour;
  final bool weightEnabled;
  final int weightHour;

  const ReminderSettings({
    this.waterEnabled = false,
    this.waterEveryHours = 3,
    this.lunchEnabled = false,
    this.lunchHour = 13,
    this.weightEnabled = false,
    this.weightHour = 8,
  });

  bool get anyEnabled => waterEnabled || lunchEnabled || weightEnabled;

  ReminderSettings copyWith({
    bool? waterEnabled,
    int? waterEveryHours,
    bool? lunchEnabled,
    int? lunchHour,
    bool? weightEnabled,
    int? weightHour,
  }) => ReminderSettings(
    waterEnabled: waterEnabled ?? this.waterEnabled,
    waterEveryHours: waterEveryHours ?? this.waterEveryHours,
    lunchEnabled: lunchEnabled ?? this.lunchEnabled,
    lunchHour: lunchHour ?? this.lunchHour,
    weightEnabled: weightEnabled ?? this.weightEnabled,
    weightHour: weightHour ?? this.weightHour,
  );

  Map<String, dynamic> toJson() => {
    'waterEnabled': waterEnabled,
    'waterEveryHours': waterEveryHours,
    'lunchEnabled': lunchEnabled,
    'lunchHour': lunchHour,
    'weightEnabled': weightEnabled,
    'weightHour': weightHour,
  };

  factory ReminderSettings.fromJson(Map<String, dynamic> json) =>
      ReminderSettings(
        waterEnabled: json['waterEnabled'] as bool? ?? false,
        waterEveryHours: (json['waterEveryHours'] as int?)?.clamp(1, 6) ?? 3,
        lunchEnabled: json['lunchEnabled'] as bool? ?? false,
        lunchHour: (json['lunchHour'] as int?)?.clamp(0, 23) ?? 13,
        weightEnabled: json['weightEnabled'] as bool? ?? false,
        weightHour: (json['weightHour'] as int?)?.clamp(0, 23) ?? 8,
      );
}

// Only this version's fields may be re-encoded. A newer profile must not be
// silently truncated by an older client's settings or weight editor.
const Set<String> _knownUserProfileFields = {
  'height',
  'currentWeight',
  'targetWeight',
  'targetWeightConfirmed',
  'heightConfirmed',
  'currentWeightConfirmed',
  'dailyCaloriesMin',
  'dailyCaloriesMax',
  'targetProtein',
  'targetFat',
  'targetCarbs',
  'calorieGoalConfirmed',
  'proteinGoalConfirmed',
  'fatGoalConfirmed',
  'carbsGoalConfirmed',
  // A flag is valid only for the exact values reviewed by the user. A legacy
  // client or an older cloud merger may preserve unknown flags while changing
  // the numbers; these snapshots make that situation fail closed.
  'calorieGoalConfirmedMin',
  'calorieGoalConfirmedMax',
  'proteinGoalConfirmedValue',
  'fatGoalConfirmedValue',
  'carbsGoalConfirmedValue',
  'workoutsPerWeek',
  'strengthDurationMinutes',
  'cardioDurationMinutes',
  'workoutCaloriesBurned',
  'dailyStepsGoal',
  'dailyWaterGoalMl',
  'stepsGoalConfirmed',
  'waterGoalConfirmed',
  'stepsGoalConfirmedValue',
  'waterGoalConfirmedValue',
  'ageYears',
};

class ProfileEditException extends StateError {
  ProfileEditException(super.message);
}

// ============================================================================
// БАЗА ПРОДУКТОВ
// ============================================================================

class FoodItem {
  final String name;
  final double calories;
  final double protein;
  final double fat;
  final double carbs;
  final Map<String, double> micros;
  final String category;
  final String source;
  final String? brand;
  final String? barcode;
  final String? note;
  final String? sourceUrl;
  final String keywords;
  final bool microsEstimated;

  const FoodItem(
    this.name,
    this.calories,
    this.protein,
    this.fat,
    this.carbs, [
    this.micros = const {},
    this.category = 'Основные продукты',
    this.source = 'База Fitness Smart',
    this.brand,
    this.barcode,
    this.note,
    this.sourceUrl,
    this.keywords = '',
    this.microsEstimated = false,
  ]);

  FoodEntry toEntry(double grams, MealType mealType, {DateTime? date}) =>
      FoodEntry(
        name: name,
        caloriesPer100g: calories,
        proteinPer100g: protein,
        fatPer100g: fat,
        carbsPer100g: carbs,
        micros: micros,
        microsEstimated: microsEstimated,
        amountGrams: grams,
        mealType: mealType,
        date: date,
      );
}

class FoodDatabase {
  static const List<FoodItem> commonFoods = [
    // Белки
    FoodItem('Куриная грудка', 165, 31, 3.6, 0),
    FoodItem('Индейка', 189, 29, 7, 0),
    FoodItem('Говядина (постная)', 250, 26, 17, 0),
    FoodItem('Свинина (постная)', 242, 27, 14, 0),
    FoodItem('Рыба белая (треска, минтай)', 82, 18, 0.7, 0),
    FoodItem('Лосось', 208, 20, 13, 0),
    FoodItem('Тунец консервированный', 136, 29, 1, 0),
    FoodItem('Яйцо куриное', 155, 13, 11, 1.1),
    FoodItem('Белок яйца', 52, 11, 0.2, 0.7),
    FoodItem('Творог 0-2%', 72, 16, 0.6, 1.3),
    FoodItem('Творог 5%', 121, 14, 5, 3),
    FoodItem('Творог 9%', 159, 14, 9, 3),
    FoodItem('Йогурт греческий 0%', 59, 10, 0.4, 3.6),
    FoodItem('Кефир 1%', 40, 3, 1, 4),
    FoodItem('Молоко 1.5%', 44, 3, 1.5, 4.8),
    FoodItem('Сыр легкий (до 20%)', 180, 24, 10, 0),
    FoodItem('Протеин сывороточный', 380, 80, 2, 6),
    // Крупы и углеводы
    FoodItem('Овсянка', 342, 12, 6, 59),
    FoodItem('Гречка', 329, 13, 3, 68),
    FoodItem('Рис бурый', 337, 7, 2, 74),
    FoodItem('Киноа', 368, 14, 6, 64),
    FoodItem('Макароны твердых сортов', 344, 13, 1, 69),
    FoodItem('Хлеб цельнозерновой', 247, 9, 3, 41),
    FoodItem('Хлеб белый', 265, 8, 3, 51),
    FoodItem('Лаваш', 236, 8, 1, 49),
    FoodItem('Хрустики рисовые', 380, 8, 1, 82),
    // Овощи
    FoodItem('Брокколи', 34, 2.8, 0.4, 7),
    FoodItem('Цветная капуста', 25, 2, 0.3, 5),
    FoodItem('Шпинат', 23, 2.9, 0.4, 3.6),
    FoodItem('Помидоры', 20, 1, 0.2, 3.9),
    FoodItem('Огурцы', 15, 0.7, 0.1, 3.6),
    FoodItem('Перец сладкий', 27, 1, 0.2, 6),
    FoodItem('Морковь', 41, 0.9, 0.2, 9.6),
    FoodItem('Салат айсберг', 14, 1, 0.2, 3),
    FoodItem('Авокадо', 160, 2, 15, 9),
    FoodItem('Картофель отварной', 87, 2, 0.1, 20),
    FoodItem('Батат', 86, 1.6, 0.1, 20),
    FoodItem('Шампиньоны', 22, 3, 0.3, 3.3),
    // Фрукты
    FoodItem('Яблоко', 52, 0.3, 0.2, 14),
    FoodItem('Банан', 89, 1.1, 0.3, 23),
    FoodItem('Апельсин', 47, 0.9, 0.1, 12),
    FoodItem('Грейпфрут', 42, 0.8, 0.1, 11),
    FoodItem('Ягоды (клубника, черника)', 50, 0.7, 0.3, 12),
    FoodItem('Киви', 61, 1.1, 0.5, 15),
    FoodItem('Ананас', 50, 0.5, 0.1, 13),
    // Жиры
    FoodItem('Оливковое масло', 884, 0, 100, 0),
    FoodItem('Сливочное масло 82%', 748, 0.6, 82, 0.6),
    FoodItem('Миндаль', 579, 21, 49, 22),
    FoodItem('Грецкие орехи', 654, 15, 65, 14),
    FoodItem('Семена чиа', 486, 17, 31, 42),
    FoodItem('Семена льна', 534, 18, 42, 29),
    FoodItem('Арахисовая паста', 588, 25, 50, 20),
    // Бобовые
    FoodItem('Фасоль вареная', 123, 9, 0.5, 22),
    FoodItem('Чечевица', 116, 9, 0.4, 20),
    FoodItem('Нут вареный', 164, 9, 2.6, 27),
    FoodItem('Горох', 81, 5, 0.4, 14),
    // Сыры
    FoodItem('Сыр твердый 45%', 350, 25, 27, 0),
    FoodItem('Моцарелла', 280, 22, 22, 2),
  ];

  /// Cyrillic local catalog first, then regional dairy and generic Cyrillic
  /// staples. English USDA rows are no longer part of the app.
  static List<FoodItem> get allFoods => <FoodItem>[
    ...localCatalogFoods,
    ...regionalDairyFoods,
    ...commonFoods,
  ];

  static List<FoodItem> search(String query) {
    if (query.isEmpty) return allFoods;
    final lower = query.toLowerCase().replaceAll('ё', 'е');
    return allFoods
        .where(
          (f) =>
              f.name.toLowerCase().replaceAll('ё', 'е').contains(lower) ||
              f.keywords.toLowerCase().contains(lower) ||
              (f.brand?.toLowerCase().contains(lower) ?? false),
        )
        .toList();
  }
}

// ============================================================================
// ХРАНИЛИЩЕ
// ============================================================================

// Validate untrusted imports/cloud documents before replacing any local records.
void validateAppDocument(String key, Object? raw) {
  if (!LocalPreferences.appKey(key))
    throw FormatException('Недопустимый ключ $key');
  if (key.startsWith(sleepDayPrefix)) {
    validateSleepDocument(key, raw);
    return;
  }
  if (raw == null) return; // cloud tombstone only
  if (key.startsWith('water_intake_') || key.startsWith('steps_')) {
    if (raw is! int || raw < 0)
      throw FormatException('Некорректное число $key');
    return;
  }
  if (key.startsWith('workout_completed_')) {
    if (raw is! bool) throw FormatException('Некорректный флаг $key');
    return;
  }
  if (raw is! String) throw FormatException('Ожидался JSON-документ $key');
  if (key == gymSettingsKey || key.startsWith(gymSessionPrefix)) {
    validateGymDocument(key, raw);
    return;
  }
  final decoded = jsonDecode(raw);
  void checkFood(Map<String, dynamic> json) {
    final e = FoodEntry.fromJson(json);
    if (e.name.trim().isEmpty ||
        e.amountGrams <= 0 ||
        [
          e.amountGrams,
          e.caloriesPer100g,
          e.proteinPer100g,
          e.fatPer100g,
          e.carbsPer100g,
        ].any((v) => !v.isFinite || v < 0)) {
      throw const FormatException('Некорректный продукт');
    }
    final micros = json['micros'];
    if (micros != null &&
        (micros is! Map ||
            micros.values.any((v) => v is! num || !v.isFinite || v < 0))) {
      throw const FormatException('Некорректные микронутриенты');
    }
  }

  if (key.startsWith('supplement_entries_')) {
    if (decoded is! List || decoded.length > 500) {
      throw const FormatException('Некорректный список добавок');
    }
    final ids = <String>{};
    for (final row in decoded) {
      final entry = SupplementEntry.fromJson(
        Map<String, dynamic>.from(row as Map),
      );
      if (!ids.add(entry.id) ||
          dayKey(entry.date) != key.substring('supplement_entries_'.length)) {
        throw const FormatException(
          'Дата или идентификатор добавки не совпадают',
        );
      }
    }
  } else if (key.startsWith('food_entries_')) {
    for (final row in decoded as List) {
      final json = Map<String, dynamic>.from(row as Map);
      checkFood(json);
      if (dayKey(FoodEntry.fromJson(json).date) != key.substring(13))
        throw const FormatException('Дата продукта не совпадает с дневником');
    }
  } else if (key.startsWith('workout_entries_')) {
    for (final row in decoded as List) {
      final e = WorkoutEntry.fromJson(Map<String, dynamic>.from(row as Map));
      if (e.caloriesBurned < 0 ||
          e.durationMinutes <= 0 ||
          dayKey(e.date) != key.substring(16))
        throw const FormatException('Некорректная тренировка');
    }
  } else if (key == 'user_profile') {
    final p = UserProfile.fromJson(Map<String, dynamic>.from(decoded as Map));
    if (p.height <= 0 ||
        p.currentWeight <= 0 ||
        p.targetWeight <= 0 ||
        !p.height.isFinite ||
        !p.currentWeight.isFinite ||
        !p.targetWeight.isFinite ||
        (p.dailyCaloriesMin != null && p.dailyCaloriesMin! < 0) ||
        (p.dailyCaloriesMax != null && p.dailyCaloriesMax! < 0) ||
        (p.dailyCaloriesMin != null &&
            p.dailyCaloriesMax != null &&
            p.dailyCaloriesMax! < p.dailyCaloriesMin!) ||
        (p.targetProtein != null && p.targetProtein! < 0) ||
        (p.targetFat != null && p.targetFat! < 0) ||
        (p.targetCarbs != null && p.targetCarbs! < 0) ||
        (p.dailyWaterGoalMl != null && p.dailyWaterGoalMl! <= 0) ||
        (p.dailyStepsGoal != null && p.dailyStepsGoal! <= 0)) {
      throw const FormatException('Некорректные цели профиля');
    }
  } else if (key == 'weight_entries') {
    for (final row in decoded as List) {
      final e = WeightEntry.fromJson(Map<String, dynamic>.from(row as Map));
      if (!e.weight.isFinite || e.weight <= 0)
        throw const FormatException('Некорректный вес');
    }
  } else if (key == 'recipes') {
    for (final row in decoded as List) {
      final e = Recipe.fromJson(Map<String, dynamic>.from(row as Map));
      if (e.name.trim().isEmpty ||
          e.servings <= 0 ||
          e.ingredients.isEmpty ||
          (e.cookedWeight != null &&
              (!e.cookedWeight!.isFinite || e.cookedWeight! <= 0)))
        throw const FormatException('Некорректный рецепт');
      for (final ingredient in e.ingredients) {
        checkFood({
          ...ingredient.toJson(),
          'amountGrams': ingredient.grams,
          'mealType': 0,
          'date': DateTime.now().toIso8601String(),
        });
      }
    }
  } else if (key == 'quick_foods') {
    for (final row in decoded as List) {
      final e = QuickFood.fromJson(Map<String, dynamic>.from(row as Map));
      checkFood(e.toEntry(date: DateTime.now()).toJson());
    }
  } else if (key == 'reminders') {
    ReminderSettings.fromJson(Map<String, dynamic>.from(decoded as Map));
  } else if (key == 'smart_settings') {
    final map = Map<String, dynamic>.from(decoded as Map);
    final m = smart.MetabolicSettings.fromJson(map);
    m.baseTarget(80, 175);
    if (map['theme'] != null &&
        !['dark', 'light', 'oled'].contains(map['theme']))
      throw const FormatException('Неизвестная тема');
    if (map['themeFollowSystem'] != null && map['themeFollowSystem'] is! bool)
      throw const FormatException('Некорректная системная тема');
    for (final flag in ['metabolismConfirmed', 'bodyFatConfirmed']) {
      if (map[flag] != null && map[flag] is! bool) {
        throw const FormatException('Некорректное подтверждение расчёта');
      }
    }
    if (map['systemThemeFallback'] != null &&
        !['dark', 'light', 'oled'].contains(map['systemThemeFallback']))
      throw const FormatException('Некорректная резервная тема');
    if (map['accent'] != null && map['accent'] is! int)
      throw const FormatException('Некорректный цвет');
  } else if (key == 'meal_templates') {
    if ((decoded as List).length > 20)
      throw const FormatException('Слишком много шаблонов');
    for (final row in decoded) {
      final map = Map<String, dynamic>.from(row as Map);
      if (map['name'] is! String ||
          (map['name'] as String).trim().isEmpty ||
          (map['entries'] as List).length > 200)
        throw const FormatException('Некорректный набор');
      for (final entry in map['entries'] as List) {
        checkFood(Map<String, dynamic>.from(entry as Map));
      }
    }
  } else if (key == 'custom_foods') {
    for (final row in decoded as List) {
      checkFood({
        ...Map<String, dynamic>.from(row as Map),
        'amountGrams': 100,
        'mealType': 0,
        'date': DateTime.now().toIso8601String(),
      });
    }
  }
}

/// Validates the exact documents accepted by the local importer without
/// modifying storage. A false return means an unknown key; malformed known
/// documents throw, just as they did before this function was extracted.
bool validateBackupDocuments(Map<dynamic, dynamic> data) {
  if (data.keys.any((key) => !LocalPreferences.appKey(key.toString()))) {
    return false;
  }
  for (final entry in data.entries) {
    if (entry.value == null) {
      throw const FormatException('В импорте не допускаются null-документы');
    }
    validateAppDocument(entry.key.toString(), entry.value);
  }
  return true;
}

/// The file-picker import limit is a limit on UTF-8 bytes, not characters.
const int backupFileLimitBytes = 20 * 1024 * 1024;

enum BackupReviewIssue { none, tooLarge, invalid, changedDocuments }

/// This is only a non-mutating preflight for the current file importer. It is
/// not an actual restore, a guarantee of completeness, or an independent copy.
class BackupReview {
  final BackupReviewIssue issue;
  final int utf8Bytes;
  const BackupReview(this.issue, this.utf8Bytes);
  bool get passesFilePreflight => issue == BackupReviewIssue.none;
}

class _BackupByteCounter extends ByteConversionSink {
  int bytes = 0;
  @override
  void add(List<int> chunk) => bytes += chunk.length;
  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    bytes += end - start;
    if (isLast) close();
  }

  @override
  void close() {}
}

/// Count with the same UTF-8 encoder without allocating a second whole file.
int _backupUtf8Bytes(String text) {
  final counter = _BackupByteCounter();
  final sink = utf8.encoder.startChunkedConversion(counter);
  sink.add(text);
  sink.close();
  return counter.bytes;
}

/// Check the bytes that would be shared/copied, including a CSV round-trip
/// against the captured documents when available. Never include record values
/// or caught parser errors in the result or messages.
/// Parse a backup with exactly the importer's rules without touching storage.
/// Returns null for an unrecognized envelope or an unknown document key;
/// malformed known documents throw, just as they do during a real import.
Map<String, dynamic>? parseBackupDocuments(String text, {bool csv = false}) {
  final dynamic decoded = csv
      ? {'app': 'fitness_tracker', 'data': importCsv(text)}
      : jsonDecode(text);
  if (decoded is! Map<String, dynamic> ||
      decoded['app'] != 'fitness_tracker' ||
      decoded['data'] is! Map) {
    return null;
  }
  final data = decoded['data'] as Map;
  if (!validateBackupDocuments(data)) return null;
  return {for (final entry in data.entries) entry.key.toString(): entry.value};
}

BackupReview reviewBackupFile(
  String text, {
  bool csv = false,
  Map<dynamic, dynamic>? expectedDocuments,
}) {
  final bytes = _backupUtf8Bytes(text);
  if (bytes > backupFileLimitBytes) {
    return BackupReview(BackupReviewIssue.tooLarge, bytes);
  }
  try {
    final data = parseBackupDocuments(text, csv: csv);
    if (data == null) return BackupReview(BackupReviewIssue.invalid, bytes);
    if (expectedDocuments != null &&
        jsonEncode(_orderedJson(data)) !=
            jsonEncode(_orderedJson(expectedDocuments))) {
      return BackupReview(BackupReviewIssue.changedDocuments, bytes);
    }
    return BackupReview(BackupReviewIssue.none, bytes);
  } catch (_) {
    return BackupReview(BackupReviewIssue.invalid, bytes);
  }
}

/// A deterministic fingerprint for comparing reviewed content later. Values
/// are never shown to the user through this class.
String documentsFingerprint(Map<dynamic, dynamic> documents) =>
    jsonEncode(_orderedJson(documents));

/// Count-only preview of what an import would change. It deliberately carries
/// neither document keys nor values.
class ImportPreview {
  final int added, changed, deleted, unchanged;
  const ImportPreview({
    required this.added,
    required this.changed,
    required this.deleted,
    required this.unchanged,
  });

  bool get isEmpty => added == 0 && changed == 0 && deleted == 0;

  /// Local records disappear only when the incoming file omits them.
  bool get removesDocuments => deleted > 0;

  String get summary =>
      'Добавлено документов: $added. Изменено: $changed. '
      'Удалено: $deleted. Без изменений: $unchanged.';
}

ImportPreview previewImportDocuments(
  Map<dynamic, dynamic> incoming,
  Map<dynamic, dynamic> current,
) {
  var added = 0, changed = 0, deleted = 0, unchanged = 0;
  for (final entry in incoming.entries) {
    if (!current.containsKey(entry.key)) {
      added++;
    } else if (jsonEncode(_orderedJson(current[entry.key])) ==
        jsonEncode(_orderedJson(entry.value))) {
      unchanged++;
    } else {
      changed++;
    }
  }
  for (final key in current.keys) {
    if (!incoming.containsKey(key)) deleted++;
  }
  return ImportPreview(
    added: added,
    changed: changed,
    deleted: deleted,
    unchanged: unchanged,
  );
}

/// Detects a changed file, diary or account between review and confirmation.
/// Only opaque fingerprints are stored, never the documents themselves.
class ImportReviewGuard {
  final String documents, diary, account;
  const ImportReviewGuard({
    required this.documents,
    required this.diary,
    required this.account,
  });

  String? staleReason({
    required String documents,
    required String diary,
    required String account,
  }) {
    if (this.documents != documents) return 'Файл копии изменился после проверки.';
    if (this.diary != diary) return 'Дневник изменился после проверки.';
    if (this.account != account) return 'Аккаунт изменился после проверки.';
    return null;
  }
}

/// Extra, explicit consent for an import that would remove local documents.
Future<bool> confirmImportRemovals(
  BuildContext context,
  ImportPreview preview,
) async {
  if (!context.mounted || !preview.removesDocuments) return true;
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Удалить локальные записи?'),
          content: Text(
            'Копия не содержит ${preview.deleted} локальных документов. '
            'Они будут удалены вместе с заменой остальных записей.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить и импортировать'),
            ),
          ],
        ),
      ) ??
      false;
}

/// Current local diary as an opaque snapshot for a review guard.
Future<String> currentDiaryFingerprint(AppDataProvider provider) async {
  await provider.storage.pendingMutations;
  return documentsFingerprint(provider.storage.local.snapshot());
}

/// Current sign-in identity plus the local account binding.
String currentImportAccount(AppDataProvider provider) {
  final remote = SmartRemote.instance;
  return '${remote.client?.auth.currentUser?.id ?? ''}'
      '|${provider.storage.local.getString('_bound_user') ?? ''}';
}

class StorageService {
  static const String _foodEntriesKey = 'food_entries';
  static const String _weightEntriesKey = 'weight_entries';
  static const String _workoutEntriesKey = 'workout_entries';
  static const String _userProfileKey = 'user_profile';
  static const String _waterIntakeKey = 'water_intake';
  static const String _stepsKey = 'steps';
  static const String _workoutCompletedKey = 'workout_completed';
  static const String _quickFoodsKey = 'quick_foods';
  static const String _recipesKey = 'recipes';
  static const String _remindersKey = 'reminders';

  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  LocalPreferences? _prefs;
  LocalPreferences get local => _prefs!;

  /// Notifies read-only views only after a gym document is durably written.
  /// The storage service is a singleton, so the notifier lives with it.
  final ValueNotifier<int> gymRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> sleepRevision = ValueNotifier<int>(0);
  Future<void> _mutationTail = Future<void>.value();

  Future<void> get pendingMutations => _mutationTail;

  Future<void> _enqueueMutation(Future<void> Function() action) {
    final store = _prefs;
    final generation = store?.diaryGeneration;
    final submittedDuringImport = LocalPreferences.importInProgress;
    final next = _mutationTail.then((_) {
      // An import/clear may already be queued but not have acquired its gate.
      // A later edit must not replay an old screen's intent against the newly
      // imported diary, even if its document happens to be byte-identical.
      if (submittedDuringImport ||
          !identical(store, _prefs) ||
          store?.diaryGeneration != generation) {
        throw StateError(
          'Дневник заменён или очищен. Обновите экран и повторите изменение.',
        );
      }
      if (store?.hasPendingImport == true) {
        throw const ImportRecoveryRequired();
      }
      return action();
    });
    // A failed operation is returned to its caller, but must not poison the queue.
    _mutationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  Future<void> _writeString(String key, String value) async {
    final prefs = _prefs;
    if (prefs == null || !await prefs.setString(key, value)) {
      throw StateError('Не удалось сохранить дневник');
    }
  }

  Future<void> init() async {
    _prefs = await LocalPreferences.open();
    // Recovery precedes all provider reads and cloud binding. If recovery is
    // impossible (for example, no space), retain the checkpoint and fail closed.
    if (_prefs!.hasPendingImport) await recoverPendingImport();
  }

  String _dateKey(DateTime date) => dayKey(date);

  // --- Еда ---
  List<FoodEntry> _readFoodEntries(DateTime date) {
    final jsonString = _prefs?.getString(
      '${_foodEntriesKey}_${_dateKey(date)}',
    );
    if (jsonString == null) return [];
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list
        .map((e) => FoodEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<FoodEntry>> getFoodEntries(DateTime date) async =>
      _readFoodEntries(date);

  /// Read only existing food documents in the explicit range; never traverse
  /// profile, weights, supplements or any other part of the user's history.
  Future<List<FoodEntry>> getFoodEntriesInRange(
    DateTime first,
    DateTime last, {
    int maxEntries = 60,
  }) async {
    await pendingMutations;
    return _readFoodEntriesInRange(first, last, maxEntries: maxEntries);
  }

  // Synchronous by design: can also run inside the mutation queue with no
  // read/compare/write gap in which another local update could slip in.
  List<FoodEntry> _readFoodEntriesInRange(
    DateTime first,
    DateTime last, {
    required int maxEntries,
  }) {
    final from = dayKey(first), to = dayKey(last);
    if (from.compareTo(to) > 0 || maxEntries < 1) {
      throw ArgumentError('Проверьте выбранный период.');
    }
    final prefix = '${_foodEntriesKey}_';
    final keys =
        (_prefs?.getKeys() ?? <String>{})
            .where((key) => key.startsWith(prefix))
            .toList()
          ..sort();
    final result = <FoodEntry>[];
    for (final key in keys) {
      final raw = key.substring(prefix.length);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw) ||
          raw.compareTo(from) < 0 ||
          raw.compareTo(to) > 0)
        continue;
      final date = DateTime.tryParse(raw);
      if (date == null || dayKey(date) != raw) continue;
      final source = _prefs?.get(key);
      _assertFoodRepresentableForAi(date, source);
      final entries = _safeFoodModels(date, source).entries;
      if (entries.any((entry) => dayKey(entry.date) != raw)) {
        throw StateError('Дата записи не совпадает с датой дневника.');
      }
      result.addAll(entries);
      if (result.length > maxEntries) {
        throw StateError(
          'За период больше $maxEntries записей еды. Выберите более короткий период.',
        );
      }
    }
    return result;
  }

  String _foodDocumentKey(DateTime date) =>
      '${_foodEntriesKey}_${_dateKey(date)}';

  ({List<FoodEntry> entries, List<String> rawRows}) _safeFoodModels(
    DateTime date,
    Object? raw,
  ) {
    final document = safeFoodDocument(
      raw,
      knownMicros: smart.microLabels.keys.toSet(),
    );
    try {
      if (raw != null) validateAppDocument(_foodDocumentKey(date), raw);
      return (
        entries: [for (final row in document.rows) FoodEntry.fromJson(row)],
        rawRows: document.rawRows,
      );
    } on FoodEditException {
      rethrow;
    } catch (_) {
      throw FoodEditException(
        'В дневнике есть некорректные данные. Записи не изменены; '
        'сохраните резервную копию и откройте их в совместимой версии.',
      );
    }
  }

  void _assertFoodRepresentableForAi(DateTime date, Object? raw) {
    final doc = _safeFoodModels(date, raw);
    for (var index = 0; index < doc.entries.length; index++) {
      final source = doc.rawRows[index];
      final model = doc.entries[index];
      final values = model.toJson();
      for (final key in const [
        'caloriesPer100g',
        'proteinPer100g',
        'fatPer100g',
        'carbsPer100g',
        'amountGrams',
      ]) {
        if (!sameJsonNumber(
          rawJsonObjectValue(source, key),
          jsonEncode(values[key]),
        )) {
          throw FoodEditException(
            'Точность старой записи нельзя безопасно представить в анализе ИИ. '
            'Дневник не изменён.',
          );
        }
      }
      final micros = rawJsonObjectValue(source, 'micros');
      if (micros != null && micros != 'null') {
        for (final entry in model.micros.entries) {
          if (!sameJsonNumber(
            rawJsonObjectValue(micros, entry.key),
            jsonEncode(entry.value),
          )) {
            throw FoodEditException(
              'Точность старых нутриентов нельзя безопасно представить в анализе ИИ. '
              'Дневник не изменён.',
            );
          }
        }
      }
      for (final key in const ['date', 'loggedAt']) {
        final token = rawJsonObjectValue(source, key);
        if (token == null || token == 'null') continue;
        final value = jsonDecode(token);
        if (value is String) {
          final extra = RegExp(r'\.[0-9]{6}([0-9]+)').firstMatch(value);
          if (extra != null && extra.group(1)!.contains(RegExp(r'[1-9]'))) {
            throw FoodEditException(
              'Точность старого времени нельзя безопасно представить в анализе ИИ. '
              'Дневник не изменён.',
            );
          }
        }
      }
    }
  }

  Future<void> _commitFoodEntries(
    DateTime date,
    Object? expected,
    List<FoodEntry> entries, {
    bool Function()? authorizationGuard,
  }) async {
    final prefs = _prefs;
    if (prefs == null) throw StateError('Хранилище не открыто');
    final key = _foodDocumentKey(date);
    final original = _safeFoodModels(date, expected);
    final byId = <String, int>{
      for (var i = 0; i < original.entries.length; i++)
        original.entries[i].id: i,
    };
    final seen = <String>{};
    final rawRows = <String>[];
    for (final entry in entries) {
      if (entry.id.trim().isEmpty ||
          !seen.add(entry.id) ||
          dayKey(entry.date) != dayKey(date)) {
        throw FoodEditException('Проверьте идентификаторы и дату записей.');
      }
      final index = byId[entry.id];
      rawRows.add(
        index == null
            ? jsonEncode(entry.toJson())
            : patchFoodRow(
                original.rawRows[index],
                original.entries[index].toJson(),
                entry.toJson(),
              ),
      );
    }
    final next = '[${rawRows.join(',')}]';
    _safeFoodModels(date, next);
    if (!await prefs.compareAndPut(
      key,
      expected,
      next,
      authorizationGuard: authorizationGuard,
    )) {
      throw FoodEditException(
        'Дневник за этот день изменился. Обновите его и проверьте изменения.',
      );
    }
  }

  /// Compatibility bulk write; unlike the single-entry editors it cannot
  /// identify a list that was already stale before this method was called.
  Future<void> saveFoodEntries(DateTime date, List<FoodEntry> entries) {
    final expected = _prefs?.get(_foodDocumentKey(date));
    final frozen = entries.map(_freezeFood).toList();
    return _enqueueMutation(() => _commitFoodEntries(date, expected, frozen));
  }

  /// All reviewed changes for one day use one write. Originals are compared in
  /// the same mutation queue immediately before committing, so stale AI
  /// proposals cannot overwrite a user's intervening edits or delete new data.
  Future<void> applyReviewedFoodChanges({
    required DateTime date,
    required Map<String, FoodEntry> expected,
    required Map<String, FoodEntry?> changes,
    required List<FoodEntry> additions,
    FoodRangeSnapshot? expectedRange,
    bool Function()? authorizationGuard,
  }) {
    // Nothing mutable from a review dialog may change while queued.
    final originals = {
      for (final e in expected.entries) e.key: _freezeFood(e.value),
    };
    final replacements = {
      for (final e in changes.entries)
        e.key: e.value == null ? null : _freezeFood(e.value!),
    };
    final added = additions.map(_freezeFood).toList();
    return _enqueueMutation(() async {
      if (authorizationGuard != null && !authorizationGuard()) {
        throw StateError(
          'Доступ к предложениям изменился. Ничего не применено.',
        );
      }
      if (originals.length != replacements.length ||
          originals.keys.any((id) => !replacements.containsKey(id)) ||
          originals.length + added.length > 30 ||
          (originals.isEmpty && added.isEmpty)) {
        throw ArgumentError('Проверьте выбранные изменения.');
      }
      final day = dayKey(date);
      if (originals.entries.any(
            (e) => e.key != e.value.id || dayKey(e.value.date) != day,
          ) ||
          replacements.entries.any(
            (e) =>
                e.value != null &&
                (e.key != e.value!.id || dayKey(e.value!.date) != day),
          ) ||
          added.any((e) => dayKey(e.date) != day)) {
        throw ArgumentError('Изменения должны относиться к одному дню.');
      }
      bool sameRange() {
        if (expectedRange == null) return true;
        final from = dayKey(expectedRange.firstDay),
            to = dayKey(expectedRange.lastDay);
        if (day.compareTo(from) < 0 || day.compareTo(to) > 0) {
          throw ArgumentError('День изменения находится вне периода анализа.');
        }
        final actual = _readFoodEntriesInRange(
          expectedRange.firstDay,
          expectedRange.lastDay,
          maxEntries: FoodRangeSnapshot.maxEntries,
        );
        return actual.length == expectedRange.entries.length &&
            List.generate(actual.length, (i) => i).every(
              (i) => sameFoodSnapshot(actual[i], expectedRange.entries[i]),
            );
      }

      if (!sameRange()) {
        throw StateError(
          'Дневник за выбранный период изменился после анализа. Ничего не применено; повторите анализ.',
        );
      }
      final prefs = _prefs;
      if (prefs == null) throw StateError('Хранилище не открыто');
      final raw = prefs.get(_foodDocumentKey(date));
      _assertFoodRepresentableForAi(date, raw);
      final current = _safeFoodModels(date, raw).entries;
      final byId = {for (final entry in current) entry.id: entry};
      for (final item in originals.entries) {
        final actual = byId[item.key];
        if (actual == null || !sameFoodSnapshot(actual, item.value)) {
          throw StateError(
            'Одна из записей изменилась после анализа. Ничего не применено; обновите анализ.',
          );
        }
      }
      final ids = byId.keys.toSet();
      for (final entry in added) {
        if (!ids.add(entry.id)) {
          throw StateError(
            'Новая запись уже существует. Повторная запись остановлена.',
          );
        }
      }
      final result = <FoodEntry>[];
      for (final entry in current) {
        if (!replacements.containsKey(entry.id)) {
          result.add(entry);
        } else if (replacements[entry.id] != null) {
          result.add(replacements[entry.id]!);
        }
      }
      result.addAll(added);
      String? denied;
      bool guard() {
        if (authorizationGuard != null && !authorizationGuard()) {
          denied = 'Доступ к предложениям изменился. Ничего не применено.';
          return false;
        }
        if (!sameRange()) {
          denied =
              'Дневник за выбранный период изменился после анализа. Ничего не применено; повторите анализ.';
          return false;
        }
        return true;
      }

      try {
        await _commitFoodEntries(date, raw, result, authorizationGuard: guard);
      } on StateError {
        if (denied != null) throw StateError(denied!);
        rethrow;
      }
    });
  }

  Future<void> addFoodEntry(FoodEntry entry) => addFoodBatch([entry]);

  /// A single durable day-document write; identical IDs are idempotent only
  /// when they also carry the same data.
  Future<void> addFoodBatch(
    List<FoodEntry> batch, {
    bool Function()? authorizationGuard,
  }) {
    final frozen = batch.map(_freezeFood).toList();
    return _enqueueMutation(() async {
      if (frozen.isEmpty) return;
      if (authorizationGuard != null && !authorizationGuard()) {
        throw StateError(
          'Аккаунт или согласие изменились. Ничего не добавлено.',
        );
      }
      final date = frozen.first.date;
      if (frozen.any((e) => dayKey(e.date) != dayKey(date))) {
        throw ArgumentError('Выберите один день для всех продуктов');
      }
      final prefs = _prefs;
      if (prefs == null) throw StateError('Хранилище не открыто');
      final raw = prefs.get(_foodDocumentKey(date));
      final entries = _safeFoodModels(date, raw).entries;
      final byId = {for (final entry in entries) entry.id: entry};
      var changed = false;
      for (final entry in frozen) {
        final existing = byId[entry.id];
        if (existing != null) {
          if (!sameFoodSnapshot(existing, entry)) {
            throw FoodEditException(
              'Идентификатор уже относится к другой записи. Ничего не добавлено.',
            );
          }
        } else {
          byId[entry.id] = entry;
          entries.add(entry);
          changed = true;
        }
      }
      if (changed) {
        await _commitFoodEntries(
          date,
          raw,
          entries,
          authorizationGuard: authorizationGuard,
        );
      }
    });
  }

  Future<void> undoFoodBatch(
    List<FoodEntry> original, {
    bool Function()? authorizationGuard,
  }) {
    final frozen = original.map(_freezeFood).toList();
    return _enqueueMutation(() async {
      if (authorizationGuard != null && !authorizationGuard()) {
        throw StateError('Дневник или доступ изменились. Отмена остановлена.');
      }
      if (frozen.isEmpty) return;
      final date = frozen.first.date;
      if (frozen.any((e) => dayKey(e.date) != dayKey(date))) {
        throw ArgumentError('Отмена должна относиться к одному дню');
      }
      final prefs = _prefs;
      if (prefs == null) throw StateError('Хранилище не открыто');
      final raw = prefs.get(_foodDocumentKey(date));
      _assertFoodRepresentableForAi(date, raw);
      final current = _safeFoodModels(date, raw).entries;
      final expected = {for (final e in frozen) e.id: e};
      for (final e in current) {
        if (expected.containsKey(e.id) &&
            !sameFoodSnapshot(e, expected[e.id]!)) {
          throw StateError(
            'Один из продуктов уже изменён. Автоматическая отмена остановлена, чтобы не удалить ваши правки. Удалите нужные записи вручную.',
          );
        }
      }
      current.removeWhere((e) => expected.containsKey(e.id));
      await _commitFoodEntries(
        date,
        raw,
        current,
        authorizationGuard: authorizationGuard,
      );
    });
  }

  Future<void> updateFoodEntry(FoodEntry entry, {FoodEditSnapshot? snapshot}) {
    final frozen = _freezeFood(entry);
    return _enqueueMutation(() async {
      final prefs = _prefs;
      if (prefs == null) throw StateError('Хранилище не открыто');
      final raw = prefs.get(_foodDocumentKey(frozen.date));
      if (snapshot != null &&
          (snapshot.day != dayKey(frozen.date) ||
              snapshot.entryId != frozen.id ||
              snapshot.document != raw)) {
        throw FoodEditException(
          'Дневник изменился. Закройте редактор и откройте запись заново.',
        );
      }
      final entries = _safeFoodModels(frozen.date, raw).entries;
      final index = entries.indexWhere((e) => e.id == frozen.id);
      if (index < 0 ||
          (snapshot != null &&
              jsonEncode(_orderedJson(entries[index].toJson())) !=
                  snapshot.fingerprint)) {
        throw FoodEditException(
          'Продукт изменился или уже удалён. Откройте запись заново.',
        );
      }
      entries[index] = frozen;
      await _commitFoodEntries(frozen.date, raw, entries);
    });
  }

  Future<void> deleteFoodEntry(
    String id,
    DateTime date, {
    FoodEditSnapshot? snapshot,
  }) => removeFoodEntries({id}, date, snapshot: snapshot);

  Future<void> removeFoodEntries(
    Set<String> ids,
    DateTime date, {
    FoodEditSnapshot? snapshot,
    FoodDaySnapshot? daySnapshot,
  }) => _enqueueMutation(() async {
    final prefs = _prefs;
    if (prefs == null) throw StateError('Хранилище не открыто');
    final raw = prefs.get(_foodDocumentKey(date));
    if (daySnapshot != null &&
        (daySnapshot.day != dayKey(date) || daySnapshot.document != raw)) {
      throw FoodEditException(
        'Дневник изменился. Повторите очистку после проверки.',
      );
    }
    if (snapshot != null &&
        (snapshot.day != dayKey(date) ||
            !ids.contains(snapshot.entryId) ||
            snapshot.document != raw)) {
      throw FoodEditException('Дневник изменился. Откройте запись заново.');
    }
    final entries = _safeFoodModels(date, raw).entries;
    if (daySnapshot != null &&
        (entries.length != daySnapshot.fingerprints.length ||
            entries.any(
              (e) =>
                  jsonEncode(_orderedJson(e.toJson())) !=
                  daySnapshot.fingerprints[e.id],
            ))) {
      throw FoodEditException(
        'Дневник изменился. Повторите очистку после проверки.',
      );
    }
    if (snapshot != null) {
      final found = entries.where((e) => e.id == snapshot.entryId).toList();
      if (found.length != 1 ||
          jsonEncode(_orderedJson(found.single.toJson())) !=
              snapshot.fingerprint) {
        throw FoodEditException(
          'Продукт изменился или уже удалён. Откройте запись заново.',
        );
      }
    }
    entries.removeWhere((e) => ids.contains(e.id));
    await _commitFoodEntries(date, raw, entries);
  });

  // --- Витамины и добавки: отдельные записи, не калории еды ---
  String _supplementKey(DateTime date) =>
      'supplement_entries_${_dateKey(date)}';

  Future<List<SupplementEntry>> getSupplementEntries(DateTime date) async {
    final raw = _prefs?.getString(_supplementKey(date));
    if (raw == null) return [];
    final rows = jsonDecode(raw);
    if (rows is! List) throw const FormatException('Некорректные добавки');
    return rows
        .map(
          (e) => SupplementEntry.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList();
  }

  Future<void> addSupplementBatch(
    List<SupplementEntry> batch, {
    bool Function()? authorizationGuard,
  }) => _enqueueMutation(() async {
    if (batch.isEmpty) return;
    if (authorizationGuard != null && !authorizationGuard()) {
      throw StateError(
        'Аккаунт, согласие или дневник изменились. Запись отменена.',
      );
    }
    if (batch.length > 30 ||
        batch.any((e) => dayKey(e.date) != dayKey(batch.first.date))) {
      throw ArgumentError('Выберите один день для всех добавок');
    }
    for (final entry in batch) {
      SupplementEntry.fromJson(entry.toJson());
    }
    final prefs = _prefs;
    if (prefs == null) throw StateError('Хранилище не открыто');
    final key = _supplementKey(batch.first.date);
    final original = prefs.get(key);
    final rows = await getSupplementEntries(batch.first.date);
    final ids = rows.map((e) => e.id).toSet();
    for (final entry in batch) {
      if (ids.add(entry.id)) rows.add(entry);
    }
    if (rows.length > 500) throw StateError('Слишком много добавок за день');
    final updated = jsonEncode(rows.map((e) => e.toJson()).toList());
    if (authorizationGuard == null) {
      await _writeString(key, updated);
    } else {
      final changed = await prefs.compareAndPut(
        key,
        original,
        updated,
        authorizationGuard: authorizationGuard,
      );
      if (!changed) {
        throw StateError('Записи добавок изменились. Проверьте их заново.');
      }
    }
  });

  Future<void> updateSupplementEntry(SupplementEntry entry) =>
      _enqueueMutation(() async {
        SupplementEntry.fromJson(entry.toJson());
        final rows = await getSupplementEntries(entry.date);
        final index = rows.indexWhere((e) => e.id == entry.id);
        if (index < 0)
          throw StateError(
            'Запись добавки уже удалена или относится к другому дню',
          );
        rows[index] = entry;
        await _writeString(
          _supplementKey(entry.date),
          jsonEncode(rows.map((e) => e.toJson()).toList()),
        );
      });

  Future<void> deleteSupplementEntry(String id, DateTime date) =>
      _enqueueMutation(() async {
        final rows = await getSupplementEntries(date);
        rows.removeWhere((e) => e.id == id);
        await _writeString(
          _supplementKey(date),
          jsonEncode(rows.map((e) => e.toJson()).toList()),
        );
      });

  // --- Вес ---
  Future<List<WeightEntry>> getWeightEntries() async {
    final jsonString = _prefs?.getString(_weightEntriesKey);
    if (jsonString == null) return [];
    final rows = jsonDecode(jsonString) as List<dynamic>;
    // Multiple measurements may share a timestamp (e.g. a date picker sets
    // midnight). Preserve document order to make the last one deterministic.
    final indexed = [
      for (var i = 0; i < rows.length; i++)
        (
          index: i,
          entry: WeightEntry.fromJson(
            Map<String, dynamic>.from(rows[i] as Map),
          ),
        ),
    ];
    indexed.sort((a, b) {
      final byDate = a.entry.date.compareTo(b.entry.date);
      return byDate != 0 ? byDate : a.index.compareTo(b.index);
    });
    return [for (final row in indexed) row.entry];
  }

  int? _latestWeightIndex(List<Map<String, dynamic>> rows) {
    int? index;
    DateTime? latest;
    for (var i = 0; i < rows.length; i++) {
      final date = DateTime.parse(rows[i]['date'] as String);
      // The last row wins only when timestamps are identical.
      if (latest == null || !date.isBefore(latest)) {
        latest = date;
        index = i;
      }
    }
    return index;
  }

  /// Conditional single-item edit. Unknown fields in *any* row block a rewrite
  /// of this shared document. The original history is never reconstructed from
  /// model objects, so unaffected raw rows retain their data and precision.
  Future<WeightChangeResult> writeWeightChange(
    WeightEditSnapshot snapshot,
    WeightEntry? next,
  ) async {
    if (next != null &&
        (!next.weight.isFinite || next.weight <= 0 || next.weight > 300)) {
      throw const WeightEditException(
        'Введите вес больше 0 и не более 300 кг.',
      );
    }
    final frozen = next == null
        ? null
        : Map<String, dynamic>.from(next.toJson());
    WeightChangeResult? result;
    await _enqueueMutation(() async {
      final prefs = _prefs;
      if (prefs == null)
        throw const WeightEditException('Хранилище не открыто.');
      if (prefs.get(_weightEntriesKey) != snapshot.document) {
        throw const WeightEditException(
          'История веса изменилась. Закройте редактор и откройте запись заново.',
        );
      }
      final document = safeWeightDocument(snapshot.document);
      final rows = document.rows;
      final rawRows = document.rawRows;
      try {
        if (snapshot.document != null)
          validateAppDocument(_weightEntriesKey, snapshot.document);
      } catch (_) {
        throw const WeightEditException(
          'Историю веса не удалось проверить. Данные не изменены.',
        );
      }
      final previousLatestIndex = _latestWeightIndex(rows);
      final previousLatestWeight = previousLatestIndex == null
          ? null
          : rawJsonObjectValue(rawRows[previousLatestIndex], 'weight');
      final id = snapshot.entryId;
      if (id == null) {
        if (frozen == null || rows.any((row) => row['id'] == frozen['id'])) {
          throw const WeightEditException(
            'Измерение уже существует или не указано.',
          );
        }
        rows.add(frozen);
        rawRows.add(jsonEncode(frozen));
      } else {
        final matches = <int>[
          for (var i = 0; i < rows.length; i++)
            if (rows[i]['id'] == id) i,
        ];
        if (matches.length != 1 ||
            _weightFingerprint(WeightEntry.fromJson(rows[matches.single])) !=
                snapshot.fingerprint) {
          throw const WeightEditException(
            'Измерение изменилось или удалено. Откройте его заново.',
          );
        }
        if (frozen == null) {
          rows.removeAt(matches.single);
          rawRows.removeAt(matches.single);
        } else {
          if (frozen['id'] != id)
            throw const WeightEditException(
              'Идентификатор измерения изменился.',
            );
          rawRows[matches.single] = patchWeightRow(
            rawRows[matches.single],
            rows[matches.single],
            frozen,
          );
          rows[matches.single] = frozen;
        }
      }
      final raw = '[${rawRows.join(',')}]';
      try {
        safeWeightRows(raw);
        validateAppDocument(_weightEntriesKey, raw);
      } catch (_) {
        throw const WeightEditException('Проверьте вес, дату и примечание.');
      }
      if (!await prefs.compareAndPut(
        _weightEntriesKey,
        snapshot.document,
        raw,
      )) {
        throw const WeightEditException(
          'История веса изменилась. Закройте редактор и откройте запись заново.',
        );
      }

      // Profile is a separate document. A failure after the history write is a
      // *partial success*, never an invitation to add the same record again.
      final action = frozen == null
          ? 'Измерение удалено'
          : 'Измерение сохранено';
      final latestIndex = _latestWeightIndex(rows);
      if (latestIndex == null) {
        result = WeightChangeResult(
          warning:
              '$action. Текущий вес в профиле не изменён; проверьте настройки.',
        );
        return;
      }
      try {
        final profileRaw = prefs.get(_userProfileKey);
        if (profileRaw != null && profileRaw is! String) {
          throw const FormatException('profile');
        }
        final profileSource = profileRaw as String? ?? '{}';
        final profileMap = uniqueJsonObject(profileSource);
        if (profileRaw != null)
          validateAppDocument(_userProfileKey, profileRaw);
        // Unknown or duplicate profile fields cannot safely be rewritten.
        if (profileMap.keys.any(
          (key) => !_knownUserProfileFields.contains(key),
        )) {
          throw const FormatException('Future profile fields');
        }
        final current = profileRaw == null
            ? const UserProfile()
            : UserProfile.fromJson(profileMap);
        final profileWeight = rawJsonObjectValue(
          profileSource,
          'currentWeight',
        );
        final latestWeight = rawJsonObjectValue(rawRows[latestIndex], 'weight');
        if (latestWeight == null) throw const FormatException('weight');
        // Exact numeric comparison matters: two different stored decimals may
        // become the same double on web. Preserve an independent value.
        final canUpdate =
            !profileMap.containsKey('currentWeight') ||
            current.currentWeightConfirmed == false ||
            sameJsonNumber(profileWeight, previousLatestWeight);
        if (!canUpdate) {
          result = WeightChangeResult(
            warning:
                '$action. Текущий вес в профиле оставлен без изменения: он отличается от истории. Проверьте настройки.',
          );
          return;
        }
        final sameWeight = sameJsonNumber(profileWeight, latestWeight);
        if (sameWeight && current.currentWeightConfirmed == true) {
          result = const WeightChangeResult();
          return;
        }
        final nextProfile = patchJsonObjectRaw(profileSource, {
          if (!sameWeight) 'currentWeight': latestWeight,
          if (current.currentWeightConfirmed != true)
            'currentWeightConfirmed': 'true',
        });
        validateAppDocument(_userProfileKey, nextProfile);
        if (!await prefs.compareAndPut(
          _userProfileKey,
          profileRaw,
          nextProfile,
        )) {
          throw StateError('Profile changed');
        }
        result = const WeightChangeResult();
      } catch (_) {
        result = WeightChangeResult(
          warning:
              '$action, но текущий вес в профиле не обновился. Проверьте настройки.',
        );
      }
    });
    return result!;
  }

  /// Compatibility bulk replacement. Existing callers should prefer the
  /// single-item editor: a list captured before this method is called cannot
  /// prove which changes happened in the meantime.
  Future<void> saveWeightEntries(List<WeightEntry> entries) async {
    final prefs = _prefs;
    if (prefs == null) throw StateError('Хранилище не открыто');
    final expected = prefs.get(_weightEntriesKey);
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await _enqueueMutation(() async {
      safeWeightRows(expected);
      safeWeightRows(raw);
      validateAppDocument(_weightEntriesKey, raw);
      if (!await prefs.compareAndPut(_weightEntriesKey, expected, raw)) {
        throw const WeightEditException(
          'История веса изменилась. Повторите после обновления.',
        );
      }
    });
  }

  // Compatibility wrappers protect the document after invocation; callers
  // holding an old item should pass an explicit snapshot to writeWeightChange.
  Future<void> addWeightEntry(WeightEntry entry) async {
    await writeWeightChange(
      WeightEditSnapshot(_prefs?.get(_weightEntriesKey), null),
      entry,
    );
  }

  Future<void> updateWeightEntry(WeightEntry entry) async {
    final original = (await getWeightEntries())
        .where((e) => e.id == entry.id)
        .firstOrNull;
    if (original == null)
      throw const WeightEditException('Измерение уже удалено.');
    await writeWeightChange(
      WeightEditSnapshot(_prefs?.get(_weightEntriesKey), original),
      entry,
    );
  }

  Future<void> deleteWeightEntry(String id) async {
    final original = (await getWeightEntries())
        .where((e) => e.id == id)
        .firstOrNull;
    if (original == null)
      throw const WeightEditException('Измерение уже удалено.');
    await writeWeightChange(
      WeightEditSnapshot(_prefs?.get(_weightEntriesKey), original),
      null,
    );
  }

  /// Per-session optimistic write: never overwrite an intervening edit or sync.
  /// Deletions also compare the exact prior document and are confirmed in UI.
  Future<void> writeGymDocument(String key, String? expected, String? next) =>
      _enqueueMutation(() async {
        if (!(key == gymSettingsKey ||
            RegExp(r'^gym_session_[a-zA-Z0-9_-]{1,80}$').hasMatch(key))) {
          throw ArgumentError('Недопустимый ключ тренировки');
        }
        validateAppDocument(key, next);
        final prefs = _prefs;
        if (prefs == null) throw StateError('Хранилище не открыто');
        if (prefs.getString(key) != expected) {
          throw StateError(
            'Запись изменилась на другом устройстве. Обновите экран.',
          );
        }
        if (next == null) {
          await prefs.remove(key);
        } else {
          await _writeString(key, next);
        }
        gymRevision.value++;
      });

  /// One day of self-reported sleep. The exact pre-edit string is checked in
  /// the shared per-key queue used by sleep sync pulls and conflict choices.
  Future<void> writeSleepDocument(String key, String? expected, String? next) =>
      _enqueueMutation(() async {
        if (!key.startsWith(sleepDayPrefix)) {
          throw ArgumentError('Недопустимый ключ сна');
        }
        validateSleepDocument(key, next);
        final prefs = _prefs;
        if (prefs == null) throw StateError('Хранилище не открыто');
        if (!await prefs.compareAndPut(key, expected, next)) {
          throw StateError('Запись сна изменилась. Проверьте её заново.');
        }
        sleepRevision.value++;
      });

  // --- Тренировки ---
  Future<List<WorkoutEntry>> getWorkoutEntries(DateTime date) async {
    final jsonString = _prefs?.getString(
      '${_workoutEntriesKey}_${_dateKey(date)}',
    );
    if (jsonString == null) return [];
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list
        .map((e) => WorkoutEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveWorkoutEntries(
    DateTime date,
    List<WorkoutEntry> entries,
  ) async {
    final jsonString = jsonEncode(entries.map((e) => e.toJson()).toList());
    await _writeString('${_workoutEntriesKey}_${_dateKey(date)}', jsonString);
  }

  /// The day document and its completion flag must succeed or fail together
  /// locally. Cloud synchronization still sends documents independently.
  Future<void> _writeWorkoutEntriesAndCompletion(
    DateTime date,
    List<WorkoutEntry> entries,
  ) async {
    final prefs = _prefs;
    if (prefs == null) throw StateError('Хранилище не открыто');
    final day = _dateKey(date);
    final encoded = jsonEncode(entries.map((e) => e.toJson()).toList());
    if (!await prefs.putBatch({
      '${_workoutEntriesKey}_$day': encoded,
      '${_workoutCompletedKey}_$day': entries.isNotEmpty,
    })) {
      throw StateError('Не удалось сохранить тренировку');
    }
  }

  Future<void> addWorkoutEntry(WorkoutEntry entry) =>
      _enqueueMutation(() async {
        final entries = await getWorkoutEntries(entry.date);
        if (!entries.any((e) => e.id == entry.id)) entries.add(entry);
        await _writeWorkoutEntriesAndCompletion(entry.date, entries);
      });

  Future<void> updateWorkoutEntry(WorkoutEntry entry) =>
      _enqueueMutation(() async {
        final entries = await getWorkoutEntries(entry.date);
        final index = entries.indexWhere((e) => e.id == entry.id);
        if (index < 0) throw StateError('Тренировка уже удалена');
        entries[index] = entry;
        await saveWorkoutEntries(entry.date, entries);
      });

  Future<void> deleteWorkoutEntry(String id, DateTime date) =>
      _enqueueMutation(() async {
        final entries = await getWorkoutEntries(date);
        entries.removeWhere((e) => e.id == id);
        await _writeWorkoutEntriesAndCompletion(date, entries);
      });

  // --- Профиль ---
  Future<UserProfile> getUserProfile() async {
    final jsonString = _prefs?.getString(_userProfileKey);
    if (jsonString == null) return UserProfile();
    return UserProfile.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
  }

  Future<void> saveUserProfile(
    UserProfile profile, {
    UserProfile? expectedProfile,
  }) async {
    final prefs = _prefs;
    if (prefs == null) throw StateError('Хранилище не открыто');
    final previous = prefs.get(_userProfileKey);
    late final String profileSource;
    late final Map<String, dynamic> decoded;
    late final UserProfile actual;
    try {
      if (previous != null && previous is! String) {
        throw const FormatException();
      }
      profileSource = previous as String? ?? '{}';
      if (previous != null) validateAppDocument(_userProfileKey, previous);
      decoded = uniqueJsonObject(profileSource);
      if (decoded.keys.any((key) => !_knownUserProfileFields.contains(key))) {
        throw const FormatException();
      }
      actual = previous == null
          ? const UserProfile()
          : UserProfile.fromJson(decoded);
    } catch (_) {
      throw ProfileEditException(
        'Профиль содержит данные неизвестного или повреждённого формата. '
        'Изменения не сохранены; сначала сохраните резервную копию и '
        'откройте профиль в совместимой версии приложения.',
      );
    }
    if (expectedProfile != null &&
        jsonEncode(_orderedJson(actual.toJson())) !=
            jsonEncode(_orderedJson(expectedProfile.toJson()))) {
      throw ProfileEditException(
        'Профиль изменился на этом устройстве. Обновите данные и '
        'проверьте изменение перед сохранением.',
      );
    }
    final before = actual.toJson();
    final after = profile.toJson();
    final changes = <String, dynamic>{};
    for (final key in _knownUserProfileFields) {
      if (before[key] != after[key]) changes[key] = after[key];
    }
    // Explicit null distinguishes a new client's age removal from an old
    // client that does not know the field in the compatibility RPC.
    if (!decoded.containsKey('ageYears'))
      changes['ageYears'] = profile.ageYears;
    // Each new-client write states all goal flags explicitly. This prevents a
    // cloud compatibility merge from restoring a remote confirmation after the
    // user imported an older, unconfirmed backup. Viewing alone never writes.
    for (final flag in const [
      'calorieGoalConfirmed',
      'proteinGoalConfirmed',
      'fatGoalConfirmed',
      'carbsGoalConfirmed',
      'stepsGoalConfirmed',
      'waterGoalConfirmed',
    ]) {
      final confirmed = after[flag] == true;
      if (changes.containsKey(flag) || decoded[flag] != confirmed) {
        changes[flag] = confirmed;
      }
    }
    // Confirming a value equal to an internal default still needs an explicit
    // stored measurement; a flag alone must never invent a measurement.
    for (final pair in const {
      'heightConfirmed': 'height',
      'currentWeightConfirmed': 'currentWeight',
      'targetWeightConfirmed': 'targetWeight',
    }.entries) {
      if (after[pair.key] == true && !decoded.containsKey(pair.value)) {
        changes[pair.value] = after[pair.value];
      }
    }
    final encoded = patchJsonObject(profileSource, changes);
    validateAppDocument(_userProfileKey, encoded);
    if (!await prefs.compareAndPut(_userProfileKey, previous, encoded)) {
      throw ProfileEditException(
        'Профиль изменился во время сохранения. Обновите данные и '
        'проверьте изменение перед повтором.',
      );
    }
  }

  // --- Вода ---
  Future<int> getWaterIntake(DateTime date) async =>
      _prefs?.getInt('${_waterIntakeKey}_${_dateKey(date)}') ?? 0;

  Future<void> _writeWater(DateTime date, int ml) async {
    final prefs = _prefs;
    if (prefs == null ||
        !await prefs.setInt('${_waterIntakeKey}_${_dateKey(date)}', ml)) {
      throw StateError('Не удалось сохранить воду');
    }
  }

  Future<void> setWaterIntake(DateTime date, int ml) =>
      _enqueueMutation(() => _writeWater(date, ml));

  Future<void> addWaterIntake(DateTime date, int ml) =>
      _enqueueMutation(() async {
        final current = await getWaterIntake(date);
        await _writeWater(date, current + ml);
      });

  // --- Шаги ---
  Future<int> getSteps(DateTime date) async =>
      _prefs?.getInt('${_stepsKey}_${_dateKey(date)}') ?? 0;

  Future<void> _writeSteps(DateTime date, int steps) async {
    if (steps < 0)
      throw ArgumentError('Количество шагов не может быть отрицательным');
    final prefs = _prefs;
    if (prefs == null ||
        !await prefs.setInt('${_stepsKey}_${_dateKey(date)}', steps)) {
      throw StateError('Не удалось сохранить шаги');
    }
  }

  Future<void> setSteps(DateTime date, int steps) =>
      _enqueueMutation(() => _writeSteps(date, steps));

  Future<void> addSteps(DateTime date, int steps) => _enqueueMutation(() async {
    if (steps < 0)
      throw ArgumentError('Количество шагов не может быть отрицательным');
    final current = await getSteps(date);
    await _writeSteps(date, current + steps);
  });

  // --- Тренировка выполнена ---
  Future<bool> isWorkoutCompleted(DateTime date) async =>
      _prefs?.getBool('${_workoutCompletedKey}_${_dateKey(date)}') ?? false;

  Future<void> setWorkoutCompleted(DateTime date, bool completed) async {
    final prefs = _prefs;
    if (prefs == null ||
        !await prefs.setBool(
          '${_workoutCompletedKey}_${_dateKey(date)}',
          completed,
        )) {
      throw StateError('Не удалось сохранить отметку тренировки');
    }
  }

  // --- Быстрые продукты и избранное ---
  Future<List<QuickFood>> getQuickFoods() async {
    final jsonString = _prefs?.getString(_quickFoodsKey);
    if (jsonString == null) return [];
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list
        .map((e) => QuickFood.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveQuickFoods(List<QuickFood> foods) async {
    final jsonString = jsonEncode(foods.map((f) => f.toJson()).toList());
    await _prefs?.setString(_quickFoodsKey, jsonString);
  }

  // --- Рецепты ---
  Future<List<Recipe>> getRecipes() async {
    final jsonString = _prefs?.getString(_recipesKey);
    if (jsonString == null) return [];
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list.map((e) => Recipe.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Edit just one item of the existing list. Unknown/future fields block the
  /// rewrite rather than being discarded by Recipe.fromJson/toJson.
  Future<void> writeRecipeChange(RecipeEditSnapshot snapshot, Recipe? next) {
    // Freeze nested ingredient lists/maps before entering an asynchronous queue.
    final frozen = next == null
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(jsonEncode(next.toJson())) as Map,
          );
    return _enqueueMutation(() async {
      final prefs = _prefs;
      if (prefs == null) {
        throw const RecipeEditException('Хранилище не открыто.');
      }
      if (prefs.get(_recipesKey) != snapshot.document) {
        throw const RecipeEditException(
          'Список рецептов изменился. Закройте редактор и откройте рецепт заново.',
        );
      }
      final rows = safeRecipeRows(snapshot.document);
      try {
        if (snapshot.document != null) {
          validateAppDocument(_recipesKey, snapshot.document);
        }
      } catch (_) {
        throw const RecipeEditException(
          'Существующие рецепты не удалось проверить. Данные не изменены.',
        );
      }
      if (frozen != null) {
        try {
          final candidate = Recipe.fromJson(frozen);
          final totals = [
            candidate.totalGrams,
            candidate.outputWeight,
            candidate.totalCalories,
            candidate.totalProtein,
            candidate.totalFat,
            candidate.totalCarbs,
            candidate.caloriesPer100g,
            candidate.proteinPer100g,
            candidate.fatPer100g,
            candidate.carbsPer100g,
            ...candidate.microsPer100g.values,
          ];
          if (totals.any((value) => !value.isFinite)) {
            throw const FormatException('Non-finite recipe totals');
          }
        } catch (_) {
          throw const RecipeEditException(
            'Не удалось рассчитать рецепт. Проверьте массы и пищевые значения.',
          );
        }
      }
      final id = snapshot.recipeId;
      if (id == null) {
        if (frozen == null || rows.any((row) => row['id'] == frozen['id'])) {
          throw const RecipeEditException(
            'Рецепт уже существует или не указан.',
          );
        }
        rows.add(frozen);
      } else {
        final matches = <int>[
          for (var i = 0; i < rows.length; i++)
            if (rows[i]['id'] == id) i,
        ];
        if (matches.length != 1 ||
            _recipeFingerprint(Recipe.fromJson(rows[matches.single])) !=
                snapshot.recipeFingerprint) {
          throw const RecipeEditException(
            'Рецепт изменился. Закройте редактор и откройте его заново.',
          );
        }
        if (frozen == null) {
          rows.removeAt(matches.single);
        } else {
          if (frozen['id'] != id) {
            throw const RecipeEditException('Идентификатор рецепта изменился.');
          }
          rows[matches.single] = frozen;
        }
      }
      final raw = jsonEncode(rows);
      try {
        // Also check the rewritten document for unsupported micronutrients.
        safeRecipeRows(raw);
        validateAppDocument(_recipesKey, raw);
      } catch (_) {
        throw const RecipeEditException(
          'Проверьте название, количество порций и ингредиенты рецепта.',
        );
      }
      if (!await prefs.compareAndPut(_recipesKey, snapshot.document, raw)) {
        throw const RecipeEditException(
          'Список рецептов изменился. Закройте редактор и откройте его заново.',
        );
      }
    });
  }

  // --- Напоминания ---
  Future<ReminderSettings> getReminderSettings() async {
    final jsonString = _prefs?.getString(_remindersKey);
    if (jsonString == null) return ReminderSettings();
    return ReminderSettings.fromJson(
      jsonDecode(jsonString) as Map<String, dynamic>,
    );
  }

  Future<void> saveReminderSettings(ReminderSettings settings) async {
    await _prefs?.setString(_remindersKey, jsonEncode(settings.toJson()));
  }

  /// История по дням: калории, тренировки, вода и шаги.
  /// Читает только ключи, которые есть в хранилище.
  Future<List<DayLog>> getDayLogs() async {
    final prefs = _prefs;
    if (prefs == null) return [];

    final prefixes = <String>[
      '${_foodEntriesKey}_',
      '${_workoutEntriesKey}_',
      '${_workoutCompletedKey}_',
      '${_waterIntakeKey}_',
      '${_stepsKey}_',
    ];
    final dates = <String>{};
    for (final key in prefs.getKeys().where(LocalPreferences.appKey)) {
      for (final prefix in prefixes) {
        if (key.startsWith(prefix)) {
          final raw = key.substring(prefix.length);
          if (DateTime.tryParse(raw) != null) dates.add(raw);
        }
      }
    }

    final logs = <DayLog>[];
    final presentKeys = prefs.getKeys();
    for (final raw in dates) {
      final date = DateTime.parse(raw);
      final food = await getFoodEntries(date);
      final calories = food.fold(0.0, (sum, e) => sum + e.calories);
      final workoutDone =
          (prefs.getBool('${_workoutCompletedKey}_$raw') ?? false) ||
          (await getWorkoutEntries(date)).isNotEmpty;
      logs.add(
        DayLog(
          date: DateTime(date.year, date.month, date.day),
          calories: calories,
          workoutDone: workoutDone,
          water: prefs.getInt('${_waterIntakeKey}_$raw') ?? 0,
          steps: prefs.getInt('${_stepsKey}_$raw') ?? 0,
          hasFoodRecord: food.isNotEmpty,
          hasWaterRecord: presentKeys.contains('${_waterIntakeKey}_$raw'),
          hasStepsRecord: presentKeys.contains('${_stepsKey}_$raw'),
        ),
      );
    }
    logs.sort((a, b) => a.date.compareTo(b.date));
    return logs;
  }

  /// Snapshot the known diary documents, not the entire browser or cloud.
  /// Local privacy state, credentials, sync metadata and other databases are
  /// intentionally excluded. Capturing a file does not prove it is restorable.
  Future<Map<String, dynamic>> exportData() async {
    Map<String, dynamic>? result;
    // Queue behind multi-document diary operations, then drain direct local
    // app-key writes as well. Never read Hive's optimistic in-memory values
    // while their writes are still in flight. Other browser tabs do not share
    // these queues; this is not a cross-tab or cloud-consistent backup.
    await _enqueueMutation(() async {
      final prefs = _prefs;
      if (prefs == null) throw StateError('Локальное хранилище не открыто.');
      if (SmartRemote.instance.busy) {
        throw StateError(
          'Дождитесь завершения синхронизации и повторите экспорт.',
        );
      }
      result = await prefs.readAfterAppWrites(() {
        if (!identical(prefs, _prefs)) {
          throw StateError('Хранилище изменилось. Повторите экспорт.');
        }
        if (SmartRemote.instance.busy) {
          throw StateError(
            'Дождитесь завершения синхронизации и повторите экспорт.',
          );
        }
        final data = <String, dynamic>{};
        for (final key in prefs.getKeys().where(LocalPreferences.appKey)) {
          final value = prefs.get(key);
          if (value is String || value is bool) {
            data[key] = value;
          } else if (value is int) {
            // Values beyond JSON's common cross-platform integer precision
            // cannot be promised to survive a browser round trip. Keep the
            // check inside this branch: on web an integral number can satisfy
            // both int and double type tests.
            if (value > 9007199254740991 || value < -9007199254740991) {
              throw StateError(
                'Не удалось безопасно создать копию: обнаружено число '
                'неподдерживаемой точности. Дневник не изменён.',
              );
            }
            data[key] = value;
          } else if (value is double && value.isFinite) {
            data[key] = value;
          } else if (value is List && value.every((item) => item is String)) {
            // Hive/SharedPreferences may return List<dynamic>. Freeze the copy
            // so a later mutation cannot change an already captured payload.
            data[key] = List<String>.from(value);
          } else {
            // Do not return a plausible partial backup or leak its contents.
            throw StateError(
              'Не удалось безопасно создать копию: обнаружены данные '
              'неподдерживаемого формата. Дневник не изменён.',
            );
          }
        }
        return {
          'app': 'fitness_tracker',
          'version': 2,
          'exportedAt': DateTime.now().toIso8601String(),
          'data': data,
        };
      });
    });
    return result!;
  }

  /// Decode a checkpoint without interpreting or normalizing the documents.
  /// An unrepresentable existing value aborts an import before any deletion.
  static Map<String, Object> _decodeImportCheckpointBody(
    Object? raw,
    List<String> allowedPrefixes,
  ) {
    if (raw is! String || !allowedPrefixes.any(raw.startsWith)) {
      throw const ImportRecoveryRequired();
    }
    try {
      final envelope = jsonDecode(raw.substring(3));
      if (envelope is! Map ||
          envelope.length != 2 ||
          envelope['version'] != 1 ||
          envelope['data'] is! Map) {
        throw const FormatException();
      }
      final result = <String, Object>{};
      for (final item in (envelope['data'] as Map).entries) {
        final key = item.key, value = item.value;
        if (key is! String || !LocalPreferences.appKey(key)) {
          throw const FormatException();
        }
        if (value is String ||
            value is int ||
            value is bool ||
            (value is double && value.isFinite)) {
          result[key] = value as Object;
        } else if (value is List && value.every((e) => e is String)) {
          result[key] = List<String>.from(value);
        } else {
          throw const FormatException();
        }
      }
      return result;
    } catch (_) {
      throw const ImportRecoveryRequired();
    }
  }

  /// The current import journal (P1/C1).
  static Map<String, Object> _decodeImportCheckpoint(Object? raw) =>
      _decodeImportCheckpointBody(raw, [
        LocalPreferences.importPendingPrefix,
        LocalPreferences.importCommittedPrefix,
      ]);

  /// The older C2 copy retained across a successful repeated import.
  static Map<String, Object> _decodeImportPrevCheckpoint(Object? raw) =>
      _decodeImportCheckpointBody(
        raw,
        [LocalPreferences.importPrevCommittedPrefix],
      );

  /// A user-triggered copy of the original pre-import snapshot, if readable.
  /// AI state and cloud credentials are not part of this recovery copy.
  String? importBackupJson() {
    final prefs = _prefs;
    if (prefs == null ||
        (prefs.get(LocalPreferences.importJournalKey) == null &&
            prefs.get(LocalPreferences.importPrevJournalKey) == null)) {
      return null;
    }
    try {
      final raw = prefs.get(LocalPreferences.importJournalKey);
      final data = raw != null
          ? _decodeImportCheckpoint(raw)
          : _decodeImportPrevCheckpoint(
              prefs.get(LocalPreferences.importPrevJournalKey),
            );
      return const JsonEncoder.withIndent('  ').convert({
        'app': 'fitness_tracker',
        'version': 2,
        'exportedAt': DateTime.now().toIso8601String(),
        'data': data,
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> _restoreImportCheckpoint(LocalPreferences prefs) async {
    final raw = prefs.get(LocalPreferences.importJournalKey);
    final backup = _decodeImportCheckpoint(raw);
    // If the import was fully written but marking it committed failed, turn
    // the record pending again before starting a rollback.
    if ((raw as String).startsWith(LocalPreferences.importCommittedPrefix)) {
      await prefs.setString(
        LocalPreferences.importJournalKey,
        '${LocalPreferences.importPendingPrefix}${raw.substring(3)}',
      );
      await prefs.flush();
    }
    // Read the older copy before restoring: after this import is rolled back
    // it becomes the single retained recovery copy again.
    final prevRaw = prefs.get(LocalPreferences.importPrevJournalKey);
    Map<String, Object>? previous;
    if (prevRaw != null) {
      try {
        previous = _decodeImportPrevCheckpoint(prevRaw);
      } catch (_) {
        previous = null;
      }
    }
    // Keep the checkpoint throughout restoration. A second interruption will
    // retry the same complete pre-import snapshot on the next startup.
    await prefs.clear(includeLocalAi: false);
    for (final item in backup.entries) {
      await prefs.put(item.key, item.value);
    }
    await prefs.flush();
    await prefs.remove(LocalPreferences.importJournalKey);
    if (previous != null) {
      // The rolled-back diary is the former C1 snapshot; the retained copy is
      // the older C2 one, promoted back to the single C1 slot.
      final older = jsonEncode({'version': 1, 'data': previous});
      await prefs.setString(
        LocalPreferences.importJournalKey,
        '${LocalPreferences.importCommittedPrefix}$older',
      );
      await prefs.remove(LocalPreferences.importPrevJournalKey);
    }
    await prefs.flush();
  }

  Future<void> recoverPendingImport() async {
    final prefs = _prefs;
    if (prefs == null || !prefs.hasPendingImport) return;
    if (SmartRemote.instance.busy) {
      throw StateError('Дождитесь завершения синхронизации');
    }
    await prefs.runExclusiveImport(() async {
      try {
        await _restoreImportCheckpoint(prefs);
        LocalPreferences.clearImportRecoveryFailure();
      } catch (_) {
        LocalPreferences.markImportRecoveryFailed();
        throw const ImportRecoveryRequired();
      }
    });
  }

  /// Import intentionally replaces the local history. Queue it with ordinary
  /// diary edits so an edit submitted during import starts afterwards.
  Future<bool> importData(Map<String, dynamic> payload) async {
    final frozen = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(payload)) as Map,
    );
    var result = false;
    await _enqueueMutation(() async {
      result = await _importDataNow(frozen);
    });
    if (result) SmartRemote.instance.afterLocalImport();
    return result;
  }

  Future<bool> _importDataNow(Map<String, dynamic> payload) async {
    final prefs = _prefs;
    final data = payload['data'];
    if (prefs == null || data is! Map) return false;

    if (!validateBackupDocuments(data)) return false;
    if (SmartRemote.instance.busy) {
      throw StateError('Дождитесь завершения синхронизации перед импортом');
    }
    if (prefs.hasPendingImport) throw const ImportRecoveryRequired();
    final remote = SmartRemote.instance;
    final owner = remote.client?.auth.currentUser?.id;
    final binding = prefs.getString('_bound_user');
    void checkOwner() {
      if (remote.client?.auth.currentUser?.id != owner ||
          prefs.getString('_bound_user') != binding) {
        throw StateError('Аккаунт или привязка изменились. Импорт остановлен.');
      }
      if (owner != null && binding != null && owner != binding) {
        throw StateError(
          'Этот дневник связан с другим аккаунтом. Используйте отдельный профиль устройства.',
        );
      }
    }

    checkOwner();
    return prefs.runExclusiveImport(() async {
      if (SmartRemote.instance.busy) {
        throw StateError('Дождитесь завершения синхронизации перед импортом');
      }
      checkOwner();
      // One durable journal record must exist before the first app-key delete.
      // Round-trip the snapshot before writing so unsupported older values fail
      // safely rather than being normalized or erased during rollback.
      final checkpoint = jsonEncode({'version': 1, 'data': prefs.snapshot()});
      final pending = '${LocalPreferences.importPendingPrefix}$checkpoint';
      final committed = '${LocalPreferences.importCommittedPrefix}$checkpoint';
      try {
        _decodeImportCheckpoint(pending);
      } on ImportRecoveryRequired {
        throw StateError(
          'Импорт остановлен: текущие данные нельзя безопасно включить в резервную копию.',
        );
      }
      // Keep the older committed copy before this import overwrites the main
      // slot. Do this first: a failure here leaves the diary untouched.
      final currentRaw = prefs.get(LocalPreferences.importJournalKey);
      if (currentRaw is String &&
          currentRaw.startsWith(LocalPreferences.importCommittedPrefix)) {
        Map<String, Object> previous;
        try {
          previous = _decodeImportCheckpoint(currentRaw);
        } on ImportRecoveryRequired {
          throw StateError(
            'Импорт остановлен: предыдущая копия нечитаема и не может быть сохранена.',
          );
        }
        final older = jsonEncode({'version': 1, 'data': previous});
        await prefs.setString(
          LocalPreferences.importPrevJournalKey,
          '${LocalPreferences.importPrevCommittedPrefix}$older',
        );
        await prefs.flush();
      }
      var checkpointStarted = false;
      try {
        await prefs.setString(LocalPreferences.importJournalKey, pending);
        checkpointStarted = true;
        await prefs.flush();
        checkOwner();
        // Stop automatic cloud writes before replacement. This local-only latch
        // survives restart and remains conservative even if rollback succeeds.
        await prefs.setBool(LocalPreferences.importSyncPauseKey, true);
        await prefs.flush();
        checkOwner();
        // Old undo actions must never delete an identical-looking document
        // that was subsequently imported. Change the token before deletion;
        // even a rolled-back import conservatively invalidates old undo.
        await prefs.setString(LocalPreferences.diaryGenerationKey, newId());
        await prefs.flush();
        checkOwner();
        await prefs.clear(includeLocalAi: false);
        checkOwner();
        for (final entry in data.entries) {
          checkOwner();
          await prefs.put(entry.key.toString(), entry.value as Object);
        }
        await prefs.flush();
        checkOwner();
        // Retain the previous local snapshot as one committed recovery copy.
        // The next import replaces it; deliberate clear-all removes it.
        await prefs.setString(LocalPreferences.importJournalKey, committed);
        await prefs.flush();
        checkOwner();
        return true;
      } catch (_) {
        final journal = prefs.get(LocalPreferences.importJournalKey);
        if (checkpointStarted || journal == pending || journal == committed) {
          try {
            await _restoreImportCheckpoint(prefs);
            LocalPreferences.clearImportRecoveryFailure();
          } catch (_) {
            LocalPreferences.markImportRecoveryFailed();
            throw const ImportRecoveryRequired();
          }
        }
        rethrow;
      }
    });
  }

  Future<void> discardImportBackup() => _enqueueMutation(() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (prefs.hasPendingImport || LocalPreferences.importInProgress) {
      throw const ImportRecoveryRequired();
    }
    if (prefs.hasImportBackup) {
      await prefs.remove(LocalPreferences.importJournalKey);
      await prefs.remove(LocalPreferences.importPrevJournalKey);
      await prefs.flush();
    }
  });

  Future<void> clearAll() {
    // Privacy operations are invalidated immediately, even if the actual
    // deletion must wait behind another diary mutation.
    LocalPreferences.beginQueuedPrivacyClear();
    try {
      return _enqueueMutation(() async {
        final prefs = _prefs;
        if (prefs == null) return;
        if (prefs.hasPendingImport) throw const ImportRecoveryRequired();
        if (SmartRemote.instance.busy) {
          throw StateError('Дождитесь завершения синхронизации перед очисткой');
        }
        await prefs.runExclusiveImport(() async {
          if (SmartRemote.instance.busy) {
            throw StateError(
              'Дождитесь завершения синхронизации перед очисткой',
            );
          }
          // Do not delete a malformed retained checkpoint merely because it
          // has a committed prefix. Validate it while the in-isolate gate is
          // held; real recovery still requires an independent backup.
          if (prefs.hasImportBackup) {
            final journal = prefs.get(LocalPreferences.importJournalKey);
            if (journal != null) _decodeImportCheckpoint(journal);
            final previous = prefs.get(LocalPreferences.importPrevJournalKey);
            if (previous != null) _decodeImportPrevCheckpoint(previous);
          }
          await prefs.setString(LocalPreferences.diaryGenerationKey, newId());
          await prefs.flush();
          // The explicitly confirmed full clear includes the retained import
          // backup in the same local deletion batch as the diary/privacy keys.
          // The generation write and later flush are still separate steps.
          await prefs.clear(includeCommittedImportBackup: true);
          await prefs.flush();
        }, blockLocalPrivacyWrites: true);
        SmartRemote.instance.afterLocalClear();
      }).whenComplete(LocalPreferences.endQueuedPrivacyClear);
    } catch (_) {
      LocalPreferences.endQueuedPrivacyClear();
      rethrow;
    }
  }
}

// ============================================================================
// СОСТОЯНИЕ ПРИЛОЖЕНИЯ
// ============================================================================

/// Each nutrient has an independent provenance. A missing/unconfirmed target
/// is null, never zero; a deliberately confirmed zero is still representable.
class NutritionTargets {
  final double? protein, fat, carbs;
  const NutritionTargets(this.protein, this.fat, this.carbs);

  double? get calories => protein == null || fat == null || carbs == null
      ? null
      : protein! * 4 + fat! * 9 + carbs! * 4;

  NutritionTargets operator +(smart.MacroBudget bonus) => NutritionTargets(
    protein == null ? null : protein! + bonus.protein,
    fat == null ? null : fat! + bonus.fat,
    carbs == null ? null : carbs! + bonus.carbs,
  );
}

double? availableGoalProgress(num consumed, num? target) =>
    target != null && target > 0 ? consumed / target : null;

class AppDataProvider extends ChangeNotifier {
  final StorageService _storage = StorageService();
  StorageService get storage => _storage;

  AppDataProvider() {
    _storage.gymRevision.addListener(_storedSectionChanged);
    _storage.sleepRevision.addListener(_storedSectionChanged);
  }

  // Independently queued documents notify retained dashboard/calendar/overview
  // only after successful writes, so views do not show stale or unsaved data.
  void _storedSectionChanged() => notifyListeners();

  @override
  void dispose() {
    _storage.gymRevision.removeListener(_storedSectionChanged);
    _storage.sleepRevision.removeListener(_storedSectionChanged);
    super.dispose();
  }

  UserProfile _profile = UserProfile();
  int _profileEditEpoch = 0;
  int _profileWritesPending = 0;
  List<FoodEntry> _todayFoodEntries = [];
  List<SupplementEntry> _todaySupplementEntries = [];
  List<WeightEntry> _weightEntries = [];
  List<WorkoutEntry> _todayWorkoutEntries = [];
  List<QuickFood> _quickFoods = [];
  List<Recipe> _recipes = [];
  List<DayLog> _dayLogs = [];
  ReminderSettings _reminders = ReminderSettings();
  int _todayWaterIntake = 0;
  int _todaySteps = 0;
  bool _todayWorkoutCompleted = false;
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = false;
  int _loadGeneration = 0;
  // Only the current startup attempt can enable the recovery export. Opening
  // the storage is not the same as validating its contents or recovering it.
  bool _startupStorageOpened = false;
  bool get startupStorageOpened => _startupStorageOpened;
  String? persistenceError;
  Map<String, dynamic> smartSettings = {};
  smart.MetabolicSettings get metabolism => smart.MetabolicSettings.fromJson({
    ...smartSettings,
    // The optional user-entered profile age is the source of truth. An old
    // smart-settings default must not override it after a birthday or edit.
    if (_profile.ageYears != null) 'age': _profile.ageYears,
  });
  bool get hasConfirmedBodyMetrics =>
      _profile.heightConfirmed == true &&
      _profile.currentWeightConfirmed == true;
  bool get canUseAutomaticMetabolism {
    final age = _profile.ageYears;
    return hasConfirmedBodyMetrics &&
        age != null &&
        age >= 18 &&
        age <= 100 &&
        smartSettings['metabolismConfirmed'] == true &&
        (!metabolism.useKatch || smartSettings['bodyFatConfirmed'] == true);
  }

  bool get automaticMetabolismActive =>
      metabolism.automatic && canUseAutomaticMetabolism;

  Future<void> updateSmartSettings(Map<String, dynamic> value) async {
    validateAppDocument('smart_settings', jsonEncode(value));
    await _storage.local.setString('smart_settings', jsonEncode(value));
    smartSettings = Map.of(value);
    notifyListeners();
  }

  double? get baseCaloriesTarget => automaticMetabolismActive
      ? metabolism.baseTarget(_profile.currentWeight, _profile.height)
      : _profile.dailyCaloriesTarget?.toDouble();
  NutritionTargets get macroTargets {
    final automaticBase = automaticMetabolismActive ? baseCaloriesTarget : null;
    var budget = automaticBase != null
        ? NutritionTargets(
            automaticBase * .3 / 4,
            automaticBase * .25 / 9,
            automaticBase * .45 / 4,
          )
        : NutritionTargets(
            _profile.hasConfirmedProteinGoal
                ? _profile.targetProtein!.toDouble()
                : null,
            _profile.hasConfirmedFatGoal
                ? _profile.targetFat!.toDouble()
                : null,
            _profile.hasConfirmedCarbsGoal
                ? _profile.targetCarbs!.toDouble()
                : null,
          );
    if (metabolism.adaptMacros) {
      for (final workout in _todayWorkoutEntries) {
        budget =
            budget +
            smart.MetabolicSettings.workoutBonus(
              workout.budgetCalories,
              workout.type.name,
            );
      }
    }
    return budget;
  }

  int? get targetProteinToday => macroTargets.protein?.round();
  int? get targetFatToday => macroTargets.fat?.round();
  int? get targetCarbsToday => macroTargets.carbs?.round();

  UserProfile get profile => _profile;
  List<FoodEntry> get todayFoodEntries => List.unmodifiable(_todayFoodEntries);
  List<SupplementEntry> get todaySupplementEntries =>
      List.unmodifiable(_todaySupplementEntries);
  List<WeightEntry> get weightEntries => List.unmodifiable(_weightEntries);
  List<WorkoutEntry> get todayWorkoutEntries =>
      List.unmodifiable(_todayWorkoutEntries);
  List<QuickFood> get quickFoods => List.unmodifiable(_quickFoods);
  List<Recipe> get recipes => List.unmodifiable(_recipes);
  List<DayLog> get dayLogs => List.unmodifiable(_dayLogs);
  ReminderSettings get reminders => _reminders;
  int get todayWaterIntake => _todayWaterIntake;

  /// A missing water entry is not an explicitly recorded zero. Include the
  /// in-memory day log so an optimistic edit is visible until it succeeds or
  /// reloadAll restores the durable state after a failed write.
  bool get hasRecordedWater {
    final key = dayKey(_selectedDate);
    return _dayLogs.any(
          (day) => dayKey(day.date) == key && day.hasWaterRecord,
        ) ||
        _storage.local.getKeys().contains('water_intake_$key');
  }

  int get todaySteps => _todaySteps;
  bool get hasRecordedSteps {
    final key = dayKey(_selectedDate);
    return _dayLogs.any(
          (day) => dayKey(day.date) == key && day.hasStepsRecord,
        ) ||
        _storage.local.getKeys().contains('steps_$key');
  }

  bool get todayWorkoutCompleted => _todayWorkoutCompleted;
  DateTime get selectedDate => _selectedDate;
  bool get isLoading => _isLoading;

  double get todayCaloriesExact =>
      _todayFoodEntries.fold(0.0, (sum, e) => sum + e.calories);
  int get todayCaloriesConsumed => todayCaloriesExact.round();
  double get todayProteinConsumed =>
      _todayFoodEntries.fold(0.0, (sum, e) => sum + e.protein);
  double get todayFatConsumed =>
      _todayFoodEntries.fold(0.0, (sum, e) => sum + e.fat);
  double get todayCarbsConsumed =>
      _todayFoodEntries.fold(0.0, (sum, e) => sum + e.carbs);

  int get todayCaloriesBurned =>
      _todayWorkoutEntries.fold(0, (sum, e) => sum + e.caloriesBurned);
  int get todayWorkoutCalorieCredit =>
      _todayWorkoutEntries.fold(0, (sum, e) => sum + e.budgetCalories);
  int? get adjustedCaloriesTarget {
    final base = baseCaloriesTarget;
    return base == null ? null : base.round() + todayWorkoutCalorieCredit;
  }

  int? get caloriesRemaining {
    final target = adjustedCaloriesTarget;
    return target == null ? null : target - todayCaloriesConsumed;
  }

  double? get caloriesProgress =>
      availableGoalProgress(todayCaloriesExact, adjustedCaloriesTarget);
  double? get proteinProgress =>
      availableGoalProgress(todayProteinConsumed, targetProteinToday);
  double? get fatProgress =>
      availableGoalProgress(todayFatConsumed, targetFatToday);
  double? get carbsProgress =>
      availableGoalProgress(todayCarbsConsumed, targetCarbsToday);
  int? get confirmedWaterGoal =>
      _profile.hasConfirmedWaterGoal ? _profile.dailyWaterGoalMl : null;
  int? get confirmedStepsGoal =>
      _profile.hasConfirmedStepsGoal ? _profile.dailyStepsGoal : null;
  double? get waterProgress =>
      availableGoalProgress(_todayWaterIntake, confirmedWaterGoal);
  double? get stepsProgress =>
      availableGoalProgress(_todaySteps, confirmedStepsGoal);

  List<FoodItem> searchFoods(String query) {
    final custom = (_storage.local.decoded('custom_foods') as List? ?? [])
        .map((raw) {
          final e = Map<String, dynamic>.from(raw as Map);
          return FoodItem(
            e['name'] as String,
            smart.number(e['caloriesPer100g']),
            smart.number(e['proteinPer100g']),
            smart.number(e['fatPer100g']),
            smart.number(e['carbsPer100g']),
            readMicros(e['micros']),
            (e['category'] as String?) ?? 'Мои продукты',
            (e['source'] as String?) ?? 'Мои продукты',
            (e['brand'] as String?) ?? (e['originSource'] as String?),
            e['barcode'] as String?,
            e['note'] as String?,
            e['sourceUrl'] as String?,
            (e['keywords'] as String?) ?? '',
            e['microsEstimated'] == true,
          );
        })
        .where(
          (f) =>
              f.name.toLowerCase().contains(query.toLowerCase()) ||
              f.keywords.toLowerCase().contains(query.toLowerCase()) ||
              (f.brand?.toLowerCase().contains(query.toLowerCase()) ?? false),
        );
    return [...custom, ...FoodDatabase.search(query)];
  }

  /// Pin an offline/online catalog result to the user's own food database.
  /// It stays a normal editable custom food and is included in cloud sync.
  Future<void> saveCustomFood(FoodItem food) async {
    if (food.name.trim().isEmpty || food.name.length > 180) {
      throw ArgumentError('Слишком длинное название продукта');
    }
    final values = [food.calories, food.protein, food.fat, food.carbs];
    if (values.any((v) => !v.isFinite || v < 0) ||
        food.micros.values.any((v) => !v.isFinite || v < 0)) {
      throw ArgumentError('Некорректные пищевые значения');
    }
    final local = _storage.local;
    final expected = local.get('custom_foods');
    final generation = local.diaryGeneration;
    late final List<String> rawRows;
    late final List<Map<String, dynamic>> existing;
    try {
      if (expected != null && expected is! String)
        throw const FormatException();
      if (expected != null) validateAppDocument('custom_foods', expected);
      rawRows = rawJsonArrayElements((expected as String?) ?? '[]');
      existing = rawRows.map(uniqueJsonObject).toList();
    } catch (_) {
      throw StateError(
        'Свою базу не удалось безопасно прочитать. Данные не изменены.',
      );
    }
    final row = <String, dynamic>{
      'name': food.name,
      'caloriesPer100g': food.calories,
      'proteinPer100g': food.protein,
      'fatPer100g': food.fat,
      'carbsPer100g': food.carbs,
      'micros': food.micros,
      'microsEstimated': food.microsEstimated,
      'category': food.category,
      // A pinned copy is always shown as the user's own food, while keeping
      // the original dataset name for provenance and attribution.
      'source': 'Мои продукты',
      'originSource': food.source,
      if (food.brand != null) 'brand': food.brand,
      if (food.barcode != null) 'barcode': food.barcode,
      if (food.note != null) 'note': food.note,
      if (food.sourceUrl != null) 'sourceUrl': food.sourceUrl,
      if (food.keywords.isNotEmpty) 'keywords': food.keywords,
    };
    if (existing.any(
      (e) =>
          (e['name'] as String).trim().toLowerCase() ==
          food.name.trim().toLowerCase(),
    )) {
      throw StateError(
        'Продукт с таким названием уже есть. Чтобы изменить его, откройте свою базу в настройках.',
      );
    }
    if (rawRows.length >= 200) {
      throw StateError('В «Моих продуктах» уже 200 продуктов. Удалите лишнее.');
    }
    final next = '[${[jsonEncode(row), ...rawRows].join(',')}]';
    validateAppDocument('custom_foods', next);
    final saved = await local.compareAndPut(
      'custom_foods',
      expected,
      next,
      authorizationGuard: () => local.diaryGeneration == generation,
    );
    if (!saved) {
      throw StateError('Своя база изменилась. Обновите экран и повторите.');
    }
    notifyListeners();
    try {
      await reloadAll();
    } catch (_) {
      // The CAS already succeeded: don't invite another insertion on retry.
      persistenceError = 'Продукт сохранён; обновите экран своей базы.';
      notifyListeners();
    }
  }

  List<FoodEntry> getFoodEntriesForMeal(MealType mealType) =>
      _todayFoodEntries.where((e) => e.mealType == mealType).toList();

  int getMealCalories(MealType mealType) => getFoodEntriesForMeal(
    mealType,
  ).fold(0.0, (sum, e) => sum + e.calories).round();

  // --- Серии и привычки ---

  /// Сколько дней подряд заполняется дневник питания.
  int get currentStreak {
    final logged = <String>{
      for (final log in _dayLogs)
        if (log.hasFoodRecord) dayKey(log.date),
    };
    if (logged.isEmpty) return 0;

    var cursor = DateTime.now();
    if (!logged.contains(dayKey(cursor))) {
      cursor = cursor.subtract(Duration(days: 1));
    }
    var count = 0;
    while (logged.contains(dayKey(cursor))) {
      count++;
      cursor = cursor.subtract(Duration(days: 1));
    }
    return count;
  }

  /// Лучшая серия за всё время.
  int get bestStreak {
    final days =
        _dayLogs
            .where((l) => l.hasFoodRecord)
            .map((l) => DateTime(l.date.year, l.date.month, l.date.day))
            .toList()
          ..sort();
    var best = 0;
    var current = 0;
    DateTime? previous;
    for (final day in days) {
      if (previous != null && day.difference(previous).inDays == 1) {
        current++;
      } else {
        current = 1;
      }
      if (current > best) best = current;
      previous = day;
    }
    return best;
  }

  /// Дней с любой активностью (еда, вода, шаги или тренировка).
  int get activeDaysCount => _dayLogs.where((log) => log.hasActivity).length;

  /// Уровень выполнения привычек для календаря 0..4.
  int habitLevel(DayLog log) {
    if (!log.hasActivity) return 0;
    // This legacy calendar only has the manual corridor, not historical or
    // automatic targets. Never compare a missing day or unreviewed values.
    if (!_profile.hasConfirmedCalorieGoal ||
        automaticMetabolismActive ||
        !log.hasFoodRecord) {
      return log.workoutDone ? 3 : 1;
    }
    final minGoal = _profile.dailyCaloriesMin!;
    final maxGoal = _profile.dailyCaloriesMax!;
    final inCorridor = log.calories >= minGoal && log.calories <= maxGoal;
    if (inCorridor && log.workoutDone) return 4;
    if (inCorridor || log.workoutDone) return 3;
    if (minGoal > 0 && log.calories >= minGoal * 0.7) return 2;
    return 1;
  }

  /// Заполненная история за последние [days] дней (включая пустые дни).
  List<DayLog> historyForDays(int days) {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    final start = end.subtract(Duration(days: days - 1));
    final byDay = <String, DayLog>{
      for (final log in _dayLogs) dayKey(log.date): log,
    };
    return List.generate(days, (i) {
      final date = start.add(Duration(days: i));
      return byDay[dayKey(date)] ?? DayLog(date: date);
    });
  }

  // --- Быстрый выбор продуктов ---

  List<QuickFood> recentFoodsForMeal(MealType mealType) {
    final list = _quickFoods.where((f) => f.mealType == mealType).toList()
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return list.take(8).toList();
  }

  List<QuickFood> get favoriteFoods {
    final list = _quickFoods.where((f) => f.favorite).toList()
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return list;
  }

  bool isFavoriteFood(String name, MealType mealType) {
    final key = '${name.toLowerCase()}|${mealType.index}';
    return _quickFoods.any((f) => f.key == key && f.favorite);
  }

  void _recordQuickFood(FoodEntry entry) {
    final key = '${entry.name.toLowerCase()}|${entry.mealType.index}';
    final index = _quickFoods.indexWhere((f) => f.key == key);
    final now = DateTime.now();

    if (index >= 0) {
      _quickFoods[index] = _quickFoods[index].copyWith(
        caloriesPer100g: entry.caloriesPer100g,
        micros: entry.micros,
        microsEstimated: entry.microsEstimated,
        proteinPer100g: entry.proteinPer100g,
        fatPer100g: entry.fatPer100g,
        carbsPer100g: entry.carbsPer100g,
        grams: entry.amountGrams,
        lastUsed: now,
      );
    } else {
      _quickFoods.add(
        QuickFood(
          name: entry.name,
          caloriesPer100g: entry.caloriesPer100g,
          micros: entry.micros,
          microsEstimated: entry.microsEstimated,
          proteinPer100g: entry.proteinPer100g,
          fatPer100g: entry.fatPer100g,
          carbsPer100g: entry.carbsPer100g,
          grams: entry.amountGrams,
          mealType: entry.mealType,
          lastUsed: now,
        ),
      );
    }

    // Храним до 20 последних продуктов на приём пищи + все избранные.
    final trimmed = <QuickFood>[];
    for (final meal in MealType.values) {
      final recent =
          _quickFoods.where((f) => f.mealType == meal && !f.favorite).toList()
            ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
      trimmed.addAll(recent.take(20));
    }
    trimmed.addAll(_quickFoods.where((f) => f.favorite));
    _quickFoods = trimmed;
  }

  Future<void> addFavorite(FoodItem food, MealType mealType) async {
    final key = '${food.name.toLowerCase()}|${mealType.index}';
    final index = _quickFoods.indexWhere((f) => f.key == key);
    if (index >= 0) {
      _quickFoods[index] = _quickFoods[index].copyWith(
        favorite: true,
        lastUsed: DateTime.now(),
      );
    } else {
      _quickFoods.add(
        QuickFood(
          name: food.name,
          caloriesPer100g: food.calories,
          micros: food.micros,
          microsEstimated: food.microsEstimated,
          proteinPer100g: food.protein,
          fatPer100g: food.fat,
          carbsPer100g: food.carbs,
          grams: 100,
          mealType: mealType,
          favorite: true,
        ),
      );
    }
    _tapFeedback();
    notifyListeners();
    await _storage.saveQuickFoods(_quickFoods);
  }

  Future<void> removeFavorite(String name, MealType mealType) async {
    final key = '${name.toLowerCase()}|${mealType.index}';
    _quickFoods.removeWhere((f) => f.key == key);
    _tapFeedback();
    notifyListeners();
    await _storage.saveQuickFoods(_quickFoods);
  }

  // --- Рецепты ---

  RecipeEditSnapshot captureRecipeEdit([Recipe? original]) =>
      RecipeEditSnapshot(_storage.local.get('recipes'), original);

  Future<void> _finishRecipeChange(
    RecipeEditSnapshot snapshot,
    Recipe? next,
  ) async {
    await _storage.writeRecipeChange(snapshot, next);
    try {
      _recipes = await _storage.getRecipes();
    } catch (_) {
      // The recipe write has already succeeded: do not present it as failed or
      // invite a retry that could create a duplicate. Ask for a refresh instead.
      persistenceError = 'Рецепт сохранён; обновите экран для отображения.';
    }
    notifyListeners();
  }

  Future<void> addRecipe(Recipe recipe, {RecipeEditSnapshot? snapshot}) {
    if (snapshot != null && snapshot.recipeId != null) {
      throw const RecipeEditException(
        'Нельзя создать рецепт из снимка редактирования.',
      );
    }
    return _finishRecipeChange(snapshot ?? captureRecipeEdit(), recipe);
  }

  Future<void> updateRecipe(Recipe recipe, {RecipeEditSnapshot? snapshot}) {
    final original = _recipes.where((item) => item.id == recipe.id).firstOrNull;
    if ((snapshot == null && original == null) ||
        (snapshot != null && snapshot.recipeId != recipe.id)) {
      throw const RecipeEditException('Рецепт уже удалён или изменился.');
    }
    return _finishRecipeChange(snapshot ?? captureRecipeEdit(original), recipe);
  }

  Future<void> deleteRecipe(String id, {RecipeEditSnapshot? snapshot}) {
    final original = _recipes.where((item) => item.id == id).firstOrNull;
    if ((snapshot == null && original == null) ||
        (snapshot != null && snapshot.recipeId != id)) {
      throw const RecipeEditException('Рецепт уже удалён или изменился.');
    }
    return _finishRecipeChange(snapshot ?? captureRecipeEdit(original), null);
  }

  Future<void> addRecipeToMeal(
    Recipe recipe,
    double grams,
    MealType mealType,
  ) async {
    await addFoodEntry(recipe.toEntry(grams, mealType, date: _selectedDate));
  }

  // --- Инициализация ---

  Future<void> init() async {
    _startupStorageOpened = false;
    _isLoading = true;
    notifyListeners();
    await _storage.init();
    _startupStorageOpened = true;
    await reloadAll();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> reloadAll() async {
    smartSettings = Map<String, dynamic>.from(
      _storage.local.decoded('smart_settings') as Map? ?? {},
    );
    _profile = await _storage.getUserProfile();
    _quickFoods = await _storage.getQuickFoods();
    _recipes = await _storage.getRecipes();
    _reminders = await _storage.getReminderSettings();
    await _loadTodayData();
    _dayLogs = await _storage.getDayLogs();
    notifyListeners();
  }

  Future<void> _loadTodayData() async {
    final generation = ++_loadGeneration;
    final date = _selectedDate;
    await _storage.pendingMutations;
    final food = await _storage.getFoodEntries(date);
    final supplements = await _storage.getSupplementEntries(date);
    final workouts = await _storage.getWorkoutEntries(date);
    final water = await _storage.getWaterIntake(date);
    final steps = await _storage.getSteps(date);
    final completed = await _storage.isWorkoutCompleted(date);
    final weights = await _storage.getWeightEntries();
    if (generation != _loadGeneration || dayKey(date) != dayKey(_selectedDate))
      return;
    _todayFoodEntries = food;
    _todaySupplementEntries = supplements;
    _todayWorkoutEntries = workouts;
    _todayWaterIntake = water;
    _todaySteps = steps;
    _todayWorkoutCompleted = completed || workouts.isNotEmpty;
    _weightEntries = weights;
    notifyListeners();
  }

  Future<void> _persistDiary(Future<void> Function() action) async {
    try {
      await action();
      persistenceError = null;
    } catch (_) {
      // Restore the actual disk state, and expose a visible retry/refresh banner.
      persistenceError =
          'Изменение не сохранено. Проверьте свободное место и повторите.';
      await _storage.pendingMutations;
      await reloadAll();
    }
    notifyListeners();
  }

  Future<void> setSelectedDate(DateTime date) async {
    _selectedDate = date;
    await _loadTodayData();
  }

  /// Перезагрузка данных без показа полноэкранного индикатора
  /// (используется pull-to-refresh).
  Future<void> refresh() async {
    await reloadAll();
  }

  // --- Добавки: durable writes, no optimistic deletion or implicit dose ---
  Future<void> addSupplementEntriesBatch(
    List<SupplementEntry> entries, {
    bool Function()? authorizationGuard,
  }) async {
    if (entries.isEmpty) return;
    for (final entry in entries) {
      SupplementEntry.fromJson(entry.toJson());
    }
    if (entries.any((e) => dayKey(e.date) != dayKey(entries.first.date))) {
      throw ArgumentError('Выберите один день для всех добавок');
    }
    try {
      await _storage.addSupplementBatch(
        entries,
        authorizationGuard: authorizationGuard,
      );
      persistenceError = null;
      await reloadAll();
    } catch (_) {
      persistenceError =
          'Добавки не удалось сохранить. Проверьте место и повторите.';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateSupplementEntry(SupplementEntry entry) async {
    await _storage.updateSupplementEntry(entry);
    persistenceError = null;
    await reloadAll();
  }

  Future<void> deleteSupplementEntry(SupplementEntry entry) async {
    await _storage.deleteSupplementEntry(entry.id, entry.date);
    persistenceError = null;
    await reloadAll();
  }

  // --- Еда ---

  void _validateFood(FoodEntry entry) {
    final values = [
      entry.caloriesPer100g,
      entry.proteinPer100g,
      entry.fatPer100g,
      entry.carbsPer100g,
      entry.amountGrams,
    ];
    if (entry.name.trim().isEmpty ||
        entry.amountGrams <= 0 ||
        values.any((v) => !v.isFinite || v < 0) ||
        entry.micros.values.any((v) => !v.isFinite || v < 0)) {
      throw ArgumentError('Проверьте название, порцию и БЖУ');
    }
  }

  /// Apply an explicitly reviewed AI plan for one day, with stale-snapshot
  /// protection and a single durable day-document write. Quick foods and
  /// recipes are intentionally not changed by edits to the diary.
  Future<void> applyReviewedFoodChanges({
    required DateTime date,
    required Map<String, FoodEntry> expected,
    required Map<String, FoodEntry?> changes,
    required List<FoodEntry> additions,
    FoodRangeSnapshot? expectedRange,
    bool Function()? authorizationGuard,
  }) async {
    for (final item in changes.values.whereType<FoodEntry>()) {
      _validateFood(item);
    }
    for (final item in additions) {
      _validateFood(item);
    }
    await _storage.applyReviewedFoodChanges(
      date: date,
      expected: expected,
      changes: changes,
      additions: additions,
      expectedRange: expectedRange,
      authorizationGuard: authorizationGuard,
    );
    persistenceError = null;
    try {
      await reloadAll();
    } catch (_) {
      // The single durable write already succeeded; never invite an unsafe retry.
      persistenceError =
          'Изменения сохранены; обновите экран для их отображения.';
      notifyListeners();
    }
    _lightFeedback();
  }

  /// Used by reviewed AI drafts. No optimistic multi-write partial saves.
  Future<void> addFoodEntriesBatch(
    List<FoodEntry> entries, {
    bool Function()? authorizationGuard,
  }) async {
    if (entries.isEmpty) return;
    for (final entry in entries) {
      _validateFood(entry);
    }
    if (entries.any((e) => dayKey(e.date) != dayKey(entries.first.date))) {
      throw ArgumentError('Выберите один день для всего набора');
    }
    try {
      await _storage.addFoodBatch(
        entries,
        authorizationGuard: authorizationGuard,
      );
      persistenceError = null;
    } catch (error) {
      _foodWriteError(error);
      rethrow;
    }
    for (final entry in entries) {
      _recordQuickFood(entry);
    }
    try {
      await _storage.saveQuickFoods(_quickFoods);
    } catch (_) {
      // Diary is already committed. Optional shortcuts never make save look failed.
      persistenceError = 'Дневник сохранён, но быстрые продукты не обновились.';
    }
    try {
      await reloadAll();
    } catch (_) {
      persistenceError =
          '${persistenceError ?? 'Дневник сохранён.'} Обновите экран дневника.';
      notifyListeners();
    }
    _lightFeedback();
  }

  Future<void> undoFoodEntriesBatch(
    List<FoodEntry> original, {
    bool Function()? authorizationGuard,
  }) async {
    for (final entry in original) {
      _validateFood(entry);
    }
    await _storage.undoFoodBatch(
      original,
      authorizationGuard: authorizationGuard,
    );
    try {
      await reloadAll();
      persistenceError = null;
    } catch (_) {
      persistenceError = 'Отмена сохранена; обновите экран дневника.';
      notifyListeners();
    }
    _lightFeedback();
  }

  FoodEditSnapshot captureFoodEdit(FoodEntry entry) => FoodEditSnapshot(
    _storage.local.get('food_entries_${dayKey(entry.date)}'),
    entry,
  );

  FoodDaySnapshot captureFoodDay() => FoodDaySnapshot(
    _storage.local.get('food_entries_${dayKey(_selectedDate)}'),
    _selectedDate,
    _todayFoodEntries,
  );

  void _foodWriteError(Object error) {
    persistenceError = error is FoodEditException
        ? error.message
        : 'Дневник не сохранён. Проверьте свободное место и повторите.';
    notifyListeners();
  }

  Future<void> _finishFoodChange({FoodEntry? quick}) async {
    String? warning;
    if (quick != null) {
      try {
        _recordQuickFood(quick);
        await _storage.saveQuickFoods(_quickFoods);
      } catch (_) {
        warning = 'Дневник сохранён, но быстрые продукты не обновились.';
      }
    }
    try {
      await reloadAll();
    } catch (_) {
      warning = '${warning ?? 'Дневник сохранён.'} Обновите экран дневника.';
    }
    persistenceError = warning;
    notifyListeners();
    _lightFeedback();
  }

  Future<void> addFoodEntry(FoodEntry entry) async {
    _validateFood(entry);
    final before = todayCaloriesExact;
    try {
      await _storage.addFoodEntry(entry);
    } catch (error) {
      _foodWriteError(error);
      rethrow;
    }
    await _finishFoodChange(quick: entry);
    final target = adjustedCaloriesTarget;
    if (target != null &&
        target > 0 &&
        dayKey(entry.date) == dayKey(_selectedDate) &&
        before < target &&
        todayCaloriesConsumed >= target) {
      _successFeedback();
    }
  }

  Future<void> updateFoodEntry(
    FoodEntry entry, {
    FoodEditSnapshot? snapshot,
  }) async {
    _validateFood(entry);
    final original = _todayFoodEntries
        .where((e) => e.id == entry.id)
        .firstOrNull;
    if (original != null && dayKey(original.date) != dayKey(entry.date)) {
      throw ArgumentError('Перенос между днями здесь не поддерживается');
    }
    final evidence =
        snapshot ?? (original == null ? null : captureFoodEdit(original));
    try {
      await _storage.updateFoodEntry(entry, snapshot: evidence);
    } catch (error) {
      _foodWriteError(error);
      rethrow;
    }
    await _finishFoodChange(quick: entry);
  }

  Future<void> deleteFoodEntry(String id, {FoodEditSnapshot? snapshot}) async {
    final original = _todayFoodEntries.where((e) => e.id == id).firstOrNull;
    final evidence =
        snapshot ?? (original == null ? null : captureFoodEdit(original));
    final date = evidence != null
        ? DateTime.parse(evidence.day)
        : (original?.date ?? _selectedDate);
    try {
      await _storage.deleteFoodEntry(id, date, snapshot: evidence);
    } catch (error) {
      _foodWriteError(error);
      rethrow;
    }
    await _finishFoodChange();
  }

  Future<void> clearFoodForSelectedDay({FoodDaySnapshot? snapshot}) async {
    final date = _selectedDate;
    final ids =
        snapshot?.fingerprints.keys.toSet() ??
        _todayFoodEntries.map((e) => e.id).toSet();
    try {
      await _storage.removeFoodEntries(ids, date, daySnapshot: snapshot);
    } catch (error) {
      _foodWriteError(error);
      rethrow;
    }
    await _finishFoodChange();
  }

  // --- Вес ---

  WeightEditSnapshot captureWeightEdit([WeightEntry? original]) =>
      WeightEditSnapshot(_storage.local.get('weight_entries'), original);

  Future<WeightChangeResult> _finishWeightChange(
    WeightEditSnapshot snapshot,
    WeightEntry? next,
  ) async {
    final saved = await _storage.writeWeightChange(snapshot, next);
    String? warning = saved.warning;
    try {
      _weightEntries = await _storage.getWeightEntries();
    } catch (_) {
      warning =
          '${warning ?? 'Изменение сохранено.'} Обновите экран истории веса.';
    }
    try {
      final profileEpoch = _profileEditEpoch;
      final currentProfile = _profile;
      final writesPending = _profileWritesPending;
      final profileDocument = _storage.local.get('user_profile');
      final storedProfile = await _storage.getUserProfile();
      // Never replace an in-progress settings edit, or a more recent profile,
      // with the value read by a concurrent history operation.
      if (writesPending == 0 &&
          _profileWritesPending == 0 &&
          _profileEditEpoch == profileEpoch &&
          identical(_profile, currentProfile) &&
          _storage.local.get('user_profile') == profileDocument) {
        _profile = storedProfile;
      }
    } catch (_) {
      warning =
          '${warning ?? 'Изменение сохранено.'} Проверьте профиль в настройках.';
    }
    notifyListeners();
    return WeightChangeResult(warning: warning);
  }

  Future<WeightChangeResult> addWeightEntry(
    WeightEntry entry, {
    WeightEditSnapshot? snapshot,
  }) {
    if (snapshot != null && snapshot.entryId != null) {
      throw const WeightEditException(
        'Нельзя создать измерение из снимка редактирования.',
      );
    }
    return _finishWeightChange(snapshot ?? captureWeightEdit(), entry);
  }

  Future<WeightChangeResult> updateWeightEntry(
    WeightEntry entry, {
    WeightEditSnapshot? snapshot,
  }) {
    final original = _weightEntries
        .where((item) => item.id == entry.id)
        .firstOrNull;
    if ((snapshot == null && original == null) ||
        (snapshot != null && snapshot.entryId != entry.id)) {
      throw const WeightEditException('Измерение уже удалено или изменилось.');
    }
    return _finishWeightChange(snapshot ?? captureWeightEdit(original), entry);
  }

  Future<WeightChangeResult> deleteWeightEntry(
    String id, {
    WeightEditSnapshot? snapshot,
  }) {
    final original = _weightEntries.where((item) => item.id == id).firstOrNull;
    if ((snapshot == null && original == null) ||
        (snapshot != null && snapshot.entryId != id)) {
      throw const WeightEditException('Измерение уже удалено или изменилось.');
    }
    return _finishWeightChange(snapshot ?? captureWeightEdit(original), null);
  }

  // --- Тренировки ---

  Future<void> addWorkoutEntry(WorkoutEntry entry) async {
    if (entry.caloriesBurned < 0 || entry.durationMinutes <= 0) {
      throw ArgumentError('Некорректная тренировка');
    }
    if (entry.details != null) WorkoutEntry.fromJson(entry.toJson());
    if (_todayWorkoutEntries.any((e) => e.id == entry.id)) return;
    if (dayKey(entry.date) == dayKey(_selectedDate)) {
      _todayWorkoutEntries.add(entry);
      _todayWorkoutCompleted = true;
    }
    _patchLog(entry.date, workoutDone: true);
    _successFeedback();
    notifyListeners();
    await _persistDiary(() => _storage.addWorkoutEntry(entry));
  }

  Future<void> updateWorkoutEntry(WorkoutEntry entry) async {
    if (entry.caloriesBurned < 0 || entry.durationMinutes <= 0) {
      throw ArgumentError('Некорректная тренировка');
    }
    if (entry.details != null) WorkoutEntry.fromJson(entry.toJson());
    final index = _todayWorkoutEntries.indexWhere((e) => e.id == entry.id);
    if (index < 0) return;
    if (dayKey(_todayWorkoutEntries[index].date) != dayKey(entry.date)) {
      throw ArgumentError('Нельзя менять дату тренировки');
    }
    _todayWorkoutEntries[index] = entry;
    notifyListeners();
    await _persistDiary(() => _storage.updateWorkoutEntry(entry));
  }

  Future<void> deleteWorkoutEntry(String id) async {
    final index = _todayWorkoutEntries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final entry = _todayWorkoutEntries.removeAt(index);
    final completed = _todayWorkoutEntries.isNotEmpty;
    _todayWorkoutCompleted = completed;
    _patchLog(entry.date, workoutDone: completed);
    notifyListeners();
    await _persistDiary(() => _storage.deleteWorkoutEntry(id, entry.date));
  }

  Future<void> toggleWorkoutCompleted() async {
    final date = _selectedDate;
    final completed = !_todayWorkoutCompleted;
    _todayWorkoutCompleted = completed;
    _patchLog(date, workoutDone: completed);
    if (completed) {
      _successFeedback();
    } else {
      _tapFeedback();
    }
    notifyListeners();
    await _persistDiary(() => _storage.setWorkoutCompleted(date, completed));
  }

  // --- Вода ---

  Future<void> addWater(int ml) async {
    if (ml < 0) throw ArgumentError('Объём воды не может быть отрицательным');
    final date = _selectedDate;
    final before = _todayWaterIntake;
    final value = before + ml;
    _todayWaterIntake = value;
    _patchLog(date, waterDelta: ml, hasWaterRecord: true);
    _lightFeedback();
    final waterGoal = confirmedWaterGoal;
    if (waterGoal != null && before < waterGoal && value >= waterGoal) {
      _successFeedback();
    }
    notifyListeners();
    // Relative, queued read-modify-write: a stale absolute value from another
    // view cannot erase this increment. Reconcile the optimistic UI afterwards.
    await _persistDiary(() => _storage.addWaterIntake(date, ml));
    // Other views may have queued increments behind ours; drain the shared
    // queue before reconciling so the UI never keeps a stale absolute value.
    await _storage.pendingMutations;
    final persisted = await _storage.getWaterIntake(date);
    if (_todayWaterIntake != persisted) {
      _todayWaterIntake = persisted;
      _patchLog(date, waterDelta: persisted - value, hasWaterRecord: true);
      notifyListeners();
    }
  }

  Future<void> setWaterIntake(int ml) async {
    if (ml < 0) throw ArgumentError('Объём воды не может быть отрицательным');
    final date = _selectedDate;
    final delta = ml - _todayWaterIntake;
    _todayWaterIntake = ml;
    _patchLog(date, waterDelta: delta, hasWaterRecord: true);
    notifyListeners();
    await _persistDiary(() => _storage.setWaterIntake(date, ml));
  }

  // --- Шаги ---

  Future<void> addSteps(int steps) async {
    if (steps < 0)
      throw ArgumentError('Количество шагов не может быть отрицательным');
    final date = _selectedDate;
    final total = _todaySteps + steps;
    _todaySteps = total;
    _patchLog(date, stepsDelta: steps, hasStepsRecord: true);
    _lightFeedback();
    notifyListeners();
    await _persistDiary(() => _storage.addSteps(date, steps));
    await _storage.pendingMutations;
    final persisted = await _storage.getSteps(date);
    if (_todaySteps != persisted) {
      _todaySteps = persisted;
      _patchLog(date, stepsDelta: persisted - total, hasStepsRecord: true);
      notifyListeners();
    }
  }

  Future<void> setSteps(int steps) async {
    if (steps < 0)
      throw ArgumentError('Количество шагов не может быть отрицательным');
    final date = _selectedDate;
    final delta = steps - _todaySteps;
    _todaySteps = steps;
    _patchLog(date, stepsDelta: delta, hasStepsRecord: true);
    notifyListeners();
    await _persistDiary(() => _storage.setSteps(date, steps));
  }

  // --- Профиль ---

  Future<void> updateProfile(UserProfile profile) async {
    final previous = _profile;
    _profileEditEpoch++;
    _profileWritesPending++;
    _profile = profile;
    notifyListeners();
    try {
      await _storage.saveUserProfile(profile, expectedProfile: previous);
    } catch (_) {
      // Another edit can have failed too, so reload the durable value rather
      // than promoting that edit's optimistic in-memory snapshot.
      if (identical(_profile, profile)) {
        try {
          final stored = await _storage.getUserProfile();
          if (identical(_profile, profile)) _profile = stored;
        } catch (_) {
          if (identical(_profile, profile)) _profile = previous;
        }
        notifyListeners();
      }
      rethrow;
    } finally {
      _profileWritesPending--;
    }
  }

  // --- Напоминания ---

  Future<void> updateReminders(ReminderSettings settings) async {
    _reminders = settings;
    notifyListeners();
    await _storage.saveReminderSettings(settings);
    await NotificationService.schedule(settings);
  }

  // --- Быстрые действия ---

  Future<void> quickAddWater([int ml = 250]) => addWater(ml);
  Future<void> quickAddSteps() => addSteps(1000);

  /// Callers must provide reviewed values; never silently record profile
  /// defaults (historically 70 minutes / 500 kcal) as a real workout.
  Future<void> quickAddWorkout({
    required int durationMinutes,
    required int caloriesBurned,
    WorkoutType type = WorkoutType.strengthCardio,
  }) async {
    if (_todayWorkoutCompleted) return;
    await addWorkoutEntry(
      WorkoutEntry(
        type: type,
        durationMinutes: durationMinutes,
        caloriesBurned: caloriesBurned,
        date: _selectedDate,
      ),
    );
  }

  // --- Экспорт / импорт ---

  Future<String> exportDataJson() async {
    await _storage.pendingMutations;
    final payload = await _storage.exportData();
    return JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Возвращает null при успехе или текст ошибки.
  Future<String?> importDataJson(String raw) async {
    try {
      await _storage.pendingMutations;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return 'Неверный формат JSON';
      }
      if (decoded['app'] != 'fitness_tracker') {
        return 'Это резервная копия другого приложения';
      }
      if (decoded['data'] is! Map) {
        return 'В файле нет данных для импорта';
      }
      final ok = await _storage.importData(decoded);
      if (!ok) return 'Не удалось импортировать данные';
      await reloadAll();
      _successFeedback();
      return null;
    } on ImportRecoveryRequired {
      persistenceError =
          'Импорт прерван. Требуется восстановление локальной копии.';
      notifyListeners();
      return persistenceError;
    } on FormatException {
      return 'Некорректная резервная копия. Данные не заменены.';
    } on StateError catch (error) {
      return 'Импорт не завершён: ${error.message}';
    } catch (_) {
      return 'Импорт не завершён. Проверьте файл и свободное место.';
    }
  }

  Future<void> discardImportBackup() async {
    await _storage.discardImportBackup();
    notifyListeners();
  }

  Future<void> clearAllData() async {
    await _storage.clearAll();
    smartSettings = {};
    _profile = UserProfile();
    _selectedDate = DateTime.now();
    _todayFoodEntries = [];
    _todaySupplementEntries = [];
    _todayWorkoutEntries = [];
    _weightEntries = [];
    _quickFoods = [];
    _recipes = [];
    _dayLogs = [];
    _reminders = ReminderSettings();
    _todayWaterIntake = 0;
    _todaySteps = 0;
    _todayWorkoutCompleted = false;
    await NotificationService.cancelAll();
    await _storage.init();
    notifyListeners();
  }

  // --- Внутренние помощники ---

  void _patchLog(
    DateTime date, {
    double? caloriesDelta,
    int? waterDelta,
    int? stepsDelta,
    bool? workoutDone,
    bool? hasFoodRecord,
    bool? hasWaterRecord,
    bool? hasStepsRecord,
  }) {
    final normalized = DateTime(date.year, date.month, date.day);
    final key = dayKey(normalized);
    final index = _dayLogs.indexWhere((log) => dayKey(log.date) == key);
    final base = index >= 0 ? _dayLogs[index] : DayLog(date: normalized);
    final updated = DayLog(
      date: normalized,
      calories: hasFoodRecord == false
          ? 0
          : base.calories + (caloriesDelta ?? 0),
      water: base.water + (waterDelta ?? 0),
      steps: base.steps + (stepsDelta ?? 0),
      workoutDone: workoutDone ?? base.workoutDone,
      hasFoodRecord: hasFoodRecord ?? base.hasFoodRecord,
      hasWaterRecord: hasWaterRecord ?? base.hasWaterRecord,
      hasStepsRecord: hasStepsRecord ?? base.hasStepsRecord,
    );

    if (index >= 0) {
      _dayLogs[index] = updated;
    } else {
      _dayLogs.add(updated);
    }
    _dayLogs.sort((a, b) => a.date.compareTo(b.date));
  }

  void _tapFeedback() {
    HapticFeedback.selectionClick().ignore();
  }

  void _lightFeedback() {
    HapticFeedback.lightImpact().ignore();
  }

  void _successFeedback() {
    HapticFeedback.mediumImpact().ignore();
  }
}

// ============================================================================
// ЛОКАЛЬНЫЕ НАПОМИНАНИЯ
// ============================================================================

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _systemAvailable = false;

  static bool get systemAvailable => _systemAvailable;

  /// Системные уведомления поддерживаются на Android и iOS.
  /// На вебе и десктопе работают мягкие напоминания внутри приложения.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static Future<void> init() async {
    if (!isSupported) return;
    try {
      _setFixedLocalTimeZone();
      final ok = await _plugin.initialize(
        settings: InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _systemAvailable = ok ?? false;
    } catch (_) {
      _systemAvailable = false;
    }
  }

  /// Фиксированный часовой пояс устройства без пакета геолокации:
  /// смещение берётся у системы, поэтому время напоминаний совпадает
  /// с локальным (при переходе на летнее время приложение
  /// пересчитывает расписание при следующем запуске).
  static void _setFixedLocalTimeZone() {
    final offset = DateTime.now().timeZoneOffset;
    tz.setLocalLocation(
      tz.Location('Local', [-8640000000000000], [0], [
        tz.TimeZone(offset, isDst: false, abbreviation: 'LOCAL'),
      ]),
    );
  }

  static Future<bool> requestPermissions() async {
    if (!_systemAvailable) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        return await android?.requestNotificationsPermission() ?? false;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        return await ios?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
    } catch (_) {}
    return false;
  }

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'fitness_reminders',
      'Напоминания',
      channelDescription: 'Вода, приёмы пищи и взвешивание',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
    iOS: DarwinNotificationDetails(),
  );

  static Future<void> schedule(ReminderSettings settings) async {
    if (!_systemAvailable) return;
    try {
      await _plugin.cancelAllPendingNotifications();
      final now = tz.TZDateTime.now(tz.local);

      if (settings.waterEnabled) {
        final step = settings.waterEveryHours.clamp(1, 6);
        var id = 100;
        for (var hour = 9; hour <= 21; hour += step) {
          await _scheduleDaily(
            id: id++,
            title: 'Пора выпить воды 💧',
            body: 'Добавьте стакан воды, чтобы держать баланс.',
            date: _nextAt(now, hour),
          );
        }
      }
      if (settings.lunchEnabled) {
        await _scheduleDaily(
          id: 10,
          title: 'Запишите обед 🍽️',
          body: 'Отметьте приём пищи в дневнике питания.',
          date: _nextAt(now, settings.lunchHour),
        );
      }
      if (settings.weightEnabled) {
        await _scheduleDaily(
          id: 11,
          title: 'Утреннее взвешивание ⚖️',
          body: 'Взвесьтесь и запишите результат — так виден тренд.',
          date: _nextAt(now, settings.weightHour),
        );
      }
    } catch (_) {}
  }

  static Future<void> _scheduleDaily({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime date,
  }) async {
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: date,
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  static tz.TZDateTime _nextAt(tz.TZDateTime now, int hour) {
    var result = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour.clamp(0, 23),
      0,
    );
    if (!result.isAfter(now)) {
      result = result.add(Duration(days: 1));
    }
    return result;
  }

  static Future<void> showNow({
    String title = 'Fitness Tracker',
    String body = 'Тестовое уведомление — всё работает!',
  }) async {
    if (!_systemAvailable) return;
    try {
      await _plugin.show(
        id: 1,
        title: title,
        body: body,
        notificationDetails: _details,
      );
    } catch (_) {}
  }

  static Future<void> cancelAll() async {
    if (!_systemAvailable) return;
    try {
      await _plugin.cancelAllPendingNotifications();
    } catch (_) {}
  }
}

// ============================================================================
// ТЕМА — MODERN DARK PREMIUM
// ============================================================================

class AppTheme {
  /// Keep the legacy theme value (`dark`/`light`/`oled`) intact in synced
  /// documents so 3.0 clients can still read them. The optional marker makes
  /// a manual theme changed by an older client take precedence over system.
  static bool followsSystem(Map<String, dynamic> settings) {
    if (settings['themeFollowSystem'] != true) return false;
    final saved = settings['theme'] as String? ?? 'dark';
    final fallback = settings['systemThemeFallback'];
    return fallback == null || fallback == saved;
  }

  static void configure(
    Map<String, dynamic> settings, {
    Brightness? platformBrightness,
  }) {
    final legacyMode = settings['theme'] as String? ?? 'dark';
    final mode = followsSystem(settings)
        ? ((platformBrightness ??
                      WidgetsBinding
                          .instance
                          .platformDispatcher
                          .platformBrightness) ==
                  Brightness.light
              ? 'light'
              : 'dark')
        : legacyMode;
    final isLight = mode == 'light';
    background = isLight
        ? Color(0xFFF2F5F9)
        : mode == 'oled'
        ? Colors.black
        : Color(0xFF121418);
    surface = isLight
        ? Colors.white
        : mode == 'oled'
        ? Color(0xFF080808)
        : Color(0xFF1E222A);
    surfaceHigh = isLight ? Color(0xFFE7ECF3) : Color(0xFF262C36);
    surfaceSoft = isLight ? Color(0xFFEFF2F7) : Color(0xFF171B21);
    textPrimary = isLight ? Color(0xFF17212B) : Color(0xFFF2F5F9);
    textSecondary = isLight ? Color(0xFF526171) : Color(0xFF9AA4B2);
    blue = isLight ? Color(0xFF0369A1) : Color(0xFF4FC3F7);
    amber = isLight ? Color(0xFF9A6400) : Color(0xFFFFC857);
    secondary = isLight ? Color(0xFF6D28D9) : Color(0xFF7C6CFF);
    carbs = isLight ? Color(0xFF047857) : Color(0xFF69F0AE);
    borderGradient = LinearGradient(
      colors: [
        textPrimary.withValues(alpha: .18),
        textPrimary.withValues(alpha: .04),
      ],
    );
    primary = Color(
      settings['accent'] as int? ?? (isLight ? 0xFF008577 : 0xFF00E676),
    );
    cardGradient = LinearGradient(colors: [surfaceHigh, surface]);
    heroGradient = LinearGradient(colors: [surfaceHigh, surfaceSoft]);
    primaryGradient = LinearGradient(
      colors: [primary, primary.withValues(alpha: .75)],
    );
  }

  static Color background = Color(0xFF121418);
  static Color surface = Color(0xFF1E222A);
  static Color surfaceHigh = Color(0xFF262C36);
  static Color surfaceSoft = Color(0xFF171B21);
  static Color primary = Color(0xFF00E676);
  static Color primaryDeep = Color(0xFF00B85F);
  static Color secondary = Color(0xFF7C6CFF);
  static Color blue = Color(0xFF4FC3F7);
  static Color amber = Color(0xFFFFC857);
  static Color carbs = Color(0xFF69F0AE);
  static Color error = Color(0xFFFF5C5C);
  static Color outline = Color(0xFF2A303A);
  static Color textPrimary = Color(0xFFF2F5F9);
  static Color textSecondary = Color(0xFF9AA4B2);

  static LinearGradient cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppTheme.surface, AppTheme.surface],
  );

  static LinearGradient heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF202A33), Color(0xFF15191F)],
  );

  static LinearGradient borderGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x33FFFFFF), Color(0x08FFFFFF)],
  );

  static LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00E676), Color(0xFF00C2A8)],
  );

  static ThemeData get darkTheme {
    final scheme = ColorScheme.fromSeed(
      brightness: background.computeLuminance() > .5
          ? Brightness.light
          : Brightness.dark,
      seedColor: primary,
      primary: primary,
      onPrimary: primary.computeLuminance() > .4 ? Colors.black : Colors.white,
      secondary: secondary,
      onSecondary: Colors.white,
      tertiary: amber,
      onTertiary: Color(0xFF231A00),
      surface: surface,
      onSurface: textPrimary,
      outline: outline,
      error: error,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: surface,
      textTheme: TextTheme(
        displayLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -2),
        displayMedium: TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: -1,
        ),
        headlineSmall: TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.6,
        ),
        titleLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleMedium: TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        titleSmall: TextStyle(fontWeight: FontWeight.w700),
        bodyLarge: TextStyle(fontWeight: FontWeight.w500),
        bodyMedium: TextStyle(fontWeight: FontWeight.w500),
        bodySmall: TextStyle(fontWeight: FontWeight.w500, color: textSecondary),
        labelLarge: TextStyle(fontWeight: FontWeight.w600),
        labelMedium: TextStyle(
          fontWeight: FontWeight.w600,
          color: textSecondary,
        ),
        labelSmall: TextStyle(
          fontWeight: FontWeight.w600,
          color: textSecondary,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      iconTheme: IconThemeData(color: textPrimary),
      dividerTheme: DividerThemeData(
        color: Colors.white.withValues(alpha: 0.06),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppTheme.surface,
        indicatorColor: primary.withValues(alpha: 0.16),
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        hintStyle: TextStyle(color: textSecondary),
        labelStyle: TextStyle(color: textSecondary),
        prefixIconColor: textSecondary,
        suffixIconColor: textSecondary,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: error, width: 1.4),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: Size(0, 52),
          padding: EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          minimumSize: Size(0, 52),
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: StadiumBorder(),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHigh,
        contentTextStyle: TextStyle(color: textPrimary),
        actionTextColor: primary,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: surfaceHigh,
        circularTrackColor: surfaceHigh,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: surfaceHigh,
        thumbColor: primary,
        overlayColor: primary.withValues(alpha: 0.2),
        valueIndicatorColor: primary,
        valueIndicatorTextStyle: TextStyle(color: Color(0xFF052012)),
      ),
    );
  }
}

// ============================================================================
// UI-ОСНОВА: ЦЕНТРИРОВАНИЕ, КАРТОЧКИ, ИКОНКИ, ПРОГРЕСС
// ============================================================================

const double kAppMaxWidth = 600;

const List<String> _ruMonths = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

const List<String> _ruMonthsShort = [
  'янв',
  'фев',
  'мар',
  'апр',
  'мая',
  'июн',
  'июл',
  'авг',
  'сен',
  'окт',
  'ноя',
  'дек',
];

String formatNumber(int value) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return '${negative ? '-' : ''}$buffer';
}

String formatDateRu(DateTime date) =>
    '${date.day} ${_ruMonths[date.month - 1]} ${date.year}';

String formatShortDateRu(DateTime date) =>
    '${date.day} ${_ruMonthsShort[date.month - 1]}';

/// Ограничивает ширину контента 600 px и центрирует его
/// (важно для веба и планшетов).
class CenteredBody extends StatelessWidget {
  final Widget child;

  const CenteredBody({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: kAppMaxWidth),
        child: child,
      ),
    );
  }
}

/// Премиальная карточка: тёмный градиент, тонкая градиентная рамка,
/// скругление 24 px и мягкая тень.
class PremiumCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final double radius;
  final Gradient? gradient;
  final Gradient? borderGradient;
  final bool glow;
  final Color? glowColor;

  const PremiumCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.onTap,
    this.radius = 24,
    this.gradient,
    this.borderGradient,
    this.glow = false,
    this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    final accent = glowColor ?? AppTheme.primary;

    return Container(
      margin: margin,
      padding: EdgeInsets.all(1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius + 1),
        gradient: borderGradient ?? AppTheme.borderGradient,
        boxShadow: [
          if (glow)
            BoxShadow(
              color: accent.withValues(alpha: 0.16),
              blurRadius: 34,
              offset: Offset(0, 14),
            )
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 22,
              offset: Offset(0, 10),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: gradient ?? AppTheme.cardGradient,
            ),
            child: InkWell(
              onTap: onTap,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class RoundIconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final double? iconSize;
  final bool glow;

  const RoundIconBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 46,
    this.iconSize,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.32),
            color.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        boxShadow: glow
            ? [BoxShadow(color: color.withValues(alpha: 0.28), blurRadius: 20)]
            : null,
      ),
      child: Icon(icon, size: iconSize ?? size * 0.5, color: color),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              if (subtitle != null) ...[
                SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class CircleActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final double size;
  final double iconSize;

  const CircleActionButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.color,
    this.size = 44,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppTheme.primary;
    return Material(
      color: Colors.transparent,
      shape: CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: CircleBorder(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withValues(alpha: 0.12),
            border: Border.all(color: accent.withValues(alpha: 0.28)),
          ),
          child: Icon(icon, size: iconSize, color: accent),
        ),
      ),
    );
  }
}

class GradientProgressBar extends StatelessWidget {
  final double value;
  final Color color;
  final double height;

  const GradientProgressBar({
    super.key,
    required this.value,
    required this.color,
    this.height = 8,
  });

  @override
  Widget build(BuildContext context) {
    final safeValue = value.isNaN ? 0.0 : value.clamp(0.0, 1.0).toDouble();
    return SpringProgress(
      tween: Tween<double>(begin: 0, end: safeValue),
      duration: MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, animatedValue, _) => Container(
        width: double.infinity,
        height: height,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(height),
        ),
        child: FractionallySizedBox(
          widthFactor: animatedValue,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height),
              gradient: LinearGradient(
                colors: [color.withValues(alpha: 0.55), color],
              ),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// ВИДЖЕТ: ОБЪЁМНАЯ КАРТОЧКА БЖУ
// ============================================================================

class MacroProgressBar extends StatelessWidget {
  final String label;
  final double consumed;
  final int? target;
  final Color color;
  final VoidCallback? onTap;
  final IconData icon;

  const MacroProgressBar({
    super.key,
    required this.label,
    required this.consumed,
    required this.target,
    required this.color,
    this.onTap,
    required this.icon,
  });

  double? get progress => availableGoalProgress(consumed, target);
  bool get isOver => target != null && target! > 0 && consumed > target!;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goal = target;
    final fraction = progress;
    final percent = fraction == null ? null : (fraction * 100).round();
    final left = goal == null ? null : goal - consumed;

    return PremiumCard(
      onTap: onTap,
      radius: 22,
      padding: EdgeInsets.fromLTRB(14, 15, 14, 14),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.18), AppTheme.surface],
      ),
      borderGradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0.04)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RoundIconBadge(icon: icon, color: color, size: 34, iconSize: 17),
              Spacer(),
              Text(
                percent != null ? '$percent%' : '—',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
          SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: formatGrams(consumed),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  TextSpan(
                    text: goal != null
                        ? ' / $goal г'
                        : ' г / цель не подтверждена',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (fraction != null) ...[
            SizedBox(height: 10),
            GradientProgressBar(value: fraction, color: color, height: 7),
          ],
          SizedBox(height: 8),
          Text(
            goal == null
                ? 'Проверьте цель в профиле'
                : goal == 0
                ? 'Цель 0 г · процент недоступен'
                : isOver
                ? '+${formatGrams(consumed - goal)} г сверх'
                : 'Осталось ${formatGrams(max(0, left!))} г',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: isOver ? AppTheme.error : AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ВИДЖЕТ: КРУГОВОЙ ИНДИКАТОР КАЛОРИЙ
// ============================================================================

class CircularCalorieIndicator extends StatelessWidget {
  final int consumed;
  final int target;
  final double size;
  final VoidCallback? onTap;

  const CircularCalorieIndicator({
    super.key,
    required this.consumed,
    required this.target,
    this.size = 200,
    this.onTap,
  });

  double get progress =>
      target > 0 ? (consumed / target).clamp(0.0, 1.0).toDouble() : 0.0;
  int get remaining => max(0, target - consumed);
  bool get isOver => consumed > target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = isOver ? AppTheme.error : AppTheme.primary;
    final display = isOver ? consumed - target : remaining;

    return Semantics(
      button: true,
      label: 'Калории. Открыть разбивку за день',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size / 2),
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SpringProgress(
                tween: Tween<double>(begin: 0, end: progress),
                duration: MediaQuery.of(context).disableAnimations
                    ? Duration.zero
                    : Duration(milliseconds: 650),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => CustomPaint(
                  size: Size.square(size),
                  painter: _CalorieRingPainter(progress: value, accent: accent),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isOver ? 'ВЫШЕ ОРИЕНТИРА' : 'ДО ОРИЕНТИРА',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2.4,
                      fontWeight: FontWeight.w700,
                      color: accent.withValues(alpha: 0.9),
                    ),
                  ),
                  SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatNumber(display),
                      style: TextStyle(
                        fontSize: size * 0.21,
                        height: 1.0,
                        letterSpacing: -1.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    isOver ? 'ккал выше ориентира' : 'ккал',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  SizedBox(height: 12),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Text(
                      'По записям ${formatNumber(consumed)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalorieRingPainter extends CustomPainter {
  final double progress;
  final Color accent;

  static const double _strokeWidth = 14;

  const _CalorieRingPainter({required this.progress, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (min(size.width, size.height) - _strokeWidth - 8) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const startAngle = -pi / 2;
    const fullAngle = pi * 2;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..color = Color(0xFF232933);
    canvas.drawCircle(center, radius, track);

    if (progress <= 0) return;

    final sweep = fullAngle * progress;

    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth + 10
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: 0.16);
    canvas.drawArc(rect, startAngle, sweep, false, halo);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [accent.withValues(alpha: 0.55), accent, Color(0xFFB9FFD9)],
        stops: [0.0, 0.5, 1.0],
        transform: GradientRotation(-pi / 2),
      ).createShader(rect);
    canvas.drawArc(rect, startAngle, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_CalorieRingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.accent != accent;
}

// ============================================================================
// ВИДЖЕТ: БЫСТРЫЕ ДЕЙСТВИЯ (СЕТКА)
// ============================================================================

class QuickActionButtons extends StatelessWidget {
  final AppDataProvider provider;

  const QuickActionButtons({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final workoutDone = provider.todayWorkoutCompleted;

    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: constraints.maxWidth < 420 ? 2 : 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          mainAxisExtent: 152,
        ),
        itemCount: 3,
        itemBuilder: (context, index) {
          switch (index) {
            case 0:
              return _QuickActionButton(
                icon: Icons.water_drop_rounded,
                title: 'Вода',
                value: provider.hasRecordedWater
                    ? formatNumber(provider.todayWaterIntake)
                    : 'Нет записи',
                caption: provider.confirmedWaterGoal == null
                    ? 'цель не подтверждена'
                    : provider.hasRecordedWater
                    ? 'из ${formatNumber(provider.confirmedWaterGoal!)} мл'
                    : 'цель ${formatNumber(provider.confirmedWaterGoal!)} мл',
                hint: '+250 мл',
                color: AppTheme.blue,
                progress: provider.hasRecordedWater
                    ? provider.waterProgress
                    : null,
                onTap: provider.quickAddWater,
              );
            case 1:
              return _QuickActionButton(
                icon: Icons.directions_walk_rounded,
                title: 'Шаги',
                value: provider.hasRecordedSteps
                    ? formatNumber(provider.todaySteps)
                    : 'Нет записи',
                caption: provider.confirmedStepsGoal == null
                    ? 'цель не подтверждена'
                    : provider.hasRecordedSteps
                    ? 'из ${formatNumber(provider.confirmedStepsGoal!)}'
                    : 'цель ${formatNumber(provider.confirmedStepsGoal!)}',
                hint: '+1 000',
                color: AppTheme.amber,
                progress: provider.hasRecordedSteps
                    ? provider.stepsProgress
                    : null,
                onTap: provider.quickAddSteps,
              );
            default:
              return _QuickActionButton(
                icon: workoutDone
                    ? Icons.check_rounded
                    : Icons.fitness_center_rounded,
                title: 'Тренировка',
                value: workoutDone ? 'Добавить' : 'Записать',
                caption: 'Расчёт и упражнения',
                hint: '+',
                color: workoutDone ? AppTheme.primary : AppTheme.secondary,
                progress: workoutDone ? 1.0 : null,
                onTap: () => showWorkoutEditor(context, provider),
                isCompleted: workoutDone,
              );
          }
        },
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String caption;
  final String hint;
  final Color color;
  final double? progress;
  final VoidCallback onTap;
  final bool isCompleted;

  const _QuickActionButton({
    required this.icon,
    required this.title,
    required this.value,
    required this.caption,
    required this.hint,
    required this.color,
    required this.progress,
    required this.onTap,
    this.isCompleted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PremiumCard(
      radius: 22,
      padding: EdgeInsets.all(12),
      onTap: onTap,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.16), AppTheme.surface],
      ),
      borderGradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.42), color.withValues(alpha: 0.03)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RoundIconBadge(
                icon: icon,
                color: color,
                size: 40,
                iconSize: 20,
                glow: isCompleted,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: color.withValues(alpha: 0.26),
                        ),
                      ),
                      child: Text(
                        hint,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Spacer(),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
          SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: 17,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9.5,
              color: AppTheme.textSecondary,
            ),
          ),
          SizedBox(height: 8),
          if (progress != null)
            GradientProgressBar(value: progress!, color: color, height: 5)
          else
            const SizedBox(height: 5),
        ],
      ),
    );
  }
}

// ============================================================================
// ВИДЖЕТ: ПРИЁМ ПИЩИ
// ============================================================================

class MealSection extends StatelessWidget {
  final MealType mealType;
  final List<FoodEntry> entries;
  final AppDataProvider provider;
  final VoidCallback onAddFood;

  const MealSection({
    super.key,
    required this.mealType,
    required this.entries,
    required this.provider,
    required this.onAddFood,
  });

  Color get _accent {
    switch (mealType) {
      case MealType.breakfast:
        return AppTheme.amber;
      case MealType.lunch:
        return AppTheme.primary;
      case MealType.snack:
        return AppTheme.blue;
      case MealType.dinner:
        return AppTheme.secondary;
      case MealType.preWorkout:
        return AppTheme.amber;
      case MealType.postWorkout:
        return AppTheme.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mealCalories = entries
        .fold(0.0, (sum, e) => sum + e.calories)
        .round();
    final mealProtein = entries.fold(0.0, (sum, e) => sum + e.protein);
    final mealFat = entries.fold(0.0, (sum, e) => sum + e.fat);
    final mealCarbs = entries.fold(0.0, (sum, e) => sum + e.carbs);

    return PremiumCard(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RoundIconBadge(
                icon: mealType.icon,
                color: _accent,
                size: 44,
                iconSize: 21,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(mealType.label, style: theme.textTheme.titleMedium),
                    SizedBox(height: 3),
                    Text(
                      entries.isEmpty
                          ? 'Пока пусто'
                          : '$mealCalories ккал · Б ${mealProtein.round()} · Ж ${mealFat.round()} · У ${mealCarbs.round()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              CircleActionButton(
                icon: Icons.add_rounded,
                color: _accent,
                size: 38,
                iconSize: 20,
                onTap: onAddFood,
              ),
            ],
          ),
          if (entries.isEmpty)
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(top: 14),
              padding: EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_circle_outline_rounded,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Добавьте первый продукт',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: EdgeInsets.only(top: 14),
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    FoodEntryCard(entry: entries[i], provider: provider),
                    if (i < entries.length - 1) SizedBox(height: 8),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// ВИДЖЕТ: ЗАПИСЬ О ПРОДУКТЕ
// ============================================================================

class FoodEntryCard extends StatelessWidget {
  final FoodEntry entry;
  final AppDataProvider provider;

  const FoodEntryCard({super.key, required this.entry, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grams = entry.amountGrams;
    final gramsText = grams == grams.truncateToDouble()
        ? grams.toStringAsFixed(0)
        : grams.toStringAsFixed(1);

    return Dismissible(
      key: Key(entry.id),
      direction: DismissDirection.horizontal,
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: 18),
        color: AppTheme.error.withValues(alpha: .15),
        child: Icon(Icons.delete_outline),
      ),
      background: Container(
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.only(right: 18),
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.error.withValues(alpha: 0.30)),
        ),
        child: Icon(Icons.edit_outlined, color: AppTheme.primary),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await editPortion(context, provider, entry);
          return false;
        }
        final snapshot = provider.captureFoodEdit(entry);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            title: Text('Удалить продукт?'),
            content: Text('Удалить «${entry.name}» из дневника?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Отмена'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: AppTheme.error),
                child: Text('Удалить'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          try {
            await provider.deleteFoodEntry(entry.id, snapshot: snapshot);
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(
                  content: Text(
                    provider.persistenceError ?? 'Не удалось удалить продукт.',
                  ),
                ),
              );
            }
          }
        }
        // The durable write itself updates the list. On failure the card
        // returns to its place; no optimistic dismissal can hide a lost write.
        return false;
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _showEditDialog(context),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.035),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppTheme.primary.withValues(alpha: 0.10),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.20),
                    ),
                  ),
                  child: Icon(
                    Icons.restaurant_rounded,
                    size: 18,
                    color: AppTheme.primary,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '$gramsText г · Б ${entry.protein.round()} · Ж ${entry.fat.round()} · У ${entry.carbs.round()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10.5,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      if (entry.microsEstimated && entry.micros.isNotEmpty)
                        Text(
                          'Витамины: оценка ИИ',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${entry.calories.round()}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primary,
                      ),
                    ),
                    Text(
                      'ккал',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 9,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
                SizedBox(width: 2),
                Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: AppTheme.textSecondary.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showEditDialog(BuildContext context) =>
      showFoodEditor(context, provider, entry);
}

enum _FoodDialogTab { all, favorites, recipes }

class AddFoodDialog extends StatefulWidget {
  final AppDataProvider provider;
  final MealType mealType;

  const AddFoodDialog({
    super.key,
    required this.provider,
    required this.mealType,
  });

  @override
  State<AddFoodDialog> createState() => _AddFoodDialogState();
}

class _AddFoodDialogState extends State<AddFoodDialog> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _amountController = TextEditingController(
    text: '100',
  );
  final TextEditingController _customName = TextEditingController();
  final TextEditingController _customCalories = TextEditingController();
  final TextEditingController _customProtein = TextEditingController();
  final TextEditingController _customFat = TextEditingController();
  final TextEditingController _customCarbs = TextEditingController();

  _FoodDialogTab _tab = _FoodDialogTab.all;
  String _searchQuery = '';
  FoodItem? _selectedFood;
  Recipe? _selectedRecipe;
  bool _isCustom = false;
  bool _saving = false;
  String? _inputError;

  @override
  void dispose() {
    _searchController.dispose();
    _amountController.dispose();
    _customName.dispose();
    _customCalories.dispose();
    _customProtein.dispose();
    _customFat.dispose();
    _customCarbs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = mealAccent(widget.mealType);
    final canAdd =
        _selectedFood != null || _selectedRecipe != null || _isCustom;

    if (MediaQuery.sizeOf(context).width < 600) {
      return PopScope(
        canPop: !_saving,
        child: AbsorbPointer(
          absorbing: _saving,
          child: _buildMobileDialog(
            theme,
            accent,
            canAdd,
            MediaQuery.viewInsetsOf(context).bottom > 0,
          ),
        ),
      );
    }
    return PopScope(
      canPop: !_saving,
      child: AbsorbPointer(
        absorbing: _saving,
        child: AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          titlePadding: EdgeInsets.fromLTRB(22, 20, 22, 8),
          contentPadding: EdgeInsets.fromLTRB(20, 0, 20, 4),
          title: Row(
            children: [
              RoundIconBadge(
                icon: widget.mealType.icon,
                color: accent,
                size: 36,
                iconSize: 18,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'В ${widget.mealType.label.toLowerCase()}',
                      style: theme.textTheme.titleLarge,
                    ),
                    Text(
                      widget.provider
                              .getFoodEntriesForMeal(widget.mealType)
                              .isEmpty
                          ? 'В приёме пока нет записей'
                          : '${widget.provider.getMealCalories(widget.mealType)} ккал по записям',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_inputError != null)
                    Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        _inputError!,
                        style: TextStyle(color: AppTheme.error),
                      ),
                    ),
                  _isCustom
                      ? _buildCustomForm(theme)
                      : (_selectedFood != null || _selectedRecipe != null)
                      ? _buildPortionForm(theme, accent)
                      : _buildBrowser(theme, accent),
                ],
              ),
            ),
          ),
          actionsPadding: EdgeInsets.fromLTRB(16, 4, 16, 14),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Отмена'),
            ),
            if (canAdd)
              ElevatedButton(
                onPressed: _saving ? null : _addFood,
                child: Text(_saving ? 'Сохранение…' : 'Добавить'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileDialog(
    ThemeData theme,
    Color accent,
    bool canAdd,
    bool keyboardOpen,
  ) {
    final browsing =
        !_isCustom && _selectedFood == null && _selectedRecipe == null;
    return Dialog.fullscreen(
      backgroundColor: AppTheme.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  RoundIconBadge(
                    icon: widget.mealType.icon,
                    color: accent,
                    size: 38,
                    iconSize: 19,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'В ${widget.mealType.label.toLowerCase()}',
                          style: theme.textTheme.titleLarge,
                        ),
                        Text(
                          widget.provider
                                  .getFoodEntriesForMeal(widget.mealType)
                                  .isEmpty
                              ? 'В приёме пока нет записей'
                              : '${widget.provider.getMealCalories(widget.mealType)} ккал по записям',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (_inputError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _inputError!,
                  style: TextStyle(color: AppTheme.error),
                ),
              ),
            Expanded(
              child: browsing
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildMobileBrowser(theme, accent, keyboardOpen),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: _isCustom
                          ? _buildCustomForm(theme)
                          : _buildPortionForm(theme, accent),
                    ),
            ),
            if (canAdd)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _addFood,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(_saving ? 'Сохранение…' : 'Добавить в дневник'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileBrowser(ThemeData theme, Color accent, bool keyboardOpen) {
    final recent = widget.provider
        .recentFoodsForMeal(widget.mealType)
        .where((food) => isRussianProductName(food.name))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'Поиск продукта',
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Очистить поиск',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _searchController.clear();
                      _searchQuery = '';
                    }),
                  ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onChanged: (value) => setState(() => _searchQuery = value),
        ),
        if (!keyboardOpen && recent.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: recent.length,
              separatorBuilder: (_, __) => const SizedBox(width: 7),
              itemBuilder: (context, index) {
                final food = recent[index];
                return ActionChip(
                  avatar: const Icon(Icons.bolt_rounded, size: 17),
                  label: Text('${food.name} · ${_formatGrams(food.grams)} г'),
                  tooltip: 'Повторить недавнюю порцию',
                  onPressed: () => _quickAdd(food),
                );
              },
            ),
          ),
        ],
        if (!keyboardOpen) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _chooseFromCatalog(),
            icon: const Icon(Icons.library_books_outlined, size: 18),
            label: const Text('Каталог ПМР и СНГ'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 45,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final producer in const [
                  'ТХК',
                ]) ...[_pmrChip(producer, producer), const SizedBox(width: 6)],
                ActionChip(
                  label: const Text('Типовое молоко'),
                  onPressed: () => _chooseFromCatalog(
                    query: 'молоко',
                    source: smart.regionalDairySource,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 6),
        Row(
          children: [
            _DialogTabChip(
              label: 'Все',
              icon: Icons.grid_view_rounded,
              selected: _tab == _FoodDialogTab.all,
              onTap: () => setState(() => _tab = _FoodDialogTab.all),
            ),
            const SizedBox(width: 6),
            _DialogTabChip(
              label: 'Избранное',
              icon: Icons.star_rounded,
              selected: _tab == _FoodDialogTab.favorites,
              onTap: () => setState(() => _tab = _FoodDialogTab.favorites),
            ),
            const SizedBox(width: 6),
            _DialogTabChip(
              label: 'Рецепты',
              icon: Icons.menu_book_rounded,
              selected: _tab == _FoodDialogTab.recipes,
              onTap: () => setState(() => _tab = _FoodDialogTab.recipes),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _tab == _FoodDialogTab.recipes
              ? _buildRecipesList(theme)
              : _buildFoodsList(theme, accent),
        ),
        if (!keyboardOpen)
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _isCustom = true),
                icon: const Icon(Icons.edit_note_rounded, size: 18),
                label: const Text('Свой продукт'),
              ),
              TextButton.icon(
                onPressed: _openRecipeEditor,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Рецепт'),
              ),
            ],
          ),
      ],
    );
  }

  // --- Каталог продуктов ---

  Future<void> _chooseFromCatalog({String? query, String? source}) async {
    final chosen = await openFoodCatalog(
      context,
      widget.provider,
      pickForDiary: true,
      initialQuery: query,
      initialSource: source,
    );
    if (chosen != null && mounted) {
      _selectFood(chosen);
    }
  }

  Widget _milkChip(String label, String query) => ActionChip(
    label: Text(label),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    onPressed: () =>
        _chooseFromCatalog(query: query, source: smart.regionalDairySource),
  );

  Widget _pmrChip(String label, String query) => ActionChip(
    label: Text(label),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    onPressed: () => _chooseFromCatalog(query: query, source: smart.pmrSource),
  );

  Widget _buildBrowser(ThemeData theme, Color accent) {
    final recent = widget.provider
        .recentFoodsForMeal(widget.mealType)
        .where((food) => isRussianProductName(food.name))
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (recent.isNotEmpty) ...[
          Row(
            children: [
              Icon(Icons.bolt_rounded, size: 15, color: AppTheme.amber),
              SizedBox(width: 5),
              Text(
                'НЕДАВНИЕ',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 9.5,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          SizedBox(height: 7),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: recent.length,
              separatorBuilder: (_, __) => SizedBox(width: 8),
              itemBuilder: (context, index) {
                final food = recent[index];
                return ActionChip(
                  avatar: Icon(Icons.add_rounded, size: 16, color: accent),
                  label: Text(
                    '${food.name} · ${_formatGrams(food.grams)} г',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  backgroundColor: AppTheme.surfaceHigh,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _quickAdd(food),
                );
              },
            ),
          ),
          SizedBox(height: 14),
        ],
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search_rounded, size: 20),
            hintText: 'Поиск продукта',
            filled: true,
            fillColor: AppTheme.surfaceSoft,
            contentPadding: EdgeInsets.symmetric(vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (value) => setState(() => _searchQuery = value),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _chooseFromCatalog(),
            icon: const Icon(Icons.library_books_outlined, size: 18),
            label: const Text('Каталог продуктов ПМР и СНГ'),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Типовое молоко — жирность:',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 6,
          runSpacing: 3,
          children: [
            _milkChip('0,5%', 'молоко fat05'),
            _milkChip('1%', 'молоко fat10'),
            _milkChip('1,5%', 'молоко fat15'),
            _milkChip('2,5%', 'молоко fat25'),
            _milkChip('3,2%', 'молоко fat32'),
            _milkChip('3,5%', 'молоко fat35'),
          ],
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Подтверждённые позиции ТХК:',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 6,
          runSpacing: 3,
          children: [
            _pmrChip('ТХК', 'ТХК'),
          ],
        ),
        SizedBox(height: 12),
        Row(
          children: [
            _DialogTabChip(
              label: 'Все',
              icon: Icons.grid_view_rounded,
              selected: _tab == _FoodDialogTab.all,
              onTap: () => setState(() => _tab = _FoodDialogTab.all),
            ),
            SizedBox(width: 7),
            _DialogTabChip(
              label: 'Избранное',
              icon: Icons.star_rounded,
              selected: _tab == _FoodDialogTab.favorites,
              onTap: () => setState(() => _tab = _FoodDialogTab.favorites),
            ),
            SizedBox(width: 7),
            _DialogTabChip(
              label: 'Рецепты',
              icon: Icons.menu_book_rounded,
              selected: _tab == _FoodDialogTab.recipes,
              onTap: () => setState(() => _tab = _FoodDialogTab.recipes),
            ),
          ],
        ),
        SizedBox(height: 8),
        SizedBox(
          height: 262,
          child: _tab == _FoodDialogTab.recipes
              ? _buildRecipesList(theme)
              : _buildFoodsList(theme, accent),
        ),
        SizedBox(height: 4),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _isCustom = true),
              icon: Icon(Icons.edit_note_rounded, size: 18),
              label: Text('Свой продукт'),
            ),
            Spacer(),
            TextButton.icon(
              onPressed: _openRecipeEditor,
              icon: Icon(Icons.add_rounded, size: 18),
              label: Text('Новый рецепт'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFoodsList(ThemeData theme, Color accent) {
    final query = _searchQuery.trim().toLowerCase();
    final candidates = _tab == _FoodDialogTab.favorites
        ? widget.provider.favoriteFoods
              .where((f) => f.name.toLowerCase().contains(query))
              .toList()
        : widget.provider.searchFoods(_searchQuery);
    String candidateName(Object item) =>
        item is QuickFood ? item.name : (item as FoodItem).name;
    final items = candidates
        .where((item) => isRussianProductName(candidateName(item)))
        .toList();
    final hiddenCount = candidates.length - items.length;

    if (items.isEmpty) {
      return _EmptyDialogState(
        icon: _tab == _FoodDialogTab.favorites
            ? Icons.star_border_rounded
            : Icons.search_off_rounded,
        title: _tab == _FoodDialogTab.favorites
            ? 'Пока нет избранного'
            : 'Ничего не найдено',
        subtitle: hiddenCount > 0
            ? 'Названия с латиницей скрыты. Личные записи не удалены; свои продукты можно переименовать в настройках.'
            : _tab == _FoodDialogTab.favorites
            ? 'Отметьте продукты звёздочкой — они\nвсегда будут под рукой'
            : 'Попробуйте другое название',
      );
    }

    return ListView.separated(
      padding: EdgeInsets.symmetric(vertical: 2),
      itemCount: items.length + (hiddenCount > 0 ? 1 : 0),
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
      itemBuilder: (context, index) {
        if (hiddenCount > 0 && index == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Скрыто названий с латиницей: $hiddenCount. Личные записи не удалены; свои продукты можно переименовать в настройках.',
              style: theme.textTheme.labelSmall,
            ),
          );
        }
        final item = items[index - (hiddenCount > 0 ? 1 : 0)];
        final isQuick = item is QuickFood;
        final name = isQuick ? item.name : (item as FoodItem).name;
        final calories = isQuick
            ? item.caloriesPer100g
            : (item as FoodItem).calories;
        final protein = isQuick
            ? item.proteinPer100g
            : (item as FoodItem).protein;
        final fat = isQuick ? item.fatPer100g : (item as FoodItem).fat;
        final carbs = isQuick ? item.carbsPer100g : (item as FoodItem).carbs;
        final favoriteMeal = isQuick ? item.mealType : widget.mealType;
        final favorite = widget.provider.isFavoriteFood(name, favoriteMeal);

        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 4),
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '${calories.round()} ккал · Б${protein.round()} '
            'Ж${fat.round()} У${carbs.round()}',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: AppTheme.textSecondary,
            ),
          ),
          trailing: IconButton(
            tooltip: favorite ? 'Убрать из избранного' : 'В избранное',
            icon: Icon(
              favorite ? Icons.star_rounded : Icons.star_border_rounded,
              size: 21,
              color: favorite
                  ? AppTheme.amber
                  : AppTheme.textSecondary.withValues(alpha: 0.6),
            ),
            onPressed: () => _toggleFavorite(
              food: isQuick
                  ? FoodItem(
                      name,
                      calories,
                      protein,
                      fat,
                      carbs,
                      item.micros,
                      'Основные продукты',
                      'База Fitness Smart',
                      null,
                      null,
                      null,
                      null,
                      '',
                      item.microsEstimated,
                    )
                  : item as FoodItem,
              mealType: favoriteMeal,
              isFavorite: favorite,
            ),
          ),
          onTap: () {
            if (isQuick) {
              _selectQuickFood(item);
            } else {
              _selectFood(item as FoodItem);
            }
          },
        );
      },
    );
  }

  Widget _buildRecipesList(ThemeData theme) {
    final query = _searchQuery.trim().toLowerCase();
    final recipes = widget.provider.recipes
        .where((r) => r.name.toLowerCase().contains(query))
        .toList();

    if (recipes.isEmpty) {
      return _EmptyDialogState(
        icon: Icons.menu_book_rounded,
        title: 'Рецептов пока нет',
        subtitle:
            'Соберите блюдо из ингредиентов —\nКБЖУ посчитается автоматически',
        action: TextButton.icon(
          onPressed: _openRecipeEditor,
          icon: Icon(Icons.add_rounded, size: 18),
          label: Text('Создать рецепт'),
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.symmetric(vertical: 2),
      itemCount: recipes.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
      itemBuilder: (context, index) {
        final recipe = recipes[index];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 4),
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.secondary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.menu_book_rounded,
              size: 17,
              color: AppTheme.secondary,
            ),
          ),
          title: Text(
            recipe.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '${recipe.caloriesPer100g.round()} ккал/100 г · '
            'порция ${_formatGrams(recipe.servingGrams)} г',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: AppTheme.textSecondary,
            ),
          ),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppTheme.textSecondary.withValues(alpha: 0.6),
          ),
          onTap: () => _selectRecipe(recipe),
        );
      },
    );
  }

  // --- Порция выбранного продукта или рецепта ---

  Widget _buildPortionForm(ThemeData theme, Color accent) {
    final recipe = _selectedRecipe;
    final food = _selectedFood;
    final title = recipe?.name ?? food!.name;
    final servings = recipe?.servings ?? 1;
    final servingGrams = recipe?.servingGrams;
    final per100 = recipe?.caloriesPer100g ?? food!.calories;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.arrow_back_rounded, size: 20),
              onPressed: () => setState(() {
                _selectedFood = null;
                _selectedRecipe = null;
              }),
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (recipe != null)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$servings порц.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.secondary,
                  ),
                ),
              ),
          ],
        ),
        SizedBox(height: 2),
        Padding(
          padding: EdgeInsets.only(left: 40),
          child: Text(
            recipe != null
                ? '${per100.round()} ккал/100 г · '
                      '${recipe.servingCalories.round()} ккал/порция'
                : '${per100.round()} ккал/100 г · '
                      'Б${food!.protein.round()} Ж${food.fat.round()} '
                      'У${food.carbs.round()}',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
        if (food?.brand != null && food!.brand!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Производитель: ${food.brand}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (food?.note != null && food!.note!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(food.note!, style: theme.textTheme.bodySmall),
        ],
        SizedBox(height: 16),
        TextField(
          controller: _amountController,
          keyboardType: TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Вес порции',
            suffixText: 'г',
            filled: true,
            fillColor: AppTheme.surfaceSoft,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (servingGrams != null)
              _PortionChip(
                label: 'Порция ${_formatGrams(servingGrams)} г',
                color: accent,
                onTap: () => setState(
                  () => _amountController.text = _formatGrams(servingGrams),
                ),
              ),
            for (final grams in [50.0, 100.0, 150.0, 200.0])
              _PortionChip(
                label: '${grams.round()} г',
                color: accent,
                onTap: () =>
                    setState(() => _amountController.text = '${grams.round()}'),
              ),
          ],
        ),
        SizedBox(height: 14),
        _PortionSummary(
          caloriesPer100g: per100,
          grams:
              double.tryParse(_amountController.text.replaceAll(',', '.')) ?? 0,
          accent: accent,
        ),
      ],
    );
  }

  // --- Свой продукт ---

  Widget _buildCustomForm(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.arrow_back_rounded, size: 20),
              onPressed: () => setState(() => _isCustom = false),
            ),
            Expanded(
              child: Text(
                'Свой продукт',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        TextField(
          controller: _customName,
          decoration: InputDecoration(
            labelText: 'Название продукта',
            filled: true,
            fillColor: AppTheme.surfaceSoft,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        SizedBox(height: 10),
        TextField(
          controller: _amountController,
          keyboardType: TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Вес порции',
            suffixText: 'г',
            filled: true,
            fillColor: AppTheme.surfaceSoft,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        SizedBox(height: 14),
        Text('КБЖУ на 100 г:', style: theme.textTheme.labelMedium),
        SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _CustomNutrientField(
                controller: _customCalories,
                label: 'Ккал',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: _CustomNutrientField(
                controller: _customProtein,
                label: 'Б (г)',
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _CustomNutrientField(
                controller: _customFat,
                label: 'Ж (г)',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: _CustomNutrientField(
                controller: _customCarbs,
                label: 'У (г)',
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- Действия ---

  void _selectFood(FoodItem food) {
    setState(() {
      _selectedFood = food;
      _selectedRecipe = null;
      _isCustom = false;
      _amountController.text = _formatGrams(_gramsFor(food.name));
    });
  }

  void _selectQuickFood(QuickFood food) {
    setState(() {
      _selectedFood = FoodItem(
        food.name,
        food.caloriesPer100g,
        food.proteinPer100g,
        food.fatPer100g,
        food.carbsPer100g,
        food.micros,
        'Основные продукты',
        'База Fitness Smart',
        null,
        null,
        null,
        null,
        '',
        food.microsEstimated,
      );
      _selectedRecipe = null;
      _isCustom = false;
      _amountController.text = _formatGrams(food.grams);
    });
  }

  void _selectRecipe(Recipe recipe) {
    setState(() {
      _selectedRecipe = recipe;
      _selectedFood = null;
      _isCustom = false;
      _amountController.text = _formatGrams(recipe.servingGrams);
    });
  }

  Future<void> _quickAdd(QuickFood food) => _saveFoodEntry(
    FoodEntry(
      name: food.name,
      caloriesPer100g: food.caloriesPer100g,
      micros: food.micros,
      microsEstimated: food.microsEstimated,
      proteinPer100g: food.proteinPer100g,
      fatPer100g: food.fatPer100g,
      carbsPer100g: food.carbsPer100g,
      amountGrams: food.grams,
      mealType: widget.mealType,
      date: widget.provider.selectedDate,
    ),
  );

  Future<void> _saveFoodEntry(FoodEntry entry) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _inputError = null;
    });
    try {
      await widget.provider.addFoodEntry(entry);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final warning = widget.provider.persistenceError;
      setState(() => _saving = false);
      Navigator.pop(context);
      if (warning != null)
        messenger?.showSnackBar(SnackBar(content: Text(warning)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _inputError = error is FoodEditException
            ? error.message
            : 'Не удалось сохранить продукт. Проверьте место и повторите.';
      });
    }
  }

  Future<void> _toggleFavorite({
    required FoodItem food,
    required MealType mealType,
    required bool isFavorite,
  }) async {
    if (isFavorite) {
      await widget.provider.removeFavorite(food.name, mealType);
    } else {
      await widget.provider.addFavorite(food, mealType);
    }
    if (mounted) setState(() {});
  }

  Future<void> _openRecipeEditor() async {
    await showDialog(
      context: context,
      builder: (_) => AddRecipeDialog(provider: widget.provider),
    );
    if (mounted) setState(() {});
  }

  double _gramsFor(String name) {
    final matches =
        widget.provider.quickFoods
            .where(
              (f) =>
                  f.name.toLowerCase() == name.toLowerCase() &&
                  f.mealType == widget.mealType,
            )
            .toList()
          ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return matches.isEmpty ? 100 : matches.first.grams;
  }

  String _formatGrams(double value) => value == value.roundToDouble()
      ? '${value.round()}'
      : value.toStringAsFixed(1);

  Future<void> _addFood() async {
    if (_saving) return;
    final grams = double.tryParse(_amountController.text.replaceAll(',', '.'));
    if (grams == null || !grams.isFinite || grams <= 0) {
      setState(() => _inputError = 'Введите положительный вес порции');
      return;
    }

    if (_selectedRecipe != null) {
      await _saveFoodEntry(
        _selectedRecipe!.toEntry(
          grams,
          widget.mealType,
          date: widget.provider.selectedDate,
        ),
      );
      return;
    }

    FoodEntry entry;
    if (_isCustom) {
      final name = _customName.text.trim();
      final calories = parseNutritionNumber(_customCalories.text);
      final protein = parseNutritionNumber(_customProtein.text);
      final fat = parseNutritionNumber(_customFat.text);
      final carbs = parseNutritionNumber(_customCarbs.text);
      if (name.isEmpty ||
          calories == null ||
          protein == null ||
          fat == null ||
          carbs == null) {
        setState(
          () => _inputError =
              'Укажите название и все значения на 100 г. '
              'Если нутриента нет, введите 0. Допустимы 12,5 и 12.5.',
        );
        return;
      }
      entry = FoodEntry(
        name: name,
        caloriesPer100g: calories,
        proteinPer100g: protein,
        fatPer100g: fat,
        carbsPer100g: carbs,
        amountGrams: grams,
        mealType: widget.mealType,
        date: widget.provider.selectedDate,
      );
    } else if (_selectedFood != null) {
      entry = _selectedFood!.toEntry(
        grams,
        widget.mealType,
        date: widget.provider.selectedDate,
      );
    } else {
      return;
    }

    await _saveFoodEntry(entry);
  }
}

class _DialogTabChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _DialogTabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Material(
        color: selected
            ? AppTheme.primary.withValues(alpha: 0.14)
            : AppTheme.surfaceSoft,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: selected ? AppTheme.primary : AppTheme.textSecondary,
                ),
                SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? AppTheme.primary
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PortionChip extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _PortionChip({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _PortionSummary extends StatelessWidget {
  final double caloriesPer100g;
  final double grams;
  final Color accent;

  const _PortionSummary({
    required this.caloriesPer100g,
    required this.grams,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final kcal = caloriesPer100g * grams / 100;
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Icon(Icons.local_fire_department_rounded, size: 16, color: accent),
          SizedBox(width: 8),
          Text(
            'В порции',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: AppTheme.textSecondary,
            ),
          ),
          Spacer(),
          Text(
            '${kcal.round()} ккал',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomNutrientField extends StatelessWidget {
  final TextEditingController controller;
  final String label;

  const _CustomNutrientField({required this.controller, required this.label});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: AppTheme.surfaceSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _EmptyDialogState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const _EmptyDialogState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 34,
                color: AppTheme.textSecondary.withValues(alpha: 0.5),
              ),
              SizedBox(height: 10),
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
              SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10.5,
                  height: 1.4,
                  color: AppTheme.textSecondary.withValues(alpha: 0.75),
                ),
              ),
              if (action != null) ...[SizedBox(height: 8), action!],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// ВИДЖЕТ: КОНСТРУКТОР РЕЦЕПТОВ
// ============================================================================

class AddRecipeDialog extends StatefulWidget {
  final AppDataProvider provider;
  final Recipe? initial;

  const AddRecipeDialog({super.key, required this.provider, this.initial});

  @override
  State<AddRecipeDialog> createState() => _AddRecipeDialogState();
}

class _AddRecipeDialogState extends State<AddRecipeDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _servings = TextEditingController(text: '2');
  final ScrollController _scroll = ScrollController();
  final List<RecipeIngredient> _ingredients = [];
  late final RecipeEditSnapshot _snapshot;

  double? _cookedWeight;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.provider.captureRecipeEdit(widget.initial);
    _cookedWeight = widget.initial?.cookedWeight;
    final recipe = widget.initial;
    if (recipe != null) {
      _name.text = recipe.name;
      _servings.text = '${recipe.servings}';
      _ingredients.addAll(recipe.ingredients);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _servings.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _showError(String message) {
    setState(() {
      _saving = false;
      _error = message;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final servings = (int.tryParse(_servings.text) ?? 1).clamp(1, 30);
    final draft = Recipe(
      id: widget.initial?.id ?? 'draft',
      name: _name.text.trim().isEmpty ? 'Новый рецепт' : _name.text.trim(),
      ingredients: _ingredients,
      cookedWeight: _cookedWeight,
      servings: servings,
    );
    final canSave =
        _name.text.trim().isNotEmpty && _ingredients.isNotEmpty && !_saving;

    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titlePadding: EdgeInsets.fromLTRB(22, 20, 22, 8),
        contentPadding: EdgeInsets.fromLTRB(20, 0, 20, 4),
        title: Row(
          children: [
            RoundIconBadge(
              icon: Icons.menu_book_rounded,
              color: AppTheme.secondary,
              size: 36,
              iconSize: 18,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.initial == null ? 'Новый рецепт' : 'Редактирование',
                style: theme.textTheme.titleLarge,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            controller: _scroll,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: _name,
                  enabled: !_saving,
                  decoration: InputDecoration(
                    labelText: 'Название блюда',
                    hintText: 'Куриная грудка с гречкой',
                    filled: true,
                    fillColor: AppTheme.surfaceSoft,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _servings,
                        enabled: !_saving,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Порций',
                          isDense: true,
                          filled: true,
                          fillColor: AppTheme.surfaceSoft,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceSoft,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Готовое блюдо',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 9.5,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '${_formatGrams(draft.outputWeight)} г',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Ингредиенты',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : _addIngredient,
                      icon: Icon(Icons.add_rounded, size: 18),
                      label: Text('Добавить'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                if (_ingredients.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceSoft,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Text(
                      'Добавьте продукты, чтобы посчитать КБЖУ',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  )
                else
                  for (final ingredient in _ingredients)
                    _IngredientRow(
                      ingredient: ingredient,
                      onEdit: _saving
                          ? null
                          : () => _editIngredient(ingredient),
                      onDelete: _saving
                          ? null
                          : () =>
                                setState(() => _ingredients.remove(ingredient)),
                    ),
                SizedBox(height: 14),
                _RecipeNutritionCard(draft: draft, servings: servings),
                const SizedBox(height: 8),
                Text(
                  _cookedWeight == null
                      ? 'Выход не указан: используется суммарная масса ингредиентов.'
                      : 'Для расчёта на 100 г используется указанный выход блюда.',
                ),
                if (_cookedWeight != null)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _cookedWeight = null),
                    child: const Text('Сбросить выход блюда'),
                  ),
              ],
            ),
          ),
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 4, 16, 14),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () async {
                    final weight = await askPositiveNumber(
                      context,
                      'Выход готового блюда, г',
                      _cookedWeight,
                      maxValue: recipeMaxInputGrams,
                    );
                    if (weight != null && mounted)
                      setState(() => _cookedWeight = weight);
                  },
            child: Text(
              _cookedWeight == null
                  ? 'Выход блюда'
                  : '${formatGrams(_cookedWeight!)} г готового',
            ),
          ),
          if (widget.initial != null)
            TextButton(
              onPressed: _saving ? null : _deleteRecipe,
              style: TextButton.styleFrom(foregroundColor: AppTheme.error),
              child: Text('Удалить'),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: canSave ? _save : null,
            child: Text(
              _saving
                  ? 'Сохраняем…'
                  : widget.initial == null
                  ? 'Создать'
                  : 'Сохранить',
            ),
          ),
        ],
      ),
    );
  }

  String _formatGrams(double value) => value == value.roundToDouble()
      ? '${value.round()}'
      : value.toStringAsFixed(1);

  Future<void> _addIngredient() async {
    final ingredient = await showDialog<RecipeIngredient>(
      context: context,
      builder: (_) => _AddIngredientDialog(provider: widget.provider),
    );
    if (ingredient != null && mounted) {
      setState(() => _ingredients.add(ingredient));
    }
  }

  Future<void> _editIngredient(RecipeIngredient ingredient) async {
    final grams = await askPositiveNumber(
      context,
      '${ingredient.name} · масса, г',
      ingredient.grams,
      maxValue: recipeMaxInputGrams,
    );
    if (grams == null || !mounted) return;
    setState(() {
      final index = _ingredients.indexOf(ingredient);
      if (index < 0) return;
      _ingredients[index] = RecipeIngredient(
        name: ingredient.name,
        grams: grams,
        caloriesPer100g: ingredient.caloriesPer100g,
        micros: ingredient.micros,
        microsEstimated: ingredient.microsEstimated,
        proteinPer100g: ingredient.proteinPer100g,
        fatPer100g: ingredient.fatPer100g,
        carbsPer100g: ingredient.carbsPer100g,
      );
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _ingredients.isEmpty || _saving) return;
    final count = int.tryParse(_servings.text.trim());
    if (count == null || count < 1 || count > 30) {
      _showError('Введите целое количество порций от 1 до 30.');
      return;
    }
    final recipe = Recipe(
      id: widget.initial?.id,
      name: name,
      ingredients: List.of(_ingredients),
      cookedWeight: _cookedWeight,
      servings: count,
    );
    await _commit(recipe);
  }

  Future<void> _commit(Recipe? recipe) async {
    if (_saving || (widget.initial == null && recipe == null)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final original = widget.initial;
      if (original == null) {
        if (recipe == null) return;
        await widget.provider.addRecipe(recipe, snapshot: _snapshot);
      } else if (recipe == null) {
        await widget.provider.deleteRecipe(original.id, snapshot: _snapshot);
      } else {
        await widget.provider.updateRecipe(recipe, snapshot: _snapshot);
      }
      if (mounted) {
        setState(() => _saving = false);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        _showError(
          e is RecipeEditException
              ? e.message
              : 'Не удалось сохранить рецепт. Исходные данные не изменены.',
        );
      }
    }
  }

  Future<void> _deleteRecipe() async {
    final recipe = widget.initial;
    if (recipe == null || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text('Удалить рецепт?'),
        content: Text(
          '«${recipe.name}» будет удалён без возможности отмены. '
          'Ранее добавленные в дневник порции останутся.',
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _commit(null);
  }
}

class _IngredientRow extends StatelessWidget {
  final RecipeIngredient ingredient;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _IngredientRow({
    required this.ingredient,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.surfaceSoft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onEdit,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ingredient.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '${ingredient.grams.round()} г · '
                        '${ingredient.calories.round()} ккал',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, size: 17),
                  color: AppTheme.textSecondary,
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecipeNutritionCard extends StatelessWidget {
  final Recipe draft;
  final int servings;

  const _RecipeNutritionCard({required this.draft, required this.servings});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perServing = servings > 0 ? draft.totalCalories / servings : 0;
    final servingGrams = servings > 0 ? draft.outputWeight / servings : 0;

    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.calculate_rounded, size: 15, color: AppTheme.primary),
              SizedBox(width: 6),
              Text(
                'Расчёт КБЖУ',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _RecipeStat(
                  label: 'на 100 г',
                  value: '${draft.caloriesPer100g.round()}',
                  hint: 'ккал',
                  color: AppTheme.primary,
                ),
              ),
              Container(
                width: 1,
                height: 30,
                color: Colors.white.withValues(alpha: 0.07),
              ),
              Expanded(
                child: _RecipeStat(
                  label: 'на порцию',
                  value: '${perServing.round()}',
                  hint: '${servingGrams.round()} г',
                  color: AppTheme.amber,
                ),
              ),
              Container(
                width: 1,
                height: 30,
                color: Colors.white.withValues(alpha: 0.07),
              ),
              Expanded(
                child: _RecipeStat(
                  label: 'всего',
                  value: '${draft.totalCalories.round()}',
                  hint: '${draft.totalGrams.round()} г',
                  color: AppTheme.blue,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MacroPill(
                  label: 'Б',
                  value: draft.proteinPer100g,
                  color: AppTheme.blue,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _MacroPill(
                  label: 'Ж',
                  value: draft.fatPer100g,
                  color: AppTheme.amber,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _MacroPill(
                  label: 'У',
                  value: draft.carbsPer100g,
                  color: AppTheme.carbs,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecipeStat extends StatelessWidget {
  final String label;
  final String value;
  final String hint;
  final Color color;

  const _RecipeStat({
    required this.label,
    required this.value,
    required this.hint,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9,
            color: AppTheme.textSecondary,
          ),
        ),
        SizedBox(height: 3),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        Text(
          hint,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9,
            color: AppTheme.textSecondary.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

class _MacroPill extends StatelessWidget {
  final String label;
  final double value;
  final Color color;

  const _MacroPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 5,
        runSpacing: 2,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(
            '${value.toStringAsFixed(1)} г',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddIngredientDialog extends StatefulWidget {
  final AppDataProvider provider;
  const _AddIngredientDialog({required this.provider});

  @override
  State<_AddIngredientDialog> createState() => _AddIngredientDialogState();
}

class _AddIngredientDialogState extends State<_AddIngredientDialog> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _grams = TextEditingController(text: '100');
  FoodItem? _selected;
  String _query = '';
  String? _amountError;

  @override
  void dispose() {
    _search.dispose();
    _grams.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = widget.provider.searchFoods(_query);
    final foods = candidates
        .where((food) => isRussianProductName(food.name))
        .toList();
    final hiddenCount = candidates.length - foods.length;
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final listHeight = (availableHeight - 260).clamp(64.0, 260.0);

    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: Text(
        _selected == null ? 'Добавить ингредиент' : _selected!.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      contentPadding: EdgeInsets.fromLTRB(20, 8, 20, 4),
      content: SizedBox(
        width: double.maxFinite,
        child: _selected == null
            ? SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _search,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search_rounded, size: 20),
                        hintText: 'Поиск продукта',
                        filled: true,
                        fillColor: AppTheme.surfaceSoft,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    SizedBox(height: 10),
                    if (hiddenCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Скрыто названий с латиницей: $hiddenCount. Свои продукты сохранены и их можно переименовать в настройках.',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    SizedBox(
                      height: listHeight,
                      child: foods.isEmpty
                          ? Center(child: Text('Ничего не найдено'))
                          : ListView.separated(
                              itemCount: foods.length,
                              separatorBuilder: (_, __) => Divider(
                                height: 1,
                                color: Colors.white.withValues(alpha: 0.05),
                              ),
                              itemBuilder: (context, index) {
                                final food = foods[index];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  title: Text(food.name),
                                  subtitle: Text(
                                    '${food.calories.round()} ккал/100 г',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontSize: 10,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                  onTap: () => setState(() => _selected = food),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_selected!.calories.round()} ккал · '
                      'Б${_selected!.protein.round()} '
                      'Ж${_selected!.fat.round()} '
                      'У${_selected!.carbs.round()} на 100 г',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    SizedBox(height: 14),
                    TextField(
                      controller: _grams,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      autofocus: true,
                      onChanged: (_) {
                        if (_amountError != null)
                          setState(() => _amountError = null);
                      },
                      decoration: InputDecoration(
                        labelText: 'Масса',
                        suffixText: 'г',
                        errorText: _amountError,
                        filled: true,
                        fillColor: AppTheme.surfaceSoft,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final grams in [50, 100, 150, 200])
                          _PortionChip(
                            label: '$grams г',
                            color: AppTheme.secondary,
                            onTap: () => setState(() => _grams.text = '$grams'),
                          ),
                      ],
                    ),
                    SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => setState(() => _selected = null),
                      icon: Icon(Icons.arrow_back_rounded, size: 18),
                      label: Text('К списку'),
                    ),
                  ],
                ),
              ),
      ),
      actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Отмена'),
        ),
        if (_selected != null)
          ElevatedButton(
            onPressed: () {
              final grams = parseNutritionNumber(_grams.text);
              if (grams == null || grams <= 0 || grams > recipeMaxInputGrams) {
                setState(
                  () => _amountError =
                      'Введите массу больше 0 и не более 1 000 000 г.',
                );
                return;
              }
              Navigator.pop(
                context,
                RecipeIngredient.fromFood(_selected!, grams),
              );
            },
            child: Text('Добавить'),
          ),
      ],
    );
  }
}

// ============================================================================
// ВИДЖЕТ: ТРЕНИРОВКИ
// ============================================================================

Color workoutColor(WorkoutType type) {
  switch (type) {
    case WorkoutType.strength:
      return AppTheme.amber;
    case WorkoutType.cardio:
      return AppTheme.blue;
    case WorkoutType.strengthCardio:
      return AppTheme.secondary;
  }
}

class WorkoutSection extends StatelessWidget {
  final AppDataProvider provider;
  final VoidCallback onAddWorkout;

  const WorkoutSection({
    super.key,
    required this.provider,
    required this.onAddWorkout,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = provider.todayWorkoutEntries;
    final totalKcal = entries.fold(0, (sum, e) => sum + e.caloriesBurned);
    final totalMin = entries.fold(0, (sum, e) => sum + e.durationMinutes);

    return PremiumCard(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RoundIconBadge(
                icon: Icons.fitness_center_rounded,
                color: AppTheme.secondary,
                size: 44,
                iconSize: 21,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Тренировки', style: theme.textTheme.titleMedium),
                    SizedBox(height: 3),
                    Text(
                      entries.isEmpty
                          ? '${provider.profile.workoutsPerWeek} в неделю по плану'
                          : '$totalMin мин · $totalKcal ккал',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              CircleActionButton(
                icon: Icons.add_rounded,
                color: AppTheme.secondary,
                size: 38,
                iconSize: 20,
                onTap: onAddWorkout,
              ),
            ],
          ),
          if (entries.isEmpty)
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(top: 14),
              padding: EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.self_improvement_rounded,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Сегодня тренировки ещё нет',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: EdgeInsets.only(top: 14),
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    WorkoutEntryCard(entry: entries[i]),
                    if (i < entries.length - 1) SizedBox(height: 8),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class WorkoutEntryCard extends StatelessWidget {
  final WorkoutEntry entry;

  const WorkoutEntryCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = workoutColor(entry.type);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => showWorkoutEditor(
        context,
        context.read<AppDataProvider>(),
        entry: entry,
      ),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Row(
          children: [
            RoundIconBadge(
              icon: entry.type.icon,
              color: color,
              size: 38,
              iconSize: 18,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.details?.segments.length == 1
                        ? entry.details!.segments.first.activity.label
                        : entry.type.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '${entry.durationMinutes} мин · ${entry.details?.calorieMode == 'estimate' ? '≈' : ''}${entry.caloriesBurned} ккал'
                    '${entry.details == null ? ' · прежняя запись' : ' · активные'}'
                    '${entry.note != null && entry.note!.isNotEmpty ? ' · ${entry.note}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: 0.25)),
              ),
              child: Text(
                '−${entry.caloriesBurned}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 10.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddWorkoutDialog extends StatefulWidget {
  final AppDataProvider provider;

  const AddWorkoutDialog({super.key, required this.provider});

  @override
  State<AddWorkoutDialog> createState() => _AddWorkoutDialogState();
}

class _AddWorkoutDialogState extends State<AddWorkoutDialog> {
  WorkoutType _selectedType = WorkoutType.strengthCardio;
  final _durationController = TextEditingController();
  final _caloriesController = TextEditingController();
  final _noteController = TextEditingController();

  // A historic profile may contain seeded 70 min / 500 kcal values. This
  // legacy editor starts blank rather than recording them without review.
  @override
  void dispose() {
    _durationController.dispose();
    _caloriesController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titlePadding: EdgeInsets.fromLTRB(22, 22, 22, 10),
      title: Row(
        children: [
          RoundIconBadge(
            icon: Icons.fitness_center_rounded,
            color: AppTheme.secondary,
            size: 36,
            iconSize: 18,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text('Тренировка', style: theme.textTheme.titleLarge),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Тип тренировки', style: theme.textTheme.labelMedium),
            SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: WorkoutType.values.map((type) {
                final isSelected = _selectedType == type;
                return FilterChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(type.icon, size: 16),
                      SizedBox(width: 6),
                      Text(type.label),
                    ],
                  ),
                  selected: isSelected,
                  onSelected: (_) => setState(() => _selectedType = type),
                  selectedColor: type.color.withValues(alpha: 0.2),
                  checkmarkColor: type.color,
                  labelStyle: TextStyle(
                    color: isSelected
                        ? type.color
                        : theme.colorScheme.onSurface,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                  side: BorderSide(
                    color: isSelected ? type.color : theme.colorScheme.outline,
                  ),
                );
              }).toList(),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _durationController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Минуты',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _caloriesController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Ккал',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Примечание',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
      actionsPadding: EdgeInsets.fromLTRB(16, 4, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Отмена'),
        ),
        ElevatedButton(onPressed: _save, child: Text('Добавить')),
      ],
    );
  }

  void _save() {
    final duration = int.tryParse(_durationController.text);
    final calories = int.tryParse(_caloriesController.text);
    if (duration == null ||
        duration <= 0 ||
        calories == null ||
        calories <= 0) {
      return;
    }
    widget.provider.addWorkoutEntry(
      WorkoutEntry(
        type: _selectedType,
        durationMinutes: duration,
        caloriesBurned: calories,
        date: widget.provider.selectedDate,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      ),
    );
    Navigator.pop(context);
  }
}

// ============================================================================
// ВИДЖЕТЫ: ГРАФИК ВЕСА
// ============================================================================

class WeightChart extends StatelessWidget {
  final List<WeightEntry> entries;
  final double? targetWeight;
  final double startWeight;

  const WeightChart({
    super.key,
    required this.entries,
    required this.targetWeight,
    required this.startWeight,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    if (entries.isEmpty) return _buildEmptyState(context);

    final spots = entries
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.weight))
        .toList();

    final weights = entries.map((e) => e.weight).toList()..add(startWeight);
    if (targetWeight != null) weights.add(targetWeight!);
    final minY = (weights.reduce(min) - 2).floorToDouble();
    final maxY = (weights.reduce(max) + 2).ceilToDouble();
    final range = maxY - minY;
    final maxX = entries.length > 1 ? (entries.length - 1).toDouble() : 1.0;

    return Container(
      height: 300,
      padding: EdgeInsets.fromLTRB(12, 16, 20, 12),
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 22,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Динамика веса',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (targetWeight != null)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Цель: ${targetWeight!.toStringAsFixed(1)} кг',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: 12),
          Expanded(
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: _interval(range),
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: theme.colorScheme.outline.withValues(alpha: 0.15),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: _dateInterval(entries.length),
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= entries.length) {
                          return SizedBox.shrink();
                        }
                        final d = entries[i].date;
                        return SideTitleWidget(
                          axisSide: meta.axisSide,
                          child: Text(
                            '${d.day}.${d.month.toString().padLeft(2, '0')}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.grey,
                              fontSize: 10,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 46,
                      interval: _interval(range),
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text(
                          value.toStringAsFixed(0),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.grey,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                minX: 0,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                lineBarsData: [
                  // Нет сохранённой цели — не рисуем выдуманную линию.
                  if (targetWeight != null)
                    LineChartBarData(
                      spots: [
                        FlSpot(0, targetWeight!),
                        FlSpot(maxX, targetWeight!),
                      ],
                      isCurved: false,
                      color: theme.colorScheme.tertiary.withValues(alpha: 0.6),
                      barWidth: 1.5,
                      dotData: FlDotData(show: false),
                      dashArray: [8, 4],
                    ),
                  // Линия старта
                  LineChartBarData(
                    spots: [FlSpot(0, startWeight), FlSpot(maxX, startWeight)],
                    isCurved: false,
                    color: Colors.grey.withValues(alpha: 0.35),
                    barWidth: 1,
                    dotData: FlDotData(show: false),
                    dashArray: [4, 4],
                  ),
                  // Фактический вес
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    gradient: LinearGradient(
                      colors: [
                        primaryColor,
                        primaryColor.withValues(alpha: 0.6),
                      ],
                    ),
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, barData, index) =>
                          FlDotCirclePainter(
                            radius: 5,
                            color: primaryColor,
                            strokeWidth: 3,
                            strokeColor: theme.colorScheme.surface,
                          ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          primaryColor.withValues(alpha: 0.3),
                          primaryColor.withValues(alpha: 0.02),
                        ],
                      ),
                    ),
                  ),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (touchedSpot) => theme.colorScheme.surface,
                    tooltipBorder: BorderSide(color: theme.colorScheme.outline),
                    getTooltipItems: (touchedSpots) =>
                        touchedSpots.map<LineTooltipItem?>((s) {
                          // Индекс фактической линии зависит от того, есть ли
                          // сохранённая цель; остальные линии не дают подсказку.
                          final actualIndex = targetWeight == null ? 1 : 2;
                          if (s.barIndex != actualIndex ||
                              s.spotIndex < 0 ||
                              s.spotIndex >= entries.length) {
                            return null;
                          }
                          final entry = entries[s.spotIndex];
                          return LineTooltipItem(
                            '${entry.weight.toStringAsFixed(1)} кг\n'
                            '${entry.date.day}.${entry.date.month.toString().padLeft(2, '0')}.${entry.date.year}',
                            TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                          );
                        }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _interval(double range) {
    if (range <= 5) return 1;
    if (range <= 10) return 2;
    if (range <= 20) return 5;
    return 10;
  }

  double _dateInterval(int count) {
    if (count <= 7) return 1;
    if (count <= 14) return 2;
    if (count <= 30) return 5;
    return 10;
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 260,
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RoundIconBadge(
              icon: Icons.show_chart_rounded,
              color: AppTheme.blue,
              size: 56,
              iconSize: 26,
            ),
            SizedBox(height: 16),
            Text(
              'Нет данных о весе',
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Добавьте первое измерение веса,\nчтобы увидеть график прогресса',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class WeightEntryDialog extends StatefulWidget {
  final AppDataProvider provider;
  final WeightEntry? entry;

  const WeightEntryDialog({super.key, required this.provider, this.entry});

  @override
  State<WeightEntryDialog> createState() => _WeightEntryDialogState();
}

class _WeightEntryDialogState extends State<WeightEntryDialog> {
  final _weightController = TextEditingController();
  final _noteController = TextEditingController();
  late final WeightEditSnapshot _snapshot;
  DateTime _selectedDate = DateTime.now();
  String? _weightError, _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.provider.captureWeightEdit(widget.entry);
    if (widget.entry != null) {
      // toString round-trips the stored double instead of silently rounding an
      // untouched measurement to one decimal place.
      _weightController.text = widget.entry!.weight.toString();
      _noteController.text = widget.entry!.note ?? '';
      _selectedDate = widget.entry!.date;
    } else if (widget.provider.weightEntries.isNotEmpty) {
      _weightController.text = widget.provider.weightEntries.last.weight
          .toString();
    }
  }

  @override
  void dispose() {
    _weightController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEditing = widget.entry != null;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        scrollable: true,
        titlePadding: EdgeInsets.fromLTRB(22, 22, 22, 10),
        title: Row(
          children: [
            RoundIconBadge(
              icon: Icons.monitor_weight_rounded,
              color: AppTheme.primary,
              size: 36,
              iconSize: 18,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                isEditing ? 'Редактировать вес' : 'Добавить вес',
                style: theme.textTheme.titleLarge,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _weightController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: 'Вес',
                suffixText: 'кг',
                errorText: _weightError,
              ),
            ),
            if (!isEditing && widget.provider.weightEntries.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Подставлено последнее измерение. Проверьте актуальный вес перед сохранением.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: RoundIconBadge(
                icon: Icons.calendar_month_rounded,
                color: AppTheme.blue,
                size: 36,
                iconSize: 18,
              ),
              title: Text('Дата'),
              subtitle: Text(formatDateRu(_selectedDate)),
              onTap: _saving
                  ? null
                  : () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _selectedDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (date != null && mounted)
                        setState(() => _selectedDate = date);
                    },
            ),
            SizedBox(height: 8),
            TextField(
              controller: _noteController,
              maxLines: 2,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: 'Примечание',
                hintText: 'Например: утром натощак',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 4, 16, 16),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text('Отмена'),
          ),
          if (isEditing)
            TextButton(
              onPressed: _saving ? null : _delete,
              style: TextButton.styleFrom(foregroundColor: AppTheme.error),
              child: Text('Удалить'),
            ),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            child: Text(
              _saving
                  ? 'Сохранение…'
                  : isEditing
                  ? 'Сохранить'
                  : 'Добавить',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final weight = double.tryParse(
      _weightController.text.trim().replaceAll(',', '.'),
    );
    if (weight == null || !weight.isFinite || weight <= 0 || weight > 300) {
      setState(() => _weightError = 'Введите вес больше 0 и не более 300 кг');
      return;
    }
    final originalNote = widget.entry?.note;
    final text = _noteController.text;
    final note = widget.entry != null && text == (originalNote ?? '')
        ? originalNote
        : text.trim().isEmpty
        ? null
        : text.trim();
    final entry = WeightEntry(
      id: widget.entry?.id,
      weight: weight,
      date: _selectedDate,
      note: note,
    );
    await _commit(entry);
  }

  Future<void> _delete() async {
    if (_saving || widget.entry == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить измерение?'),
        content: const Text(
          'Запись веса будет удалена без возможности отмены. '
          'Если это последняя запись, текущий вес в профиле останется без изменения.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _commit(null);
  }

  Future<void> _commit(WeightEntry? entry) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _weightError = null;
    });
    try {
      final original = widget.entry;
      final WeightChangeResult result;
      if (original == null && entry != null) {
        result = await widget.provider.addWeightEntry(
          entry,
          snapshot: _snapshot,
        );
      } else if (original != null && entry == null) {
        result = await widget.provider.deleteWeightEntry(
          original.id,
          snapshot: _snapshot,
        );
      } else if (original != null && entry != null) {
        result = await widget.provider.updateWeightEntry(
          entry,
          snapshot: _snapshot,
        );
      } else {
        throw const WeightEditException('Измерение не указано.');
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      setState(() => _saving = false);
      Navigator.pop(context);
      if (result.warning != null) {
        messenger?.showSnackBar(SnackBar(content: Text(result.warning!)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is WeightEditException
            ? e.message
            : 'Не удалось изменить запись. Проверьте свободное место и повторите.';
      });
    }
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppDataProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return Center(child: CircularProgressIndicator());
        }

        return RefreshIndicator(
          color: AppTheme.primary,
          backgroundColor: AppTheme.surface,
          onRefresh: provider.refresh,
          child: CenteredBody(
            child: ListView(
              physics: AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                _buildHeader(context, provider),
                SizedBox(height: 24),
                DaySlider(provider: provider),
                DiaryErrorBanner(provider: provider),
                Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: FilledButton.icon(
                        onPressed: () => showMealPicker(context, provider),
                        icon: const Icon(Icons.add_rounded, size: 19),
                        label: const Text(
                          'Добавить еду',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 5,
                      child: OutlinedButton.icon(
                        onPressed: () => openFoodCatalog(context, provider),
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: const Text(
                          'Каталог',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: () => showGym(context, provider),
                    icon: const Icon(Icons.fitness_center_rounded),
                    label: const Text('Зал · план и подтягивания'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _buildCalorieCard(context, provider),
                SizedBox(height: 14),
                SoftReminderBanner(provider: provider),
                FluidWaterCard(provider: provider),
                SizedBox(height: 28),
                SectionHeader(
                  title: 'БЖУ за день',
                  subtitle: 'Баланс белков, жиров и углеводов',
                  trailing: _GoalChip(
                    label: provider.adjustedCaloriesTarget == null
                        ? 'Цель не подтверждена'
                        : '${formatNumber(provider.adjustedCaloriesTarget!)} ккал',
                  ),
                ),
                SizedBox(height: 14),
                if (provider.todayFoodEntries.isEmpty)
                  const Text('Питание за этот день не записано.')
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: MacroProgressBar(
                          label: 'Белки',
                          consumed: provider.todayProteinConsumed,
                          onTap: () => showNutritionDetails(
                            context,
                            provider,
                            NutrientMetric.protein,
                          ),
                          target: provider.targetProteinToday,
                          color: AppTheme.blue,
                          icon: Icons.fitness_center_rounded,
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: MacroProgressBar(
                          label: 'Жиры',
                          consumed: provider.todayFatConsumed,
                          onTap: () => showNutritionDetails(
                            context,
                            provider,
                            NutrientMetric.fat,
                          ),
                          target: provider.targetFatToday,
                          color: AppTheme.amber,
                          icon: Icons.water_drop_rounded,
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: MacroProgressBar(
                          label: 'Углеводы',
                          consumed: provider.todayCarbsConsumed,
                          onTap: () => showNutritionDetails(
                            context,
                            provider,
                            NutrientMetric.carbs,
                          ),
                          target: provider.targetCarbsToday,
                          color: AppTheme.carbs,
                          icon: Icons.grain_rounded,
                        ),
                      ),
                    ],
                  ),
                SizedBox(height: 28),
                SectionHeader(
                  title: 'Быстрые действия',
                  subtitle: 'Вода и шаги — сразу, тренировка — после проверки',
                ),
                SizedBox(height: 14),
                QuickActionButtons(provider: provider),
                SizedBox(height: 28),
                SectionHeader(
                  title: 'Приёмы пищи',
                  subtitle: formatDateRu(provider.selectedDate),
                  trailing: TextButton.icon(
                    onPressed: () =>
                        _showAddFood(context, provider, MealType.breakfast),
                    icon: Icon(Icons.add_rounded, size: 18),
                    label: Text('Добавить'),
                  ),
                ),
                SizedBox(height: 14),
                _buildMealsGrid(context, provider),
                SizedBox(height: 28),
                WorkoutSection(
                  provider: provider,
                  onAddWorkout: () => showWorkoutEditor(context, provider),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, AppDataProvider provider) {
    final theme = Theme.of(context);
    final date = provider.selectedDate;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.primary,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.7),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                dayKey(date) == dayKey(DateTime.now())
                    ? 'СЕГОДНЯ'
                    : 'ВЫБРАННЫЙ ДЕНЬ',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text('Привет! 👋', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          formatDateRu(date),
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
        ),
      ],
    );
    final dateControl = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _selectDate(context, provider),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_month_rounded,
                size: 15,
                color: AppTheme.primary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  formatShortDateRu(date),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final weightBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.monitor_weight_rounded, size: 15, color: AppTheme.blue),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              provider.profile.currentWeightConfirmed == true
                  ? '${provider.profile.currentWeight.toStringAsFixed(1)} кг'
                  : 'Вес не подтверждён',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
    final streakBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.amber.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department_rounded,
            size: 15,
            color: AppTheme.amber,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${provider.currentStreak} ${_daysWord(provider.currentStreak)}',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.amber,
              ),
            ),
          ),
        ],
      ),
    );
    final badges = [
      dateControl,
      weightBadge,
      if (provider.currentStreak > 0) streakBadge,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 400) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: badges),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < badges.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  badges[i],
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildCalorieCard(BuildContext context, AppDataProvider provider) {
    final theme = Theme.of(context);
    final target = provider.baseCaloriesTarget?.round();
    final adjusted = provider.adjustedCaloriesTarget;
    final burned = provider.todayCaloriesBurned;
    final hasFood = provider.todayFoodEntries.isNotEmpty;
    final hasWorkout = provider.todayWorkoutEntries.isNotEmpty;

    return PremiumCard(
      onTap: () =>
          showNutritionDetails(context, provider, NutrientMetric.calories),
      glow: true,
      gradient: AppTheme.heroGradient,
      padding: EdgeInsets.fromLTRB(20, 20, 20, 22),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Калории', style: theme.textTheme.titleMedium),
                    SizedBox(height: 2),
                    Text(
                      'Дневной баланс',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _GoalChip(
                label: adjusted == null
                    ? 'цель не подтверждена'
                    : 'ориентир ${formatNumber(adjusted)}',
              ),
            ],
          ),
          SizedBox(height: 18),
          if (hasFood && adjusted != null && adjusted > 0)
            CircularCalorieIndicator(
              consumed: provider.todayCaloriesConsumed,
              target: adjusted,
              size: 208,
              onTap: () => showNutritionDetails(
                context,
                provider,
                NutrientMetric.calories,
              ),
            )
          else if (hasFood)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 44),
              child: Text(
                adjusted == null
                    ? 'По записям: ${formatNumber(provider.todayCaloriesConsumed)} ккал. Подтвердите цель в профиле.'
                    : 'По записям: ${formatNumber(provider.todayCaloriesConsumed)} ккал. Для нулевой цели процент недоступен.',
                textAlign: TextAlign.center,
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 44),
              child: Text('Питание за этот день не записано.'),
            ),
          SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: 'По записям',
                  value: hasFood
                      ? formatNumber(provider.todayCaloriesConsumed)
                      : 'нет записи',
                  color: AppTheme.primary,
                ),
              ),
              _statDivider(),
              Expanded(
                child: _MiniStat(
                  label: 'Ручные тренировки · оценка',
                  value: hasWorkout ? formatNumber(burned) : 'нет записи',
                  color: AppTheme.amber,
                ),
              ),
              _statDivider(),
              Expanded(
                child: _MiniStat(
                  label: 'Ориентир',
                  value: target == null
                      ? 'не подтверждён'
                      : formatNumber(target),
                  color: AppTheme.blue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMealsGrid(BuildContext context, AppDataProvider provider) {
    return GridView.builder(
      shrinkWrap: true,
      physics: NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        mainAxisExtent: 112,
      ),
      itemCount: MealType.values.length,
      itemBuilder: (context, index) {
        final mealType = MealType.values[index];
        final entries = provider.getFoodEntriesForMeal(mealType);
        return _MealSummaryCard(
          mealType: mealType,
          calories: provider.getMealCalories(mealType),
          count: entries.length,
          onTap: () => _showAddFood(context, provider, mealType),
        );
      },
    );
  }

  void _selectDate(BuildContext context, AppDataProvider provider) async {
    final date = await showDatePicker(
      context: context,
      initialDate: provider.selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (date != null) provider.setSelectedDate(date);
  }

  void _showAddFood(
    BuildContext context,
    AppDataProvider provider,
    MealType mealType,
  ) {
    showDialog(
      context: context,
      builder: (_) => AddFoodDialog(provider: provider, mealType: mealType),
    );
  }
}

class WaterQuickCard extends StatelessWidget {
  final AppDataProvider provider;

  const WaterQuickCard({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goal = provider.confirmedWaterGoal;
    final intake = provider.todayWaterIntake;
    final recorded = provider.hasRecordedWater;
    final progress = goal == null ? null : intake / goal;
    final done = recorded && goal != null && intake >= goal;

    return PremiumCard(
      radius: 22,
      padding: EdgeInsets.fromLTRB(16, 13, 12, 13),
      child: Column(
        children: [
          Row(
            children: [
              RoundIconBadge(
                icon: Icons.water_drop_rounded,
                color: AppTheme.blue,
                size: 38,
                iconSize: 18,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Вода',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (done) ...[
                          SizedBox(width: 6),
                          Icon(
                            Icons.check_circle_rounded,
                            size: 14,
                            color: AppTheme.primary,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      recorded
                          ? goal == null
                                ? '${formatNumber(intake)} мл · цель не подтверждена'
                                : '${formatNumber(intake)} / ${formatNumber(goal)} мл'
                          : goal == null
                          ? 'Не записана · цель не подтверждена'
                          : 'Не записана · цель ${formatNumber(goal)} мл',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _WaterButton(
                label: '+250',
                onTap: () => provider.quickAddWater(250),
              ),
              SizedBox(width: 7),
              _WaterButton(
                label: '+500',
                onTap: () => provider.quickAddWater(500),
                filled: true,
              ),
            ],
          ),
          if (recorded && progress != null) ...[
            SizedBox(height: 11),
            GradientProgressBar(
              value: progress,
              color: done ? AppTheme.primary : AppTheme.blue,
              height: 6,
            ),
          ],
        ],
      ),
    );
  }
}

class _WaterButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool filled;

  const _WaterButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = filled
        ? AppTheme.blue
        : AppTheme.blue.withValues(alpha: 0.14);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: filled ? AppTheme.background : AppTheme.blue,
            ),
          ),
        ),
      ),
    );
  }
}

class SoftReminderBanner extends StatefulWidget {
  final AppDataProvider provider;

  const SoftReminderBanner({super.key, required this.provider});

  @override
  State<SoftReminderBanner> createState() => _SoftReminderBannerState();
}

class _SoftReminderBannerState extends State<SoftReminderBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return SizedBox.shrink();

    final provider = widget.provider;
    final settings = provider.reminders;
    if (!settings.anyEnabled) return SizedBox.shrink();
    if (dayKey(provider.selectedDate) != dayKey(DateTime.now())) {
      return SizedBox.shrink();
    }

    final now = DateTime.now();
    String? message;
    IconData icon = Icons.notifications_active_rounded;
    Color color = AppTheme.blue;

    final waterGoal = provider.confirmedWaterGoal;
    if (settings.waterEnabled &&
        now.hour >= 9 &&
        (!provider.hasRecordedWater ||
            (waterGoal != null &&
                provider.todayWaterIntake < waterGoal * 0.5))) {
      message = provider.hasRecordedWater
          ? 'В дневнике записано меньше половины вашей цели воды — при необходимости добавьте запись'
          : 'Вода ещё не записана — при желании добавьте запись';
      icon = Icons.water_drop_rounded;
      color = AppTheme.blue;
    } else if (settings.lunchEnabled &&
        now.hour >= settings.lunchHour &&
        provider.getFoodEntriesForMeal(MealType.lunch).isEmpty) {
      message = 'Обед ещё не записан — отметьте приём пищи';
      icon = Icons.lunch_dining_rounded;
      color = AppTheme.amber;
    } else if (settings.weightEnabled &&
        now.hour >= settings.weightHour &&
        !provider.weightEntries.any((e) => dayKey(e.date) == dayKey(now))) {
      message = 'Утреннее взвешивание не записано — добавьте результат';
      icon = Icons.monitor_weight_rounded;
      color = AppTheme.secondary;
    }

    if (message == null) return SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: 14),
      child: PremiumCard(
        radius: 18,
        padding: EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            RoundIconBadge(icon: icon, color: color, size: 34, iconSize: 16),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  height: 1.3,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 16),
              color: AppTheme.textSecondary,
              onPressed: () => setState(() => _dismissed = true),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
        SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9.5,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

Widget _statDivider() {
  return Container(
    width: 1,
    height: 28,
    margin: EdgeInsets.symmetric(horizontal: 6),
    color: Colors.white.withValues(alpha: 0.08),
  );
}

class _GoalChip extends StatelessWidget {
  final String label;

  const _GoalChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}

Color mealAccent(MealType mealType) {
  switch (mealType) {
    case MealType.breakfast:
      return AppTheme.amber;
    case MealType.lunch:
      return AppTheme.primary;
    case MealType.snack:
      return AppTheme.blue;
    case MealType.dinner:
      return AppTheme.secondary;
    case MealType.preWorkout:
      return AppTheme.amber;
    case MealType.postWorkout:
      return AppTheme.blue;
  }
}

class _MealSummaryCard extends StatelessWidget {
  final MealType mealType;
  final int calories;
  final int count;
  final VoidCallback onTap;

  const _MealSummaryCard({
    required this.mealType,
    required this.calories,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = mealAccent(mealType);
    final isEmpty = count == 0;

    return PremiumCard(
      radius: 22,
      padding: EdgeInsets.all(14),
      onTap: onTap,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          color.withValues(alpha: isEmpty ? 0.08 : 0.16),
          AppTheme.surface,
        ],
      ),
      borderGradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0.03)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RoundIconBadge(
                icon: mealType.icon,
                color: color,
                size: 36,
                iconSize: 18,
              ),
              Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  count > 0 ? '$count' : '+',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          Spacer(),
          Text(
            mealType.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
          SizedBox(height: 2),
          if (isEmpty)
            Text(
              'Не записано',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    '$calories',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      color: isEmpty
                          ? AppTheme.textSecondary
                          : AppTheme.textPrimary,
                    ),
                  ),
                ),
                SizedBox(width: 4),
                Text(
                  'ккал',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// ЭКРАН: ПИТАНИЕ
// ============================================================================

class NutritionScreen extends StatelessWidget {
  const NutritionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppDataProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return Center(child: CircularProgressIndicator());
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: RefreshIndicator(
            color: AppTheme.primary,
            backgroundColor: AppTheme.surface,
            onRefresh: provider.refresh,
            child: CenteredBody(
              child: ListView(
                physics: AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, 16, 20, 130),
                children: [
                  _buildHeader(context, provider),
                  SizedBox(height: 18),
                  DaySlider(provider: provider),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: RepeatPreviousDay(provider: provider),
                  ),
                  QuickTemplates(provider: provider),
                  DiaryErrorBanner(provider: provider),
                  _buildSummaryCard(context, provider),
                  SizedBox(height: 24),
                  ...MealType.values.map(
                    (mealType) => Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: MealSection(
                        mealType: mealType,
                        entries: provider.getFoodEntriesForMeal(mealType),
                        provider: provider,
                        onAddFood: () =>
                            _showAddFood(context, provider, mealType),
                      ),
                    ),
                  ),
                  SizedBox(height: 8),
                  _MyRecipesSection(provider: provider),
                ],
              ),
            ),
          ),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButton: FloatingActionButton.extended(
            heroTag: 'nutrition_fab',
            onPressed: () => showMealPicker(context, provider),
            icon: Icon(Icons.add_rounded),
            label: Text('Добавить еду'),
            extendedPadding: EdgeInsets.symmetric(horizontal: 22),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, AppDataProvider provider) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Дневник питания', style: theme.textTheme.headlineSmall),
              SizedBox(height: 4),
              Text(
                formatDateRu(provider.selectedDate),
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Очистить еду за выбранный день',
          onPressed: provider.todayFoodEntries.isEmpty
              ? null
              : () => confirmClearFood(context, provider),
          icon: Icon(Icons.delete_sweep_outlined),
        ),
        SizedBox(width: 4),
        CircleActionButton(
          icon: Icons.calendar_month_rounded,
          size: 42,
          onTap: () => _selectDate(context, provider),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(BuildContext context, AppDataProvider provider) {
    final theme = Theme.of(context);
    final consumed = provider.todayCaloriesConsumed;
    final target = provider.adjustedCaloriesTarget;
    final remaining = provider.caloriesRemaining;
    final progress = provider.caloriesProgress;
    final over =
        target != null && target > 0 && remaining != null && remaining < 0;

    if (provider.todayFoodEntries.isEmpty) {
      return PremiumCard(
        onTap: () =>
            showNutritionDetails(context, provider, NutrientMetric.calories),
        glow: true,
        gradient: AppTheme.heroGradient,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Питание за этот день не записано',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              target == null
                  ? 'Цель калорий не задана или не подтверждена.'
                  : 'Ориентир с тренировками: ${formatNumber(target)} ккал',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return PremiumCard(
      onTap: () =>
          showNutritionDetails(context, provider, NutrientMetric.calories),
      glow: true,
      gradient: AppTheme.heroGradient,
      padding: EdgeInsets.all(18),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target == null
                          ? 'По записям · цель не подтверждена'
                          : 'По записям · ориентир с тренировками',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    SizedBox(height: 4),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: formatNumber(consumed),
                            style: TextStyle(
                              fontSize: 30,
                              letterSpacing: -1,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          if (target != null)
                            TextSpan(
                              text: ' / ${formatNumber(target)}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (progress != null && remaining != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      over ? 'Выше ориентира' : 'До ориентира',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: over ? AppTheme.error : AppTheme.textSecondary,
                      ),
                    ),
                    Text(
                      '${formatNumber(over ? -remaining : remaining)} ккал',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: over ? AppTheme.error : AppTheme.primary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (progress != null) ...[
            SizedBox(height: 16),
            GradientProgressBar(
              value: progress,
              color: over ? AppTheme.error : AppTheme.primary,
              height: 10,
            ),
          ],
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _NutrientMini(
                  label: 'Белки',
                  consumed: provider.todayProteinConsumed,
                  onTap: () => showNutritionDetails(
                    context,
                    provider,
                    NutrientMetric.protein,
                  ),
                  target: provider.targetProteinToday,
                  color: AppTheme.blue,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _NutrientMini(
                  label: 'Жиры',
                  consumed: provider.todayFatConsumed,
                  onTap: () => showNutritionDetails(
                    context,
                    provider,
                    NutrientMetric.fat,
                  ),
                  target: provider.targetFatToday,
                  color: AppTheme.amber,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _NutrientMini(
                  label: 'Углеводы',
                  consumed: provider.todayCarbsConsumed,
                  onTap: () => showNutritionDetails(
                    context,
                    provider,
                    NutrientMetric.carbs,
                  ),
                  target: provider.targetCarbsToday,
                  color: AppTheme.carbs,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _selectDate(BuildContext context, AppDataProvider provider) async {
    final date = await showDatePicker(
      context: context,
      initialDate: provider.selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (date != null) provider.setSelectedDate(date);
  }

  void _showAddFood(
    BuildContext context,
    AppDataProvider provider,
    MealType mealType,
  ) {
    showDialog(
      context: context,
      builder: (_) => AddFoodDialog(provider: provider, mealType: mealType),
    );
  }
}

void showMealPicker(BuildContext context, AppDataProvider provider) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);

      return SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: kAppMaxWidth),
            child: Container(
              margin: EdgeInsets.all(12),
              padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 30,
                    offset: Offset(0, -10),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Куда добавить?',
                            style: theme.textTheme.titleMedium,
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Выберите приём пищи',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10.5,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 14),
                    for (final mealType in MealType.values)
                      Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: PremiumCard(
                          radius: 18,
                          padding: EdgeInsets.zero,
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            showDialog<void>(
                              context: context,
                              builder: (_) => AddFoodDialog(
                                provider: provider,
                                mealType: mealType,
                              ),
                            );
                          },
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            child: Row(
                              children: [
                                RoundIconBadge(
                                  icon: mealType.icon,
                                  color: mealAccent(mealType),
                                  size: 38,
                                  iconSize: 18,
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    mealType.label,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  provider
                                          .getFoodEntriesForMeal(mealType)
                                          .isEmpty
                                      ? 'нет записей'
                                      : '${provider.getMealCalories(mealType)} ккал',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 10.5,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                SizedBox(width: 4),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: AppTheme.textSecondary.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// A direct route to the existing recipe component, not a second recipe store.
class RecipesScreen extends StatelessWidget {
  const RecipesScreen({super.key});

  @override
  Widget build(BuildContext context) => Consumer<AppDataProvider>(
    builder: (context, provider, _) => CenteredBody(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          Text('Рецепты', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Ингредиенты, порции и вес готового блюда.'),
          const SizedBox(height: 20),
          DiaryErrorBanner(provider: provider),
          _MyRecipesSection(provider: provider),
        ],
      ),
    ),
  );
}

class _MyRecipesSection extends StatelessWidget {
  final AppDataProvider provider;

  const _MyRecipesSection({required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipes = provider.recipes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Мои рецепты',
          subtitle: 'КБЖУ на 100 г и на порцию',
          trailing: TextButton.icon(
            onPressed: () => _open(context, null),
            icon: Icon(Icons.add_rounded, size: 18),
            label: Text('Новый'),
          ),
        ),
        SizedBox(height: 12),
        if (recipes.isEmpty)
          PremiumCard(
            radius: 20,
            padding: EdgeInsets.all(16),
            onTap: () => _open(context, null),
            child: Row(
              children: [
                RoundIconBadge(
                  icon: Icons.menu_book_rounded,
                  color: AppTheme.secondary,
                  size: 44,
                  iconSize: 20,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Соберите первое блюдо',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Добавьте ингредиенты — приложение посчитает\n'
                        'калории и БЖУ автоматически',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          height: 1.35,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppTheme.textSecondary.withValues(alpha: 0.6),
                ),
              ],
            ),
          )
        else
          for (final recipe in recipes)
            Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: PremiumCard(
                radius: 20,
                padding: EdgeInsets.zero,
                onTap: () => _open(context, recipe),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppTheme.secondary.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          Icons.menu_book_rounded,
                          size: 19,
                          color: AppTheme.secondary,
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              recipe.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '${recipe.caloriesPer100g.round()} ккал/100 г · '
                              'порция ${recipe.servingGrams.round()} г · '
                              '${recipe.servings} порц.',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: AppTheme.textSecondary.withValues(alpha: 0.6),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _open(BuildContext context, Recipe? recipe) {
    return showDialog(
      context: context,
      builder: (_) => AddRecipeDialog(provider: provider, initial: recipe),
    );
  }
}

class _NutrientMini extends StatelessWidget {
  final String label;
  final double consumed;
  final int? target;
  final Color color;
  final VoidCallback? onTap;

  const _NutrientMini({
    required this.label,
    required this.consumed,
    required this.target,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goal = target;
    final progress = availableGoalProgress(consumed, goal);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
              Text(
                goal != null
                    ? '${formatGrams(consumed)}/$goal'
                    : '${formatGrams(consumed)} г / —',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            SizedBox(height: 6),
            GradientProgressBar(value: progress, color: color, height: 6),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// ЭКРАН: ПРОГРЕСС И АНАЛИТИКА
// ============================================================================

enum ProgressPeriod { week, month, quarter, all }

extension ProgressPeriodX on ProgressPeriod {
  String get label {
    switch (this) {
      case ProgressPeriod.week:
        return 'Неделя';
      case ProgressPeriod.month:
        return 'Месяц';
      case ProgressPeriod.quarter:
        return '3 месяца';
      case ProgressPeriod.all:
        return 'Всё время';
    }
  }

  int get days {
    switch (this) {
      case ProgressPeriod.week:
        return 7;
      case ProgressPeriod.month:
        return 30;
      case ProgressPeriod.quarter:
        return 90;
      case ProgressPeriod.all:
        return 365;
    }
  }
}

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  ProgressPeriod _period = ProgressPeriod.month;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppDataProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return Center(child: CircularProgressIndicator());
        }

        return RefreshIndicator(
          color: AppTheme.primary,
          backgroundColor: AppTheme.surface,
          onRefresh: provider.refresh,
          child: CenteredBody(
            child: ListView(
              physics: AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                _buildHeader(context),
                SizedBox(height: 18),
                _StreakCard(provider: provider),
                SizedBox(height: 22),
                _buildPeriodSelector(),
                SizedBox(height: 18),
                _buildWeightSection(context, provider),
                SizedBox(height: 22),
                _buildCaloriesSection(context, provider),
                SizedBox(height: 22),
                _HabitHeatmap(provider: provider),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Прогресс', style: theme.textTheme.headlineSmall),
              SizedBox(height: 4),
              Text(
                'Аналитика, серии и привычки',
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
        RoundIconBadge(
          icon: Icons.insights_rounded,
          color: AppTheme.primary,
          size: 46,
          iconSize: 22,
        ),
      ],
    );
  }

  Widget _buildPeriodSelector() {
    return Row(
      children: [
        for (var i = 0; i < ProgressPeriod.values.length; i++) ...[
          if (i > 0) SizedBox(width: 6),
          Expanded(
            child: _PeriodChip(
              label: ProgressPeriod.values[i].label,
              selected: _period == ProgressPeriod.values[i],
              onTap: () => setState(() => _period = ProgressPeriod.values[i]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildWeightSection(BuildContext context, AppDataProvider provider) {
    final entries = _filteredWeights(provider);
    final change = entries.length >= 2
        ? entries.last.weight - entries.first.weight
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Вес',
          subtitle: 'Факт и тренд по 7 дням',
          trailing: change == null
              ? null
              : _DeltaChip(change: change, suffix: 'кг'),
        ),
        SizedBox(height: 12),
        if (entries.isEmpty)
          _EmptyChartCard(
            icon: Icons.monitor_weight_rounded,
            title: 'Нет измерений за период',
            subtitle: 'Добавьте вес на вкладке «Вес»',
          )
        else
          _WeightTrendChart(entries: entries, height: 270),
      ],
    );
  }

  Widget _buildCaloriesSection(BuildContext context, AppDataProvider provider) {
    final days = _caloriesDays(provider);
    final logs = provider.historyForDays(days);
    final recordedDays = logs.where((log) => log.hasFoodRecord).toList();
    final hasData = recordedDays.isNotEmpty;
    final average = hasData
        ? recordedDays.fold<double>(0, (sum, log) => sum + log.calories) /
              recordedDays.length
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Калории',
          subtitle: average == null
              ? 'Нет записей питания за период'
              : 'Среднее по ${recordedDays.length} дн. с записью: '
                    '${formatNumber(average.round())} ккал',
          trailing: provider.baseCaloriesTarget == null
              ? null
              : _TargetLegendChip(target: provider.baseCaloriesTarget!.round()),
        ),
        SizedBox(height: 12),
        if (!hasData)
          _EmptyChartCard(
            icon: Icons.bar_chart_rounded,
            title: 'Дневник пока пуст',
            subtitle: 'Запишите приём пищи — появится график',
          )
        else
          _CaloriesBarChart(
            logs: logs,
            // This is the current base goal, not each historical day's goal.
            target: provider.baseCaloriesTarget?.round(),
          ),
      ],
    );
  }

  List<WeightEntry> _filteredWeights(AppDataProvider provider) {
    if (_period == ProgressPeriod.all) return provider.weightEntries;
    final now = DateTime.now();
    final start = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: _period.days - 1));
    return provider.weightEntries
        .where((e) => !e.date.isBefore(start))
        .toList();
  }

  int _caloriesDays(AppDataProvider provider) {
    if (_period != ProgressPeriod.all) return _period.days;
    if (provider.dayLogs.isEmpty) return 30;
    final first = provider.dayLogs.first.date;
    final now = DateTime.now();
    final diff =
        DateTime(
          now.year,
          now.month,
          now.day,
        ).difference(DateTime(first.year, first.month, first.day)).inDays +
        1;
    return diff.clamp(7, 365);
  }
}

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? AppTheme.primary.withValues(alpha: 0.14)
          : AppTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? AppTheme.primary.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: selected ? AppTheme.primary : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  final AppDataProvider provider;

  const _StreakCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final streak = provider.currentStreak;

    return PremiumCard(
      glow: true,
      gradient: AppTheme.heroGradient,
      padding: EdgeInsets.all(18),
      child: Column(
        children: [
          Row(
            children: [
              RoundIconBadge(
                icon: Icons.local_fire_department_rounded,
                color: AppTheme.amber,
                size: 52,
                iconSize: 26,
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      streak == 0
                          ? 'Начни серию сегодня'
                          : '$streak ${_daysWord(streak)} подряд',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      streak == 0
                          ? 'Запишите завтрак — и счётчик запустится'
                          : 'Дневник питания заполняется каждый день',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StreakStat(
                  label: 'Лучшая серия',
                  value: '${provider.bestStreak}',
                  hint: _daysWord(provider.bestStreak),
                  color: AppTheme.amber,
                ),
              ),
              Container(
                width: 1,
                height: 32,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              Expanded(
                child: _StreakStat(
                  label: 'Дней в дневнике',
                  value: '${provider.activeDaysCount}',
                  hint: 'с активностью',
                  color: AppTheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StreakStat extends StatelessWidget {
  final String label;
  final String value;
  final String hint;
  final Color color;

  const _StreakStat({
    required this.label,
    required this.value,
    required this.hint,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9.5,
            color: AppTheme.textSecondary,
          ),
        ),
        SizedBox(height: 3),
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        Text(
          hint,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9,
            color: AppTheme.textSecondary.withValues(alpha: 0.75),
          ),
        ),
      ],
    );
  }
}

String _daysWord(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return 'день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return 'дня';
  }
  return 'дней';
}

class _WeightTrendChart extends StatelessWidget {
  final List<WeightEntry> entries;
  final double height;

  const _WeightTrendChart({required this.entries, required this.height});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weights = entries.map((e) => e.weight).toList();
    var minY = weights.reduce(min) - 1;
    var maxY = weights.reduce(max) + 1;
    if ((maxY - minY) < 2) {
      minY -= 1;
      maxY += 1;
    }
    final maxX = entries.length > 1 ? (entries.length - 1).toDouble() : 1.0;
    final trend = _movingAverage(entries);

    return Container(
      height: height,
      padding: EdgeInsets.fromLTRB(8, 16, 16, 8),
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: ((maxY - minY) / 4).clamp(0.5, 20),
            getDrawingHorizontalLine: (value) => FlLine(
              color: Colors.white.withValues(alpha: 0.05),
              strokeWidth: 1,
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 42,
                interval: ((maxY - minY) / 4).clamp(0.5, 20),
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    value.toStringAsFixed(1),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                interval: _dateInterval(entries.length),
                getTitlesWidget: (value, meta) {
                  final index = value.round();
                  if (index < 0 || index >= entries.length) {
                    return SizedBox.shrink();
                  }
                  final date = entries[index].date;
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      '${date.day}.${date.month.toString().padLeft(2, '0')}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 9,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            enabled: true,
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => AppTheme.surfaceHigh,
              tooltipBorder: BorderSide(
                color: Colors.white.withValues(alpha: 0.10),
              ),
              getTooltipItems: (spots) => spots.map<LineTooltipItem?>((spot) {
                final index = spot.spotIndex;
                if (index < 0 || index >= entries.length) return null;
                final entry = entries[index];
                final isTrend = spot.barIndex == 1;
                return LineTooltipItem(
                  isTrend
                      ? 'Тренд · ${spot.y.toStringAsFixed(1)} кг'
                      : '${entry.weight.toStringAsFixed(1)} кг\n'
                            '${formatDateRu(entry.date)}',
                  TextStyle(
                    color: isTrend ? AppTheme.secondary : AppTheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                );
              }).toList(),
            ),
          ),
          lineBarsData: [
            // Фактический вес
            LineChartBarData(
              spots: [
                for (var i = 0; i < entries.length; i++)
                  FlSpot(i.toDouble(), entries[i].weight),
              ],
              isCurved: true,
              curveSmoothness: 0.25,
              barWidth: 3,
              isStrokeCapRound: true,
              gradient: LinearGradient(
                colors: [AppTheme.primary, AppTheme.blue],
              ),
              dotData: FlDotData(
                show: entries.length <= 45,
                getDotPainter: (spot, percent, barData, index) =>
                    FlDotCirclePainter(
                      radius: 3.5,
                      color: AppTheme.primary,
                      strokeWidth: 2.5,
                      strokeColor: AppTheme.surface,
                    ),
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppTheme.primary.withValues(alpha: 0.22),
                    AppTheme.primary.withValues(alpha: 0.01),
                  ],
                ),
              ),
            ),
            // Скользящее среднее за 7 дней
            LineChartBarData(
              spots: [
                for (var i = 0; i < trend.length; i++)
                  FlSpot(i.toDouble(), trend[i]),
              ],
              isCurved: true,
              curveSmoothness: 0.25,
              barWidth: 2,
              color: AppTheme.secondary,
              dashArray: [7, 4],
              dotData: FlDotData(show: false),
            ),
          ],
        ),
      ),
    );
  }

  List<double> _movingAverage(List<WeightEntry> items) {
    return List.generate(items.length, (i) {
      final from = items[i].date.subtract(Duration(days: 6));
      final window = items
          .where(
            (e) => !e.date.isBefore(from) && !e.date.isAfter(items[i].date),
          )
          .toList();
      if (window.isEmpty) return items[i].weight;
      return window.fold(0.0, (sum, e) => sum + e.weight) / window.length;
    });
  }

  double _dateInterval(int count) {
    if (count <= 7) return 1;
    if (count <= 14) return 2;
    if (count <= 30) return 5;
    if (count <= 90) return 14;
    return 30;
  }
}

class _CaloriesBarChart extends StatelessWidget {
  final List<DayLog> logs;
  final int? target;

  const _CaloriesBarChart({required this.logs, required this.target});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxCalories = logs.fold<double>(
      0,
      (maxValue, log) => max(maxValue, log.calories),
    );
    // A deliberately recorded 0 kcal is still data; keep axes valid even if
    // a user also set a zero target.
    final maxY = max(max(maxCalories, target?.toDouble() ?? 0) * 1.18, 1.0);
    final interval = max((maxY / 4).ceilToDouble(), 1.0);

    return Container(
      height: 240,
      padding: EdgeInsets.fromLTRB(8, 16, 12, 8),
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final chartWidth = constraints.maxWidth - 34;
          final barWidth = (chartWidth / logs.length * 0.62)
              .clamp(0.6, 22.0)
              .toDouble();

          return BarChart(
            BarChartData(
              minY: 0,
              maxY: maxY,
              alignment: BarChartAlignment.spaceAround,
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: interval,
                getDrawingHorizontalLine: (value) => FlLine(
                  color: Colors.white.withValues(alpha: 0.05),
                  strokeWidth: 1,
                ),
              ),
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  if (target != null)
                    HorizontalLine(
                      y: target!.toDouble(),
                      color: AppTheme.amber.withValues(alpha: 0.45),
                      strokeWidth: 1.2,
                      dashArray: [6, 4],
                    ),
                ],
              ),
              titlesData: FlTitlesData(
                topTitles: AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 34,
                    interval: interval,
                    getTitlesWidget: (value, meta) {
                      if (value <= 0) return SizedBox.shrink();
                      return SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text(
                          value >= 1000
                              ? '${(value / 1000).toStringAsFixed(1)}k'
                              : value.toStringAsFixed(0),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: _labelInterval(logs.length),
                    getTitlesWidget: (value, meta) {
                      final index = value.round();
                      if (index < 0 || index >= logs.length) {
                        return SizedBox.shrink();
                      }
                      final date = logs[index].date;
                      return SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text(
                          '${date.day}.${date.month.toString().padLeft(2, '0')}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                enabled: true,
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.surfaceHigh,
                  tooltipRoundedRadius: 10,
                  getTooltipItem: (group, groupIndex, rod, rodIndex) {
                    final log = logs[group.x];
                    final goal = target;
                    final inTarget =
                        goal != null &&
                        goal > 0 &&
                        log.hasFoodRecord &&
                        log.calories >= goal * 0.9 &&
                        log.calories <= goal * 1.1;
                    return BarTooltipItem(
                      '${formatShortDateRu(log.date)}\n'
                      '${formatNumber(log.calories.round())} ккал${inTarget ? ' ✅' : ''}',
                      TextStyle(
                        color: inTarget
                            ? AppTheme.primary
                            : AppTheme.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  },
                ),
              ),
              barGroups: [
                for (var i = 0; i < logs.length; i++)
                  BarChartGroupData(
                    x: i,
                    // Empty group reserves the date without inventing a zero.
                    barRods: [
                      if (logs[i].hasFoodRecord)
                        BarChartRodData(
                          toY: logs[i].calories,
                          width: barWidth,
                          borderRadius: BorderRadius.circular(3),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: logs[i].calories > 0
                                ? [
                                    AppTheme.primary.withValues(alpha: 0.35),
                                    AppTheme.primary,
                                  ]
                                : [
                                    Colors.white.withValues(alpha: 0.03),
                                    Colors.white.withValues(alpha: 0.06),
                                  ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  double _labelInterval(int count) {
    if (count <= 7) return 1;
    if (count <= 30) return 7;
    if (count <= 90) return 14;
    return 30;
  }
}

class _EmptyChartCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyChartCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 150,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 30,
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
            ),
            SizedBox(height: 10),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: AppTheme.textSecondary.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeltaChip extends StatelessWidget {
  final double change;
  final String suffix;

  const _DeltaChip({required this.change, required this.suffix});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = change > 0;
    final color = change.abs() < 0.05
        ? AppTheme.textSecondary
        : (positive ? AppTheme.amber : AppTheme.primary);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            change.abs() < 0.05
                ? Icons.remove_rounded
                : (positive
                      ? Icons.trending_up_rounded
                      : Icons.trending_down_rounded),
            size: 14,
            color: color,
          ),
          SizedBox(width: 4),
          Text(
            '${positive ? '+' : ''}${change.toStringAsFixed(1)} $suffix',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _TargetLegendChip extends StatelessWidget {
  final int target;

  const _TargetLegendChip({required this.target});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 2,
          color: AppTheme.amber.withValues(alpha: 0.7),
        ),
        SizedBox(width: 5),
        Text(
          'цель ${formatNumber(target)}',
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9.5,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _HabitHeatmap extends StatelessWidget {
  final AppDataProvider provider;

  const _HabitHeatmap({required this.provider});

  static const int _weeks = 16;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    final end = DateTime(today.year, today.month, today.day);
    var start = end.subtract(Duration(days: _weeks * 7 - 1));
    start = start.subtract(Duration(days: start.weekday - 1));

    final byDay = <String, DayLog>{
      for (final log in provider.dayLogs) dayKey(log.date): log,
    };
    final activeInPeriod = provider.dayLogs
        .where((log) => !log.date.isBefore(start))
        .where((log) => log.hasActivity)
        .length;

    return PremiumCard(
      radius: 24,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Календарь привычек',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '$activeInPeriod ${_daysWord(activeInPeriod)} с активностью · 16 недель',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.grid_on_rounded, size: 18, color: AppTheme.primary),
            ],
          ),
          SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              const labelWidth = 20.0;
              const gap = 2.5;
              final available = constraints.maxWidth - labelWidth - 4;
              final cell = ((available / _weeks) - gap).clamp(7.0, 16.0);
              final totalWidth = labelWidth + 4 + _weeks * (cell + gap);

              return SizedBox(
                width: totalWidth,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        for (var day = 1; day <= 7; day++)
                          SizedBox(
                            height: cell + gap,
                            width: labelWidth,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _weekdayLabel(day),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 7.5,
                                  color: AppTheme.textSecondary.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(width: 4),
                    ...List.generate(_weeks, (week) {
                      final weekStart = start.add(Duration(days: week * 7));
                      return Padding(
                        padding: EdgeInsets.only(right: gap),
                        child: Column(
                          children: [
                            for (var day = 0; day < 7; day++)
                              _HeatCell(
                                date: weekStart.add(Duration(days: day)),
                                today: end,
                                log:
                                    byDay[dayKey(
                                      weekStart.add(Duration(days: day)),
                                    )],
                                level: provider.habitLevel(
                                  byDay[dayKey(
                                        weekStart.add(Duration(days: day)),
                                      )] ??
                                      DayLog(
                                        date: weekStart.add(
                                          Duration(days: day),
                                        ),
                                      ),
                                ),
                                size: cell,
                                gap: gap,
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              );
            },
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Text(
                'Меньше',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 9,
                  color: AppTheme.textSecondary.withValues(alpha: 0.7),
                ),
              ),
              SizedBox(width: 6),
              for (var level = 0; level <= 4; level++)
                Container(
                  width: 10,
                  height: 10,
                  margin: EdgeInsets.only(right: 3),
                  decoration: BoxDecoration(
                    color: _heatColor(level),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              SizedBox(width: 3),
              Text(
                'Больше',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 9,
                  color: AppTheme.textSecondary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _weekdayLabel(int day) {
    switch (day) {
      case 1:
        return 'Пн';
      case 3:
        return 'Ср';
      case 5:
        return 'Пт';
      case 7:
        return 'Вс';
      default:
        return '';
    }
  }
}

class _HeatCell extends StatelessWidget {
  final DateTime date;
  final DateTime today;
  final DayLog? log;
  final int level;
  final double size;
  final double gap;

  const _HeatCell({
    required this.date,
    required this.today,
    required this.log,
    required this.level,
    required this.size,
    required this.gap,
  });

  @override
  Widget build(BuildContext context) {
    if (date.isAfter(today)) {
      return SizedBox(height: size + gap, width: size);
    }

    final day = DateTime(date.year, date.month, date.day);
    final isToday = day == today;
    final workout = log?.workoutDone ?? false;
    final foodText = log == null
        ? 'нет записей'
        : log!.hasFoodRecord
        ? '${formatNumber(log!.calories.round())} ккал'
        : 'еда не записана';
    final message =
        '${formatDateRu(day)}\n'
        '$foodText${workout ? ' · тренировка' : ''}';

    return Tooltip(
      message: message,
      waitDuration: Duration(milliseconds: 250),
      child: Container(
        width: size,
        height: size,
        margin: EdgeInsets.only(bottom: gap),
        decoration: BoxDecoration(
          color: _heatColor(level),
          borderRadius: BorderRadius.circular(2.5),
          border: isToday
              ? Border.all(
                  color: AppTheme.textPrimary.withValues(alpha: 0.7),
                  width: 1,
                )
              : null,
        ),
      ),
    );
  }
}

Color _heatColor(int level) {
  switch (level) {
    case 0:
      return Colors.white.withValues(alpha: 0.05);
    case 1:
      return AppTheme.primary.withValues(alpha: 0.22);
    case 2:
      return AppTheme.primary.withValues(alpha: 0.42);
    case 3:
      return AppTheme.primary.withValues(alpha: 0.68);
    default:
      return AppTheme.primary;
  }
}

// ЭКРАН: ВЕС
// ============================================================================

class WeightScreen extends StatelessWidget {
  const WeightScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppDataProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return Center(child: CircularProgressIndicator());
        }

        final entries = provider.weightEntries;
        final profile = provider.profile;
        final hasConfirmedTarget = profile.targetWeightConfirmed == true;

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: RefreshIndicator(
            color: AppTheme.primary,
            backgroundColor: AppTheme.surface,
            onRefresh: provider.refresh,
            child: CenteredBody(
              child: ListView(
                physics: AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, 16, 20, 130),
                children: [
                  _buildHeader(context, provider),
                  SizedBox(height: 20),
                  _buildStatsRow(context, provider),
                  if (!hasConfirmedTarget) ...[
                    SizedBox(height: 8),
                    Text(
                      profile.targetWeightConfirmed == null
                          ? 'Цель не подтверждена. Значение из старой версии '
                                'сохранено; проверьте его в настройках.'
                          : 'Цель не подтверждена. Укажите её в настройках.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => Scaffold(
                              appBar: AppBar(title: const Text('Настройки')),
                              body: const SettingsScreen(),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.flag_outlined),
                        label: const Text('Проверить цель'),
                      ),
                    ),
                  ],
                  if (entries.length >= 2 && hasConfirmedTarget) ...[
                    SizedBox(height: 14),
                    _buildProgressCard(context, provider),
                  ],
                  if (entries.isNotEmpty) ...[
                    SizedBox(height: 20),
                    WeightChart(
                      entries: entries,
                      targetWeight: hasConfirmedTarget
                          ? profile.targetWeight
                          : null,
                      startWeight: entries.first.weight,
                    ),
                  ],
                  SizedBox(height: 26),
                  SectionHeader(
                    title: 'История измерений',
                    subtitle: entries.isEmpty
                        ? 'Пока нет ни одной записи'
                        : '${entries.length} ${_measureWord(entries.length)}',
                    trailing: CircleActionButton(
                      icon: Icons.add_rounded,
                      size: 38,
                      iconSize: 20,
                      onTap: () => _showAddWeight(context, provider),
                    ),
                  ),
                  SizedBox(height: 14),
                  ...(entries.isEmpty
                      ? <Widget>[_buildEmptyState(context, provider)]
                      : _buildHistory(context, provider)),
                ],
              ),
            ),
          ),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButton: FloatingActionButton.extended(
            heroTag: 'weight_fab',
            onPressed: () => _showAddWeight(context, provider),
            icon: Icon(Icons.add_rounded),
            label: Text('Добавить вес'),
            extendedPadding: EdgeInsets.symmetric(horizontal: 22),
          ),
        );
      },
    );
  }

  String _measureWord(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return 'измерение';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'измерения';
    }
    return 'измерений';
  }

  Widget _buildHeader(BuildContext context, AppDataProvider provider) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Трекер веса', style: theme.textTheme.headlineSmall),
              SizedBox(height: 4),
              Text(
                'Держите курс под контролем',
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
        SizedBox(width: 12),
        RoundIconBadge(
          icon: Icons.monitor_weight_rounded,
          color: AppTheme.blue,
          size: 46,
          iconSize: 22,
        ),
      ],
    );
  }

  Widget _buildStatsRow(BuildContext context, AppDataProvider provider) {
    // A saved profile may have been created automatically when adding weight.
    // It is not evidence that the user chose the default target.
    final latest = provider.weightEntries.isNotEmpty
        ? provider.weightEntries.last.weight
        : null;
    final target = provider.profile.targetWeightConfirmed == true
        ? provider.profile.targetWeight
        : null;
    final diff = latest != null && target != null ? latest - target : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _WeightStatCard(
            icon: Icons.monitor_weight_rounded,
            label: 'Текущий',
            value: latest?.toStringAsFixed(1) ?? '—',
            unit: latest == null ? '' : 'кг',
            color: AppTheme.primary,
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: _WeightStatCard(
            icon: Icons.flag_rounded,
            label: 'Цель',
            value: target?.toStringAsFixed(1) ?? '—',
            unit: target == null ? '' : 'кг',
            color: AppTheme.amber,
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: _WeightStatCard(
            icon: Icons.compare_arrows_rounded,
            label: 'Разница',
            value: diff?.abs().toStringAsFixed(1) ?? '—',
            unit: diff == null ? '' : 'кг',
            color: AppTheme.blue,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressCard(BuildContext context, AppDataProvider provider) {
    final theme = Theme.of(context);
    final entries = provider.weightEntries;
    final first = entries.first.weight;
    final last = entries.last.weight;
    final total = last - first;
    final days = entries.last.date.difference(entries.first.date).inDays;
    final perWeek = days > 0 ? (total / days * 7) : 0.0;
    final target = provider.profile.targetWeight;

    // This compares the first measurement with the current target; it is
    // not proof of when the goal was set or which direction was intended.
    final span = target - first;
    final progress = span.abs() > 1e-9
        ? ((last - first) / span).clamp(0.0, 1.0).toDouble()
        : null;

    return PremiumCard(
      radius: 22,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'От первого измерения к цели',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              SizedBox(width: 8),
              Text(
                progress == null ? '—' : '${(progress * 100).round()}%',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          GradientProgressBar(value: progress ?? 0, color: AppTheme.primary),
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ProgressMini(
                  icon: total <= 0
                      ? Icons.trending_down_rounded
                      : Icons.trending_up_rounded,
                  label: 'Изменение',
                  value:
                      '${total >= 0 ? '+' : '−'}${total.abs().toStringAsFixed(1)} кг',
                  color: total <= 0 ? AppTheme.primary : AppTheme.error,
                ),
              ),
              _progressDivider(),
              Expanded(
                child: _ProgressMini(
                  icon: Icons.speed_rounded,
                  label: 'В неделю',
                  value:
                      '${perWeek >= 0 ? '+' : '−'}${perWeek.abs().toStringAsFixed(1)} кг',
                  color: perWeek <= 0 ? AppTheme.primary : AppTheme.error,
                ),
              ),
              _progressDivider(),
              Expanded(
                child: _ProgressMini(
                  icon: Icons.timer_rounded,
                  label: 'Дней',
                  value: '$days',
                  color: AppTheme.blue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _progressDivider() {
    return Container(
      width: 1,
      height: 30,
      margin: EdgeInsets.symmetric(horizontal: 6),
      color: Colors.white.withValues(alpha: 0.07),
    );
  }

  List<Widget> _buildHistory(BuildContext context, AppDataProvider provider) {
    final reversed = provider.weightEntries.reversed.toList();
    final tiles = <Widget>[];

    for (var i = 0; i < reversed.length; i++) {
      final prevWeight = i < reversed.length - 1
          ? reversed[i + 1].weight
          : null;
      tiles.add(
        Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: _WeightEntryTile(
            entry: reversed[i],
            previousWeight: prevWeight,
            provider: provider,
          ),
        ),
      );
    }

    return tiles;
  }

  Widget _buildEmptyState(BuildContext context, AppDataProvider provider) {
    final theme = Theme.of(context);

    return PremiumCard(
      padding: EdgeInsets.fromLTRB(24, 28, 24, 26),
      child: Column(
        children: [
          RoundIconBadge(
            icon: Icons.monitor_weight_outlined,
            color: AppTheme.blue,
            size: 64,
            iconSize: 30,
          ),
          SizedBox(height: 16),
          Text(
            'Начните отслеживать вес',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          SizedBox(height: 6),
          Text(
            'Добавляйте измерения регулярно,\nчтобы видеть прогресс на графике',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
          ),
          SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _showAddWeight(context, provider),
              icon: Icon(Icons.add_rounded, size: 20),
              label: Text('Добавить измерение'),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddWeight(BuildContext context, AppDataProvider provider) {
    showDialog(
      context: context,
      builder: (_) => WeightEntryDialog(provider: provider),
    );
  }
}

class _WeightStatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;

  const _WeightStatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PremiumCard(
      radius: 22,
      padding: EdgeInsets.fromLTRB(12, 13, 12, 13),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.16), AppTheme.surface],
      ),
      borderGradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.40), color.withValues(alpha: 0.03)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RoundIconBadge(icon: icon, color: color, size: 32, iconSize: 16),
          SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: value,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  TextSpan(
                    text: ' $unit',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressMini extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _ProgressMini({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Icon(icon, size: 17, color: color),
        SizedBox(height: 5),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
        SizedBox(height: 1),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9.5,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _WeightEntryTile extends StatelessWidget {
  final WeightEntry entry;
  final double? previousWeight;
  final AppDataProvider provider;

  const _WeightEntryTile({
    required this.entry,
    this.previousWeight,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPrev = previousWeight != null;
    final diff = hasPrev ? entry.weight - previousWeight! : 0.0;
    final isLoss = diff < 0;

    return PremiumCard(
      radius: 20,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: () => showDialog(
        context: context,
        builder: (_) => WeightEntryDialog(provider: provider, entry: entry),
      ),
      child: Row(
        children: [
          RoundIconBadge(
            icon: Icons.monitor_weight_rounded,
            color: AppTheme.primary,
            size: 42,
            iconSize: 20,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      entry.weight.toStringAsFixed(1),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(width: 4),
                    Text(
                      'кг',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (hasPrev) ...[
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: (isLoss ? AppTheme.primary : AppTheme.error)
                              .withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: (isLoss ? AppTheme.primary : AppTheme.error)
                                .withValues(alpha: 0.24),
                          ),
                        ),
                        child: Text(
                          '${isLoss ? '−' : '+'}${diff.abs().toStringAsFixed(1)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9.5,
                            color: isLoss ? AppTheme.primary : AppTheme.error,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: 3),
                Text(
                  formatDateRu(entry.date),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10.5,
                    color: AppTheme.textSecondary,
                  ),
                ),
                if (entry.note != null && entry.note!.isNotEmpty) ...[
                  SizedBox(height: 3),
                  Text(
                    entry.note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppTheme.textSecondary.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ЭКРАН: НАСТРОЙКИ
// ============================================================================

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  String _macroGoalLabel(int? value, bool? confirmed) => value == null
      ? 'Не задано'
      : '$value г${confirmed == true ? '' : ' · не подтверждено'}';

  String _calorieGoalLabel(UserProfile p) {
    final min = p.dailyCaloriesMin, max = p.dailyCaloriesMax;
    if (min == null && max == null) return 'Не задано';
    final values = min != null && max != null
        ? '$min–$max ккал'
        : min != null
        ? 'Минимум $min ккал; максимум не указан'
        : 'Максимум $max ккал; минимум не указан';
    return '$values${p.hasConfirmedCalorieGoal ? '' : ' · не подтверждено'}';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppDataProvider>(
      builder: (context, provider, _) {
        final p = provider.profile;
        final r = provider.reminders;
        final theme = Theme.of(context);

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: CenteredBody(
            child: ListView(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                _header(context, p),
                SizedBox(height: 16),
                if (kIsWeb) ...[
                  OutlinedButton.icon(
                    onPressed: () => showInstallHelp(context),
                    icon: const Icon(Icons.install_mobile_rounded),
                    label: const Text('Установить на телефон'),
                  ),
                  const SizedBox(height: 20),
                ],
                _SettingsGroup(
                  title: 'Профиль',
                  subtitle: 'Основные параметры тела',
                  children: [
                    _SettingsRow(
                      icon: Icons.cake_outlined,
                      color: AppTheme.secondary,
                      label: 'Возраст',
                      value: p.ageYears == null
                          ? 'Не указан'
                          : '${p.ageYears} полных лет',
                      onTap: () => _editAge(context, provider),
                    ),
                    _SettingsRow(
                      icon: Icons.height_rounded,
                      color: AppTheme.blue,
                      label: 'Рост',
                      value: p.heightConfirmed == true
                          ? '${p.height.toStringAsFixed(0)} см'
                          : p.heightConfirmed == null
                          ? 'Не подтверждён'
                          : 'Не указан',
                      onTap: () => _editDouble(
                        context,
                        'Рост (см)',
                        p.heightConfirmed == false ? null : p.height,
                        100,
                        250,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(height: v),
                        ),
                        helper: p.heightConfirmed == null
                            ? 'Значение из старого профиля — проверьте и подтвердите.'
                            : null,
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.monitor_weight_rounded,
                      color: AppTheme.primary,
                      label: 'Текущий вес',
                      value: p.currentWeightConfirmed == true
                          ? '${p.currentWeight.toStringAsFixed(1)} кг'
                          : p.currentWeightConfirmed == null
                          ? 'Не подтверждён'
                          : 'Не указан',
                      onTap: () => _editDouble(
                        context,
                        'Текущий вес (кг)',
                        p.currentWeightConfirmed == false
                            ? null
                            : p.currentWeight,
                        30,
                        300,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(currentWeight: v),
                        ),
                        helper: p.currentWeightConfirmed == null
                            ? 'Значение из старого профиля — проверьте и подтвердите.'
                            : null,
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.flag_rounded,
                      color: AppTheme.amber,
                      label: 'Целевой вес',
                      value: p.targetWeightConfirmed == true
                          ? '${p.targetWeight.toStringAsFixed(1)} кг'
                          : 'Не подтверждена',
                      onTap: () => _editDouble(
                        context,
                        'Целевой вес (кг)',
                        p.targetWeight,
                        30,
                        200,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(targetWeight: v),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 22),
                _SettingsGroup(
                  title: 'Питание',
                  subtitle: 'Ваши цели калорий и БЖУ на день',
                  children: [
                    _SettingsRow(
                      icon: Icons.local_fire_department_rounded,
                      color: AppTheme.primary,
                      label: 'Калории',
                      value: _calorieGoalLabel(p),
                      onTap: () => _editCalories(context, provider),
                    ),
                    _SettingsRow(
                      icon: Icons.fitness_center_rounded,
                      color: AppTheme.blue,
                      label: 'Белки',
                      value: _macroGoalLabel(
                        p.targetProtein,
                        p.proteinGoalConfirmed,
                      ),
                      onTap: () => _editInt(
                        context,
                        'Белки (г)',
                        p.targetProtein,
                        0,
                        500,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(targetProtein: v),
                        ),
                        helper:
                            'Проверьте значение: сохранение подтвердит эту цель.',
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.water_drop_rounded,
                      color: AppTheme.amber,
                      label: 'Жиры',
                      value: _macroGoalLabel(p.targetFat, p.fatGoalConfirmed),
                      onTap: () => _editInt(
                        context,
                        'Жиры (г)',
                        p.targetFat,
                        0,
                        500,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(targetFat: v),
                        ),
                        helper:
                            'Проверьте значение: сохранение подтвердит эту цель.',
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.grain_rounded,
                      color: AppTheme.carbs,
                      label: 'Углеводы',
                      value: _macroGoalLabel(
                        p.targetCarbs,
                        p.carbsGoalConfirmed,
                      ),
                      onTap: () => _editInt(
                        context,
                        'Углеводы (г)',
                        p.targetCarbs,
                        0,
                        500,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(targetCarbs: v),
                        ),
                        helper:
                            'Проверьте значение: сохранение подтвердит эту цель.',
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 22),
                _SettingsGroup(
                  title: 'Тренировки',
                  subtitle: 'План и расход энергии',
                  children: [
                    _SettingsRow(
                      icon: Icons.event_repeat_rounded,
                      color: AppTheme.secondary,
                      label: 'Тренировок в неделю',
                      value: '${p.workoutsPerWeek}',
                      onTap: () => _editInt(
                        context,
                        'Тренировок в неделю',
                        p.workoutsPerWeek,
                        0,
                        7,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(workoutsPerWeek: v),
                        ),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.fitness_center_rounded,
                      color: AppTheme.amber,
                      label: 'Силовая',
                      value: '${p.strengthDurationMinutes} мин',
                      onTap: () => _editInt(
                        context,
                        'Силовая (мин)',
                        p.strengthDurationMinutes,
                        0,
                        180,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(strengthDurationMinutes: v),
                        ),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.directions_run_rounded,
                      color: AppTheme.blue,
                      label: 'Кардио',
                      value: '${p.cardioDurationMinutes} мин',
                      onTap: () => _editInt(
                        context,
                        'Кардио (мин)',
                        p.cardioDurationMinutes,
                        0,
                        180,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(cardioDurationMinutes: v),
                        ),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.whatshot_rounded,
                      color: AppTheme.primary,
                      label: 'Ккал за тренировку',
                      value: '${p.workoutCaloriesBurned}',
                      onTap: () => _editInt(
                        context,
                        'Ккал за тренировку',
                        p.workoutCaloriesBurned,
                        0,
                        2000,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(workoutCaloriesBurned: v),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 22),
                _SettingsGroup(
                  title: 'Ежедневные цели',
                  subtitle: 'Активность и вода',
                  children: [
                    _SettingsRow(
                      icon: Icons.directions_walk_rounded,
                      color: AppTheme.amber,
                      label: 'Цель по шагам',
                      value: p.hasConfirmedStepsGoal
                          ? formatNumber(p.dailyStepsGoal!)
                          : 'Не подтверждена',
                      onTap: () => _editInt(
                        context,
                        'Цель по шагам',
                        p.dailyStepsGoal,
                        1000,
                        50000,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(dailyStepsGoal: v),
                        ),
                        helper:
                            p.dailyStepsGoal != null && !p.hasConfirmedStepsGoal
                            ? 'Прежнее значение сохранено. Проверьте и подтвердите его.'
                            : null,
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.water_drop_rounded,
                      color: AppTheme.blue,
                      label: 'Цель по воде',
                      value: p.hasConfirmedWaterGoal
                          ? '${formatNumber(p.dailyWaterGoalMl!)} мл'
                          : 'Не подтверждена',
                      onTap: () => _editInt(
                        context,
                        'Цель по воде (мл)',
                        p.dailyWaterGoalMl,
                        500,
                        10000,
                        (v) => provider.updateProfile(
                          provider.profile.copyWith(dailyWaterGoalMl: v),
                        ),
                        helper:
                            p.dailyWaterGoalMl != null &&
                                !p.hasConfirmedWaterGoal
                            ? 'Прежнее значение сохранено. Проверьте и подтвердите его.'
                            : null,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 22),
                _SettingsGroup(
                  title: 'Напоминания',
                  subtitle: 'Вода, обед и утреннее взвешивание',
                  children: [
                    _SettingsSwitchRow(
                      icon: Icons.water_drop_rounded,
                      color: AppTheme.blue,
                      label: 'Вода',
                      value: r.waterEnabled
                          ? 'каждые ${r.waterEveryHours} ч'
                          : 'выкл.',
                      valueColor: r.waterEnabled ? AppTheme.blue : null,
                      isOn: r.waterEnabled,
                      onChanged: (value) => _toggleReminders(
                        context,
                        provider,
                        r.copyWith(waterEnabled: value),
                      ),
                    ),
                    if (r.waterEnabled)
                      _SettingsRow(
                        icon: Icons.schedule_rounded,
                        color: AppTheme.blue,
                        label: 'Интервал воды',
                        value: 'каждые ${r.waterEveryHours} ч',
                        onTap: () => _pickWaterInterval(context, provider, r),
                      ),
                    _SettingsSwitchRow(
                      icon: Icons.lunch_dining_rounded,
                      color: AppTheme.amber,
                      label: 'Обед',
                      value: r.lunchEnabled
                          ? '${r.lunchHour.toString().padLeft(2, '0')}:00'
                          : 'выкл.',
                      valueColor: r.lunchEnabled ? AppTheme.amber : null,
                      isOn: r.lunchEnabled,
                      onChanged: (value) => _toggleReminders(
                        context,
                        provider,
                        r.copyWith(lunchEnabled: value),
                      ),
                    ),
                    if (r.lunchEnabled)
                      _SettingsRow(
                        icon: Icons.access_time_rounded,
                        color: AppTheme.amber,
                        label: 'Время обеда',
                        value: '${r.lunchHour.toString().padLeft(2, '0')}:00',
                        onTap: () => _pickHour(
                          context,
                          provider,
                          r,
                          title: 'Время обеда',
                          initial: r.lunchHour,
                          onSave: (hour) => r.copyWith(lunchHour: hour),
                        ),
                      ),
                    _SettingsSwitchRow(
                      icon: Icons.monitor_weight_rounded,
                      color: AppTheme.secondary,
                      label: 'Взвешивание',
                      value: r.weightEnabled
                          ? '${r.weightHour.toString().padLeft(2, '0')}:00'
                          : 'выкл.',
                      valueColor: r.weightEnabled ? AppTheme.secondary : null,
                      isOn: r.weightEnabled,
                      onChanged: (value) => _toggleReminders(
                        context,
                        provider,
                        r.copyWith(weightEnabled: value),
                      ),
                    ),
                    if (r.weightEnabled)
                      _SettingsRow(
                        icon: Icons.access_time_rounded,
                        color: AppTheme.secondary,
                        label: 'Время взвешивания',
                        value: '${r.weightHour.toString().padLeft(2, '0')}:00',
                        onTap: () => _pickHour(
                          context,
                          provider,
                          r,
                          title: 'Время взвешивания',
                          initial: r.weightHour,
                          onSave: (hour) => r.copyWith(weightHour: hour),
                        ),
                      ),
                    _SettingsRow(
                      icon: Icons.notifications_active_rounded,
                      color: AppTheme.primary,
                      label: 'Проверить напоминание',
                      value: NotificationService.isSupported
                          ? 'тест'
                          : 'в приложении',
                      onTap: () => _testNotification(context),
                    ),
                  ],
                ),
                SizedBox(height: 22),
                _SettingsGroup(
                  title: 'Данные',
                  subtitle: 'Резервная копия истории',
                  children: [
                    _SettingsRow(
                      icon: Icons.upload_file_rounded,
                      color: AppTheme.primary,
                      label: 'Экспортировать в JSON',
                      value: 'копия',
                      onTap: () => _exportData(context, provider),
                    ),
                    _SettingsRow(
                      icon: Icons.download_rounded,
                      color: AppTheme.blue,
                      label: 'Импортировать из JSON',
                      value: '',
                      onTap: () => _importData(context, provider),
                    ),
                    if (provider.storage.local.hasImportBackup)
                      _SettingsRow(
                        icon: Icons.history_rounded,
                        color: AppTheme.amber,
                        label: 'Копия до последнего импорта',
                        value: 'локально',
                        onTap: () {
                          final backup = provider.storage.importBackupJson();
                          if (backup == null) {
                            _showMessage(
                              context,
                              'Не удалось прочитать сохранённую копию',
                            );
                          } else {
                            _exportData(
                              context,
                              provider,
                              existingJson: backup,
                            );
                          }
                        },
                      ),
                    if (provider.storage.local.hasImportBackup)
                      _SettingsRow(
                        icon: Icons.delete_outline_rounded,
                        color: AppTheme.textSecondary,
                        label: 'Удалить копию до импорта',
                        value: '',
                        onTap: () =>
                            _confirmDiscardImportBackup(context, provider),
                      ),
                  ],
                ),
                SizedBox(height: 22),
                _SettingsGroup(
                  title: 'Опасная зона',
                  subtitle: 'Необратимые действия',
                  danger: true,
                  children: [
                    _SettingsRow(
                      icon: Icons.delete_forever_rounded,
                      color: AppTheme.error,
                      label: 'Очистить все данные',
                      value: '',
                      danger: true,
                      showChevron: false,
                      onTap: () => _confirmClear(context, provider),
                    ),
                  ],
                ),
                SizedBox(height: 26),
                Center(
                  child: Text(
                    'Fitness Tracker · данные хранятся на устройстве',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: AppTheme.textSecondary.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, UserProfile p) {
    final theme = Theme.of(context);
    final bmi =
        p.heightConfirmed == true &&
            p.currentWeightConfirmed == true &&
            p.height > 0
        ? p.currentWeight / ((p.height / 100) * (p.height / 100))
        : null;

    return PremiumCard(
      glow: true,
      gradient: AppTheme.heroGradient,
      padding: EdgeInsets.all(18),
      child: Row(
        children: [
          RoundIconBadge(
            icon: Icons.tune_rounded,
            color: AppTheme.secondary,
            size: 52,
            iconSize: 24,
          ),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Настройки', style: theme.textTheme.headlineSmall),
                SizedBox(height: 4),
                Text(
                  bmi != null
                      ? 'ИМТ ${bmi.toStringAsFixed(1)} · оценка по профилю'
                      : 'Для ИМТ подтвердите рост и вес',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _profileSaveError(
    BuildContext context,
    Object error, {
    String fallback = 'Не удалось сохранить параметр профиля.',
  }) {
    final message = error is ProfileEditException ? error.message : fallback;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editAge(BuildContext context, AppDataProvider provider) async {
    final change = await showDialog<({bool clear, int? value})>(
      context: context,
      builder: (_) => _AgeDialog(initial: provider.profile.ageYears),
    );
    if (change == null || !context.mounted) return;
    try {
      // Re-read the profile after the dialog, so it does not overwrite another
      // edit that happened while the dialog was open.
      await provider.updateProfile(
        provider.profile.copyWith(
          ageYears: change.value,
          clearAge: change.clear,
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              change.clear ? 'Возраст удалён.' : 'Возраст сохранён.',
            ),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        _profileSaveError(
          context,
          error,
          fallback: 'Не удалось сохранить возраст. Попробуйте ещё раз.',
        );
      }
    }
  }

  Future<void> _editCalories(
    BuildContext context,
    AppDataProvider provider,
  ) async {
    final minCtrl = TextEditingController(
      text: provider.profile.dailyCaloriesMin?.toString() ?? '',
    );
    final maxCtrl = TextEditingController(
      text: provider.profile.dailyCaloriesMax?.toString() ?? '',
    );

    final values = await showDialog<({int min, int max})>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text('Калорийный коридор'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Проверьте оба значения: сохранение подтвердит этот коридор.',
            ),
            TextField(
              controller: minCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Минимум, ккал'),
            ),
            SizedBox(height: 12),
            TextField(
              controller: maxCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Максимум, ккал'),
            ),
          ],
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              final min = int.tryParse(minCtrl.text);
              final max = int.tryParse(maxCtrl.text);
              if (min != null && max != null && min > 0 && max >= min) {
                Navigator.pop(ctx, (min: min, max: max));
              }
            },
            child: Text('Сохранить'),
          ),
        ],
      ),
    );
    if (values == null || !context.mounted) return;
    try {
      await provider.updateProfile(
        provider.profile.copyWith(
          dailyCaloriesMin: values.min,
          dailyCaloriesMax: values.max,
        ),
      );
    } catch (error) {
      if (context.mounted) _profileSaveError(context, error);
    }
  }

  Future<void> _editInt(
    BuildContext context,
    String title,
    int? initial,
    int min,
    int max,
    Future<void> Function(int) onSave, {
    String? helper,
  }) async {
    final ctrl = TextEditingController(text: initial?.toString() ?? '');

    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(helperText: helper, helperMaxLines: 3),
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text);
              if (v != null && v >= min && v <= max) {
                Navigator.pop(ctx, v);
              }
            },
            child: Text('Сохранить'),
          ),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    try {
      await onSave(value);
    } catch (error) {
      if (context.mounted) _profileSaveError(context, error);
    }
  }

  Future<void> _editDouble(
    BuildContext context,
    String title,
    double? initial,
    double min,
    double max,
    Future<void> Function(double) onSave, {
    String? helper,
  }) async {
    final ctrl = TextEditingController(text: initial?.toStringAsFixed(1) ?? '');
    String? error;
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          title: Text(title),
          content: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            decoration: InputDecoration(
              helperText: helper,
              helperMaxLines: 3,
              errorText: error,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () {
                final v = double.tryParse(ctrl.text.replaceAll(',', '.'));
                if (v == null || !v.isFinite || v < min || v > max) {
                  setDialogState(
                    () => error = 'Введите значение от $min до $max',
                  );
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (value == null || !context.mounted) return;
    try {
      await onSave(value);
    } catch (error) {
      if (context.mounted) _profileSaveError(context, error);
    }
  }

  Future<void> _toggleReminders(
    BuildContext context,
    AppDataProvider provider,
    ReminderSettings next,
  ) async {
    if (next.anyEnabled && NotificationService.isSupported) {
      await NotificationService.requestPermissions();
    }
    await provider.updateReminders(next);
    if (!context.mounted) return;
    if (next.anyEnabled && !NotificationService.isSupported) {
      _showMessage(
        context,
        'Системные уведомления недоступны — напомним на главном экране',
      );
    }
  }

  Future<void> _pickWaterInterval(
    BuildContext context,
    AppDataProvider provider,
    ReminderSettings settings,
  ) async {
    final hours = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text('Напоминать о воде'),
        children: [
          for (final value in [2, 3])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('Каждые $value ч · с 09:00 до 21:00'),
              ),
            ),
        ],
      ),
    );
    if (hours == null) return;
    await provider.updateReminders(settings.copyWith(waterEveryHours: hours));
  }

  Future<void> _pickHour(
    BuildContext context,
    AppDataProvider provider,
    ReminderSettings settings, {
    required String title,
    required int initial,
    required ReminderSettings Function(int hour) onSave,
  }) async {
    final controller = TextEditingController(text: '$initial');
    final hour = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Час (0–23)',
            suffixText: ':00',
          ),
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value != null && value >= 0 && value <= 23) {
                Navigator.pop(ctx, value);
              }
            },
            child: Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (hour == null) return;
    await provider.updateReminders(onSave(hour));
  }

  Future<void> _testNotification(BuildContext context) async {
    if (!NotificationService.isSupported) {
      _showMessage(
        context,
        'Мягкие напоминания появятся на главном экране в нужное время',
      );
      return;
    }
    await NotificationService.requestPermissions();
    await NotificationService.showNow();
    if (!context.mounted) return;
    _showMessage(context, 'Тестовое уведомление отправлено');
  }

  Future<void> _exportData(
    BuildContext context,
    AppDataProvider provider, {
    String? existingJson,
  }) async {
    late final String json;
    try {
      json = existingJson ?? await provider.exportDataJson();
    } on ImportRecoveryRequired catch (error) {
      if (context.mounted) _showMessage(context, error.toString());
      return;
    } on StateError catch (error) {
      if (context.mounted) _showMessage(context, error.message.toString());
      return;
    } catch (_) {
      if (context.mounted) {
        _showMessage(context, 'Не удалось создать копию. Дневник не изменён.');
      }
      return;
    }
    if (!context.mounted) return;
    final review = reviewBackupFile(json);
    if (!await confirmUnverifiedBackup(context, review)) return;
    if (!context.mounted) return;
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: json));
      copied = true;
    } catch (_) {}
    if (!context.mounted) return;

    final size = (json.length / 1024).toStringAsFixed(1);
    final theme = Theme.of(context);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Row(
          children: [
            RoundIconBadge(
              icon: Icons.upload_file_rounded,
              color: AppTheme.primary,
              size: 36,
              iconSize: 18,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                copied ? 'JSON скопирован' : 'Экспорт данных',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              copied
                  ? 'Копия ($size КБ) в буфере обмена. Сохраните её в '
                        'защищённом месте: буфер временный.'
                  : 'Скопируйте данные ($size КБ) и сохраните их в защищённом месте.',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                height: 1.4,
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Файл содержит личные записи. Локальные черновики, избранное '
              'и согласие ИИ, данные входа и облако в него не входят. '
              'Проверьте восстановление в отдельном профиле: некоторые старые '
              'или повреждённые записи могут не импортироваться.',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 6),
            Text(
              review.passesFilePreflight
                  ? 'Структура и размер проверены для загрузки файла; '
                        'это не проверка восстановления или полноты копии.'
                  : 'Копия непроверенная: не считайте её пригодной для импорта.',
              style: theme.textTheme.labelSmall,
            ),
            SizedBox(height: 12),
            Container(
              constraints: BoxConstraints(maxHeight: 180),
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.surfaceSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  json,
                  style: TextStyle(
                    fontSize: 9.5,
                    height: 1.35,
                    fontFamily: 'monospace',
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Закрыть'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: json));
              } catch (_) {}
              if (ctx.mounted) Navigator.pop(ctx);
            },
            icon: Icon(Icons.copy_rounded, size: 17),
            label: Text('Копировать'),
          ),
        ],
      ),
    );

    if (!context.mounted) return;
    _showMessage(
      context,
      copied
          ? 'Резервная копия скопирована · $size КБ'
          : 'Скопируйте JSON из окна экспорта',
    );
  }

  Future<void> _confirmDiscardImportBackup(
    BuildContext context,
    AppDataProvider provider,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить предимпортную копию?'),
        content: const Text(
          'Будет удалена только локальная копия до последнего импорта. '
          'Текущие записи дневника останутся без изменений.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить копию'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await provider.discardImportBackup();
      if (context.mounted) _showMessage(context, 'Локальная копия удалена');
    } catch (_) {
      if (context.mounted)
        _showMessage(context, 'Не удалось удалить копию. Повторите позже.');
    }
  }

  Future<void> _importData(
    BuildContext context,
    AppDataProvider provider,
  ) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _BackupTextImportDialog(),
    );

    if (raw == null || raw.isEmpty) return;
    if (!context.mounted) return;
    final review = reviewBackupFile(raw);
    // The clipboard path historically has no file-size limit. Preserve that
    // behavior: large text still receives the importer's validation later,
    // whereas smaller known-invalid text is rejected before confirmation.
    if (review.issue == BackupReviewIssue.invalid ||
        review.issue == BackupReviewIssue.changedDocuments) {
      _showMessage(
        context,
        'Копия не прошла проверку импортёра. Дневник не изменён. '
        'Сохраните исходный текст для возможного восстановления.',
      );
      return;
    }
    final incoming = parseBackupDocuments(raw);
    if (incoming == null) {
      _showMessage(context, 'Копия не прошла проверку импортёра. Дневник не изменён.');
      return;
    }
    final current = provider.storage.local.snapshot();
    final preview = previewImportDocuments(incoming, current);
    final guard = ImportReviewGuard(
      documents: documentsFingerprint(incoming),
      diary: documentsFingerprint(current),
      account: currentImportAccount(provider),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text('Заменить данные?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview.summary),
            const SizedBox(height: 10),
            Text(
              'Записи, рецепты и настройки будут заменены содержимым резервной копии. '
              'Заранее сохраните отдельный экспорт текущего дневника. '
              'Последняя предимпортная копия также хранится на этом устройстве до следующего импорта или очистки данных. '
              'При следующей синхронизации замена и удаления могут попасть в облако. '
              'Локальные черновики, избранное ИИ и согласие не входят в копию '
              'и останутся на этом устройстве.',
            ),
          ],
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Импортировать'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    if (!await confirmImportRemovals(context, preview)) return;
    if (!context.mounted) return;

    final nowIncoming = parseBackupDocuments(raw);
    await provider.storage.pendingMutations;
    final stale = guard.staleReason(
      documents: documentsFingerprint(nowIncoming ?? const {}),
      diary: await currentDiaryFingerprint(provider),
      account: currentImportAccount(provider),
    );
    if (stale != null) {
      if (context.mounted) _showMessage(context, '$stale Импорт отменён.');
      return;
    }

    final error = await provider.importDataJson(raw);
    if (!context.mounted) return;
    _showMessage(context, error ?? 'Данные успешно импортированы');
  }

  void _showMessage(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _confirmClear(BuildContext context, AppDataProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Row(
          children: [
            RoundIconBadge(
              icon: Icons.warning_amber_rounded,
              color: AppTheme.error,
              size: 36,
              iconSize: 18,
            ),
            SizedBox(width: 10),
            Expanded(child: Text('Очистить всё?')),
          ],
        ),
        content: Text(
          'Это действие нельзя отменить. На устройстве будут удалены записи, '
          'настройки и локальная предимпортная копия. При синхронизации удаления '
          'могут попасть в облако. Сам аккаунт при этом не удаляется.',
        ),
        actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await provider.clearAllData();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Данные на устройстве удалены'),
                    ),
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Очистка не завершена. Дождитесь синхронизации, проверьте хранилище и повторите.',
                      ),
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: Text('Удалить всё'),
          ),
        ],
      ),
    );
  }
}

/// Owns its controller for the entire dialog lifetime, including dismissal.
/// Own the text controller until the dialog route is actually unmounted.
/// Navigator.pop completes before the reverse animation finishes, so disposing
/// a controller immediately after awaiting showDialog can race the TextField.
class _BackupTextImportDialog extends StatefulWidget {
  const _BackupTextImportDialog();

  @override
  State<_BackupTextImportDialog> createState() =>
      _BackupTextImportDialogState();
}

class _BackupTextImportDialogState extends State<_BackupTextImportDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: const Text('Импорт данных'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Вставьте JSON резервной копии. Текущие данные будут заменены.',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                height: 1.4,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              minLines: 4,
              maxLines: 7,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: '{"app":"fitness_tracker", ...}',
                filled: true,
                fillColor: AppTheme.surfaceSoft,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  final text = data?.text;
                  if (mounted && text != null && text.isNotEmpty) {
                    controller.text = text;
                  }
                },
                icon: const Icon(Icons.content_paste_rounded, size: 17),
                label: const Text('Вставить из буфера'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Импортировать'),
        ),
      ],
    );
  }
}

class _AgeDialog extends StatefulWidget {
  final int? initial;
  const _AgeDialog({required this.initial});

  @override
  State<_AgeDialog> createState() => _AgeDialogState();
}

class _AgeDialogState extends State<_AgeDialog> {
  late final TextEditingController controller;
  bool invalid = false;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initial?.toString() ?? '');
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Возраст'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Полных лет',
              errorText: invalid ? 'Укажите целое число от 1 до 120' : null,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Необязательно. Возраст хранится в профиле и может попасть в '
            'резервную копию и облачную синхронизацию. Обновляйте его после '
            'дня рождения. В новый ИИ-анализ он передаётся только по вашему выбору.',
          ),
        ],
      ),
    ),
    actions: [
      if (widget.initial != null)
        TextButton(
          onPressed: () => Navigator.pop(context, (clear: true, value: null)),
          child: const Text('Удалить возраст'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          final age = int.tryParse(controller.text.trim());
          if (age == null || age < 1 || age > 120) {
            setState(() => invalid = true);
            return;
          }
          Navigator.pop(context, (clear: false, value: age));
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

class _SettingsGroup extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool danger;

  const _SettingsGroup({
    required this.title,
    this.subtitle,
    required this.children,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = danger ? AppTheme.error : AppTheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 13,
                        letterSpacing: 0.2,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PremiumCard(
          padding: EdgeInsets.zero,
          gradient: danger
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppTheme.error.withValues(alpha: 0.10),
                    AppTheme.surface,
                  ],
                )
              : null,
          borderGradient: danger
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppTheme.error.withValues(alpha: 0.35),
                    AppTheme.error.withValues(alpha: 0.04),
                  ],
                )
              : null,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i < children.length - 1)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 62,
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool danger;
  final bool showChevron;

  const _SettingsRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.onTap,
    this.danger = false,
    this.showChevron = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = danger ? AppTheme.error : AppTheme.textPrimary;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            RoundIconBadge(icon: icon, color: color, size: 34, iconSize: 17),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: tint,
                    ),
                  ),
                  if (value.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: danger ? AppTheme.error : color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (showChevron) ...[
              SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppTheme.textSecondary.withValues(alpha: 0.6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final Color? valueColor;
  final bool isOn;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitchRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.isOn,
    required this.onChanged,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 5, 8, 5),
      child: Row(
        children: [
          RoundIconBadge(icon: icon, color: color, size: 34, iconSize: 17),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: valueColor ?? AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              value: isOn,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SmartRemote.instance.initialize();
  await NotificationService.init();

  final provider = AppDataProvider();
  try {
    await provider.init();
  } on ImportRecoveryRequired {
    // Do not expose partially restored documents or start cloud sync.
    final storage = provider.storage;
    provider.dispose();
    runApp(ImportRecoveryApp(storage: storage));
    return;
  } catch (_) {
    // Never render a plausible empty diary or bind cloud sync after a failed
    // startup read. Do not log exception text: it can contain personal data.
    // Only offer export when this startup actually opened the local store.
    final storage = provider.storage;
    final canRead = provider.startupStorageOpened;
    provider.dispose();
    runApp(StartupRecoveryApp(storage: storage, canReadStorage: canRead));
    return;
  }
  SmartRemote.instance.bindLocal(
    provider.storage.local,
    validateAppDocument,
    provider.reloadAll,
    () => provider.storage.pendingMutations,
  );

  // Пересчитываем расписание при запуске: часовой пояс и настройки
  // могли измениться, а после перезагрузки устройства уведомления
  // восстанавливаются тем же способом.
  await NotificationService.schedule(provider.reminders);

  runApp(MyApp(provider: provider));
}

/// Fail-closed screen when an interrupted import cannot yet be restored.
/// The original copy is only exposed to the user through an explicit action.
class ImportRecoveryApp extends StatelessWidget {
  final StorageService storage;
  const ImportRecoveryApp({super.key, required this.storage});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fitness Smart · восстановление',
    debugShowCheckedModeBanner: false,
    builder: (context, child) =>
        IsolatedPreviewBanner(child: child ?? const SizedBox.shrink()),
    theme: AppTheme.darkTheme,
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: ImportRecoveryScreen(storage: storage),
  );
}

class ImportRecoveryScreen extends StatelessWidget {
  final StorageService storage;
  const ImportRecoveryScreen({super.key, required this.storage});

  @override
  Widget build(BuildContext context) {
    final backup = storage.importBackupJson();
    return Scaffold(
      appBar: AppBar(title: const Text('Восстановление дневника')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Импорт был прерван',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Дневник и синхронизация временно заблокированы, чтобы не перезаписать данные. '
                    'Освободите место на устройстве и полностью перезапустите приложение: '
                    'оно проверит состояние и при незавершённом импорте попытается восстановить исходные записи. '
                    'Не очищайте данные браузера или приложения.',
                  ),
                  const SizedBox(height: 16),
                  if (backup == null)
                    const Text(
                      'Автоматически прочитать резервную копию не удалось. Не удаляйте данные приложения; может понадобиться ручное восстановление.',
                    )
                  else ...[
                    const Text(
                      'Можно скопировать исходную резервную копию. Она содержит личные записи — сохраните её в надёжном месте и никому не отправляйте.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () async {
                        try {
                          final review = reviewBackupFile(backup);
                          if (!await confirmUnverifiedBackup(context, review)) {
                            return;
                          }
                          await Clipboard.setData(ClipboardData(text: backup));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Копия помещена в буфер обмена. Сохраните её в надёжном месте.',
                                ),
                              ),
                            );
                          }
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Не удалось скопировать. Не очищайте данные приложения.',
                                ),
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Скопировать резервную копию'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatefulWidget {
  final AppDataProvider provider;

  const MyApp({super.key, required this.provider});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppDataProvider>.value(
      value: widget.provider,
      child: Consumer<AppDataProvider>(
        builder: (context, data, _) {
          AppTheme.configure(data.smartSettings);
          final recovery =
              data.storage.local.hasPendingImport &&
              !LocalPreferences.importInProgress;
          return MaterialApp(
            key: ValueKey(recovery),
            title: 'Fitness Smart',
            debugShowCheckedModeBanner: false,
            builder: (context, child) =>
                IsolatedPreviewBanner(child: child ?? const SizedBox.shrink()),
            theme: AppTheme.darkTheme,
            locale: Locale('ru'),
            supportedLocales: [Locale('ru'), Locale('en')],
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: recovery
                ? ImportRecoveryScreen(storage: data.storage)
                : const MainScreen(),
          );
        },
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final PageController _pageController = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _openTab(int index) {
    setState(() => _currentIndex = index);
    _pageController.jumpToPage(index);
  }

  static const List<_NavItem> _items = [
    _NavItem(
      label: 'Сегодня',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
    ),
    _NavItem(
      label: 'Дневник',
      icon: Icons.restaurant_menu_outlined,
      selectedIcon: Icons.restaurant_menu_rounded,
    ),
    _NavItem(
      label: 'Тренировка',
      icon: Icons.fitness_center_outlined,
      selectedIcon: Icons.fitness_center_rounded,
    ),
    _NavItem(
      label: 'Обзор',
      icon: Icons.auto_awesome_outlined,
      selectedIcon: Icons.auto_awesome_rounded,
    ),
    _NavItem(
      label: 'Каталог продуктов',
      icon: Icons.local_grocery_store_outlined,
      selectedIcon: Icons.local_grocery_store_rounded,
    ),
    _NavItem(
      label: 'Рецепты',
      icon: Icons.menu_book_outlined,
      selectedIcon: Icons.menu_book_rounded,
    ),
    _NavItem(
      label: 'Упражнения',
      icon: Icons.sports_gymnastics_outlined,
      selectedIcon: Icons.sports_gymnastics_rounded,
    ),
    _NavItem(
      label: 'Активность',
      icon: Icons.directions_walk_outlined,
      selectedIcon: Icons.directions_walk_rounded,
    ),
    _NavItem(
      label: 'Календарь',
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month_rounded,
    ),
    _NavItem(
      label: 'ИИ-помощник',
      icon: Icons.chat_bubble_outline_rounded,
      selectedIcon: Icons.chat_bubble_rounded,
    ),
    _NavItem(
      label: 'Профиль',
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
    ),
    _NavItem(
      label: 'Настройки',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppDataProvider>();
    final screens = <Widget>[
      SimpleHomeScreen(openTab: _openTab),
      const NutritionScreen(),
      GymHomeScreen(provider: provider),
      JournalOverviewScreen(provider: provider),
      FoodCatalogScreen(provider: provider),
      const RecipesScreen(),
      PlanExercisesScreen(openTraining: () => _openTab(2)),
      const ManualActivityScreen(),
      JournalCalendarScreen(
        openDiary: () => _openTab(1),
        openTraining: () => _openTab(2),
        openActivity: () => _openTab(7),
      ),
      const AiChatScreen(),
      const SettingsScreen(),
      const SmartHub(),
    ];
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= 840;
    final expandedRail = width >= 1100;
    // The same PageView and routes are reused at each breakpoint. No new
    // placeholder screens or parallel copies of the existing functionality.
    final pages = SafeArea(
      bottom: false,
      child: PageView(
        // Preserve the active page when the shell switches between rail/bar.
        key: const PageStorageKey<String>('fitness-main-pages'),
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < screens.length; i++)
            _RetainedMainPage(
              key: ValueKey('main-section-$i'),
              active: i == _currentIndex,
              child: screens[i],
            ),
        ],
      ),
    );
    void openMore() => Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => const MoreScreen()));

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppTheme.background,
      drawer: Drawer(
        child: Builder(
          builder: (drawerContext) => SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Разделы Fitness Smart',
                          style: Theme.of(drawerContext).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Закрыть меню разделов',
                        onPressed: () => Navigator.of(drawerContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return ListTile(
                        leading: Icon(
                          index == _currentIndex
                              ? item.selectedIcon
                              : item.icon,
                        ),
                        title: Text(item.label),
                        selected: index == _currentIndex,
                        onTap: () {
                          Navigator.of(drawerContext).pop();
                          _openTab(index);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Row(
        children: [
          if (useRail)
            SafeArea(
              child: NavigationRail(
                backgroundColor: AppTheme.surface,
                scrollable: true,
                extended: expandedRail,
                minExtendedWidth: 205,
                labelType: expandedRail
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                selectedIndex: _currentIndex,
                onDestinationSelected: _openTab,
                useIndicator: true,
                indicatorColor: AppTheme.primary.withValues(alpha: .16),
                selectedIconTheme: IconThemeData(color: AppTheme.primary),
                unselectedIconTheme: IconThemeData(
                  color: AppTheme.textSecondary,
                ),
                selectedLabelTextStyle: TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelTextStyle: TextStyle(
                  color: AppTheme.textSecondary,
                ),
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: expandedRail
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.spa_rounded, color: AppTheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              'Fitness Smart',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        )
                      : Icon(Icons.spa_rounded, color: AppTheme.primary),
                ),
                destinations: [
                  for (final item in _items)
                    NavigationRailDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selectedIcon),
                      label: Text(item.label),
                    ),
                ],
                trailing: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: expandedRail
                      ? TextButton.icon(
                          onPressed: openMore,
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Ещё'),
                        )
                      : IconButton(
                          onPressed: openMore,
                          tooltip: 'Ещё: настройки и данные',
                          icon: const Icon(Icons.tune_rounded),
                        ),
                ),
              ),
            ),
          if (useRail) VerticalDivider(width: 1, color: AppTheme.outline),
          // Keep this element at the same place across breakpoints so open
          // screens and in-progress UI state are not recreated on resize.
          Expanded(key: const ValueKey('main-pages-shell'), child: pages),
        ],
      ),
      bottomNavigationBar: useRail
          ? null
          : Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 24,
                    offset: Offset(0, -8),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: kAppMaxWidth),
                    child: NavigationBarTheme(
                      data: NavigationBarThemeData(
                        backgroundColor: Colors.transparent,
                        indicatorColor: AppTheme.primary.withValues(
                          alpha: 0.16,
                        ),
                        elevation: 0,
                        labelTextStyle: WidgetStateProperty.resolveWith((
                          states,
                        ) {
                          final selected = states.contains(
                            WidgetState.selected,
                          );
                          return TextStyle(
                            fontSize: MediaQuery.sizeOf(context).width < 360
                                ? 9.0
                                : 10.5,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: selected
                                ? AppTheme.primary
                                : AppTheme.textSecondary,
                          );
                        }),
                      ),
                      child: NavigationBar(
                        height: 68,
                        selectedIndex: _currentIndex < 4 ? _currentIndex : 4,
                        onDestinationSelected: (index) {
                          if (index == 4) {
                            _scaffoldKey.currentState?.openDrawer();
                          } else {
                            _openTab(index);
                          }
                        },
                        labelBehavior:
                            MediaQuery.sizeOf(context).width < 380 ||
                                MediaQuery.textScalerOf(context).scale(1) > 1.25
                            ? NavigationDestinationLabelBehavior
                                  .onlyShowSelected
                            : NavigationDestinationLabelBehavior.alwaysShow,
                        destinations: [
                          for (final item in _items.take(4))
                            NavigationDestination(
                              icon: Icon(
                                item.icon,
                                color: AppTheme.textSecondary,
                              ),
                              selectedIcon: Icon(
                                item.selectedIcon,
                                color: AppTheme.primary,
                              ),
                              label: item.label,
                            ),
                          const NavigationDestination(
                            icon: Icon(Icons.menu_rounded),
                            selectedIcon: Icon(Icons.menu_open_rounded),
                            label: 'Разделы',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Keep visited sections alive when switching tabs, so an in-progress search or
/// form is not destroyed. Inactive animations are muted with TickerMode.
class _RetainedMainPage extends StatefulWidget {
  final bool active;
  final Widget child;
  const _RetainedMainPage({
    super.key,
    required this.active,
    required this.child,
  });

  @override
  State<_RetainedMainPage> createState() => _RetainedMainPageState();
}

class _RetainedMainPageState extends State<_RetainedMainPage>
    with AutomaticKeepAliveClientMixin<_RetainedMainPage> {
  final PageStorageBucket _bucket = PageStorageBucket();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PageStorage(
      bucket: _bucket,
      child: TickerMode(enabled: widget.active, child: widget.child),
    );
  }
}

class _NavItem {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });
}
// ============================================================================
// РАЗБИВКА, ОЧИСТКА И ПОЛНОЕ РЕДАКТИРОВАНИЕ ДНЕВНИКА
// ============================================================================

enum NutrientMetric { calories, protein, fat, carbs }

extension NutrientMetricView on NutrientMetric {
  String get label => switch (this) {
    NutrientMetric.calories => 'Калории',
    NutrientMetric.protein => 'Белки',
    NutrientMetric.fat => 'Жиры',
    NutrientMetric.carbs => 'Углеводы',
  };
  String get unit => this == NutrientMetric.calories ? 'ккал' : 'г';
  double value(FoodEntry e) => switch (this) {
    NutrientMetric.calories => e.calories,
    NutrientMetric.protein => e.protein,
    NutrientMetric.fat => e.fat,
    NutrientMetric.carbs => e.carbs,
  };
  int? target(AppDataProvider p) => switch (this) {
    NutrientMetric.calories => p.adjustedCaloriesTarget,
    NutrientMetric.protein => p.targetProteinToday,
    NutrientMetric.fat => p.targetFatToday,
    NutrientMetric.carbs => p.targetCarbsToday,
  };
}

class DiaryErrorBanner extends StatelessWidget {
  final AppDataProvider provider;
  const DiaryErrorBanner({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    if (provider.persistenceError == null) return SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: MaterialBanner(
        content: Text(provider.persistenceError!),
        leading: Icon(Icons.error_outline, color: AppTheme.error),
        actions: [
          TextButton(onPressed: provider.refresh, child: Text('Обновить')),
        ],
      ),
    );
  }
}

Future<void> confirmClearFood(
  BuildContext context,
  AppDataProvider provider,
) async {
  final date = provider.selectedDate;
  final snapshot = provider.captureFoodDay();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Очистить дневник питания?'),
      content: Text(
        'Будет удалена вся еда за ${formatDateRu(date)}. '
        'Тренировки, вода и другие дни останутся. Отменить очистку нельзя.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: AppTheme.error),
          child: Text('Очистить'),
        ),
      ],
    ),
  );
  if (confirmed == true && dayKey(date) == dayKey(provider.selectedDate)) {
    try {
      await provider.clearFoodForSelectedDay(snapshot: snapshot);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              provider.persistenceError ?? 'Не удалось очистить дневник.',
            ),
          ),
        );
      }
    }
  }
}

Future<void> showNutritionDetails(
  BuildContext context,
  AppDataProvider provider,
  NutrientMetric metric,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: AppTheme.surface,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (_) => ChangeNotifierProvider.value(
    value: provider,
    child: FractionallySizedBox(
      heightFactor: 0.86,
      child: SafeArea(
        top: false,
        child: Consumer<AppDataProvider>(
          builder: (context, p, _) {
            final total = p.todayFoodEntries.fold(
              0.0,
              (sum, e) => sum + metric.value(e),
            );
            final target = metric.target(p);
            final fraction = availableGoalProgress(total, target);
            final percent = fraction == null ? null : (fraction * 100).round();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${metric.label} · ${formatDateRu(p.selectedDate)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
                    children: [
                      DiaryErrorBanner(provider: p),
                      if (p.todayFoodEntries.isNotEmpty) ...[
                        Text(
                          '${formatGrams(total)} ${metric.unit} по записям / '
                          '${target == null ? 'цель не задана или не подтверждена' : 'ориентир $target ${metric.unit}${percent == null ? ' · процент недоступен' : ' · $percent%'}'}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (fraction != null) ...[
                          SizedBox(height: 12),
                          GradientProgressBar(
                            value: fraction,
                            color: AppTheme.primary,
                          ),
                        ],
                        SizedBox(height: 12),
                        if (metric == NutrientMetric.calories &&
                            p.baseCaloriesTarget != null) ...[
                          Text(
                            'Ориентир ${p.baseCaloriesTarget!.round()} − по записям ${p.todayCaloriesConsumed}'
                            ' + учтено тренировок ${p.todayWorkoutCalorieCredit} = ${p.caloriesRemaining} ккал',
                          ),
                          Text(
                            'Ориентир с тренировками: ${p.adjustedCaloriesTarget} ккал. '
                            'Адаптация БЖУ: ${p.metabolism.adaptMacros ? 'включена' : 'выключена'}.',
                          ),
                        ] else if (metric == NutrientMetric.calories)
                          const Text(
                            'Подтвердите цель в профиле, чтобы сравнить с записями.',
                          )
                        else
                          Text(
                            'Значения рассчитаны по весу порции. Нажмите на продукт, чтобы исправить порцию или БЖУ.',
                          ),
                        MacroInsights(provider: p, metric: metric),
                      ],
                      if (p.todayFoodEntries.any(
                        (e) =>
                            e.calories > 0 &&
                            e.protein == 0 &&
                            e.fat == 0 &&
                            e.carbs == 0,
                      ))
                        Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'У некоторых продуктов есть калории, но БЖУ равны нулю. '
                            'Проверьте этикетку и исправьте данные: автоматически восстановить их нельзя.',
                            style: TextStyle(color: AppTheme.amber),
                          ),
                        ),
                      if (p.todayFoodEntries.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('За этот день еда ещё не добавлена.'),
                        ),
                      for (final meal in MealType.values)
                        if (p.getFoodEntriesForMeal(meal).isNotEmpty) ...[
                          SizedBox(height: 20),
                          Text(
                            '${meal.label} · ${formatGrams(p.getFoodEntriesForMeal(meal).fold(0.0, (sum, e) => sum + metric.value(e)))} ${metric.unit}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          for (final entry in p.getFoodEntriesForMeal(meal))
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(entry.name),
                              subtitle: Text(
                                '${formatGrams(entry.amountGrams)} г · '
                                '${formatGrams(metric.value(entry))} ${metric.unit}',
                              ),
                              onTap: () => showFoodEditor(context, p, entry),
                              trailing: IconButton(
                                tooltip: 'Редактировать продукт',
                                icon: Icon(Icons.edit_outlined),
                                onPressed: () =>
                                    showFoodEditor(context, p, entry),
                              ),
                            ),
                        ],
                      if (p.todayFoodEntries.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => confirmClearFood(context, p),
                          icon: Icon(Icons.delete_sweep_outlined),
                          label: Text('Очистить еду за этот день'),
                        ),
                      if (metric == NutrientMetric.calories &&
                          p.todayWorkoutEntries.isNotEmpty) ...[
                        Divider(),
                        Text(
                          'Тренировки · расход ${p.todayCaloriesBurned} ккал · +${p.todayWorkoutCalorieCredit} ккал к лимиту',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        for (final workout in p.todayWorkoutEntries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              workout.type.icon,
                              color: AppTheme.amber,
                            ),
                            title: Text(workout.type.label),
                            subtitle: Text(
                              '${workout.durationMinutes} мин · ${workout.caloriesBurned} ккал · +${workout.budgetCalories} к лимиту',
                            ),
                            trailing: IconButton(
                              tooltip: 'Редактировать тренировку',
                              icon: Icon(Icons.edit_outlined),
                              onPressed: () =>
                                  showWorkoutEditor(context, p, entry: workout),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  ),
);

Future<void> showFoodEditor(
  BuildContext context,
  AppDataProvider provider,
  FoodEntry entry,
) => showDialog<void>(
  context: context,
  builder: (_) => _EditFoodDialog(provider: provider, entry: entry),
);

class _EditFoodDialog extends StatefulWidget {
  final AppDataProvider provider;
  final FoodEntry entry;
  const _EditFoodDialog({required this.provider, required this.entry});
  @override
  State<_EditFoodDialog> createState() => _EditFoodDialogState();
}

class _EditFoodDialogState extends State<_EditFoodDialog> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  late final TextEditingController _name;
  late final List<TextEditingController> _numbers;
  late final FoodEditSnapshot _snapshot;
  String? _error;
  bool _saving = false, _estimating = false;
  late bool _microsEstimated;
  late Map<String, double> _micros;
  late DateTime _loggedAt;
  late MealType _meal;
  late bool _timeKnown;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _snapshot = widget.provider.captureFoodEdit(e);
    _micros = Map.of(e.micros);
    _microsEstimated = e.microsEstimated;
    _loggedAt = e.loggedAt;
    _meal = e.mealType;
    _timeKnown = e.timeKnown;
    _name = TextEditingController(text: e.name);
    // Keep full stored precision unless the user explicitly changes the field.
    _numbers = [
      e.amountGrams,
      e.caloriesPer100g,
      e.proteinPer100g,
      e.fatPer100g,
      e.carbsPer100g,
    ].map((v) => TextEditingController(text: v.toString())).toList();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _name.dispose();
    for (final c in _numbers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = [
      'Вес порции, г',
      'Калории на 100 г',
      'Белки на 100 г',
      'Жиры на 100 г',
      'Углеводы на 100 г',
    ];
    final grams = parseNutritionNumber(_numbers[0].text) ?? 0;
    final values = _numbers
        .skip(1)
        .map((c) => (parseNutritionNumber(c.text) ?? 0) * grams / 100)
        .toList();
    return PopScope(
      canPop: !_saving && !_estimating,
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        titlePadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        title: Text('Редактировать продукт'),
        content: SizedBox(
          width: 380,
          child: AbsorbPointer(
            absorbing: _saving || _estimating,
            child: Form(
              key: _form,
              child: SingleChildScrollView(
                controller: _scroll,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: AppTheme.error)),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _name,
                      decoration: InputDecoration(labelText: 'Название'),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Укажите название'
                          : null,
                    ),
                    SizedBox(height: 8),
                    Text('Все нутриенты ниже — на 100 г, не на всю порцию.'),
                    for (var i = 0; i < _numbers.length; i++)
                      Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: TextFormField(
                          controller: _numbers[i],
                          keyboardType: TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(labelText: labels[i]),
                          onChanged: (_) => setState(() {}),
                          validator: (text) {
                            final value = parseNutritionNumber(text ?? '');
                            if (value == null || (i == 0 && value <= 0)) {
                              return i == 0
                                  ? 'Введите вес больше 0'
                                  : 'Введите число ≥ 0 (или 0, если нет)';
                            }
                            return null;
                          },
                        ),
                      ),
                    SizedBox(height: 16),
                    DropdownButtonFormField<MealType>(
                      initialValue: _meal,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: 'Приём пищи'),
                      items: [
                        for (final meal in MealType.values)
                          DropdownMenuItem(
                            value: meal,
                            child: Text(
                              meal.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => _meal = value!,
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final result = await editMicros(context, _micros);
                        if (result != null && mounted)
                          setState(() => _micros = result);
                      },
                      icon: Icon(Icons.science_outlined),
                      label: Text('Витамины и минералы на 100 г'),
                    ),
                    if (_microsEstimated && _micros.isNotEmpty)
                      const Text(
                        'Часть витаминов — оценка ИИ; проверьте источники.',
                        style: TextStyle(fontSize: 12),
                      ),
                    TextButton.icon(
                      onPressed: _saving || _estimating
                          ? null
                          : _estimateMicros,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: Text(
                        _estimating
                            ? 'Определяем витамины…'
                            : 'Определить витамины с ИИ',
                      ),
                    ),
                    if (_estimating) const LinearProgressIndicator(),
                    TextButton.icon(
                      onPressed: () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(_loggedAt),
                        );
                        if (time != null && mounted)
                          setState(() {
                            _timeKnown = true;
                            _loggedAt = DateTime(
                              widget.entry.date.year,
                              widget.entry.date.month,
                              widget.entry.date.day,
                              time.hour,
                              time.minute,
                            );
                          });
                      },
                      icon: Icon(Icons.schedule),
                      label: Text(
                        _timeKnown
                            ? 'Время: ${_loggedAt.hour.toString().padLeft(2, '0')}:${_loggedAt.minute.toString().padLeft(2, '0')}'
                            : 'Время неизвестно — указать',
                      ),
                    ),
                    Text(
                      'Порция: ${formatGrams(values[0])} ккал · Б ${formatGrams(values[1])}'
                      ' · Ж ${formatGrams(values[2])} · У ${formatGrams(values[3])}',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving || _estimating ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: Text('Удалить'),
          ),
          TextButton(
            onPressed: _saving || _estimating
                ? null
                : () => Navigator.pop(context),
            child: Text('Отмена'),
          ),
          FilledButton(
            onPressed: _saving || _estimating ? null : _save,
            child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> _estimateMicros() async {
    final account = SmartRemote.instance.client?.auth.currentUser?.id;
    final privacyEpoch = LocalPreferences.privacyEpoch;
    final foodName = _name.text.trim();
    if (account == null) {
      await notice(
        context,
        'Для ИИ войдите в аккаунт в разделе Smart. Ручной ввод доступен без входа.',
      );
      return;
    }
    if (foodName.isEmpty) {
      await notice(context, 'Сначала укажите название продукта.');
      return;
    }
    setState(() => _estimating = true);
    try {
      final accepted = await ensureAiConsent(
        context,
        widget.provider.storage.local,
        account,
      );
      if (!accepted || !mounted) return;
      if (SmartRemote.instance.client?.auth.currentUser?.id != account ||
          !AiConsent(
            widget.provider.storage.local,
            account,
          ).validFor(privacyEpoch)) {
        throw StateError(
          'Аккаунт или согласие изменились. Запрос не отправлен.',
        );
      }
      final items = await SmartRemote.instance.parseFood(
        mode: 'micronutrients',
        text: 'Оцени витамины и минералы на 100 г одного продукта: $foodName.',
      );
      if (!mounted) return;
      if (SmartRemote.instance.client?.auth.currentUser?.id != account) {
        throw StateError('Аккаунт изменился. Оценка не применена.');
      }
      if (!AiConsent(
        widget.provider.storage.local,
        account,
      ).validFor(privacyEpoch)) {
        throw StateError('Согласие изменилось. Оценка не применена.');
      }
      if (_name.text.trim() != foodName) {
        throw StateError(
          'Название продукта изменилось. Повторите запрос для текущего названия.',
        );
      }
      if (items.length != 1 || readMicros(items.first['micros']).isEmpty) {
        throw StateError(
          'Не удалось оценить состав. Существующие значения не изменены.',
        );
      }
      final proposed = mergeMicronutrientEstimates(
        _micros,
        items.first['micros'],
      );
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Проверить оценку ИИ?'),
          content: Text(
            'ИИ предложил состав для «${items.first['name']}». Это приблизительная оценка на 100 г, не данные анализа и не назначение добавок. Уже введённые значения не заменяются; неизвестные остаются пустыми. Сверьте состав с упаковкой.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Проверить значения'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
      bool stillAuthorized() =>
          SmartRemote.instance.client?.auth.currentUser?.id == account &&
          AiConsent(
            widget.provider.storage.local,
            account,
          ).validFor(privacyEpoch) &&
          _name.text.trim() == foodName;
      if (!stillAuthorized()) {
        throw StateError(
          'Аккаунт, согласие или название изменились. Оценка не применена.',
        );
      }
      final reviewed = await editMicros(context, proposed);
      if (reviewed != null && mounted) {
        if (!stillAuthorized()) {
          throw StateError(
            'Аккаунт, согласие или название изменились. Оценка не применена.',
          );
        }
        setState(() {
          _micros = reviewed;
          _microsEstimated = true;
        });
        await notice(
          context,
          'Оценка в редакторе. Нажмите «Сохранить», чтобы записать её в дневник.',
        );
      }
    } catch (e) {
      if (mounted) await notice(context, friendlyAiError(e));
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final n = _numbers.map((c) => parseNutritionNumber(c.text)!).toList();
    final entry = widget.entry.copyWith(
      name: _name.text.trim(),
      mealType: _meal,
      micros: Map.of(_micros),
      microsEstimated: _microsEstimated,
      loggedAt: _loggedAt,
      timeKnown: _timeKnown,
      amountGrams: n[0],
      caloriesPer100g: n[1],
      proteinPer100g: n[2],
      fatPer100g: n[3],
      carbsPer100g: n[4],
    );
    await _commit(entry);
  }

  Future<void> _commit(FoodEntry? entry) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (entry == null) {
        await widget.provider.deleteFoodEntry(
          widget.entry.id,
          snapshot: _snapshot,
        );
      } else {
        await widget.provider.updateFoodEntry(entry, snapshot: _snapshot);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final warning = widget.provider.persistenceError;
      setState(() => _saving = false);
      Navigator.pop(context);
      if (warning != null)
        messenger?.showSnackBar(SnackBar(content: Text(warning)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is FoodEditException
            ? error.message
            : 'Не удалось изменить дневник. Проверьте свободное место и повторите.';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить продукт?'),
        content: Text(widget.entry.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _commit(null);
  }
}
