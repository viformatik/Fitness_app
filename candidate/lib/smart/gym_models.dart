import 'dart:convert';
import 'dart:math' as math;

// Every gym session is its own versioned sync/backup document. Missing values
// mean unknown, not zero. Result rows retain the actual name used at the time.
typedef GymJson = Map<String, dynamic>;

String _text(Object? value, String field, {int max = 200, bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.trim().isEmpty)) {
    throw FormatException('Некорректное поле: $field');
  }
  return value.trim();
}

int _integer(Object? value, String field, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw FormatException('Некорректное число: $field');
  }
  return value;
}

int? _optionalInt(Object? value, String field, int min, int max) =>
    value == null ? null : _integer(value, field, min, max);

double? _optionalNumber(Object? value, String field, double min, double max) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < min || value > max) {
    throw FormatException('Некорректное число: $field');
  }
  return value.toDouble();
}

DateTime _date(Object? value, String field) {
  if (value is! String || value.length > 50) {
    throw FormatException('Некорректная дата: $field');
  }
  final date = DateTime.tryParse(value);
  if (date == null) throw FormatException('Некорректная дата: $field');
  return date.toLocal();
}

DateTime? _optionalDate(Object? value, String field) =>
    value == null ? null : _date(value, field);
String _iso(DateTime value) => value.toUtc().toIso8601String();

String _id(Object? value, String field) {
  final result = _text(value, field, max: 80);
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(result)) {
    throw FormatException('Некорректный идентификатор: $field');
  }
  return result;
}

bool isPullupName(String name) => name.toLowerCase().contains('подтягив');

class GymSet {
  final int index;
  final DateTime recordedAt;
  final String exerciseName;
  final int? reps, seconds, rir;
  final double? weightKg;
  // unknown / bodyweight / weighted / assisted. Assistance is NOT external load.
  final String pullupMode;
  final bool isTest;
  final String note;

  const GymSet({
    required this.index,
    required this.recordedAt,
    required this.exerciseName,
    this.reps,
    this.seconds,
    this.rir,
    this.weightKg,
    this.pullupMode = 'unknown',
    this.isTest = false,
    this.note = '',
  });

  bool get isPullup => isPullupName(exerciseName);
  bool get isComparableTest =>
      isPullup && isTest && pullupMode == 'bodyweight' && reps != null;

  factory GymSet.fromJson(GymJson j) {
    final reps = _optionalInt(j['reps'], 'повторения', 0, 1000);
    final seconds = _optionalInt(j['seconds'], 'секунды', 0, 86400);
    if (reps == null && seconds == null) {
      throw const FormatException('Укажите повторения или время подхода');
    }
    final mode = _text(j['pullupMode'] ?? 'unknown', 'вариант', max: 20);
    if (!['unknown', 'bodyweight', 'weighted', 'assisted'].contains(mode)) {
      throw const FormatException('Неизвестный вариант подтягиваний');
    }
    final kg = _optionalNumber(j['weightKg'], 'вес', 0, 2000);
    if (mode == 'bodyweight' && kg != null && kg != 0) {
      throw const FormatException('Для подтягиваний без веса укажите 0 кг');
    }
    return GymSet(
      index: _integer(j['index'], 'номер подхода', 1, 100),
      recordedAt: _date(j['recordedAt'], 'время подхода'),
      exerciseName: _text(j['exerciseName'], 'упражнение', max: 120),
      reps: reps,
      seconds: seconds,
      rir: _optionalInt(j['rir'], 'запас повторений', 0, 20),
      weightKg: kg,
      pullupMode: mode,
      isTest: j['isTest'] == true,
      note: _text(j['note'] ?? '', 'заметка', max: 300, empty: true),
    );
  }

  GymJson toJson() => {
    'index': index,
    'recordedAt': _iso(recordedAt),
    'exerciseName': exerciseName,
    if (reps != null) 'reps': reps,
    if (seconds != null) 'seconds': seconds,
    if (rir != null) 'rir': rir,
    if (weightKg != null) 'weightKg': weightKg,
    'pullupMode': pullupMode,
    'isTest': isTest,
    if (note.isNotEmpty) 'note': note,
  };
}

class GymExercise {
  final String id, originalName;
  String name, target;
  int plannedSets;
  bool timed, isTest;
  List<String> targets, alternatives;
  List<GymSet> sets;

  GymExercise({
    required this.id,
    required this.name,
    String? originalName,
    required this.plannedSets,
    this.target = '',
    this.timed = false,
    this.isTest = false,
    List<String>? targets,
    List<String>? alternatives,
    List<GymSet>? sets,
  }) : originalName = originalName ?? name,
       targets = targets ?? [],
       alternatives = alternatives ?? [],
       sets = sets ?? [];

  String targetFor(int index) =>
      index <= targets.length ? targets[index - 1] : target;
  GymSet? setAt(int index) {
    for (final set in sets) {
      if (set.index == index) return set;
    }
    return null;
  }

  int get nextExtraIndex {
    var n = plannedSets;
    for (final set in sets) {
      n = math.max(n, set.index);
    }
    return n + 1;
  }

  factory GymExercise.fromJson(GymJson j) {
    if (j['sets'] is! List ||
        j['alternatives'] is! List ||
        j['targets'] is! List) {
      throw const FormatException('Некорректное упражнение');
    }
    final rows = j['sets'] as List;
    final alternatives = j['alternatives'] as List;
    final targets = j['targets'] as List;
    if (rows.length > 100 || alternatives.length > 30 || targets.length > 100) {
      throw const FormatException('Слишком много данных упражнения');
    }
    final sets = rows
        .map((e) => GymSet.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    if (sets.map((e) => e.index).toSet().length != sets.length) {
      throw const FormatException('Повторяются номера подходов');
    }
    return GymExercise(
      id: _id(j['id'], 'упражнение'),
      name: _text(j['name'], 'название', max: 120),
      originalName: _text(j['originalName'], 'исходное название', max: 120),
      plannedSets: _integer(j['plannedSets'], 'количество подходов', 1, 50),
      target: _text(j['target'] ?? '', 'цель', max: 120, empty: true),
      timed: j['timed'] == true,
      isTest: j['isTest'] == true,
      targets: targets
          .map((e) => _text(e, 'цель подхода', max: 100, empty: true))
          .toList(),
      alternatives: alternatives
          .map((e) => _text(e, 'замена', max: 120))
          .toList(),
      sets: sets,
    );
  }

  GymJson toJson() => {
    'id': id,
    'name': name,
    'originalName': originalName,
    'plannedSets': plannedSets,
    'target': target,
    'timed': timed,
    'isTest': isTest,
    'targets': targets,
    'alternatives': alternatives,
    'sets': sets.map((e) => e.toJson()).toList(),
  };
}

class GymBlock {
  final String id;
  String title, note;
  int restMinSeconds, restMaxSeconds;
  bool optional;
  List<GymExercise> exercises;
  GymBlock({
    required this.id,
    required this.title,
    required this.restMinSeconds,
    required this.restMaxSeconds,
    this.note = '',
    this.optional = false,
    required this.exercises,
  });

  int get plannedRounds =>
      exercises.fold(0, (n, e) => math.max(n, e.plannedSets));
  // Unequal supersets: in a round where an exercise has no planned set, skip it.
  GymExercise? nextExercise() {
    for (var i = 1; i <= plannedRounds; i++) {
      for (final exercise in exercises) {
        if (i <= exercise.plannedSets && exercise.setAt(i) == null)
          return exercise;
      }
    }
    return null;
  }

  int? nextRound() {
    for (var i = 1; i <= plannedRounds; i++) {
      for (final exercise in exercises) {
        if (i <= exercise.plannedSets && exercise.setAt(i) == null) return i;
      }
    }
    return null;
  }

  factory GymBlock.fromJson(GymJson j) {
    if (j['exercises'] is! List ||
        (j['exercises'] as List).length > 30 ||
        (j['exercises'] as List).isEmpty) {
      throw const FormatException('Некорректный блок тренировки');
    }
    final exercises = (j['exercises'] as List)
        .map((e) => GymExercise.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    if (exercises.map((e) => e.id).toSet().length != exercises.length) {
      throw const FormatException('Повторяется упражнение');
    }
    final min = _integer(j['restMinSeconds'], 'отдых', 0, 7200);
    final max = _integer(j['restMaxSeconds'], 'отдых', min, 7200);
    return GymBlock(
      id: _id(j['id'], 'блок'),
      title: _text(j['title'], 'блок', max: 120),
      note: _text(j['note'] ?? '', 'заметка', max: 500, empty: true),
      restMinSeconds: min,
      restMaxSeconds: max,
      optional: j['optional'] == true,
      exercises: exercises,
    );
  }

  GymJson toJson() => {
    'id': id,
    'title': title,
    'note': note,
    'restMinSeconds': restMinSeconds,
    'restMaxSeconds': restMaxSeconds,
    'optional': optional,
    'exercises': exercises.map((e) => e.toJson()).toList(),
  };
}

class GymCardio {
  final String id, type, note;
  final DateTime recordedAt;
  final double minutes;
  // Treadmill values are entered as displayed: no assumed unit or incline scale.
  final double? distanceKm, speed, incline;
  const GymCardio({
    required this.id,
    required this.type,
    required this.recordedAt,
    required this.minutes,
    this.distanceKm,
    this.speed,
    this.incline,
    this.note = '',
  });
  factory GymCardio.fromJson(GymJson j) {
    final minutes = _optionalNumber(j['minutes'], 'минуты', 0.1, 1440);
    if (minutes == null) throw const FormatException('Укажите минуты кардио');
    return GymCardio(
      id: _id(j['id'], 'кардио'),
      type: _text(j['type'], 'вид кардио', max: 120),
      recordedAt: _date(j['recordedAt'], 'время кардио'),
      minutes: minutes,
      distanceKm: _optionalNumber(j['distanceKm'], 'дистанция', 0, 1000),
      speed: _optionalNumber(j['speed'], 'скорость', 0, 100),
      incline: _optionalNumber(j['incline'], 'наклон', -30, 100),
      note: _text(j['note'] ?? '', 'заметка', max: 300, empty: true),
    );
  }
  GymJson toJson() => {
    'id': id,
    'type': type,
    'recordedAt': _iso(recordedAt),
    'minutes': minutes,
    if (distanceKm != null) 'distanceKm': distanceKm,
    if (speed != null) 'speed': speed,
    if (incline != null) 'incline': incline,
    if (note.isNotEmpty) 'note': note,
  };
}

class GymSession {
  final String id, planDay, title, warmup, cardioPlan;
  final DateTime startedAt;
  DateTime? resumedAt, endedAt, restDeadline, intervalResumedAt;
  int elapsedBaseSeconds;
  int? restPausedSeconds, intervalBaseSeconds;
  // Optional display metadata; old sessions without these fields still load.
  int? restTotalSeconds;
  String? restBlockId;
  bool restIsTransition;
  String restLabel, note;
  List<GymBlock> blocks;
  List<GymCardio> cardio;

  GymSession({
    required this.id,
    required this.planDay,
    required this.title,
    required this.startedAt,
    required this.warmup,
    required this.cardioPlan,
    this.resumedAt,
    this.endedAt,
    this.restDeadline,
    this.intervalResumedAt,
    this.elapsedBaseSeconds = 0,
    this.restPausedSeconds,
    this.intervalBaseSeconds,
    this.restTotalSeconds,
    this.restBlockId,
    this.restIsTransition = false,
    this.restLabel = '',
    this.note = '',
    required this.blocks,
    List<GymCardio>? cardio,
  }) : cardio = cardio ?? [];

  bool get completed => endedAt != null;
  bool get running => !completed && resumedAt != null;
  Iterable<GymSet> get allSets =>
      blocks.expand((b) => b.exercises).expand((e) => e.sets);
  int get setCount => allSets.length;
  int get knownReps => allSets.fold<int>(0, (n, row) => n + (row.reps ?? 0));
  Iterable<GymSet> get volumeRows => allSets.where(
    (row) =>
        row.reps != null &&
        row.weightKg != null &&
        (!row.isPullup ||
            row.pullupMode == 'weighted' ||
            row.pullupMode == 'bodyweight'),
  );
  double get externalVolumeKg =>
      volumeRows.fold<double>(0, (n, row) => n + row.reps! * row.weightKg!);
  int elapsedAt(DateTime now) =>
      elapsedBaseSeconds +
      (running ? math.max(0, now.difference(resumedAt!).inSeconds) : 0);
  int restRemainingAt(DateTime now) {
    if (restPausedSeconds != null) return restPausedSeconds!;
    if (restDeadline == null) return 0;
    // Round up so the first visible second is the selected value.
    final ms = restDeadline!.difference(now).inMilliseconds;
    return math.max(0, (ms / 1000).ceil());
  }

  // Eight 1-minute faster / 2-minute slower intervals. Absolute timestamps
  // keep the display accurate after the browser suspends; no notification is promised.
  int? intervalElapsedAt(DateTime now) {
    final base = intervalBaseSeconds;
    if (base == null) return null;
    final extra = intervalResumedAt == null
        ? 0
        : math.max(0, now.difference(intervalResumedAt!).inSeconds);
    return (base + extra).clamp(0, 1440);
  }

  void startIntervals(DateTime now) {
    intervalBaseSeconds = 0;
    intervalResumedAt = now;
  }

  void pauseIntervals(DateTime now) {
    if (intervalBaseSeconds != null) {
      intervalBaseSeconds = intervalElapsedAt(now);
      intervalResumedAt = null;
    }
  }

  void resumeIntervals(DateTime now) {
    if (intervalBaseSeconds != null &&
        intervalBaseSeconds! < 1440 &&
        intervalResumedAt == null)
      intervalResumedAt = now;
  }

  void clearIntervals() {
    intervalBaseSeconds = null;
    intervalResumedAt = null;
  }

  GymSession clone() => GymSession.fromJson(toJson());
  GymBlock block(String id) => blocks.firstWhere((b) => b.id == id);
  GymExercise exercise(String blockId, String id) =>
      block(blockId).exercises.firstWhere((e) => e.id == id);
  void pauseSession(DateTime now) {
    if (running) {
      elapsedBaseSeconds = elapsedAt(now);
      resumedAt = null;
    }
    if (restDeadline != null) {
      restPausedSeconds = restRemainingAt(now);
      restDeadline = null;
    }
    pauseIntervals(now);
  }

  void resumeSession(DateTime now) {
    if (!completed && resumedAt == null) resumedAt = now;
  }

  void finish(DateTime now) {
    pauseSession(now);
    endedAt = now;
    clearRest();
  }

  void reopen(DateTime now) {
    endedAt = null;
    resumedAt = now;
  }

  void startRest(
    DateTime now,
    int seconds,
    String label, {
    bool isTransition = false,
    String? blockId,
  }) {
    final safeSeconds = seconds.clamp(0, 7200);
    restDeadline = now.add(Duration(seconds: safeSeconds));
    restPausedSeconds = null;
    restTotalSeconds = safeSeconds;
    restBlockId = blockId;
    restIsTransition = isTransition;
    restLabel = label;
  }

  void pauseRest(DateTime now) {
    if (restDeadline != null) {
      restPausedSeconds = restRemainingAt(now);
      restDeadline = null;
    }
  }

  void resumeRest(DateTime now) {
    if (restPausedSeconds != null) {
      restDeadline = now.add(Duration(seconds: restPausedSeconds!));
      restPausedSeconds = null;
    }
  }

  void adjustRest(DateTime now, int adjustment) {
    if (restPausedSeconds == null && restDeadline == null) return;
    final previous = restRemainingAt(now);
    final remaining = (previous + adjustment).clamp(0, 7200);
    restTotalSeconds = math.max(restTotalSeconds ?? previous, remaining);
    if (restPausedSeconds != null) {
      restPausedSeconds = remaining;
    } else {
      restDeadline = now.add(Duration(seconds: remaining));
    }
  }

  void clearRest() {
    restDeadline = null;
    restPausedSeconds = null;
    restTotalSeconds = null;
    restBlockId = null;
    restIsTransition = false;
    restLabel = '';
  }

  factory GymSession.fromJson(GymJson j) {
    if (j['version'] != 1 ||
        j['blocks'] is! List ||
        j['cardio'] is! List ||
        (j['blocks'] as List).length > 30 ||
        (j['cardio'] as List).length > 100) {
      throw const FormatException('Некорректная сессия зала');
    }
    final blocks = (j['blocks'] as List)
        .map((b) => GymBlock.fromJson(Map<String, dynamic>.from(b as Map)))
        .toList();
    if (blocks.map((e) => e.id).toSet().length != blocks.length) {
      throw const FormatException('Повторяется блок');
    }
    final cardio = (j['cardio'] as List)
        .map((e) => GymCardio.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    if (cardio.map((e) => e.id).toSet().length != cardio.length) {
      throw const FormatException('Повторяется кардио');
    }
    final day = _text(j['planDay'], 'день плана', max: 20);
    if (![
      'mon',
      'tue',
      'wed',
      'thu',
      'fri',
      'sat',
      'sun',
      'manual',
    ].contains(day)) {
      throw const FormatException('Некорректный день плана');
    }
    final ended = _optionalDate(j['endedAt'], 'завершение');
    final resumed = _optionalDate(j['resumedAt'], 'продолжение');
    final restDeadline = _optionalDate(j['restDeadline'], 'таймер');
    final intervalResumed = _optionalDate(j['intervalResumedAt'], 'интервалы');
    final intervalBase = _optionalInt(
      j['intervalBaseSeconds'],
      'интервалы',
      0,
      1440,
    );
    final restPaused = _optionalInt(
      j['restPausedSeconds'],
      'пауза таймера',
      0,
      7200,
    );
    if ((ended != null && (resumed != null || intervalResumed != null)) ||
        (intervalResumed != null && intervalBase == null) ||
        (restDeadline != null && restPaused != null)) {
      throw const FormatException('Некорректное состояние таймера');
    }
    return GymSession(
      id: _id(j['id'], 'сессия'),
      planDay: day,
      title: _text(j['title'], 'тренировка', max: 120),
      startedAt: _date(j['startedAt'], 'начало'),
      warmup: _text(j['warmup'] ?? '', 'разминка', max: 1000, empty: true),
      cardioPlan: _text(
        j['cardioPlan'] ?? '',
        'кардио',
        max: 1000,
        empty: true,
      ),
      resumedAt: resumed,
      endedAt: ended,
      elapsedBaseSeconds: _integer(
        j['elapsedBaseSeconds'],
        'длительность',
        0,
        31536000,
      ),
      restDeadline: restDeadline,
      restPausedSeconds: restPaused,
      restTotalSeconds: _optionalInt(
        j['restTotalSeconds'],
        'длительность отдыха',
        0,
        7200,
      ),
      restBlockId: j['restBlockId'] == null
          ? null
          : _id(j['restBlockId'], 'блок отдыха'),
      restIsTransition: j['restIsTransition'] == true,
      intervalResumedAt: intervalResumed,
      intervalBaseSeconds: intervalBase,
      restLabel: _text(j['restLabel'] ?? '', 'таймер', max: 120, empty: true),
      note: _text(j['note'] ?? '', 'заметка', max: 1000, empty: true),
      blocks: blocks,
      cardio: cardio,
    );
  }
  GymJson toJson() => {
    'version': 1,
    'id': id,
    'planDay': planDay,
    'title': title,
    'startedAt': _iso(startedAt),
    'warmup': warmup,
    'cardioPlan': cardioPlan,
    if (resumedAt != null) 'resumedAt': _iso(resumedAt!),
    if (endedAt != null) 'endedAt': _iso(endedAt!),
    'elapsedBaseSeconds': elapsedBaseSeconds,
    if (restDeadline != null) 'restDeadline': _iso(restDeadline!),
    if (restPausedSeconds != null) 'restPausedSeconds': restPausedSeconds,
    if (restTotalSeconds != null) 'restTotalSeconds': restTotalSeconds,
    if (restBlockId != null) 'restBlockId': restBlockId,
    if (restIsTransition) 'restIsTransition': true,
    if (intervalResumedAt != null)
      'intervalResumedAt': _iso(intervalResumedAt!),
    if (intervalBaseSeconds != null) 'intervalBaseSeconds': intervalBaseSeconds,
    'restLabel': restLabel,
    'note': note,
    'blocks': blocks.map((e) => e.toJson()).toList(),
    'cardio': cardio.map((e) => e.toJson()).toList(),
  };
}

const gymSessionPrefix = 'gym_session_';
const gymSettingsKey = 'gym_plan_settings';

// Weekly self-reported checks are separate from automatically counted sessions.
// False values are not persisted; no records are silently discarded.
const gymChecklistLabels = <String, String>{
  'liss': 'Спокойное кардио 3–4 раза — по самочувствию',
  'interval': 'Интервалы или прогулка — по желанию',
  'recovery': 'Сон и самочувствие проверены',
  'journal': 'Подходы и веса записаны в журнал',
  'test': 'Технический тест выполнен — необязательно',
  'deload': 'Разгрузка согласована — если нужна',
};

String gymWeekKey(DateTime date) {
  final monday = mondayOf(date);
  return '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';
}

Map<String, bool> gymWeekChecks(String? raw, DateTime date) {
  if (raw == null) return {};
  validateGymDocument(gymSettingsKey, raw);
  final settings = jsonDecode(raw) as Map;
  final weeks = settings['weeklyChecks'];
  if (weeks is! Map || weeks[gymWeekKey(date)] is! Map) return {};
  return Map<String, bool>.from(weeks[gymWeekKey(date)] as Map);
}

String gymSetWeekCheck(String? raw, DateTime date, String id, bool checked) {
  if (!gymChecklistLabels.containsKey(id)) {
    throw const FormatException('Неизвестный пункт чек-листа');
  }
  if (raw != null) validateGymDocument(gymSettingsKey, raw);
  final settings = raw == null
      ? <String, dynamic>{'version': 1}
      : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  final weeks = Map<String, dynamic>.from(
    settings['weeklyChecks'] as Map? ?? {},
  );
  final key = gymWeekKey(date);
  final checks = Map<String, dynamic>.from(weeks[key] as Map? ?? {});
  if (checked) {
    checks[id] = true;
  } else {
    checks.remove(id);
  }
  if (checks.isEmpty) {
    weeks.remove(key);
  } else {
    weeks[key] = checks;
  }
  if (weeks.isEmpty) {
    settings.remove('weeklyChecks');
  } else {
    settings['weeklyChecks'] = weeks;
  }
  final result = jsonEncode(settings);
  validateGymDocument(gymSettingsKey, result);
  return result;
}

void validateGymDocument(String key, Object? raw) {
  if (raw == null) return;
  if (raw is! String || utf8.encode(raw).length > 1000000) {
    throw const FormatException('Некорректный документ тренировки');
  }
  final data = jsonDecode(raw);
  if (data is! Map)
    throw const FormatException('Некорректный документ тренировки');
  final j = Map<String, dynamic>.from(data);
  if (key == gymSettingsKey) {
    if (j['version'] != 1) throw const FormatException('Некорректный план');
    if (j['cycleStart'] != null) _date(j['cycleStart'], 'начало цикла');
    final weeks = j['weeklyChecks'];
    if (weeks != null) {
      if (weeks is! Map || weeks.length > 520) {
        throw const FormatException('Некорректный недельный чек-лист');
      }
      for (final entry in weeks.entries) {
        final dateKey = entry.key;
        final parsed = dateKey is String ? DateTime.tryParse(dateKey) : null;
        if (dateKey is! String ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateKey) ||
            parsed == null ||
            gymWeekKey(parsed) != dateKey ||
            entry.value is! Map ||
            (entry.value as Map).length > gymChecklistLabels.length) {
          throw const FormatException('Некорректная неделя чек-листа');
        }
        for (final check in (entry.value as Map).entries) {
          if (!gymChecklistLabels.containsKey(check.key) ||
              check.value is! bool) {
            throw const FormatException('Некорректный пункт чек-листа');
          }
        }
      }
    }
  } else if (key.startsWith(gymSessionPrefix)) {
    final s = GymSession.fromJson(j);
    if (key != '$gymSessionPrefix${s.id}') {
      throw const FormatException('Идентификатор тренировки не совпадает');
    }
  } else {
    throw const FormatException('Неизвестный документ зала');
  }
}

DateTime mondayOf(DateTime d) {
  final date = DateTime.utc(d.year, d.month, d.day);
  return date.subtract(Duration(days: date.weekday - 1));
}

int? cycleWeek(DateTime cycleStart, DateTime current) {
  final days = mondayOf(current).difference(mondayOf(cycleStart)).inDays;
  return days < 0 ? null : days ~/ 7 + 1;
}
