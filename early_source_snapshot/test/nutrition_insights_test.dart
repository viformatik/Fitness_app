import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/home_simple.dart';
import 'package:fitness_tracker/smart/journal_overview.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/nutrition_insights.dart';
import 'package:fitness_tracker/smart/nutrition_insights_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

FoodEntry food(
  String name,
  double grams,
  double per100,
  double protein,
  DateTime date, {
  Map<String, double> micros = const {},
  bool estimated = false,
}) => FoodEntry(
  id: 'private-$name',
  name: name,
  amountGrams: grams,
  caloriesPer100g: per100,
  proteinPer100g: protein,
  fatPer100g: 4,
  carbsPer100g: 15,
  mealType: MealType.lunch,
  date: date,
  micros: micros,
  microsEstimated: estimated,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 20);
  final apple = food('Яблоко', 200, 51.5, 0.3, day);
  final chicken = food(
    'Курица',
    120.5,
    180,
    24,
    day,
    micros: const {'iron': 1},
    estimated: true,
  );

  test('ranks real portions using full precision, not per-100g values', () {
    final r = analyzeRecordedNutrition([apple, chicken]);
    expect(r.records, 2);
    expect(r.calories, closeTo(319.9, 1e-9));
    expect(r.largestEnergyRecords.first.name, 'Курица');
    expect(r.largestProteinRecord!.name, 'Курица');
    expect(r.share(chicken), closeTo(216.9 / 319.9, 1e-12));
    expect(r.recordsWithoutMicros, 1);
    expect(r.recordsEstimatedMicros, 1);
  });

  test('empty, actual zero and malformed values remain distinct', () {
    final empty = analyzeRecordedNutrition([]);
    expect(empty.records, 0);
    expect(empty.largestEnergyRecords, isEmpty);
    final zero = analyzeRecordedNutrition([food('Вода', 100, 0, 0, day)]);
    expect(zero.records, 1);
    expect(zero.calories, 0);
    expect(zero.largestEnergyRecords, isEmpty);
    final invalid = analyzeRecordedNutrition([
      food('Ошибка', 100, double.nan, 0, day),
    ]);
    expect(invalid.records, 0);
    expect(invalid.skipped, 1);
  });

  test('hypothetical portion math is exact and never edits input', () {
    final original = chicken.toJson();
    final change = PortionComparison.calculate(chicken, 80.25);
    expect(change.caloriesChange, closeTo(-72.45, 1e-10));
    expect(change.proteinChange, closeTo(-9.66, 1e-10));
    expect(chicken.toJson(), original);
    expect(
      PortionComparison.calculate(chicken, 0).caloriesChange,
      closeTo(-216.9, 1e-10),
    );
    expect(
      () => PortionComparison.calculate(chicken, double.nan),
      throwsArgumentError,
    );
    expect(() => PortionComparison.calculate(chicken, -1), throwsArgumentError);
    expect(
      () => PortionComparison.calculate(chicken, 10001),
      throwsArgumentError,
    );
  });

  test(
    'overview keeps portion details local and out of the AI summary request',
    () {
      final overview = summarizeJournal(
        {
          'food_entries_${dayKey(day)}': jsonEncode([
            apple.toJson(),
            chicken.toJson(),
          ]),
        },
        day,
        day,
      );
      expect(overview.foodInsights.largestEnergyRecords.first.name, 'Курица');
      final request = jsonEncode(overview.request({'food'}, ''));
      expect(request, isNot(contains('private-')));
      expect(
        request,
        isNot(contains('120.5')),
      ); // individual portion never added to old aggregate request
      expect(request, isNot(contains('foodInsights')));
    },
  );

  testWidgets('comparison is interactive, read-only and responsive at 320px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final before = jsonEncode(chicken.toJson());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecordedNutritionDetails(
              insight: analyzeRecordedNutrition([chicken, apple]),
              daysWithRecords: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сравнить порцию').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '80,25');
    await tester.pumpAndSettle();
    expect(find.textContaining('−72,5 ккал'), findsOneWidget);
    expect(find.textContaining('Дневник не изменится'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '-5');
    await tester.pumpAndSettle();
    expect(find.text('Укажите число от 0 до 10 000'), findsOneWidget);
    expect(jsonEncode(chicken.toJson()), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home tip reflects selected records and opens overview', (
    tester,
  ) async {
    LocalPreferences.memoryForTests = true;
    SharedPreferences.setMockInitialValues({});
    final p = AppDataProvider();
    await p.init();
    var opened = -1;
    await tester.runAsync(() async {
      final d = p.selectedDate;
      await p.addFoodEntry(food('Тестовый обед', 200, 150, 10, d));
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(body: SimpleHomeScreen(openTab: (v) => opened = v)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Совет дня'), findsOneWidget);
    expect(find.textContaining('Тестовый обед'), findsOneWidget);
    await tester.ensureVisible(find.text('Подробный разбор питания'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подробный разбор питания'));
    expect(opened, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    p.dispose();
  });
}
