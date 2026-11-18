import 'dart:convert';
import 'package:fitness_tracker/smart/local_store.dart';

import 'package:fitness_tracker/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

FoodEntry food(
  DateTime date, {
  String name = 'Йогурт',
  double grams = 150,
  double kcal = 100,
  double protein = 12.5,
  double fat = 3.2,
  double carbs = 8,
  MealType meal = MealType.breakfast,
}) => FoodEntry(
  name: name,
  caloriesPer100g: kcal,
  proteinPer100g: protein,
  fatPer100g: fat,
  carbsPer100g: carbs,
  amountGrams: grams,
  mealType: meal,
  date: date,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider p;
  final day = DateTime(2026, 10, 25);

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
        targetProtein: 100,
        targetFat: 60,
        targetCarbs: 250,
      ),
    );
  });
  tearDown(() => p.dispose());

  test('Парсер принимает запятую, точку, пробелы и явный ноль', () {
    expect(parseNutritionNumber(' 12,5 '), 12.5);
    expect(parseNutritionNumber('12.5'), 12.5);
    expect(parseNutritionNumber('0'), 0);
  });
  test('Парсер отвергает пустое, мусор, отрицательное, NaN и Infinity', () {
    for (final text in ['', ' ', 'abc', '-1', 'NaN', 'Infinity', '1,2,3']) {
      expect(parseNutritionNumber(text), isNull, reason: text);
    }
  });
  test('Порция и все БЖУ сохраняются в JSON без потери точности', () {
    final original = food(day, grams: 125.5);
    final restored = FoodEntry.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(restored.id, original.id);
    expect(restored.amountGrams, 125.5);
    expect(restored.protein, closeTo(15.6875, 1e-9));
    expect(restored.fat, closeTo(4.016, 1e-9));
    expect(restored.carbs, closeTo(10.04, 1e-9));
  });
  test('Осталось = норма - съедено + сожжено', () async {
    await p.addFoodEntry(food(day, grams: 100, kcal: 1800));
    await p.addWorkoutEntry(
      WorkoutEntry(
        type: WorkoutType.cardio,
        durationMinutes: 40,
        caloriesBurned: 400,
        date: day,
      ),
    );
    expect(p.todayCaloriesBurned, 400);
    expect(p.adjustedCaloriesTarget, 2400);
    expect(p.caloriesRemaining, 600);
    expect(p.caloriesProgress, 0.75);
    expect(
      p.profile.targetProtein,
      100,
    ); // exercise never changes macro targets
  });
  test('Перебор сохраняется отрицательным, без обрезания к нулю', () async {
    await p.addFoodEntry(food(day, grams: 100, kcal: 2600));
    await p.addWorkoutEntry(
      WorkoutEntry(
        type: WorkoutType.cardio,
        durationMinutes: 20,
        caloriesBurned: 200,
        date: day,
      ),
    );
    expect(p.caloriesRemaining, -400);
    expect(p.caloriesProgress, greaterThan(1));
  });
  test('БЖУ суммируются по всем приёмам и остаются дробными', () async {
    await p.addFoodEntry(food(day)); // 150g
    await p.addFoodEntry(food(day, grams: 50, meal: MealType.dinner));
    expect(p.todayProteinConsumed, 25);
    expect(p.todayFatConsumed, closeTo(6.4, 1e-9));
    expect(p.todayCarbsConsumed, 16);
    expect(p.proteinProgress, 0.25);
    expect(p.fatProgress, closeTo(6.4 / 60, 1e-9));
    expect(p.carbsProgress, 16 / 250);
  });
  test(
    'Маленькие порции не теряются из-за преждевременного округления',
    () async {
      await p.addFoodEntry(food(day, grams: 1, kcal: 40, protein: 4));
      await p.addFoodEntry(food(day, grams: 1, kcal: 40, protein: 4));
      expect(p.todayCaloriesConsumed, 1); // round(0.4 + 0.4), not 0 + 0
      expect(p.todayProteinConsumed, closeTo(0.08, 1e-9));
      expect(p.dayLogs.single.calories, closeTo(0.8, 1e-9));
      expect(p.dayLogs.single.calories.round(), 1); // round only in the view
      await p.refresh();
      expect(p.dayLogs.single.calories, closeTo(0.8, 1e-9));
      expect(p.dayLogs.single.calories.round(), 1);
    },
  );
  test('Редактирование пересчитывает калории, БЖУ, историю и диск', () async {
    final entry = food(day);
    await p.addFoodEntry(entry);
    await p.updateFoodEntry(
      entry.copyWith(amountGrams: 200, proteinPer100g: 20),
    );
    expect(p.todayCaloriesConsumed, 200);
    expect(p.todayProteinConsumed, 40);
    expect(p.dayLogs.single.calories, 200);
    await p.refresh();
    expect(p.todayProteinConsumed, 40);
    expect(p.todayFoodEntries.single.amountGrams, 200);
    expect(p.dayLogs.single.calories, 200);
  });
  test(
    'Удаление пересчитывает нутриенты и сохраняется после загрузки',
    () async {
      final entry = food(day);
      await p.addFoodEntry(entry);
      await p.deleteFoodEntry(entry.id);
      expect(p.todayProteinConsumed, 0);
      expect(p.caloriesRemaining, 2000);
      await p.refresh();
      expect(p.todayFoodEntries, isEmpty);
      expect(p.todayCaloriesConsumed, 0);
    },
  );
  test('Очистка еды оставляет тренировку, воду и другие дни', () async {
    final yesterday = day.subtract(const Duration(days: 1));
    await p.addFoodEntry(food(day));
    await p.addFoodEntry(food(yesterday, name: 'Вчера'));
    await p.addWater(250);
    await p.addWorkoutEntry(
      WorkoutEntry(
        type: WorkoutType.cardio,
        durationMinutes: 20,
        caloriesBurned: 200,
        date: day,
      ),
    );
    await p.clearFoodForSelectedDay();
    await p.refresh();
    expect(p.todayFoodEntries, isEmpty);
    expect(p.todayWaterIntake, 250);
    expect(p.todayWorkoutEntries, hasLength(1));
    expect(p.caloriesRemaining, 2200);
    await p.setSelectedDate(yesterday);
    expect(p.todayFoodEntries.single.name, 'Вчера');
  });
  test('Быстрое добавление 20 продуктов не теряет записи на диске', () async {
    await Future.wait(
      List.generate(20, (i) => p.addFoodEntry(food(day, name: 'Еда $i'))),
    );
    expect(p.todayFoodEntries, hasLength(20));
    await p.refresh();
    expect(p.todayFoodEntries, hasLength(20));
    expect(p.todayProteinConsumed, 375);
  });
  test('Быстрые add → edit → delete не воскрешают запись', () async {
    final e = food(day);
    await Future.wait([
      p.addFoodEntry(e),
      p.updateFoodEntry(e.copyWith(amountGrams: 250)),
      p.deleteFoodEntry(e.id),
    ]);
    await p.refresh();
    expect(p.todayFoodEntries, isEmpty);
  });
  test(
    'Очистка и следующее быстрое добавление не теряют новый продукт',
    () async {
      await p.addFoodEntry(food(day, name: 'Старый'));
      await Future.wait([
        p.clearFoodForSelectedDay(),
        p.addFoodEntry(food(day, name: 'Новый')),
      ]);
      await p.refresh();
      expect(p.todayFoodEntries.single.name, 'Новый');
    },
  );
  test(
    'Быстрые тренировки сохраняются, редактирование/удаление меняют лимит',
    () async {
      final a = WorkoutEntry(
        type: WorkoutType.cardio,
        durationMinutes: 30,
        caloriesBurned: 300,
        date: day,
      );
      final b = WorkoutEntry(
        type: WorkoutType.strength,
        durationMinutes: 40,
        caloriesBurned: 400,
        date: day,
      );
      await Future.wait([p.addWorkoutEntry(a), p.addWorkoutEntry(b)]);
      await p.refresh();
      expect(p.todayCaloriesBurned, 700);
      await p.updateWorkoutEntry(
        WorkoutEntry(
          id: a.id,
          type: a.type,
          durationMinutes: 20,
          caloriesBurned: 100,
          date: day,
        ),
      );
      expect(p.caloriesRemaining, 2500);
      await p.deleteWorkoutEntry(b.id);
      await p.refresh();
      expect(p.caloriesRemaining, 2100);
      await p.deleteWorkoutEntry(a.id);
      expect(p.caloriesRemaining, 2000);
      expect(p.todayWorkoutCompleted, isFalse);
    },
  );
  test('Смена дня не смешивает еду и тренировки', () async {
    final yesterday = day.subtract(const Duration(days: 1));
    await p.addFoodEntry(food(day));
    await p.addWorkoutEntry(
      WorkoutEntry(
        type: WorkoutType.cardio,
        durationMinutes: 20,
        caloriesBurned: 200,
        date: yesterday,
      ),
    );
    expect(p.todayCaloriesBurned, 0);
    expect(p.todayFoodEntries, hasLength(1));
    await Future.wait([p.setSelectedDate(yesterday), p.setSelectedDate(day)]);
    expect(p.selectedDate, day);
    expect(p.todayCaloriesConsumed, 150);
    expect(p.todayCaloriesBurned, 0);
  });
  test('Нулевая цель не приводит к делению на ноль', () async {
    await p.updateProfile(
      const UserProfile(
        dailyCaloriesMin: 0,
        dailyCaloriesMax: 0,
        calorieGoalConfirmed: true,
        proteinGoalConfirmed: true,
        fatGoalConfirmed: true,
        carbsGoalConfirmed: true,
        targetProtein: 0,
        targetFat: 0,
        targetCarbs: 0,
      ),
    );
    await p.addFoodEntry(food(day));
    for (final progress in [
      p.caloriesProgress,
      p.proteinProgress,
      p.fatProgress,
      p.carbsProgress,
    ]) {
      expect(
        progress,
        isNull,
      ); // zero is confirmed, but a percentage is undefined
    }
  });
  test('Рецепт передаёт КБЖУ в дневную порцию', () async {
    final recipe = Recipe(
      name: 'Смесь',
      ingredients: [
        RecipeIngredient(
          name: 'A',
          grams: 100,
          caloriesPer100g: 100,
          proteinPer100g: 10,
          fatPer100g: 2,
          carbsPer100g: 8,
        ),
        RecipeIngredient(
          name: 'B',
          grams: 100,
          caloriesPer100g: 200,
          proteinPer100g: 20,
          fatPer100g: 4,
          carbsPer100g: 16,
        ),
      ],
    );
    await p.addRecipeToMeal(recipe, 100, MealType.lunch);
    expect(p.todayCaloriesConsumed, 150);
    expect(p.todayProteinConsumed, 15);
    expect(p.todayFatConsumed, 3);
    expect(p.todayCarbsConsumed, 12);
  });
  test('Некорректные данные не попадают в провайдер', () async {
    await expectLater(
      p.addFoodEntry(food(day, protein: double.nan)),
      throwsArgumentError,
    );
    await expectLater(
      p.addFoodEntry(food(day, grams: -5)),
      throwsArgumentError,
    );
    expect(p.todayFoodEntries, isEmpty);
  });

  Widget host(Widget child) => ChangeNotifierProvider.value(
    value: p,
    child: MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(body: child),
    ),
  );

  testWidgets('Карточка БЖУ показывает 150%, хотя полоса ограничена 100%', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 200,
          child: MacroProgressBar(
            label: 'Белки',
            consumed: 150,
            target: 100,
            color: Colors.blue,
            icon: Icons.restaurant,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsOneWidget);
    expect(find.text('+50 г сверх'), findsOneWidget);
    expect(
      tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .widthFactor,
      1,
    );
  });
  testWidgets('Нулевая подтверждённая цель не подменяется отсутствием', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 200,
          child: MacroProgressBar(
            label: 'Белки',
            consumed: 12.5,
            target: 0,
            color: Colors.blue,
            icon: Icons.restaurant,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Цель 0 г · процент недоступен'), findsOneWidget);
    expect(find.text('Проверьте цель в профиле'), findsNothing);
    expect(find.text('+12.5 г сверх'), findsNothing);
  });
  testWidgets('Кольцо плавно обновляет прогресс без сброса к нулю', (
    tester,
  ) async {
    Widget ring(int consumed, int target) =>
        host(CircularCalorieIndicator(consumed: consumed, target: target));
    await tester.pumpWidget(ring(1000, 2000));
    await tester.pumpAndSettle();
    double progress() {
      final paint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere(
            (w) => w.painter.runtimeType.toString() == '_CalorieRingPainter',
          );
      return (paint.painter as dynamic).progress as double;
    }

    expect(progress(), 0.5);
    await tester.pumpWidget(ring(1500, 2000));
    expect(progress(), 0.5);
    await tester.pump(const Duration(milliseconds: 250));
    expect(progress(), inExclusiveRange(0.5, 0.75));
    await tester.pumpAndSettle();
    expect(progress(), 0.75);
    // Adding a workout increases the target, so the ring fill must decrease.
    await tester.pumpWidget(ring(1500, 2500));
    await tester.pumpAndSettle();
    expect(progress(), 0.6);
    expect(find.text('1 000'), findsOneWidget);
  });
  testWidgets(
    'Модальное окно показывает продукты и обновляется от провайдера',
    (tester) async {
      await tester.runAsync(() => p.addFoodEntry(food(day)));
      await tester.pumpWidget(
        host(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () =>
                  showNutritionDetails(ctx, p, NutrientMetric.protein),
              child: const Text('Открыть'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Йогурт'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Йогурт'), findsOneWidget);
      expect(find.text('150 г · 18.8 г'), findsOneWidget);
      await tester.runAsync(
        () => p.addFoodEntry(food(day, name: 'Обед', meal: MealType.lunch)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Обед'), findsWidgets);
      await tester.scrollUntilVisible(
        find.textContaining('37.5 г по записям / ориентир 100 г'),
        -180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(
        find.textContaining('37.5 г по записям / ориентир 100 г'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'Редактор принимает дробную запятую и исправляет старые нулевые БЖУ',
    (tester) async {
      final entry = food(day, protein: 0, fat: 0, carbs: 0);
      await tester.runAsync(() => p.addFoodEntry(entry));
      await tester.pumpWidget(
        host(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showFoodEditor(ctx, p, entry),
              child: const Text('Править'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Править'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Вес порции, г'),
        '200',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Белки на 100 г'),
        '12,5',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(p.todayProteinConsumed, 25);
      expect(p.todayCaloriesConsumed, 200);
      expect(find.text('Редактировать продукт'), findsNothing);
    },
  );
  testWidgets('Свой продукт: дробная запятая доходит из UI до БЖУ и диска', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showDialog<void>(
              context: ctx,
              builder: (_) =>
                  AddFoodDialog(mealType: MealType.breakfast, provider: p),
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Свой продукт'));
    await tester.tap(find.text('Свой продукт'));
    await tester.pumpAndSettle();
    Future<void> fill(String label, String value) async {
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
    }

    await fill('Название продукта', 'Творог');
    await fill('Вес порции', '200');
    await fill('Ккал', '100,5');
    await fill('Б (г)', '12,5');
    await fill('Ж (г)', '3,2');
    await fill('У (г)', '4,1');
    await tester.runAsync(() async {
      await tester.tap(find.text('Добавить'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(p.todayProteinConsumed, 25);
    expect(p.todayFatConsumed, closeTo(6.4, 1e-9));
    expect(p.todayCarbsConsumed, closeTo(8.2, 1e-9));
    expect(p.todayCaloriesConsumed, 201);
    await tester.runAsync(p.refresh);
    expect(p.todayProteinConsumed, 25);
  });
  testWidgets('Очистка требует подтверждения и не выполняется при отмене', (
    tester,
  ) async {
    await tester.runAsync(() => p.addFoodEntry(food(day)));
    await tester.pumpWidget(
      host(
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => confirmClearFood(ctx, p),
            child: const Text('Очистка'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Очистка'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(p.todayFoodEntries, hasLength(1));
    await tester.tap(find.text('Очистка'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Очистить'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    // The durable document and provider reload must finish after the
    // confirmation route has closed; clearing is no longer optimistic.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(p.todayFoodEntries, isEmpty);
    expect(p.storage.local.getString('food_entries_${dayKey(day)}'), '[]');
  });
}
