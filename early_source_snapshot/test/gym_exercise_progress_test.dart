import 'dart:convert';

import 'package:fitness_tracker/smart/gym_exercise_history.dart';
import 'package:fitness_tracker/smart/gym_exercise_progress.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:flutter_test/flutter_test.dart';

final origin = DateTime.utc(2026, 10, 10, 10);

GymSet sampleSet(
  String name,
  DateTime when, {
  int index = 1,
  int? reps = 8,
  int? seconds,
  int? rir,
  double? weight,
  String mode = 'unknown',
  bool test = false,
}) => GymSet(
  index: index,
  recordedAt: when,
  exerciseName: name,
  reps: reps,
  seconds: seconds,
  rir: rir,
  weightKg: weight,
  pullupMode: mode,
  isTest: test,
  note: 'synthetic private note',
);

GymSession sampleSession(
  String id,
  DateTime when,
  String name,
  List<GymSet> sets, {
  bool completed = false,
}) => GymSession(
  id: id,
  planDay: 'manual',
  title: 'Синтетическое занятие',
  startedAt: when,
  endedAt: completed ? when.add(const Duration(minutes: 30)) : null,
  warmup: '',
  cardioPlan: '',
  note: 'synthetic private session note',
  blocks: [
    GymBlock(
      id: 'A',
      title: 'Блок',
      restMinSeconds: 30,
      restMaxSeconds: 60,
      exercises: [
        GymExercise(id: 'A1', name: name, plannedSets: 3, sets: sets),
      ],
    ),
  ],
);

Map<String, Object?> documents(List<GymSession> sessions) => {
  for (final session in sessions)
    '$gymSessionPrefix${session.id}': jsonEncode(session.toJson()),
};

void main() {
  test(
    'Epley uses unrounded saved values and compares two distinct sessions',
    () {
      final newer =
          sampleSession('new', origin.add(const Duration(days: 2)), 'Тяга', [
            sampleSet(
              'Тяга',
              origin.add(const Duration(days: 2, minutes: 1)),
              reps: 6,
              weight: 60,
            ),
          ]);
      final older = sampleSession('old', origin, 'Тяга', [
        sampleSet(
          'Тяга',
          origin.add(const Duration(minutes: 1)),
          reps: 8,
          weight: 50,
        ),
      ], completed: true);
      final docs = documents([newer, older]);
      final before = Map<String, Object?>.from(docs);
      final history = indexExerciseHistory(docs);
      final result = estimateExerciseProgress(history.forName('Тяга'));
      expect(result.latest!.sessionId, 'new');
      expect(result.latest!.sessionCompleted, isFalse);
      expect(result.latest!.estimatedOneRepMaxKg, closeTo(72, 1e-12));
      expect(result.previous!.sessionId, 'old');
      expect(result.previous!.sessionCompleted, isTrue);
      expect(
        result.previous!.estimatedOneRepMaxKg,
        closeTo(50 * (1 + 8 / 30), 1e-12),
      );
      expect(
        result.percentageChange,
        closeTo((72 / (50 * (1 + 8 / 30)) - 1) * 100, 1e-12),
      );
      expect(result.qualifyingSets, 2);
      expect(result.excludedSets, 0);
      expect(result.qualifyingSessions, 2);
      expect(docs, before);
    },
  );

  test(
    'uses the best eligible set once per session, not the last recorded set',
    () {
      final workout = sampleSession('one', origin, 'Жим', [
        sampleSet('Жим', origin, index: 1, reps: 10, weight: 50),
        sampleSet(
          'Жим',
          origin.add(const Duration(minutes: 2)),
          index: 2,
          reps: 3,
          weight: 60,
        ),
      ]);
      final item = indexExerciseHistory(documents([workout])).forName('Жим')!;
      final result = estimateExerciseProgress(item);
      expect(result.latest!.setIndex, 1);
      expect(
        result.latest!.estimatedOneRepMaxKg,
        closeTo(50 * (1 + 10 / 30), 1e-12),
      );
      expect(result.qualifyingSets, 2);
      expect(result.qualifyingSessions, 1);
      expect(result.previous, isNull);
      expect(result.percentageChange, isNull);
    },
  );

  test(
    'missing, zero, timed, technical, unsupported and assisted sets are excluded',
    () {
      final workout = sampleSession('filtered', origin, 'Тяга', [
        sampleSet('Тяга', origin, index: 1, reps: 5),
        sampleSet('Тяга', origin, index: 2, reps: 6, weight: 0),
        sampleSet('Тяга', origin, index: 3, reps: 0, weight: 20),
        sampleSet('Тяга', origin, index: 4, reps: 1, weight: 20),
        sampleSet('Тяга', origin, index: 5, reps: 11, weight: 20),
        sampleSet('Тяга', origin, index: 6, reps: 5, seconds: 10, weight: 20),
        sampleSet('Тяга', origin, index: 7, reps: 5, weight: 20, test: true),
        sampleSet(
          'Тяга',
          origin,
          index: 8,
          reps: 5,
          weight: 20,
          mode: 'assisted',
        ),
        sampleSet('Тяга', origin, index: 9, reps: 8, weight: 30),
      ]);
      final item = indexExerciseHistory(documents([workout])).forName('Тяга')!;
      final result = estimateExerciseProgress(item);
      expect(result.qualifyingSets, 1);
      expect(result.excludedSets, 8);
      expect(result.latest!.setIndex, 9);
      expect(result.previous, isNull);
      expect(result.percentageChange, isNull);
    },
  );

  test(
    'pull-ups with or without added weight are never treated as total load',
    () {
      final workout = sampleSession('pull', origin, 'Подтягивания', [
        sampleSet(
          'Подтягивания',
          origin,
          index: 1,
          reps: 8,
          weight: 15,
          mode: 'weighted',
        ),
        sampleSet('Подтягивания', origin, index: 2, reps: 6, weight: 20),
      ]);
      final result = estimateExerciseProgress(
        indexExerciseHistory(documents([workout])).forName('Подтягивания'),
      );
      expect(result.qualifyingSets, 0);
      expect(result.excludedSets, 2);
      expect(result.latest, isNull);
      expect(result.previous, isNull);
      expect(result.percentageChange, isNull);
    },
  );

  test(
    'a newer ineligible session is not invented as a zero or comparison',
    () {
      final current = sampleSession(
        'current',
        origin.add(const Duration(days: 2)),
        'Тяга',
        [sampleSet('Тяга', origin.add(const Duration(days: 2)), reps: 8)],
      );
      final old = sampleSession('old', origin, 'Тяга', [
        sampleSet('Тяга', origin, reps: 6, weight: 30),
      ]);
      final result = estimateExerciseProgress(
        indexExerciseHistory(documents([current, old])).forName('Тяга'),
      );
      expect(result.latest!.sessionId, 'old');
      expect(result.qualifyingSessions, 1);
      expect(result.excludedSets, 1);
      expect(result.previous, isNull);
      expect(result.percentageChange, isNull);
    },
  );

  test('equal latest start times never manufacture a chronological winner', () {
    final a = sampleSession('a', origin, 'Присед', [
      sampleSet('Присед', origin, weight: 20),
    ]);
    final b = sampleSession('b', origin, 'Присед', [
      sampleSet('Присед', origin, weight: 50),
    ]);
    final result = estimateExerciseProgress(
      indexExerciseHistory(documents([b, a])).forName('Присед'),
    );
    expect(result.qualifyingSessions, 2);
    expect(result.latestOrderUnclear, isTrue);
    expect(result.latest, isNull);
    expect(result.previous, isNull);
    expect(result.percentageChange, isNull);
  });

  test('equal previous start times do not produce an arbitrary percentage', () {
    final latest = sampleSession(
      'latest',
      origin.add(const Duration(days: 1)),
      'Присед',
      [sampleSet('Присед', origin.add(const Duration(days: 1)), weight: 60)],
    );
    final a = sampleSession('a', origin, 'Присед', [
      sampleSet('Присед', origin, weight: 20),
    ]);
    final b = sampleSession('b', origin, 'Присед', [
      sampleSet('Присед', origin, weight: 50),
    ]);
    final result = estimateExerciseProgress(
      indexExerciseHistory(documents([latest, b, a])).forName('Присед'),
    );
    expect(result.latest!.sessionId, 'latest');
    expect(result.latestOrderUnclear, isFalse);
    expect(result.previousOrderUnclear, isTrue);
    expect(result.previous, isNull);
    expect(result.percentageChange, isNull);
  });

  test('ties inside a single session use the latest saved set', () {
    final workout = sampleSession('tie', origin, 'Жим', [
      sampleSet('Жим', origin, index: 1, reps: 6, weight: 40),
      sampleSet(
        'Жим',
        origin.add(const Duration(minutes: 1)),
        index: 2,
        reps: 2,
        weight: 45,
      ),
    ]);
    final result = estimateExerciseProgress(
      indexExerciseHistory(documents([workout])).forName('Жим'),
    );
    expect(result.latest!.estimatedOneRepMaxKg, closeTo(48, 1e-12));
    expect(result.latest!.setIndex, 2);
  });

  test(
    'similar spelling remains separate and unreadable documents are not changed',
    () {
      final a = sampleSession('a', origin, 'Жим лёжа', [
        sampleSet('Жим лёжа', origin, weight: 20),
      ]);
      final b = sampleSession(
        'b',
        origin.add(const Duration(days: 1)),
        'Жим лежа',
        [
          sampleSet(
            'Жим лежа',
            origin.add(const Duration(days: 1)),
            weight: 30,
          ),
        ],
      );
      final docs = {
        ...documents([a, b]),
        'gym_session_broken': '{invalid',
      };
      final before = Map<String, Object?>.from(docs);
      final index = indexExerciseHistory(docs);
      expect(index.unreadable, 1);
      final result = estimateExerciseProgress(index.forName('Жим лёжа'));
      expect(result.qualifyingSessions, 1);
      expect(result.latest!.sessionId, 'a');
      expect(result.previous, isNull);
      expect(docs, before);
    },
  );

  test(
    'recorded repetitions-in-reserve are not added by the Epley projection',
    () {
      final older = sampleSession('rir_old', origin, 'Тяга', [
        sampleSet('Тяга', origin, reps: 6, weight: 50, rir: 0),
      ]);
      final newer = sampleSession(
        'rir_new',
        origin.add(const Duration(days: 1)),
        'Тяга',
        [
          sampleSet(
            'Тяга',
            origin.add(const Duration(days: 1)),
            reps: 6,
            weight: 50,
            rir: 5,
          ),
        ],
      );
      final result = estimateExerciseProgress(
        indexExerciseHistory(documents([older, newer])).forName('Тяга'),
      );
      expect(result.latest!.estimatedOneRepMaxKg, closeTo(60, 1e-12));
      expect(result.previous!.estimatedOneRepMaxKg, closeTo(60, 1e-12));
      expect(result.percentageChange, 0);
    },
  );

  test('known equal and lower estimates are distinct from missing values', () {
    final previous = sampleSession('previous', origin, 'Тяга', [
      sampleSet('Тяга', origin, reps: 6, weight: 50),
    ]);
    final equal = sampleSession(
      'equal',
      origin.add(const Duration(days: 1)),
      'Тяга',
      [
        sampleSet(
          'Тяга',
          origin.add(const Duration(days: 1)),
          reps: 6,
          weight: 50,
        ),
      ],
    );
    final lower = sampleSession(
      'lower',
      origin.add(const Duration(days: 2)),
      'Тяга',
      [
        sampleSet(
          'Тяга',
          origin.add(const Duration(days: 2)),
          reps: 6,
          weight: 40,
        ),
      ],
    );
    final equalResult = estimateExerciseProgress(
      indexExerciseHistory(documents([previous, equal])).forName('Тяга'),
    );
    final lowerResult = estimateExerciseProgress(
      indexExerciseHistory(documents([previous, equal, lower])).forName('Тяга'),
    );
    expect(equalResult.percentageChange, 0);
    expect(lowerResult.percentageChange, closeTo(-20, 1e-12));
  });

  test('no history stays absent rather than becoming zero', () {
    final result = estimateExerciseProgress(null);
    expect(result.latest, isNull);
    expect(result.previous, isNull);
    expect(result.percentageChange, isNull);
    expect(result.qualifyingSets, 0);
    expect(result.excludedSets, 0);
    expect(result.latestOrderUnclear, isFalse);
    expect(result.previousOrderUnclear, isFalse);
  });
}
