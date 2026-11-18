import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/catalog_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/lossless_json.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic values include future fields and numeric spellings whose exact
// source tokens must not be reconstructed through a JavaScript double.
const original =
    '[{"name":"Йогурт Fresh","caloriesPer100g":123.4500,'
    '"proteinPer100g":5.000,"fatPer100g":2.0,"carbsPer100g":7.0,'
    '"micros":{"calcium":100.0000,"futureMicro":1.234567890123456789},'
    '"futureField":{"serial":9007199254740993123456789}},'
    '{"name":"Другой продукт","caloriesPer100g":20.5000,'
    '"proteinPer100g":1,"fatPer100g":2,"carbsPer100g":3,'
    '"unrecognized":9007199254740993123456789}]';

FoodItem catalogFood(String name) => FoodItem(
  name,
  50,
  2,
  1,
  8,
  const {'calcium': 50},
  'Молочные продукты',
  'Продукция ПМР',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;
  late LocalPreferences local;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
    local = provider.storage.local;
    await local.setString('custom_foods', original);
  });

  tearDown(() {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    provider.dispose();
  });

  test(
    'pinning preserves every existing raw row; duplicate never overwrites',
    () async {
      await provider.saveCustomFood(catalogFood('Молоко местное'));
      final saved = local.getString('custom_foods')!;
      final beforeRows = rawJsonArrayElements(original);
      final afterRows = rawJsonArrayElements(saved);
      expect(afterRows, hasLength(3));
      expect(jsonDecode(afterRows.first)['name'], 'Молоко местное');
      expect(afterRows.skip(1).toList(), beforeRows);

      await expectLater(
        provider.saveCustomFood(catalogFood('ЙОГУРТ FRESH')),
        throwsA(isA<StateError>()),
      );
      expect(local.getString('custom_foods'), saved);
    },
  );

  test(
    'pinning does not overwrite a concurrent change to the custom database',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == 'custom_foods' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final competing = original.replaceFirst(
        'Другой продукт',
        'Обновлённый продукт',
      );
      final first = local.compareAndPut('custom_foods', original, competing);
      await entered.future;
      final pinResult = expectLater(
        provider.saveCustomFood(catalogFood('Молоко местное')),
        throwsA(isA<StateError>()),
      );
      release.complete();
      expect(await first, isTrue);
      await pinResult;
      expect(local.getString('custom_foods'), competing);
    },
  );

  test(
    'pinning rejects a stale diary generation even when the document matches',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == 'custom_foods' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      // Occupy the same queue without changing the expected document.
      final first = local.compareAndPut('custom_foods', original, original);
      await entered.future;
      final pinResult = expectLater(
        provider.saveCustomFood(catalogFood('Молоко местное')),
        throwsA(isA<StateError>()),
      );
      await local.setString(
        LocalPreferences.diaryGenerationKey,
        'new-generation',
      );
      release.complete();
      expect(await first, isTrue);
      await pinResult;
      expect(local.getString('custom_foods'), original);
    },
  );

  test(
    'pinning refuses duplicate JSON keys without modifying the document',
    () async {
      final ambiguous = original.replaceFirst(
        '"name":"Йогурт Fresh"',
        '"name":"Йогурт Fresh","name":"Другое название"',
      );
      await local.setString('custom_foods', ambiguous);
      await expectLater(
        provider.saveCustomFood(catalogFood('Молоко местное')),
        throwsA(isA<StateError>()),
      );
      expect(local.getString('custom_foods'), ambiguous);
    },
  );

  testWidgets(
    'mixed names are hidden; explicit rename preserves the raw records',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: FoodCatalogScreen(provider: provider, initialQuery: 'Fresh'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Йогурт Fresh'), findsNothing);
      expect(find.text('Скрыто названий: 1'), findsOneWidget);
      expect(local.getString('custom_foods'), original);
      await tester.tap(find.text('Скрыто названий: 1'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Личные записи и избранное не удалены'),
        findsOneWidget,
      );
      await tester.tap(find.text('Понятно'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CustomFoodPanel(provider: provider),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Йогурт Fresh'), findsOneWidget);
      await tester.tap(find.text('Йогурт Fresh'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Йогурт свежий');
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      final after = rawJsonArrayElements(local.getString('custom_foods')!);
      final before = rawJsonArrayElements(original);
      expect(after[0], patchJsonObject(before[0], {'name': 'Йогурт свежий'}));
      expect(after[1], before[1]);
      expect(after[0], contains('1.234567890123456789'));
      expect(after[0], contains('9007199254740993123456789'));

      await tester.pumpWidget(
        MaterialApp(
          home: FoodCatalogScreen(
            provider: provider,
            initialQuery: 'Йогурт свежий',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Йогурт свежий'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'editing a known micronutrient retains unknown raw micronutrients',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CustomFoodPanel(provider: provider),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Йогурт Fresh'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Микронутриенты:'));
      await tester.pumpAndSettle();
      final calcium = find.widgetWithText(TextFormField, 'Кальций, мг');
      await tester.ensureVisible(calcium);
      await tester.enterText(calcium, '125.25');
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      final after = rawJsonArrayElements(local.getString('custom_foods')!);
      final before = rawJsonArrayElements(original);
      expect(after[1], before[1]);
      final microToken = rawJsonObjectValue(after[0], 'micros')!;
      expect(microToken, contains('"futureMicro":1.234567890123456789'));
      expect(jsonDecode(microToken)['calcium'], 125.25);
      expect(after[0], contains('"serial":9007199254740993123456789'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'renaming to an existing custom name is rejected without a write',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CustomFoodPanel(provider: provider),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Йогурт Fresh'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        '  ДРУГОЙ ПРОДУКТ  ',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Такой продукт уже есть'), findsOneWidget);
      expect(local.getString('custom_foods'), original);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ambiguous custom database is shown read-only and not rewritten',
    (tester) async {
      final ambiguous = original.replaceFirst(
        '"name":"Йогурт Fresh"',
        '"name":"Йогурт Fresh","name":"Другое название"',
      );
      await tester.runAsync(() => local.setString('custom_foods', ambiguous));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CustomFoodPanel(provider: provider)),
        ),
      );
      expect(
        find.textContaining('не удалось безопасно прочитать'),
        findsOneWidget,
      );
      expect(find.byTooltip('Удалить из своей базы'), findsNothing);
      expect(local.getString('custom_foods'), ambiguous);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('removing one custom item retains every other source row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CustomFoodPanel(provider: provider),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Удалить из своей базы').first);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(rawJsonArrayElements(local.getString('custom_foods')!), [
      rawJsonArrayElements(original)[1],
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('diary product picker hides mixed names without deleting them', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AddFoodDialog(
                  provider: provider,
                  mealType: MealType.breakfast,
                ),
              ),
              child: const Text('Открыть выбор'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть выбор'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Fresh');
    await tester.pumpAndSettle();
    expect(find.text('Йогурт Fresh'), findsNothing);
    expect(find.textContaining('Названия с латиницей скрыты'), findsOneWidget);
    expect(local.getString('custom_foods'), original);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'mixed recent and favorite shortcuts remain stored but are hidden',
    (tester) async {
      final quick = jsonEncode([
        {
          'name': 'Йогурт Fresh',
          'caloriesPer100g': 123.45,
          'proteinPer100g': 5,
          'fatPer100g': 2,
          'carbsPer100g': 7,
          'grams': 100,
          'mealType': MealType.breakfast.index,
          'lastUsed': '2026-10-25T08:00:00.000',
          'favorite': true,
          'futureField': 'kept',
        },
      ]);
      await tester.runAsync(() async {
        await local.setString('quick_foods', quick);
        await provider.refresh();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AddFoodDialog(
                    provider: provider,
                    mealType: MealType.breakfast,
                  ),
                ),
                child: const Text('Открыть выбор'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть выбор'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Йогурт Fresh ·'), findsNothing);
      await tester.tap(find.text('Избранное'));
      await tester.pumpAndSettle();
      expect(find.text('Йогурт Fresh'), findsNothing);
      expect(
        find.textContaining('Названия с латиницей скрыты'),
        findsOneWidget,
      );
      expect(local.getString('quick_foods'), quick);
      expect(local.getString('custom_foods'), original);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ingredient search hides mixed names without touching custom foods',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AddRecipeDialog(provider: provider),
                ),
                child: const Text('Открыть рецепт'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть рецепт'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Поиск продукта',
      );
      expect(search, findsOneWidget);
      await tester.enterText(search, 'Fresh');
      await tester.pumpAndSettle();
      expect(find.text('Йогурт Fresh'), findsNothing);
      expect(
        find.textContaining('Скрыто названий с латиницей:'),
        findsOneWidget,
      );
      expect(local.getString('custom_foods'), original);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
