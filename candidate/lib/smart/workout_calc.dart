import 'dart:math' as math;

/// Adult 2024 Compendium activity codes and standard METs. These are population
/// averages, never measurements of an individual's energy expenditure.
class WorkoutActivity {
  final String id, label, family, code;
  final double? met;
  const WorkoutActivity(this.id, this.label, this.family, this.met, this.code);
}

const workoutActivities = <WorkoutActivity>[
  WorkoutActivity('other', 'Другое / не выбрано', 'other', null, ''),
  WorkoutActivity(
    'strength_regular',
    'Силовая · обычная, несколько упражнений',
    'strength',
    3.5,
    '02054',
  ),
  WorkoutActivity(
    'strength_vigorous',
    'Силовая · высокая интенсивность',
    'strength',
    6.0,
    '02050',
  ),
  WorkoutActivity(
    'bodyweight',
    'Упражнения с весом тела · обычные',
    'strength',
    3.0,
    '02056',
  ),
  WorkoutActivity(
    'calisthenics',
    'Упражнения с весом тела · умеренные',
    'strength',
    3.8,
    '02022',
  ),
  WorkoutActivity('elliptical', 'Эллипс · умеренно', 'cardio', 5.0, '02048'),
  WorkoutActivity('walk_slow', 'Ходьба · медленная', 'cardio', 2.8, '17152'),
  WorkoutActivity('walk', 'Ходьба · умеренная', 'cardio', 3.8, '17190'),
  WorkoutActivity('walk_brisk', 'Ходьба · быстрая', 'cardio', 4.8, '17200'),
  WorkoutActivity('jog', 'Бег · около 8 км/ч', 'cardio', 8.5, '12030'),
  WorkoutActivity('run', 'Бег · около 9,7 км/ч', 'cardio', 9.3, '12050'),
  WorkoutActivity('bike_easy', 'Велосипед · неспешно', 'cardio', 4.0, '01010'),
  WorkoutActivity('bike', 'Велосипед · обычная езда', 'cardio', 7.0, '01014'),
  WorkoutActivity(
    'bike_moderate',
    'Велосипед · около 19–22 км/ч',
    'cardio',
    8.0,
    '01030',
  ),
  WorkoutActivity('swim', 'Плавание кролем · медленно', 'cardio', 5.8, '18240'),
  WorkoutActivity('yoga', 'Йога · хатха', 'other', 2.3, '02150'),
];

WorkoutActivity? workoutActivity(String id) {
  for (final a in workoutActivities) {
    if (a.id == id) return a;
  }
  return null;
}

bool _validNumber(Object? x, double min, double max) =>
    x is num && x.isFinite && x >= min && x <= max;
int? _optionalInt(Object? raw, int max) {
  if (raw == null) return null;
  if (raw is! num ||
      !raw.isFinite ||
      raw != raw.roundToDouble() ||
      raw < 1 ||
      raw > max) {
    throw const FormatException('Некорректные подходы или повторения.');
  }
  return raw.toInt();
}

double? _optionalDouble(Object? raw, double min, double max) {
  if (raw == null) return null;
  if (!_validNumber(raw, min, max))
    throw const FormatException('Некорректное число тренировки.');
  return (raw as num).toDouble();
}

class WorkoutSegment {
  final String activityId;
  final int minutes;
  final double? distanceKm;
  const WorkoutSegment({
    required this.activityId,
    required this.minutes,
    this.distanceKm,
  });
  WorkoutActivity get activity =>
      workoutActivity(activityId) ?? workoutActivities.first;
  factory WorkoutSegment.fromJson(Map<String, dynamic> j) {
    final id = j['activityId'];
    if (id is! String ||
        workoutActivity(id) == null ||
        !_validNumber(j['minutes'], 1, 1440) ||
        j['minutes'] != (j['minutes'] as num).roundToDouble()) {
      throw const FormatException('Некорректный этап тренировки.');
    }
    return WorkoutSegment(
      activityId: id,
      minutes: (j['minutes'] as num).toInt(),
      distanceKm: _optionalDouble(j['distanceKm'], 0.01, 1000),
    );
  }
  Map<String, dynamic> toJson() => {
    'activityId': activityId,
    'minutes': minutes,
    if (distanceKm != null) 'distanceKm': distanceKm,
  };
}

class WorkoutExercise {
  final String name;
  final int? sets, reps;
  final double? weightKg;
  const WorkoutExercise({
    required this.name,
    this.sets,
    this.reps,
    this.weightKg,
  });
  factory WorkoutExercise.fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    if (name is! String || name.trim().isEmpty || name.length > 120) {
      throw const FormatException('Укажите название упражнения.');
    }
    return WorkoutExercise(
      name: name.trim(),
      sets: _optionalInt(j['sets'], 100),
      reps: _optionalInt(j['reps'], 1000),
      weightKg: _optionalDouble(j['weightKg'], 0, 2000),
    );
  }
  Map<String, dynamic> toJson() => {
    'name': name,
    if (sets != null) 'sets': sets,
    if (reps != null) 'reps': reps,
    if (weightKg != null) 'weightKg': weightKg,
  };
  bool get hasVolume => sets != null && reps != null && weightKg != null;
  double get volumeKg => hasVolume ? sets! * reps! * weightKg! : 0;
}

class WorkoutDetails {
  final List<WorkoutSegment> segments;
  final List<WorkoutExercise> exercises;
  final double? weightKg;
  final String calorieMode, source;
  final int budgetPercent;
  const WorkoutDetails({
    required this.segments,
    required this.exercises,
    required this.weightKg,
    required this.calorieMode,
    required this.budgetPercent,
    required this.source,
  });
  factory WorkoutDetails.fromJson(Map<String, dynamic> j) {
    if (j['version'] != 1 ||
        j['segments'] is! List ||
        (j['segments'] as List).isEmpty ||
        (j['segments'] as List).length > 20 ||
        j['exercises'] is! List ||
        (j['exercises'] as List).length > 30 ||
        !['estimate', 'manual'].contains(j['calorieMode']) ||
        !['manual', 'ai'].contains(j['source']) ||
        !_validNumber(j['budgetPercent'], 0, 100) ||
        j['budgetPercent'] != (j['budgetPercent'] as num).roundToDouble()) {
      throw const FormatException('Некорректные подробности тренировки.');
    }
    final segments = (j['segments'] as List)
        .map(
          (e) => WorkoutSegment.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList();
    if (segments.fold<int>(0, (sum, e) => sum + e.minutes) > 1440) {
      throw const FormatException('Тренировка не может длиться больше суток.');
    }
    final weight = _optionalDouble(j['weightKg'], 20, 400);
    if (j['calorieMode'] == 'estimate' &&
        (weight == null || segments.any((e) => e.activity.met == null))) {
      throw const FormatException('Для расчёта нужны вес и вид всех этапов.');
    }
    return WorkoutDetails(
      segments: segments,
      exercises: (j['exercises'] as List)
          .map(
            (e) =>
                WorkoutExercise.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      weightKg: weight,
      calorieMode: j['calorieMode'] as String,
      budgetPercent: (j['budgetPercent'] as num).toInt(),
      source: j['source'] as String,
    );
  }
  Map<String, dynamic> toJson() => {
    'version': 1,
    'segments': segments.map((e) => e.toJson()).toList(),
    'exercises': exercises.map((e) => e.toJson()).toList(),
    if (weightKg != null) 'weightKg': weightKg,
    'calorieMode': calorieMode,
    'budgetPercent': budgetPercent,
    'source': source,
  };
  int get minutes => segments.fold(0, (sum, e) => sum + e.minutes);
  int get knownVolumeExercises => exercises.where((e) => e.hasVolume).length;
  double get volumeKg => exercises.fold(0, (sum, e) => sum + e.volumeKg);
  int get knownDistanceSegments =>
      segments.where((e) => e.distanceKm != null).length;
  double? get knownDistanceKm => knownDistanceSegments == 0
      ? null
      : segments.fold<double>(0, (sum, e) => sum + (e.distanceKm ?? 0));
}

class WorkoutEnergy {
  final double gross, active;
  const WorkoutEnergy(this.gross, this.active);
}

/// 1 standard MET ≈ 1 kcal/kg/hour. Active expenditure subtracts one
/// resting MET so that only the above-rest part can be added to the food goal.
WorkoutEnergy calculateWorkoutEnergy(
  List<WorkoutSegment> segments,
  double weightKg,
) {
  if (!_validNumber(weightKg, 20, 400) ||
      segments.isEmpty ||
      segments.length > 20) {
    throw ArgumentError('Проверьте вес и этапы тренировки.');
  }
  var gross = 0.0, active = 0.0, minutes = 0;
  for (final s in segments) {
    final met = s.activity.met;
    if (met == null || s.minutes <= 0 || s.minutes > 1440)
      throw ArgumentError('Выберите вид и длительность каждого этапа.');
    minutes += s.minutes;
    gross += met * weightKg * s.minutes / 60;
    active += math.max(0, met - 1) * weightKg * s.minutes / 60;
  }
  if (minutes > 1440) throw ArgumentError('Общая длительность больше суток.');
  return WorkoutEnergy(gross, active);
}

/// Strictly accept only editable fields from the model. Missing numeric inputs
/// use zero as an UNKNOWN sentinel; they are never counted as a measurement.
Map<String, dynamic> validateWorkoutDraft(Object? raw) {
  if (raw is! Map ||
      raw['segments'] is! List ||
      (raw['segments'] as List).length > 20 ||
      raw['exercises'] is! List ||
      (raw['exercises'] as List).length > 30 ||
      raw['remarks'] is! String ||
      (raw['remarks'] as String).length > 1500) {
    throw const FormatException('Не удалось проверить ответ ИИ.');
  }
  int nonNegativeInt(Object? v, int max) {
    if (v is! num ||
        !_validNumber(v, 0, max.toDouble()) ||
        v != v.roundToDouble()) {
      throw const FormatException('Некорректное число в ответе ИИ.');
    }
    return v.toInt();
  }

  double nonNegative(Object? v, double max) {
    if (!_validNumber(v, 0, max))
      throw const FormatException('Некорректное число в ответе ИИ.');
    return (v as num).toDouble();
  }

  final segments = <Map<String, dynamic>>[];
  for (final item in raw['segments'] as List) {
    if (item is! Map ||
        item['activityId'] is! String ||
        workoutActivity(item['activityId'] as String) == null) {
      throw const FormatException('Некорректный вид тренировки в ответе ИИ.');
    }
    segments.add({
      'activityId': item['activityId'],
      'minutes': nonNegativeInt(item['minutes'], 1440),
      'distanceKm': nonNegative(item['distanceKm'], 1000),
    });
  }
  if (segments.fold<int>(0, (v, s) => v + (s['minutes'] as int)) > 1440)
    throw const FormatException('Сумма длительностей больше суток.');
  final exercises = <Map<String, dynamic>>[];
  for (final item in raw['exercises'] as List) {
    if (item is! Map ||
        item['name'] is! String ||
        (item['name'] as String).trim().isEmpty ||
        (item['name'] as String).length > 120) {
      throw const FormatException('Некорректное упражнение в ответе ИИ.');
    }
    exercises.add({
      'name': (item['name'] as String).trim(),
      'sets': nonNegativeInt(item['sets'], 100),
      'reps': nonNegativeInt(item['reps'], 1000),
      'weightKg': nonNegative(item['weightKg'], 2000),
    });
  }
  return {
    'segments': segments,
    'exercises': exercises,
    'remarks': (raw['remarks'] as String).trim(),
  };
}
