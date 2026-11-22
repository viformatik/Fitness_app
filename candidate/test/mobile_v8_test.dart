import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/catalog_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/mobile_extras.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final target = DateTime(2026, 10, 28);
  final previous = DateTime(2026, 10, 27);
  late AppDataProvider p;

  FoodEntry sourceEntry() => FoodEntry(
    name: 'Творог местный',
    caloriesPer100g: 101.5,
    proteinPer100g: 12.5,
    fatPer100g: 4.2,
    carbsPer100g: 2.1,
    amountGrams: 125.5,
    mealType: MealType.lunch,
    date: previous,
    loggedAt: DateTime(2026, 10, 27, 13, 25),
    micros: const {'calcium': 120, 'fiber': 0},
  );

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
    await p.setSelectedDate(target);
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    p.dispose();
  });

  test(
    'Повтор создаёт новые ID, сохраняет порцию, БЖУ и микроэлементы, но не выдумывает время',
    () {
      final original = sourceEntry();
      final copy = makePreviousDayCopies([original], target).single;
      expect(copy.id, isNot(original.id));
      expect(copy.name, original.name);
      expect(copy.caloriesPer100g, 101.5);
      expect(copy.proteinPer100g, 12.5);
      expect(copy.fatPer100g, 4.2);
      expect(copy.carbsPer100g, 2.1);
      expect(copy.amountGrams, 125.5);
      expect(copy.mealType, MealType.lunch);
      expect(copy.micros, {'calcium': 120, 'fiber': 0});
      expect(copy.micros.containsKey('vitaminD'), isFalse);
      expect(dayKey(copy.date), dayKey(target));
      expect(copy.timeKnown, isFalse);
      expect(dayKey(original.date), dayKey(previous));
      expect(original.timeKnown, isTrue);
    },
  );

  test(
    'Вода: быстрые изменения записываются последовательно, ошибка восстанавливает данные',
    () async {
      await Future.wait([
        p.addWater(250),
        p.addWater(500),
        p.setWaterIntake(500),
      ]);
      expect(p.todayWaterIntake, 500);
      await p.refresh();
      expect(p.todayWaterIntake, 500);
      expect(p.dayLogs.single.water, 500);
      LocalPreferences.rejectWriteKeyForTests =
          'water_intake_${dayKey(target)}';
      await p.addWater(250);
      expect(p.todayWaterIntake, 500);
      expect(p.persistenceError, contains('не сохранено'));
      expect(await p.storage.getWaterIntake(target), 500);
    },
  );

  test('Отмена копий не удаляет изменённые пользователем записи', () async {
    final copies = makePreviousDayCopies([sourceEntry()], target);
    await p.addFoodEntriesBatch(copies);
    await p.updateFoodEntry(copies.single.copyWith(amountGrams: 200));
    await expectLater(p.undoFoodEntriesBatch(copies), throwsStateError);
    await p.refresh();
    expect(p.todayFoodEntries.single.amountGrams, 200);
  });

  testWidgets(
    'Повтор показывает содержимое до записи, добавляет к текущему дню и отменяется',
    (tester) async {
      await tester.runAsync(() async {
        await p.addFoodEntry(sourceEntry());
        await p.addFoodEntry(
          FoodEntry(
            name: 'Уже в дневнике',
            caloriesPer100g: 50,
            proteinPer100g: 1,
            fatPer100g: 1,
            carbsPer100g: 1,
            amountGrams: 100,
            mealType: MealType.breakfast,
            date: target,
          ),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: RepeatPreviousDay(provider: p)),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Повторить предыдущий день'));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(find.text('Повторить питание?'), findsOneWidget);
      expect(find.textContaining('Творог местный · 125.5 г'), findsOneWidget);
      expect(p.todayFoodEntries, hasLength(1));
      await tester.runAsync(() async {
        await tester.tap(find.text('Отмена'));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries, hasLength(1));
      await tester.runAsync(() async {
        await tester.tap(find.text('Повторить предыдущий день'));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Добавить копии'));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries, hasLength(2));
      expect(p.todayFoodEntries.any((e) => e.name == 'Уже в дневнике'), isTrue);
      final copied = p.todayFoodEntries.singleWhere(
        (e) => e.name == 'Творог местный',
      );
      expect(copied.micros['calcium'], 120);
      expect(copied.timeKnown, isFalse);
      expect(
        await tester.runAsync(() => p.storage.getFoodEntries(previous)),
        hasLength(1),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Отменить'));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries.map((e) => e.name).toList(), [
        'Уже в дневнике',
      ]);
      expect(
        await tester.runAsync(() => p.storage.getFoodEntries(previous)),
        hasLength(1),
      );
    },
  );

  testWidgets('Ошибка записи повторного дня не создаёт частичного набора', (
    tester,
  ) async {
    await tester.runAsync(() => p.addFoodEntry(sourceEntry()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: RepeatPreviousDay(provider: p)),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Повторить предыдущий день'));
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
    await tester.pumpAndSettle();
    LocalPreferences.rejectWriteKeyForTests = 'food_entries_${dayKey(target)}';
    await tester.runAsync(() async {
      await tester.tap(find.text('Добавить копии'));
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
    await tester.pumpAndSettle();
    expect(p.todayFoodEntries, isEmpty);
    expect(
      await tester.runAsync(() => p.storage.getFoodEntries(target)),
      isEmpty,
    );
    expect(
      await tester.runAsync(() => p.storage.getFoodEntries(previous)),
      hasLength(1),
    );
    expect(find.textContaining('Не удалось повторить питание'), findsOneWidget);
  });

  testWidgets(
    'Каталог виден на 320×568 и с клавиатурой; быстрый фильтр не перезаписывается старым поиском',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(home: FoodCatalogScreen(provider: p)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Каталог ПМР и СНГ'), findsOneWidget);
      expect(find.textContaining('Найдено 186'), findsOneWidget);
      expect(find.textContaining('Батон "Витебский"'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final search = find.byType(TextField).first;
      await tester.ensureVisible(find.text('ТХК'));
      await tester.pumpAndSettle();
      await tester.enterText(search, 'БМК');
      // The queued debounce must not overwrite the explicit producer tap.
      await tester.tap(find.text('ТХК'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'ТХК');
      expect(find.textContaining('Найдено 94'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Найдено 94'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Фильтры каталога'));
      await tester.pumpAndSettle();
      expect(find.text('Фильтры каталога'), findsOneWidget);
      await tester.drag(find.byType(ListView).last, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('Молоко по жирности'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'На телефоне поиск и выбор порции доступны в полноэкранном окне',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) =>
                      AddFoodDialog(provider: p, mealType: MealType.breakfast),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Каталог ПМР и СНГ'), findsOneWidget);
      expect(find.text('ТХК'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).first, 'Витебский');
      await tester.pumpAndSettle();
      expect(find.text('Батон "Витебский"'), findsOneWidget);
      await tester.tap(find.text('Батон "Витебский"'));
      await tester.pumpAndSettle();
      expect(find.textContaining('официальному каталогу ТХК'), findsOneWidget);
      expect(find.text('Добавить в дневник'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).last, '150');
      await tester.runAsync(() async {
        await tester.tap(find.text('Добавить в дневник'));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries.single.name, 'Батон "Витебский"');
      expect(p.todayFoodEntries.single.amountGrams, 150);
      expect(p.todayCaloriesConsumed, 276);
      expect(
        await tester.runAsync(() => p.storage.getFoodEntries(target)),
        hasLength(1),
      );
    },
  );
}
