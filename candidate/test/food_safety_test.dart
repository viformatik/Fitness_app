import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/food_guard.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart' show editPortion;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

FoodEntry food(DateTime day, {String id = 'food-a', double grams = 100}) =>
    FoodEntry(
      id: id,
      name: 'Синтетический продукт $id',
      caloriesPer100g: 120.5,
      proteinPer100g: 10.25,
      fatPer100g: 2.5,
      carbsPer100g: 12.75,
      amountGrams: grams,
      mealType: MealType.breakfast,
      date: day,
      loggedAt: DateTime(day.year, day.month, day.day, 8),
      micros: {'vitaminC': 3.5, 'iron': 1.25},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 25);
  final key = 'food_entries_${dayKey(day)}';
  late AppDataProvider p;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
    await p.setSelectedDate(day);
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    p.dispose();
  });

  test(
    'an edit submitted during an import is rejected until an explicit retry',
    () async {
      await p.storage.addFoodEntry(food(day, id: 'before-import'));
      final imported = jsonEncode([food(day, id: 'from-backup').toJson()]);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (written) async {
        if (written == key && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final importing = p.storage.importData({
        'data': {key: imported},
      });
      await started.future;
      final stale = expectLater(
        p.storage.addFoodEntry(food(day, id: 'after-import')),
        throwsStateError,
      );
      release.complete();
      expect(await importing, isTrue);
      await stale;
      expect((await p.storage.getFoodEntries(day)).map((e) => e.id), [
        'from-backup',
      ]);
      await p.storage.addFoodEntry(food(day, id: 'after-import'));
      expect((await p.storage.getFoodEntries(day)).map((e) => e.id), [
        'from-backup',
        'after-import',
      ]);
      LocalPreferences.beforeWriteForTests = null;
    },
  );

  test(
    'targeted edits preserve other rows and unchanged numeric tokens',
    () async {
      const precise =
          r'{"id":"precise","name":"Еда","caloriesPer100g":120.123456789123456789,"proteinPer100g":10,"fatPer100g":2,"carbsPer100g":3,"amountGrams":100.123456789123456789,"mealType":0,"date":"2026-10-25T00:00:00.123456789","loggedAt":"2026-10-25T08:00:00.123456789","timeKnown":true,"micros":{"vitaminC":3.25,"iron":1.123456789123456789}}';
      final other = jsonEncode(food(day, id: 'other').toJson());
      await p.storage.local.setString(key, '[ $precise, $other ]');
      await p.reloadAll();
      final entry = p.todayFoodEntries.first;
      final snapshot = p.captureFoodEdit(entry);
      await p.updateFoodEntry(
        entry.copyWith(
          amountGrams: 150.25,
          micros: {...entry.micros, 'vitaminC': 4.5},
        ),
        snapshot: snapshot,
      );
      final raw = p.storage.local.getString(key)!;
      expect(raw, contains(other));
      expect(raw, contains('"caloriesPer100g":120.123456789123456789'));
      expect(raw, contains('"iron":1.123456789123456789'));
      expect(raw, contains('2026-10-25T00:00:00.123456789'));
      expect(raw, contains('2026-10-25T08:00:00.123456789'));
      expect(raw, contains('"amountGrams":150.25'));
      expect(raw, contains('"vitaminC":4.5'));
      await p.reloadAll();
      expect(p.todayFoodEntries, hasLength(2));
      expect(p.todayFoodEntries.first.amountGrams, 150.25);
    },
  );

  test(
    'unknown fields, nutrients, duplicate IDs and duplicate JSON keys block all writes',
    () async {
      final base = food(day).toJson();
      final examples = [
        jsonEncode([
          {
            ...base,
            'futureField': {'keep': true},
          },
        ]),
        jsonEncode([
          {
            ...base,
            'micros': {'vitaminC': 1, 'futureVitamin': 7},
          },
        ]),
        jsonEncode([base, base]),
        '[${jsonEncode(base).replaceFirst('"id":"food-a"', '"id":"food-a","i\\u0064":"other"')}]',
        '[${jsonEncode(base).replaceFirst('"micros":{', '"micros":{"iron":2,')}]',
      ];
      for (final raw in examples) {
        await p.storage.local.setString(key, raw);
        await p.reloadAll();
        final visible = p.todayFoodEntries.first;
        final snapshot = p.captureFoodEdit(visible);
        await expectLater(
          p.addFoodEntry(food(day, id: 'new')),
          throwsA(isA<FoodEditException>()),
        );
        await expectLater(
          p.updateFoodEntry(
            visible.copyWith(amountGrams: 200),
            snapshot: snapshot,
          ),
          throwsA(isA<FoodEditException>()),
        );
        await expectLater(
          p.deleteFoodEntry(visible.id, snapshot: snapshot),
          throwsA(isA<FoodEditException>()),
        );
        expect(p.storage.local.getString(key), raw);
      }
    },
  );

  test(
    'stale editor and stale day confirmation cannot remove newer food',
    () async {
      final first = food(day);
      await p.addFoodEntry(first);
      final editor = p.captureFoodEdit(p.todayFoodEntries.single);
      final clearing = p.captureFoodDay();
      await p.storage.addFoodEntry(food(day, id: 'new'));
      final after = p.storage.local.getString(key);
      await expectLater(
        p.updateFoodEntry(first.copyWith(amountGrams: 200), snapshot: editor),
        throwsA(isA<FoodEditException>()),
      );
      await expectLater(
        p.deleteFoodEntry(first.id, snapshot: editor),
        throwsA(isA<FoodEditException>()),
      );
      await expectLater(
        p.clearFoodForSelectedDay(snapshot: clearing),
        throwsA(isA<FoodEditException>()),
      );
      expect(p.storage.local.getString(key), after);
      expect((await p.storage.getFoodEntries(day)).map((e) => e.id), [
        'food-a',
        'new',
      ]);
    },
  );

  test(
    'failed add, edit, delete and clear do not mutate displayed or durable food',
    () async {
      await p.addFoodEntry(food(day));
      final initial = p.storage.local.getString(key);
      final original = p.todayFoodEntries.single;
      final snapshot = p.captureFoodEdit(original);
      final daySnapshot = p.captureFoodDay();
      LocalPreferences.rejectWriteKeyForTests = key;
      await expectLater(p.addFoodEntry(food(day, id: 'new')), throwsStateError);
      await expectLater(
        p.updateFoodEntry(
          original.copyWith(amountGrams: 300),
          snapshot: snapshot,
        ),
        throwsStateError,
      );
      await expectLater(
        p.deleteFoodEntry(original.id, snapshot: snapshot),
        throwsStateError,
      );
      await expectLater(
        p.clearFoodForSelectedDay(snapshot: daySnapshot),
        throwsStateError,
      );
      expect(p.storage.local.getString(key), initial);
      expect(p.todayFoodEntries.single.amountGrams, 100);
      expect(p.persistenceError, contains('не сохранён'));
      LocalPreferences.rejectWriteKeyForTests = null;
      await p.updateFoodEntry(
        original.copyWith(amountGrams: 300),
        snapshot: snapshot,
      );
      expect(p.todayFoodEntries.single.amountGrams, 300);
    },
  );

  test(
    'quick-food failure is partial success and retry does not duplicate diary',
    () async {
      final entry = food(day);
      LocalPreferences.rejectWriteKeyForTests = 'quick_foods';
      await p.addFoodEntry(entry);
      expect(p.persistenceError, contains('Дневник сохранён'));
      expect(p.todayFoodEntries, hasLength(1));
      expect(
        (jsonDecode(p.storage.local.getString(key)!) as List),
        hasLength(1),
      );
      LocalPreferences.rejectWriteKeyForTests = null;
      await p.addFoodEntry(entry);
      expect(
        (jsonDecode(p.storage.local.getString(key)!) as List),
        hasLength(1),
      );
    },
  );

  test(
    'ambiguous high-precision records cannot be submitted to AI changes',
    () async {
      final base = jsonEncode(
        food(day).toJson(),
      ).replaceFirst('120.5', '120.123456789123456789');
      final raw = '[$base]';
      await p.storage.local.setString(key, raw);
      await p.reloadAll();
      final original = p.todayFoodEntries.single;
      await expectLater(
        p.storage.getFoodEntriesInRange(day, day),
        throwsA(isA<FoodEditException>()),
      );
      await expectLater(
        p.applyReviewedFoodChanges(
          date: day,
          expected: {original.id: original},
          changes: {original.id: null},
          additions: [],
        ),
        throwsA(isA<FoodEditException>()),
      );
      expect(p.storage.local.getString(key), raw);
    },
  );

  test(
    'same ID with different data is not silently treated as a retry',
    () async {
      final original = food(day);
      await p.addFoodEntry(original);
      final raw = p.storage.local.getString(key);
      await expectLater(
        p.addFoodEntry(food(day, grams: 222)),
        throwsA(isA<FoodEditException>()),
      );
      expect(p.storage.local.getString(key), raw);
      expect(p.todayFoodEntries.single.amountGrams, 100);
    },
  );

  testWidgets(
    'food editor waits for save and keeps an error visible on 320px',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => p.addFoodEntry(food(day)));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () =>
                    showFoodEditor(ctx, p, p.todayFoodEntries.single),
                child: const Text('Открыть редактор'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть редактор'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Вес порции, г',
      );
      await tester.enterText(field, '175,25');
      final initial = p.storage.local.getString(key);
      LocalPreferences.rejectWriteKeyForTests = key;
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить').last);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Редактировать продукт'), findsOneWidget);
      expect(
        find.textContaining('Не удалось изменить дневник'),
        findsOneWidget,
      );
      expect(p.storage.local.getString(key), initial);
      expect(p.todayFoodEntries.single.amountGrams, 100);
      LocalPreferences.rejectWriteKeyForTests = null;
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить').last);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Редактировать продукт'), findsNothing);
      expect(p.todayFoodEntries.single.amountGrams, 175.25);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('portion edit preserves typed value after an I/O failure', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => p.addFoodEntry(food(day)));
    final raw = p.storage.local.getString(key);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => editPortion(ctx, p, p.todayFoodEntries.single),
              child: const Text('Изменить порцию'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Изменить порцию'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '170,25');
    LocalPreferences.rejectWriteKeyForTests = key;
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Дневник не сохранён'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '170,25',
    );
    expect(p.storage.local.getString(key), raw);
    LocalPreferences.rejectWriteKeyForTests = null;
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Сохранить'), findsNothing);
    expect(p.todayFoodEntries.single.amountGrams, 170.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale editor refuses to overwrite a newer day', (tester) async {
    await tester.runAsync(() => p.addFoodEntry(food(day)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () =>
                  showFoodEditor(ctx, p, p.todayFoodEntries.single),
              child: const Text('Открыть редактор'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть редактор'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => p.storage.addFoodEntry(food(day, id: 'new')));
    final current = p.storage.local.getString(key);
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Дневник изменился'), findsOneWidget);
    expect(find.text('Редактировать продукт'), findsOneWidget);
    expect(p.storage.local.getString(key), current);
    expect((await p.storage.getFoodEntries(day)), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'new food remains in its editor on write failure and retries once',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) =>
                      AddFoodDialog(mealType: MealType.breakfast, provider: p),
                ),
                child: const Text('Добавить еду'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Добавить еду'));
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

      await fill('Название продукта', 'Синтетический сыр');
      await fill('Вес порции', '120');
      await fill('Ккал', '100,5');
      await fill('Б (г)', '12,5');
      await fill('Ж (г)', '3,2');
      await fill('У (г)', '4,1');
      LocalPreferences.rejectWriteKeyForTests = key;
      await tester.runAsync(() async {
        await tester.tap(find.text('Добавить в дневник'));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Не удалось сохранить продукт'),
        findsOneWidget,
      );
      expect(find.byType(AddFoodDialog), findsOneWidget);
      expect(p.storage.local.getString(key), isNull);
      LocalPreferences.rejectWriteKeyForTests = null;
      await tester.runAsync(() async {
        await tester.tap(find.text('Добавить в дневник'));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(find.byType(AddFoodDialog), findsNothing);
      expect(p.todayFoodEntries, hasLength(1));
      expect(p.todayFoodEntries.single.amountGrams, 120);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('food editor is scrollable in short landscape with a keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 320);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 150);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.runAsync(() => p.addFoodEntry(food(day)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () =>
                  showFoodEditor(ctx, p, p.todayFoodEntries.single),
              child: const Text('Открыть редактор'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть редактор'));
    await tester.pumpAndSettle();
    expect(find.text('Редактировать продукт'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('Сохранить'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'swipe deletion requires confirmation and failure leaves the card',
    (tester) async {
      await tester.runAsync(() => p.addFoodEntry(food(day)));
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer<AppDataProvider>(
                builder: (context, provider, _) => Column(
                  children: [
                    for (final entry in provider.todayFoodEntries)
                      FoodEntryCard(entry: entry, provider: provider),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = p.storage.local.getString(key);
      await tester.drag(find.byKey(const Key('food-a')), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Удалить продукт?'), findsOneWidget);
      await tester.tap(find.text('Отмена').last);
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries, hasLength(1));
      await tester.drag(find.byKey(const Key('food-a')), const Offset(-600, 0));
      await tester.pumpAndSettle();
      LocalPreferences.rejectWriteKeyForTests = key;
      await tester.runAsync(() async {
        await tester.tap(find.text('Удалить').last);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries, hasLength(1));
      expect(p.storage.local.getString(key), original);
      expect(find.byType(FoodEntryCard), findsOneWidget);
      LocalPreferences.rejectWriteKeyForTests = null;
      await tester.drag(find.byKey(const Key('food-a')), const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Удалить').last);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries, isEmpty);
      expect(p.storage.local.getString(key), '[]');
      expect(tester.takeException(), isNull);
    },
  );
}
