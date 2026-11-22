import 'dart:convert';
import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/workout_calc.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

WorkoutDetails details({
  int percent = 50,
  String mode = 'estimate',
  double? weight = 80,
}) => WorkoutDetails.fromJson({
  'version': 1,
  'segments': [
    {'activityId': 'strength_regular', 'minutes': 60},
    {'activityId': 'walk', 'minutes': 30, 'distanceKm': 2.5},
  ],
  'exercises': [
    {'name': 'Жим', 'sets': 3, 'reps': 10, 'weightKg': 30},
    {'name': 'Подтягивания', 'sets': 3, 'reps': 8},
  ],
  if (weight != null) 'weightKg': weight,
  'calorieMode': mode,
  'budgetPercent': percent,
  'source': 'manual',
});
Map<String, dynamic> draft() => {
  'segments': [
    {'activityId': 'strength_regular', 'minutes': 40, 'distanceKm': 0},
  ],
  'exercises': [
    {'name': 'Жим', 'sets': 3, 'reps': 10, 'weightKg': 30},
    {'name': 'Приседания', 'sets': 0, 'reps': 0, 'weightKg': 0},
  ],
  'remarks': 'Проверьте длительность',
  'calories': 99999,
  'profile': {'weight': 123},
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 25);
  late AppDataProvider p;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
    await p.setSelectedDate(day);
    await p.updateProfile(
      const UserProfile(
        dailyCaloriesMin: 2000,
        dailyCaloriesMax: 2000,
        calorieGoalConfirmed: true,
        proteinGoalConfirmed: true,
        fatGoalConfirmed: true,
        carbsGoalConfirmed: true,
        currentWeight: 80,
        targetProtein: 100,
        targetFat: 60,
        targetCarbs: 250,
      ),
    );
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    p.dispose();
  });
  test('Official 2024 MET codes match their activities', () {
    expect(workoutActivity('strength_regular')!.met, 3.5);
    expect(workoutActivity('walk')!.code, '17190');
    expect(workoutActivity('walk')!.met, 3.8);
    expect(workoutActivity('walk_brisk')!.code, '17200');
    expect(workoutActivity('jog')!.code, '12030');
    expect(workoutActivity('run')!.met, 9.3);
    expect(workoutActivity('swim')!.code, '18240');
    expect(workoutActivity('swim')!.met, 5.8);
  });
  test('MET total and active use same standard, multiple segments', () {
    final d = details();
    final e = calculateWorkoutEnergy(d.segments, 80);
    expect(e.gross, closeTo(3.5 * 80 + 3.8 * 80 * .5, 1e-8));
    expect(e.active, closeTo(2.5 * 80 + 2.8 * 80 * .5, 1e-8));
    expect(e.active, 312);
    expect(e.gross, 432);
    expect(d.minutes, 90);
    expect(d.knownDistanceKm, 2.5);
    expect(d.knownDistanceSegments, 1);
    expect(d.knownVolumeExercises, 1);
    expect(d.volumeKg, 900);
  });
  test('Unknown distance and load are not interpreted as known zero', () {
    final d = WorkoutDetails.fromJson({
      'version': 1,
      'segments': [
        {'activityId': 'walk', 'minutes': 15},
      ],
      'exercises': [
        {'name': 'Приседания', 'sets': 3, 'reps': 10},
      ],
      'calorieMode': 'estimate',
      'weightKg': 80,
      'budgetPercent': 100,
      'source': 'manual',
    });
    expect(d.knownDistanceKm, isNull);
    expect(d.knownVolumeExercises, 0);
    expect(d.exercises.single.weightKg, isNull);
    final bodyweight = WorkoutExercise.fromJson({
      'name': 'Приседания',
      'sets': 3,
      'reps': 10,
      'weightKg': 0,
    });
    expect(bodyweight.hasVolume, isTrue);
    expect(bodyweight.volumeKg, 0);
  });
  test('Reject invalid details and untrusted diary imports', () {
    final original = details().toJson();
    for (final bad in [
      {...original, 'weightKg': double.nan},
      {...original, 'budgetPercent': 101},
      {
        ...original,
        'segments': [
          {'activityId': 'missing', 'minutes': 30},
        ],
      },
      {
        ...original,
        'segments': [
          {'activityId': 'other', 'minutes': 30},
        ],
      },
      {
        ...original,
        'segments': [
          {'activityId': 'walk', 'minutes': 1440},
          {'activityId': 'walk', 'minutes': 1},
        ],
      },
      {
        ...original,
        'exercises': [
          {'name': '', 'sets': 3},
        ],
      },
      {
        ...original,
        'exercises': [
          {'name': 'Жим', 'sets': -1},
        ],
      },
    ]) {
      expect(() => WorkoutDetails.fromJson(bad), throwsA(anything));
    }
    final legacy = WorkoutEntry(
      id: 'x',
      type: WorkoutType.strength,
      durationMinutes: 60,
      caloriesBurned: 200,
      date: day,
    );
    final invalid = {
      ...legacy.toJson(),
      'details': original,
    }; // 90 minutes != 60
    expect(
      () => validateAppDocument(
        'workout_entries_${dayKey(day)}',
        jsonEncode([invalid]),
      ),
      throwsFormatException,
    );
  });
  test(
    'AI schema keeps unknown sentinel, ignores extra fields and rejects forged values',
    () {
      final out = validateWorkoutDraft(draft());
      expect(out.keys.toSet(), {'segments', 'exercises', 'remarks'});
      final unknown = (out['exercises'] as List)[1] as Map;
      expect(unknown['sets'], 0);
      expect(unknown['weightKg'], 0);
      for (final bad in [
        {
          ...draft(),
          'segments': [
            {'activityId': 'forged', 'minutes': 30, 'distanceKm': 0},
          ],
        },
        {
          ...draft(),
          'segments': [
            {'activityId': 'walk', 'minutes': -1, 'distanceKm': 0},
          ],
        },
        {
          ...draft(),
          'exercises': [
            {'name': 'Жим', 'sets': 3, 'reps': 10, 'weightKg': double.infinity},
          ],
        },
        {
          ...draft(),
          'exercises': List.filled(31, {
            'name': 'Жим',
            'sets': 0,
            'reps': 0,
            'weightKg': 0,
          }),
        },
      ]) {
        expect(() => validateWorkoutDraft(bad), throwsFormatException);
      }
    },
  );
  test(
    'Legacy JSON and 100 percent calorie credit survive unchanged',
    () async {
      final old = {
        'id': 'legacy',
        'type': WorkoutType.strength.index,
        'durationMinutes': 70,
        'caloriesBurned': 500,
        'date': day.toIso8601String(),
        'note': null,
      };
      final entry = WorkoutEntry.fromJson(old);
      expect(entry.toJson(), old);
      expect(entry.details, isNull);
      expect(entry.budgetCalories, 500);
      await p.addWorkoutEntry(entry);
      expect(p.todayCaloriesBurned, 500);
      expect(p.adjustedCaloriesTarget, 2500);
      await p.refresh();
      expect(p.todayWorkoutEntries.single.toJson(), old);
      expect(p.caloriesRemaining, 2500);
    },
  );
  test(
    'New entries preserve old entries, fractional credit, macros, sync snapshot, reload and deletion',
    () async {
      await p.updateSmartSettings({'adaptMacros': true});
      final old = WorkoutEntry(
        id: 'old',
        type: WorkoutType.strength,
        durationMinutes: 40,
        caloriesBurned: 400,
        date: day,
      );
      final d = details();
      final entry = WorkoutEntry(
        id: 'new',
        type: WorkoutType.strengthCardio,
        durationMinutes: 90,
        caloriesBurned: 312,
        date: day,
        details: d,
        note: 'Тест',
      );
      await p.addWorkoutEntry(old);
      await p.addWorkoutEntry(entry);
      expect(p.todayCaloriesBurned, 712);
      expect(p.todayWorkoutCalorieCredit, 556);
      expect(p.adjustedCaloriesTarget, 2556);
      expect(p.macroTargets.protein, closeTo(100 + 40 + 156 * .3 / 4, 1e-8));
      final snapshot = p.storage.local.snapshot();
      final key = 'workout_entries_${dayKey(day)}';
      validateAppDocument(key, snapshot[key]);
      expect(snapshot[key], contains('strength_regular'));
      await p.refresh();
      expect(p.todayWorkoutEntries, hasLength(2));
      final restored = p.todayWorkoutEntries.singleWhere((e) => e.id == 'new');
      expect(restored.details!.exercises.first.weightKg, 30);
      expect(restored.budgetCalories, 156);
      expect(restored.durationMinutes, 90);
      await p.deleteWorkoutEntry('new');
      expect(p.todayWorkoutEntries.single.toJson(), old.toJson());
      expect(p.todayWorkoutCalorieCredit, 400);
      expect(p.adjustedCaloriesTarget, 2400);
    },
  );
  test(
    'Zero percent tracks the workout but does not increase food or macro goals',
    () async {
      await p.updateSmartSettings({'adaptMacros': true});
      final d = details(percent: 0);
      await p.addWorkoutEntry(
        WorkoutEntry(
          type: WorkoutType.strengthCardio,
          durationMinutes: 90,
          caloriesBurned: 312,
          date: day,
          details: d,
        ),
      );
      expect(p.todayCaloriesBurned, 312);
      expect(p.todayWorkoutCalorieCredit, 0);
      expect(p.adjustedCaloriesTarget, 2000);
      expect(p.targetProteinToday, 100);
    },
  );
  test('Manual active calories work with other type without weight', () {
    final d = WorkoutDetails.fromJson({
      'version': 1,
      'segments': [
        {'activityId': 'other', 'minutes': 30},
      ],
      'exercises': [],
      'calorieMode': 'manual',
      'budgetPercent': 75,
      'source': 'manual',
    });
    expect(d.weightKg, isNull);
    expect(d.minutes, 30);
    final e = WorkoutEntry(
      type: WorkoutType.strengthCardio,
      durationMinutes: 30,
      caloriesBurned: 100,
      date: day,
      details: d,
    );
    expect(e.budgetCalories, 75);
  });
  test('Failed completion flag cannot leave a newly saved workout', () async {
    final key = 'workout_entries_${dayKey(day)}';
    final flag = 'workout_completed_${dayKey(day)}';
    LocalPreferences.rejectWriteKeyForTests = flag;
    await p.addWorkoutEntry(
      WorkoutEntry(
        id: 'new',
        type: WorkoutType.cardio,
        durationMinutes: 20,
        caloriesBurned: 100,
        date: day,
      ),
    );
    expect(p.persistenceError, contains('не сохранено'));
    expect(p.todayWorkoutEntries, isEmpty);
    expect(p.storage.local.get(key), isNull);
    expect(p.storage.local.get(flag), isNull);
  });
  test('Failed completion flag cannot partially delete a workout', () async {
    final key = 'workout_entries_${dayKey(day)}';
    final flag = 'workout_completed_${dayKey(day)}';
    final old = WorkoutEntry(
      id: 'old',
      type: WorkoutType.cardio,
      durationMinutes: 20,
      caloriesBurned: 100,
      date: day,
    );
    await p.addWorkoutEntry(old);
    final original = p.storage.local.get(key);
    expect(p.storage.local.get(flag), isTrue);
    LocalPreferences.rejectWriteKeyForTests = flag;
    await p.deleteWorkoutEntry(old.id);
    expect(p.persistenceError, contains('не сохранено'));
    expect(p.todayWorkoutEntries.single.id, 'old');
    expect(p.storage.local.get(key), original);
    expect(p.storage.local.get(flag), isTrue);
  });
  test('Failed manual completion flag is rolled back and reported', () async {
    final flag = 'workout_completed_${dayKey(day)}';
    LocalPreferences.rejectWriteKeyForTests = flag;
    await p.toggleWorkoutCompleted();
    expect(p.persistenceError, contains('не сохранено'));
    expect(p.todayWorkoutCompleted, isFalse);
    expect(p.storage.local.get(flag), isNull);
  });
  test('Failed workout document write restores earlier diary', () async {
    final old = WorkoutEntry(
      id: 'old',
      type: WorkoutType.cardio,
      durationMinutes: 20,
      caloriesBurned: 100,
      date: day,
    );
    await p.addWorkoutEntry(old);
    LocalPreferences.rejectWriteKeyForTests = 'workout_entries_${dayKey(day)}';
    final d = details();
    await p.addWorkoutEntry(
      WorkoutEntry(
        id: 'new',
        type: WorkoutType.strengthCardio,
        durationMinutes: 90,
        caloriesBurned: 312,
        date: day,
        details: d,
      ),
    );
    expect(p.persistenceError, contains('не сохранено'));
    expect(p.todayWorkoutEntries, hasLength(1));
    expect(p.todayWorkoutEntries.single.id, 'old');
  });
}
