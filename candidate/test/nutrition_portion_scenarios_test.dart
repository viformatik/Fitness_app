// Synthetic-only tests. The scenarios are read-only mathematical examples,
// never a medical recommendation or an instruction to alter past diary rows.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/nutrition_insights.dart';
import 'package:fitness_tracker/smart/nutrition_insights_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FoodEntry fixture({
  double grams = 137.35,
  double kcal = 60.7,
  double protein = 3.1,
  double fat = 3.6,
  double carbs = 4.7,
}) => FoodEntry(
  id: 'synthetic-only',
  name: 'Тестовое молоко',
  caloriesPer100g: kcal,
  proteinPer100g: protein,
  fatPer100g: fat,
  carbsPer100g: carbs,
  amountGrams: grams,
  mealType: MealType.lunch,
  date: DateTime(2026, 10, 25),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'read-only smaller, larger and omit scenarios retain full precision',
    () {
      final entry = fixture();
      final before = jsonEncode(entry.toJson());
      final scenarios = futurePortionExamples(entry);
      expect(scenarios.map((e) => e.kind).toList(), [
        PortionExampleKind.smaller,
        PortionExampleKind.larger,
        PortionExampleKind.omit,
      ]);
      final smaller = scenarios[0].comparison;
      final larger = scenarios[1].comparison;
      final omit = scenarios[2].comparison;
      expect(smaller.hypotheticalGrams, closeTo(103.0125, 1e-10));
      expect(smaller.caloriesChange, closeTo(-20.8428625, 1e-10));
      expect(smaller.proteinChange, closeTo(-1.0644625, 1e-10));
      expect(smaller.fatChange, closeTo(-1.23615, 1e-10));
      expect(smaller.carbsChange, closeTo(-1.6138625, 1e-10));
      expect(larger.hypotheticalGrams, closeTo(171.6875, 1e-10));
      expect(larger.caloriesChange, closeTo(-smaller.caloriesChange, 1e-10));
      expect(omit.hypotheticalGrams, 0);
      expect(omit.caloriesChange, closeTo(-entry.calories, 1e-10));
      expect(omit.proteinChange, closeTo(-entry.protein, 1e-10));
      expect(jsonEncode(entry.toJson()), before);
      expect(() => scenarios.clear(), throwsUnsupportedError);
    },
  );

  test(
    'unavailable or invalid figures are never offered as valid examples',
    () {
      expect(futurePortionExamples(fixture(grams: 0)), isEmpty);
      expect(futurePortionExamples(fixture(grams: -1)), isEmpty);
      expect(futurePortionExamples(fixture(grams: double.nan)), isEmpty);
      expect(futurePortionExamples(fixture(kcal: double.infinity)), isEmpty);
      expect(futurePortionExamples(fixture(protein: -1)), isEmpty);
      expect(
        () => PortionComparison.calculate(fixture(grams: -1), 0),
        throwsArgumentError,
      );
      expect(
        () => PortionComparison.calculate(fixture(protein: -1), 50),
        throwsArgumentError,
      );
      expect(
        () => PortionComparison.calculate(fixture(kcal: double.nan), 50),
        throwsArgumentError,
      );
    },
  );

  test(
    'oversized alternative is omitted without clipping or changing source',
    () {
      final entry = fixture(grams: 9000);
      final original = jsonEncode(entry.toJson());
      final scenarios = futurePortionExamples(entry);
      expect(scenarios.map((e) => e.kind).toList(), [
        PortionExampleKind.smaller,
        PortionExampleKind.omit,
      ]);
      expect(scenarios.first.comparison.hypotheticalGrams, 6750);
      expect(jsonEncode(entry.toJson()), original);
    },
  );

  testWidgets(
    'specific future options are selectable and never edit food at 320 px',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final entry = fixture();
      final before = jsonEncode(entry.toJson());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RecordedNutritionDetails(
                insight: analyzeRecordedNutrition([entry]),
                daysWithRecords: 1,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('103,01 г вместо 137,35 г'), findsOneWidget);
      expect(find.textContaining('−20,8 ккал'), findsOneWidget);
      expect(find.textContaining('Это пример, не норма'), findsOneWidget);
      await tester.ensureVisible(find.text('Сравнить порцию'));
      await tester.tap(find.text('Сравнить порцию'));
      await tester.pumpAndSettle();
      expect(find.text('На 25% меньше'), findsOneWidget);
      expect(find.text('На 25% больше'), findsOneWidget);
      expect(find.text('Не добавлять в будущем'), findsOneWidget);
      final larger = find.widgetWithText(OutlinedButton, 'На 25% больше');
      expect(larger, findsOneWidget);
      final semantics = tester.ensureSemantics();
      try {
        expect(
          tester
              .getSemantics(larger)
              .getSemanticsData()
              .flagsCollection
              .isButton,
          isTrue,
        );
      } finally {
        semantics.dispose();
      }
      await tester.tap(find.text('На 25% больше'));
      await tester.pumpAndSettle();
      expect(find.textContaining('+20,8 ккал'), findsOneWidget);
      expect(find.textContaining('Б +1,1 г'), findsOneWidget);
      await tester.tap(find.text('Не добавлять в будущем'));
      await tester.pumpAndSettle();
      expect(find.textContaining('−83,4 ккал'), findsOneWidget);
      expect(find.textContaining('Б −4,3 г'), findsOneWidget);
      expect(find.textContaining('Дневник не изменится'), findsOneWidget);
      expect(jsonEncode(entry.toJson()), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home tip uses the recorded portion and stays on device', (
    tester,
  ) async {
    final entry = fixture();
    final before = jsonEncode(entry.toJson());
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DailyNutritionTip(
            insight: analyzeRecordedNutrition([entry]),
            openDetails: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Тестовое молоко'), findsOneWidget);
    expect(find.textContaining('103,01 г'), findsOneWidget);
    expect(find.textContaining('−20,8 ккал и Б −1,1 г'), findsOneWidget);
    expect(find.textContaining('Это пример, не норма'), findsOneWidget);
    await tester.tap(find.text('Подробный разбор питания'));
    expect(opened, isTrue);
    expect(jsonEncode(entry.toJson()), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an indistinguishable rounded portion is not advertised as different',
    (tester) async {
      final entry = fixture(grams: .01, kcal: 10000);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DailyNutritionTip(
              insight: analyzeRecordedNutrition([entry]),
              openDetails: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Пример на будущее:'), findsNothing);
      expect(
        find.textContaining('можно сравнить варианты порции'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('no manufactured options for an empty recorded diary', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedNutritionDetails(
            insight: analyzeRecordedNutrition([]),
            daysWithRecords: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('нет записей еды'), findsOneWidget);
    expect(find.text('Сравнить порцию'), findsNothing);
    expect(find.textContaining('Это пример, не норма'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
