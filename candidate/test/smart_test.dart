import 'dart:convert';
import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/csv_reader.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

FoodEntry sample(DateTime date, {Map<String, double> micros = const {}}) =>
    FoodEntry(
      name: 'Творог',
      caloriesPer100g: 100,
      proteinPer100g: 12.5,
      fatPer100g: 3,
      carbsPer100g: 4,
      amountGrams: 200,
      mealType: MealType.postWorkout,
      date: date,
      micros: micros,
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 25);
  late AppDataProvider p;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
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
        height: 180,
        ageYears: 30,
        currentWeightConfirmed: true,
        heightConfirmed: true,
        targetProtein: 100,
        targetFat: 60,
        targetCarbs: 250,
      ),
    );
    AppTheme.configure({});
  });
  tearDown(() {
    p.dispose();
    AppTheme.configure({});
  });
  test('Mifflin–St Jeor: male and female constants', () {
    expect(const MetabolicSettings(age: 30).bmr(80, 180), 1780);
    expect(const MetabolicSettings(age: 30, male: false).bmr(80, 180), 1614);
  });
  test('Katch–McArdle uses lean mass, not total mass', () {
    expect(
      const MetabolicSettings(useKatch: true, bodyFat: 20).bmr(80, 180),
      closeTo(1752.4, 1e-9),
    );
  });
  test('Invalid metabolic input is rejected', () {
    expect(
      () => const MetabolicSettings(age: 17).bmr(80, 180),
      throwsArgumentError,
    );
    expect(
      () => const MetabolicSettings(bodyFat: 80).bmr(80, 180),
      throwsArgumentError,
    );
    expect(
      () => const MetabolicSettings(activity: 3).baseTarget(80, 180),
      throwsArgumentError,
    );
  });
  test('Strength bonus 400kcal: 40g protein, 40g carbs, 8.888g fat', () {
    final b = MetabolicSettings.workoutBonus(400, 'strength');
    expect(b.protein, 40);
    expect(b.carbs, 40);
    expect(b.fat, closeTo(80 / 9, 1e-9));
    expect(b.calories, closeTo(400, 1e-9));
  });
  test('All workout distributions conserve energy', () {
    for (final type in ['strength', 'cardio', 'strengthCardio']) {
      expect(
        MetabolicSettings.workoutBonus(731, type).calories,
        closeTo(731, 1e-9),
      );
    }
  });
  test(
    'Automatic target and macro budget flow into the existing provider',
    () async {
      await p.updateSmartSettings({
        'automatic': true,
        'metabolismConfirmed': true,
        'age': 30,
        'activity': 1.2,
        'goalDelta': 0,
        'adaptMacros': true,
      });
      expect(p.baseCaloriesTarget, 2136);
      expect(p.macroTargets.calories, closeTo(2136, 1e-9));
      await p.addWorkoutEntry(
        WorkoutEntry(
          type: WorkoutType.strength,
          durationMinutes: 40,
          caloriesBurned: 400,
          date: day,
        ),
      );
      expect(p.adjustedCaloriesTarget, 2536);
      expect(p.macroTargets.protein, closeTo(2136 * .3 / 4 + 40, 1e-9));
      expect(p.macroTargets.calories, closeTo(2536, 1e-9));
      await p.refresh();
      expect(p.metabolism.automatic, isTrue);
    },
  );
  test('Adaptive macros off preserves legacy targets', () async {
    await p.addWorkoutEntry(
      WorkoutEntry(
        type: WorkoutType.strength,
        durationMinutes: 40,
        caloriesBurned: 400,
        date: day,
      ),
    );
    expect(p.targetProteinToday, 100);
    expect(p.caloriesRemaining, 2400);
  });
  test('Unknown micronutrients are not zeros; weight coverage is reported', () {
    final totals = aggregateMicros([
      sample(day, micros: {'fiber': 2}).toJson(),
      sample(day).toJson(),
    ]);
    expect(totals['fiber']!.value, 4);
    expect(totals['fiber']!.coverage, .5);
    expect(totals['vitaminD']!.coverage, 0);
    expect(dietScore(totals), isNull);
  });
  test('Score only available with coverage for all four inputs', () {
    final totals = aggregateMicros([
      sample(
        day,
        micros: {'fiber': 12.5, 'sodium': 200, 'sugars': 10, 'saturatedFat': 2},
      ).toJson(),
    ]);
    expect(dietScore(totals), 100);
  });
  test(
    'Micronutrients survive JSON, copyWith, quick logs and actual reload',
    () async {
      final e = sample(day, micros: {'iron': 1.5, 'vitaminD': 2});
      await p.addFoodEntry(e);
      await p.updateFoodEntry(e.copyWith(amountGrams: 150));
      await p.refresh();
      expect(p.todayFoodEntries.single.micros, {'iron': 1.5, 'vitaminD': 2});
      expect(p.quickFoods.single.toEntry().micros, e.micros);
      expect(
        aggregateMicros(
          p.todayFoodEntries.map((e) => e.toJson()),
        )['iron']!.value,
        2.25,
      );
    },
  );
  test('Legacy meal enum indices are unchanged; pre/post are appended', () {
    expect(MealType.breakfast.index, 0);
    expect(MealType.lunch.index, 1);
    expect(MealType.snack.index, 2);
    expect(MealType.dinner.index, 3);
    expect(MealType.preWorkout.index, 4);
    expect(MealType.postWorkout.index, 5);
  });
  test('Legacy entries never invent a time from selectedDate midnight', () {
    final raw = sample(day).toJson()
      ..remove('loggedAt')
      ..remove('timeKnown');
    final e = FoodEntry.fromJson(raw);
    expect(e.timeKnown, isFalse);
    expect(e.copyWith(amountGrams: 250).timeKnown, isFalse);
  });
  test('Recipe output weight changes per100g, not total calories/macros', () {
    final r = Recipe(
      name: 'После готовки',
      cookedWeight: 150,
      ingredients: [
        RecipeIngredient(
          name: 'A',
          grams: 200,
          caloriesPer100g: 100,
          proteinPer100g: 10,
          fatPer100g: 3,
          carbsPer100g: 4,
          micros: {'fiber': 2},
        ),
      ],
    );
    expect(r.totalCalories, 200);
    expect(r.caloriesPer100g, closeTo(20000 / 150, 1e-9));
    final e = r.toEntry(150, MealType.dinner, date: day);
    expect(e.calories, closeTo(200, 1e-9));
    expect(e.protein, 20);
    expect(e.micros['fiber'], closeTo(400 / 150, 1e-9));
    expect(Recipe.fromJson(r.toJson()).outputWeight, 150);
  });
  test(
    'Own foods are searchable for the diary and recipes with micros',
    () async {
      await p.storage.local.setString(
        'custom_foods',
        jsonEncode([
          {
            'name': 'Свой продукт',
            'caloriesPer100g': 100,
            'proteinPer100g': 12,
            'fatPer100g': 3,
            'carbsPer100g': 4,
            'micros': {'sodium': 25},
          },
        ]),
      );
      final item = p.searchFoods('Свой').single;
      expect(item.toEntry(100, MealType.lunch, date: day).micros['sodium'], 25);
      expect(RecipeIngredient.fromFood(item, 100).micros['sodium'], 25);
    },
  );
  test(
    'Whole-history CSV round trip includes unknown fields, newlines and typed documents',
    () async {
      await p.addFoodEntry(
        sample(day).copyWith(name: '=SUM(A1), "сыр"\nвторая строка'),
      );
      await p.addWater(250);
      final data = p.storage.local.snapshot();
      final csv = exportCsv(data);
      final recovered = importCsv(csv);
      expect(recovered, data);
      expect(
        csv,
        contains("'=SUM"),
      ); // formula injection is escaped in human-readable rows
      expect(readCsv(csv).first.length, 12 + microLabels.length);
    },
  );
  test('Malformed CSV is rejected before import', () {
    expect(() => readCsv('a,b\n"unterminated'), throwsFormatException);
    expect(() => importCsv('foo,bar\n1,2'), throwsFormatException);
  });
  test('Invalid imported food cannot erase existing data', () async {
    await p.addFoodEntry(sample(day));
    final original = p.todayFoodEntries.single.id;
    final result = await p.importDataJson(
      jsonEncode({
        'app': 'fitness_tracker',
        'data': {
          'food_entries_2026-10-25': jsonEncode([
            sample(day).copyWith(amountGrams: -20).toJson(),
          ]),
        },
      }),
    );
    expect(result, isNotNull);
    await p.refresh();
    expect(p.todayFoodEntries.single.id, original);
  });
  test('Sync conflict decisions never silently choose a divergent version', () {
    bool equal(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
    expect(decideMerge(null, 'local', null, equal), MergeDecision.push);
    expect(decideMerge(null, null, 'remote', equal), MergeDecision.pull);
    expect(decideMerge('old', 'new', 'new', equal), MergeDecision.unchanged);
    expect(
      decideMerge('old', 'local', 'remote', equal),
      MergeDecision.conflict,
    );
    expect(
      decideMerge('old', null, 'changed remotely', equal),
      MergeDecision.conflict,
    );
  });
  test(
    'Private account/session keys are excluded from backups and imports',
    () {
      expect(LocalPreferences.appKey('supabase.auth.token'), isFalse);
      expect(LocalPreferences.appKey('_baseline_uid'), isFalse);
      expect(
        () => validateAppDocument('supabase.auth.token', 'secret'),
        throwsFormatException,
      );
    },
  );
  for (final mode in ['light', 'dark', 'oled']) {
    testWidgets('Application layout at 390px with $mode theme', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await p.updateSmartSettings({'theme': mode});
      await tester.pumpWidget(MyApp(provider: p));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      if (mode == 'light')
        expect(AppTheme.darkTheme.brightness, Brightness.light);
      if (mode == 'oled') expect(AppTheme.background, Colors.black);
      // The old Smart tab was moved into the existing More menu in 3.0.
      // Verify the real route instead of skipping this navigation assertion.
      await tester.tap(find.byTooltip('Ещё: настройки и данные'));
      await tester.pumpAndSettle();
      expect(find.text('Ещё'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Расширенные инструменты'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Расширенные инструменты'));
      await tester.pumpAndSettle();
      expect(find.text('Smart • здоровье и данные'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
