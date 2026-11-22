import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/recipe_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Recipe fixture({String id = 'recipe-a', String name = 'Тестовое блюдо'}) =>
    Recipe(
      id: id,
      name: name,
      servings: 3,
      cookedWeight: 150.125,
      ingredients: const [
        RecipeIngredient(
          name: 'Первый ингредиент',
          grams: 123.456,
          caloriesPer100g: 101.2345,
          proteinPer100g: 5.25,
          fatPer100g: 2.35,
          carbsPer100g: 13.5,
          micros: {'iron': 1.25, 'fiber': 2.5},
          microsEstimated: true,
        ),
        RecipeIngredient(
          name: 'Второй ингредиент',
          grams: 67.89,
          caloriesPer100g: 87.5,
          proteinPer100g: 4,
          fatPer100g: 3,
          carbsPer100g: 9,
          micros: {'iron': 2.5},
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
    await provider.setSelectedDate(DateTime(2026, 10, 25));
    AppTheme.configure({});
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    provider.dispose();
    AppTheme.configure({});
  });

  test(
    'fractional ingredients, cooked yield and portions keep full precision',
    () {
      final recipe = fixture();
      final calories = 123.456 * 101.2345 / 100 + 67.89 * 87.5 / 100;
      final protein = 123.456 * 5.25 / 100 + 67.89 * 4 / 100;
      expect(recipe.totalGrams, closeTo(191.346, 1e-10));
      expect(recipe.outputWeight, 150.125);
      expect(recipe.totalCalories, closeTo(calories, 1e-10));
      expect(recipe.caloriesPer100g, closeTo(calories * 100 / 150.125, 1e-10));
      expect(recipe.servingGrams, closeTo(150.125 / 3, 1e-10));
      expect(recipe.servingCalories, closeTo(calories / 3, 1e-10));
      final serving = recipe.toEntry(recipe.servingGrams, MealType.lunch);
      expect(serving.calories, closeTo(calories / 3, 1e-10));
      expect(serving.protein, closeTo(protein / 3, 1e-10));
      expect(serving.microsEstimated, isTrue);
      expect(recipe.microsPer100g.keys, contains('iron'));
      expect(
        recipe.microsPer100g.keys,
        isNot(contains('fiber')),
        reason: 'an unknown ingredient nutrient is not an invented zero',
      );
    },
  );

  test(
    'non-finite aggregate calculations are rejected before any write',
    () async {
      final bad = Recipe(
        id: 'huge',
        name: 'Недопустимый расчёт',
        ingredients: const [
          RecipeIngredient(
            name: 'Продукт',
            grams: 1e200,
            caloriesPer100g: 1e200,
            proteinPer100g: 1,
            fatPer100g: 1,
            carbsPer100g: 1,
          ),
        ],
      );
      await expectLater(
        provider.addRecipe(bad),
        throwsA(isA<RecipeEditException>()),
      );
      expect(provider.storage.local.getString('recipes'), isNull);
      expect(provider.recipes, isEmpty);
    },
  );

  test(
    'failed edits do not change storage/provider and can be retried',
    () async {
      final recipe = fixture();
      await provider.addRecipe(recipe);
      final raw = provider.storage.local.getString('recipes');
      final snapshot = provider.captureRecipeEdit(provider.recipes.single);
      var notifications = 0;
      provider.addListener(() => notifications++);
      LocalPreferences.rejectWriteKeyForTests = 'recipes';
      await expectLater(
        provider.updateRecipe(
          recipe.copyWith(name: 'Изменено'),
          snapshot: snapshot,
        ),
        throwsStateError,
      );
      expect(provider.storage.local.getString('recipes'), raw);
      expect(provider.recipes.single.name, recipe.name);
      expect(notifications, 0);
      LocalPreferences.rejectWriteKeyForTests = null;
      await provider.updateRecipe(
        recipe.copyWith(name: 'Изменено'),
        snapshot: snapshot,
      );
      expect(provider.recipes.single.name, 'Изменено');
      expect(notifications, 1);
    },
  );

  test(
    'two editors cannot silently overwrite each other; fresh retry preserves both',
    () async {
      final recipe = fixture();
      await provider.addRecipe(recipe);
      final first = provider.captureRecipeEdit(provider.recipes.single);
      final second = provider.captureRecipeEdit(provider.recipes.single);
      Future<bool> tryEdit(String name, RecipeEditSnapshot snapshot) async {
        try {
          await provider.updateRecipe(
            recipe.copyWith(name: name),
            snapshot: snapshot,
          );
          return true;
        } on RecipeEditException {
          return false;
        }
      }

      final outcomes = await Future.wait([
        tryEdit('Из редактора 1', first),
        tryEdit('Из редактора 2', second),
      ]);
      expect(outcomes.where((value) => value), hasLength(1));
      final winner = provider.recipes.single;
      expect(['Из редактора 1', 'Из редактора 2'], contains(winner.name));
      final a = provider.captureRecipeEdit(), b = provider.captureRecipeEdit();
      Future<bool> tryAdd(String id, RecipeEditSnapshot snapshot) async {
        try {
          await provider.addRecipe(
            fixture(id: id, name: id),
            snapshot: snapshot,
          );
          return true;
        } on RecipeEditException {
          return false;
        }
      }

      final added = await Future.wait([
        tryAdd('second', a),
        tryAdd('third', b),
      ]);
      expect(added.where((value) => value), hasLength(1));
      final missing = added[0] ? 'third' : 'second';
      await provider.addRecipe(fixture(id: missing, name: missing));
      expect(provider.recipes.map((r) => r.id).toSet(), {
        'recipe-a',
        'second',
        'third',
      });
      expect(provider.recipes.first.name, winner.name);
    },
  );

  test(
    'queued write freezes nested ingredients and micronutrients at submission',
    () async {
      final micros = <String, double>{'iron': 2.5};
      final ingredients = <RecipeIngredient>[
        RecipeIngredient(
          name: 'Исходный',
          grams: 50,
          caloriesPer100g: 100,
          proteinPer100g: 3,
          fatPer100g: 4,
          carbsPer100g: 5,
          micros: micros,
        ),
      ];
      final submitted = Recipe(
        id: 'frozen',
        name: 'Снимок',
        ingredients: ingredients,
      );
      final pending = provider.addRecipe(submitted);
      ingredients.clear();
      micros['iron'] = 99;
      await pending;
      expect(provider.recipes.single.ingredients.single.grams, 50);
      expect(provider.recipes.single.ingredients.single.micros['iron'], 2.5);
    },
  );

  test(
    'stale UI model is rejected even if snapshot is captured after storage changed',
    () async {
      final original = fixture();
      await provider.addRecipe(original);
      final oldModel = provider.recipes.single;
      final changed = fixture(name: 'Внешнее изменение');
      await provider.storage.local.setString(
        'recipes',
        jsonEncode([changed.toJson()]),
      );
      final stale = provider.captureRecipeEdit(oldModel);
      final before = provider.storage.local.getString('recipes');
      await expectLater(
        provider.updateRecipe(
          oldModel.copyWith(name: 'Устаревший редактор'),
          snapshot: stale,
        ),
        throwsA(isA<RecipeEditException>()),
      );
      expect(provider.storage.local.getString('recipes'), before);
    },
  );

  test(
    'unknown future recipe, ingredient or nutrient fields block all rewrites',
    () async {
      for (final kind in ['recipe', 'ingredient', 'micro', 'provenance']) {
        final row = fixture().toJson();
        final ingredients = row['ingredients'] as List;
        final first = ingredients.first as Map<String, dynamic>;
        if (kind == 'recipe') row['newField'] = {'keep': 'opaque'};
        if (kind == 'ingredient') first['newField'] = 123;
        if (kind == 'micro')
          first['micros'] = {...(first['micros'] as Map), 'futureVitamin': 2.5};
        if (kind == 'provenance') first['microsEstimated'] = null;
        final raw = jsonEncode([row]);
        await provider.storage.local.setString('recipes', raw);
        await provider.refresh();
        final original = provider.recipes.single;
        await expectLater(
          provider.updateRecipe(
            original.copyWith(name: 'Потеря'),
            snapshot: provider.captureRecipeEdit(original),
          ),
          throwsA(isA<RecipeEditException>()),
        );
        await expectLater(
          provider.addRecipe(
            fixture(id: 'new'),
            snapshot: provider.captureRecipeEdit(),
          ),
          throwsA(isA<RecipeEditException>()),
        );
        await expectLater(
          provider.deleteRecipe(
            original.id,
            snapshot: provider.captureRecipeEdit(original),
          ),
          throwsA(isA<RecipeEditException>()),
        );
        expect(provider.storage.local.getString('recipes'), raw, reason: kind);
      }
    },
  );

  test(
    'old recipe shape can be read and its food snapshot survives edit/delete',
    () async {
      final row = fixture().toJson();
      row.remove('cookedWeight');
      row.remove('servings');
      for (final ingredient in row['ingredients'] as List) {
        (ingredient as Map).remove('microsEstimated');
      }
      await provider.storage.local.setString('recipes', jsonEncode([row]));
      await provider.refresh();
      final old = provider.recipes.single;
      expect(old.servings, 1);
      expect(old.outputWeight, closeTo(old.totalGrams, 1e-10));
      await provider.addRecipeToMeal(old, 37.125, MealType.lunch);
      final before = jsonEncode(
        (await provider.storage.getFoodEntries(
          provider.selectedDate,
        )).single.toJson(),
      );
      await provider.updateRecipe(
        old.copyWith(name: 'Новое название', servings: 2),
      );
      await provider.deleteRecipe(old.id);
      final after = jsonEncode(
        (await provider.storage.getFoodEntries(
          provider.selectedDate,
        )).single.toJson(),
      );
      expect(after, before);
      expect(provider.recipes, isEmpty);
      final export = await provider.storage.exportData();
      expect((export['data'] as Map).keys, contains('food_entries_2026-10-25'));
    },
  );

  test(
    'ambiguous duplicate IDs are rejected, never silently deleting another recipe',
    () async {
      final a = fixture(), b = fixture(name: 'Другой с тем же ID');
      final raw = jsonEncode([a.toJson(), b.toJson()]);
      await provider.storage.local.setString('recipes', raw);
      await provider.refresh();
      await expectLater(
        provider.deleteRecipe(
          a.id,
          snapshot: provider.captureRecipeEdit(provider.recipes.first),
        ),
        throwsA(isA<RecipeEditException>()),
      );
      expect(provider.storage.local.getString('recipes'), raw);
    },
  );

  Future<void> openEditor(
    WidgetTester tester,
    Recipe? initial,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    AddRecipeDialog(provider: provider, initial: initial),
              ),
              child: const Text('Открыть тест'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть тест'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'editor keeps exact mass and estimation flag, validates portions and reports write failure',
    (tester) async {
      final recipe = fixture();
      await tester.runAsync(() => provider.addRecipe(recipe));
      final saved = provider.storage.local.getString('recipes');
      await openEditor(tester, provider.recipes.single, const Size(320, 740));
      final firstIngredient = find.text('Первый ингредиент');
      await tester.ensureVisible(firstIngredient);
      await tester.tap(firstIngredient);
      await tester.pumpAndSettle();
      final field = find.byType(TextFormField).last;
      expect(tester.widget<TextFormField>(field).controller!.text, '123.456');
      await tester.tap(find.text('Сохранить').last);
      await tester.pumpAndSettle();
      final portions = find.widgetWithText(TextField, 'Порций');
      await tester.ensureVisible(portions);
      await tester.enterText(portions, '0');
      await tester.tap(find.text('Сохранить').last);
      await tester.pump();
      final countError = find.text(
        'Введите целое количество порций от 1 до 30.',
      );
      expect(countError, findsOneWidget);
      await tester.pump();
      final scroll = find
          .ancestor(
            of: countError,
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      expect(
        tester.getRect(scroll).overlaps(tester.getRect(countError)),
        isTrue,
      );
      expect(provider.storage.local.getString('recipes'), saved);
      await tester.enterText(portions, '3');
      LocalPreferences.rejectWriteKeyForTests = 'recipes';
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить').last);
        await provider.storage.pendingMutations;
      });
      await tester.pump();
      expect(
        find.textContaining('Не удалось сохранить рецепт'),
        findsOneWidget,
      );
      expect(provider.storage.local.getString('recipes'), saved);
      LocalPreferences.rejectWriteKeyForTests = null;
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить').last);
        await provider.storage.pendingMutations;
      });
      await tester.pumpAndSettle();
      expect(provider.recipes.single.ingredients.first.grams, 123.456);
      expect(provider.recipes.single.ingredients.first.microsEstimated, isTrue);
      expect(find.byType(AddRecipeDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cooked yield can be reset and is displayed correctly in landscape',
    (tester) async {
      await tester.runAsync(() => provider.addRecipe(fixture()));
      await openEditor(tester, provider.recipes.single, const Size(900, 320));
      expect(find.text('150.1 г'), findsOneWidget);
      final reset = find.text('Сбросить выход блюда');
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pump();
      expect(find.text('191.3 г'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить').last);
        await provider.storage.pendingMutations;
      });
      await tester.pumpAndSettle();
      expect(provider.recipes.single.cookedWeight, isNull);
      expect(provider.recipes.single.outputWeight, closeTo(191.346, 1e-10));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new recipe can be created from the catalog in short landscape', (
    tester,
  ) async {
    await openEditor(tester, null, const Size(900, 320));
    final nameField = find.widgetWithText(TextField, 'Название блюда');
    await tester.ensureVisible(nameField);
    await tester.enterText(nameField, 'Готовая гречка');
    final addIngredient = find.widgetWithText(TextButton, 'Добавить');
    await tester.ensureVisible(addIngredient);
    await tester.tap(addIngredient);
    await tester.pumpAndSettle();
    final search = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Поиск продукта',
    );
    await tester.enterText(search, 'гречка');
    await tester.pumpAndSettle();
    final results = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(ListTile),
    );
    expect(results, findsWidgets);
    await tester.tap(results.first);
    await tester.pumpAndSettle();
    final mass = find.widgetWithText(TextField, 'Масса');
    await tester.ensureVisible(mass);
    await tester.enterText(mass, 'NaN');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Добавить').last);
    await tester.pump();
    expect(find.textContaining('Введите массу больше 0'), findsOneWidget);
    await tester.enterText(mass, '123,456');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Добавить').last);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Создать').last);
      await provider.storage.pendingMutations;
    });
    await tester.pumpAndSettle();
    expect(provider.recipes.single.name, 'Готовая гречка');
    expect(provider.recipes.single.ingredients.single.grams, 123.456);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recipe deletion needs confirmation and keeps the diary entry', (
    tester,
  ) async {
    final recipe = fixture();
    await tester.runAsync(() async {
      await provider.addRecipe(recipe);
      await provider.addRecipeToMeal(recipe, 100, MealType.lunch);
    });
    final before = provider.storage.local.getString('food_entries_2026-10-25');
    await openEditor(tester, provider.recipes.single, const Size(320, 740));
    await tester.runAsync(() => tester.tap(find.text('Удалить').first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена').last);
    await tester.pumpAndSettle();
    expect(provider.recipes, hasLength(1));
    await tester.runAsync(() => tester.tap(find.text('Удалить').first));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Удалить').last));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => provider.storage.pendingMutations);
    await tester.pumpAndSettle();
    expect(provider.recipes, isEmpty);
    expect(provider.storage.local.getString('food_entries_2026-10-25'), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale editor cannot overwrite newer recipe or delete it', (
    tester,
  ) async {
    await tester.runAsync(() => provider.addRecipe(fixture()));
    await openEditor(tester, provider.recipes.single, const Size(390, 844));
    final original = provider.recipes.single;
    await tester.runAsync(
      () => provider.updateRecipe(original.copyWith(name: 'Новая версия')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить').last);
      await provider.storage.pendingMutations;
    });
    await tester.pump();
    expect(find.textContaining('Список рецептов изменился'), findsOneWidget);
    expect(provider.recipes.single.name, 'Новая версия');
    await tester.runAsync(() => tester.tap(find.text('Удалить').first));
    await tester.pumpAndSettle();
    expect(find.textContaining('порции останутся'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('Удалить').last));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => provider.storage.pendingMutations);
    await tester.pump();
    expect(provider.recipes.single.name, 'Новая версия');
    expect(find.textContaining('Список рецептов изменился'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
