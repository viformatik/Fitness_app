import 'dart:convert';
import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:fitness_tracker/smart/gym_plan.dart';
import 'package:fitness_tracker/smart/journal_ai_result.dart';
import 'package:fitness_tracker/smart/journal_overview.dart';
import 'package:fitness_tracker/smart/journal_overview_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/supplements.dart';
import 'package:fitness_tracker/smart/workout_calc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final d1 = DateTime(2026, 10, 20, 10);
final d2 = DateTime(2026, 10, 21, 10);
FoodEntry food(
  DateTime day, {
  String name = 'Яблоко',
  String id = 'secret-id',
  double grams = 150,
  bool estimated = false,
}) => FoodEntry(
  id: id,
  name: name,
  caloriesPer100g: 52,
  proteinPer100g: .3,
  fatPer100g: .2,
  carbsPer100g: 14,
  amountGrams: grams,
  mealType: MealType.snack,
  date: day,
  micros: const {'vitaminC': 6},
  microsEstimated: estimated,
);
Map<String, dynamic> fixture() {
  final session = gymDay('sun').start('private-gym', d2);
  final test = session.block('T1').exercises.single;
  test.sets.add(
    GymSet(
      index: 1,
      recordedAt: d2,
      exerciseName: test.name,
      reps: 7,
      isTest: true,
      pullupMode: 'bodyweight',
      note: 'секретная заметка',
    ),
  );
  final lift = session.block('A').exercises.first;
  lift.sets.add(
    GymSet(
      index: 1,
      recordedAt: d2.add(const Duration(minutes: 1)),
      exerciseName: lift.name,
      reps: 8,
      weightKg: 27.25,
    ),
  );
  session.cardio.add(
    GymCardio(
      id: 'synthetic-cardio',
      type: 'Ходьба',
      recordedAt: d2,
      minutes: 12,
      distanceKm: 0.8,
    ),
  );
  session.finish(d2.add(const Duration(minutes: 45)));
  final supp = SupplementEntry(
    id: 'secret-supp',
    name: 'Витамин D',
    quantity: 1,
    unit: 'tablet',
    nutrientKey: 'vitaminD',
    date: d2,
    strength: 5,
    strengthUnit: 'mcg',
  );
  final workout = WorkoutEntry(
    id: 'secret-workout',
    type: WorkoutType.strengthCardio,
    durationMinutes: 30,
    caloriesBurned: 200,
    date: d2,
    note: 'секретная тренировка',
    details: const WorkoutDetails(
      segments: [WorkoutSegment(activityId: 'strength_regular', minutes: 30)],
      exercises: [
        WorkoutExercise(name: 'Тяга', sets: 3, reps: 8, weightKg: 20),
      ],
      weightKg: 80,
      calorieMode: 'estimate',
      budgetPercent: 50,
      source: 'manual',
    ),
  );
  return {
    'food_entries_2026-10-20': jsonEncode([
      food(d1).toJson(),
      food(
        d1,
        name: 'Груша',
        id: 'second-id',
        grams: 100,
        estimated: true,
      ).toJson(),
    ]),
    'food_entries_2026-10-21': jsonEncode([food(d2, id: 'third-id').toJson()]),
    'food_entries_2026-10-22': jsonEncode([
      food(DateTime(2026, 10, 22), name: 'За пределами').toJson(),
    ]),
    'water_intake_2026-10-20': 1000,
    'water_intake_2026-10-21': 0,
    'steps_2026-10-21': 4000,
    'workout_entries_2026-10-21': jsonEncode([workout.toJson()]),
    'weight_entries': jsonEncode([
      WeightEntry(
        id: 'secret-weight-1',
        weight: 80,
        date: d1,
        note: 'секретная медицинская заметка',
      ).toJson(),
      WeightEntry(id: 'secret-weight-2', weight: 79.5, date: d2).toJson(),
      WeightEntry(
        id: 'secret-outside',
        weight: 70,
        date: DateTime(2025),
      ).toJson(),
    ]),
    'supplement_entries_2026-10-21': jsonEncode([supp.toJson()]),
    'gym_session_private-gym': jsonEncode(session.toJson()),
    'user_profile': jsonEncode({'name': 'Иван Секретный', 'weight': 42}),
    'photo': 'secret-photo',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all sections use selected dates, portions, coverage and known days',
    () {
      final o = summarizeJournal(fixture(), d1, d2);
      expect(o.periodDays, 2);
      expect(o.unreadableDocuments, 0);
      expect(o.sections['food']!['records'], 3);
      expect(o.sections['food']!['daysWithRecords'], 2);
      expect(o.sections['food']!['caloriesTotal'], 208.0);
      expect(o.sections['food']!['proteinTotalG'], 1.2);
      expect(o.sections['food']!['recordsWithMicronutrients'], 3);
      expect(o.sections['food']!['recordsWithEstimatedMicronutrients'], 1);
      expect(o.sections['food']!['micronutrients']['vitaminC'], {
        'knownRecords': 3,
        'total': 24.0,
      });
      expect(o.sections['water'], {
        'recordedDays': 2,
        'totalMl': 1000,
      }); // Explicit zero is known.
      expect(o.sections['steps'], {
        'recordedDays': 1,
        'totalSteps': 4000,
      }); // Missing day is unknown.
      expect(o.sections['weight'], {
        'measurements': 2,
        'firstKg': 80.0,
        'lastKg': 79.5,
      });
      expect(o.sections['supplements']!['records'], 1);
      expect(o.sections['supplements']!['knownMicronutrients']['vitaminD'], {
        'knownRecords': 1,
        'total': 5.0,
      });
      final t = o.sections['training']!;
      expect(t['manualWorkouts'], 1);
      expect(t['manualMinutes'], 30);
      expect(t['manualCaloriesBurnedTotal'], 200);
      expect(t['manualCaloriesAddedToBudget'], 100);
      expect((t['manualExercisesUpTo10'] as List).single['totalRepsKnown'], 24);
      expect(t['gymSessionsStarted'], 1);
      expect(t['gymSessionsFinished'], 1);
      expect(t['gymRecordedSets'], 2);
      expect(t['gymCardioEntries'], 1);
      expect(t['gymCardioMinutes'], 12.0);
      expect(t['gymCardioDistanceKm'], 0.8);
      final lift = (t['gymExercisesUpTo10'] as List).firstWhere(
        (e) => e['lastWeightKg'] == 27.25,
      );
      expect(lift['totalReps'], 8);
      expect(t['comparablePullupTests'], 1);
      expect(t['firstPullupReps'], 7);
    },
  );

  test(
    'request contains only selected aggregates, no IDs, notes, profiles or outside records',
    () {
      final o = summarizeJournal(fixture(), d1, d2);
      final payload = o.request({'food', 'water'}, 'Что проверить?');
      final serialized = jsonEncode(payload);
      expect((payload['sections'] as Map).keys.toSet(), {'food', 'water'});
      for (final secret in [
        'secret-id',
        'secret-weight',
        'private-gym',
        'секретная',
        'Иван Секретный',
        'secret-photo',
        'За пределами',
        'supplements',
        'training',
      ]) {
        expect(serialized, isNot(contains(secret)), reason: secret);
      }
      expect(serialized, contains('Яблоко'));
      expect(serialized, contains('Что проверить?'));
      expect(() => o.request({}, ''), throwsArgumentError);
      expect(() => o.request({'bad'}, ''), throwsArgumentError);
      expect(() => o.request({'food'}, 'x' * 801), throwsArgumentError);
    },
  );

  test('bad documents are flagged rather than silently treated as zero', () {
    final docs = fixture();
    docs['food_entries_2026-10-20'] = '{broken';
    docs['water_intake_2026-10-20'] = -2;
    final o = summarizeJournal(docs, d1, d2);
    expect(o.unreadableDocuments, 2);
    expect(o.sections['food']!['records'], 1);
    expect(o.sections['water']!['recordedDays'], 1);
    expect(() => summarizeJournal(docs, d2, d1), throwsArgumentError);
  });

  test('top lists are bounded and stable irrespective of insertion order', () {
    final docs = <String, dynamic>{};
    docs['food_entries_2026-10-20'] = jsonEncode(
      List.generate(14, (i) => food(d1, name: 'Продукт $i', id: '$i').toJson()),
    );
    final o = summarizeJournal(docs, d1, d2);
    expect(o.sections['food']!['uniqueFoodNames'], 14);
    expect((o.sections['food']!['commonFoodsUpTo10'] as List).length, 10);
    final reverse = Map<String, dynamic>.fromEntries(
      docs.entries.toList().reversed,
    );
    expect(
      jsonEncode(o.request({'food'}, '')),
      jsonEncode(summarizeJournal(reverse, d1, d2).request({'food'}, '')),
    );
  });

  test('AI output is bounded, validated and incapable of creating actions', () {
    final r = JournalAiResult.fromJson({
      'summary': 'Итог',
      'observations': ['Наблюдение'],
      'suggestions': ['Идея'],
      'limitations': ['Мало данных'],
      'actions': [
        {'kind': 'delete'},
      ],
    });
    expect(r.summary, 'Итог');
    expect(r.suggestions, ['Идея']);
    expect(
      () => JournalAiResult.fromJson({
        'summary': 'Итог',
        'observations': List.filled(9, 'x'),
        'suggestions': [],
        'limitations': [],
      }),
      throwsFormatException,
    );
    expect(
      () => JournalAiResult.fromJson({
        'summary': '',
        'observations': [],
        'suggestions': [],
        'limitations': [],
      }),
      throwsFormatException,
    );
  });

  testWidgets(
    'overview is local and available without sign-in; no data is changed',
    (tester) async {
      LocalPreferences.memoryForTests = true;
      SharedPreferences.setMockInitialValues({});
      final p = AppDataProvider();
      await p.init();
      await p.setSelectedDate(d2);
      await p.storage.local.setInt('water_intake_2026-10-20', 1000);
      final before = jsonEncode(p.storage.local.snapshot());
      await tester.binding.setSurfaceSize(const Size(390, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: MaterialApp(home: JournalOverviewScreen(provider: p)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Локальная сводка'), findsOneWidget);
      expect(find.text('1 дн. с записью'), findsWidgets);
      // The new local chart increases content height. Reach the existing AI
      // control by scrolling rather than assuming every card fits the viewport.
      await tester.scrollUntilVisible(
        find.text('Разбор с Gemini'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Разбор с Gemini'), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(0, 3000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Посмотреть подробности'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('всего 1000 мл'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('всего 1000 мл'), findsOneWidget);
      // Large lazy-list extent estimates can initially overshoot a short card;
      // approach the steps detail from below with small reverse scrolls.
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Без записей активность неизвестна'),
        -100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Без записей активность неизвестна'),
        findsOneWidget,
      );
      expect(jsonEncode(p.storage.local.snapshot()), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      p.dispose();
    },
  );
}
