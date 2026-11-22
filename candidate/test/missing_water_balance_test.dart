import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 26);
  late AppDataProvider p;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
    await p.setSelectedDate(day);
  });

  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    p.dispose();
  });

  test(
    'missing, recorded zero and positive water stay distinct by day and reload',
    () async {
      final key = 'water_intake_${dayKey(day)}';
      expect(p.hasRecordedWater, isFalse);
      expect(p.storage.local.getKeys(), isNot(contains(key)));
      await p.setWaterIntake(0);
      expect(p.hasRecordedWater, isTrue);
      expect(p.todayWaterIntake, 0);
      expect(p.storage.local.getInt(key), 0);
      await p.setSelectedDate(day.add(const Duration(days: 1)));
      expect(p.hasRecordedWater, isFalse);
      await p.setSelectedDate(day);
      await p.reloadAll();
      expect(p.hasRecordedWater, isTrue);
      expect(p.todayWaterIntake, 0);
      await p.addWater(250);
      await p.reloadAll();
      expect(p.hasRecordedWater, isTrue);
      expect(p.todayWaterIntake, 250);
      expect(p.storage.local.getInt(key), 250);
    },
  );

  test('missing steps stay distinct from explicitly recorded zero', () async {
    expect(p.hasRecordedSteps, isFalse);
    await p.setSteps(0);
    expect(p.hasRecordedSteps, isTrue);
    expect(p.todaySteps, 0);
    await p.setSelectedDate(day.add(const Duration(days: 1)));
    expect(p.hasRecordedSteps, isFalse);
    await p.setSelectedDate(day);
    await p.reloadAll();
    expect(p.hasRecordedSteps, isTrue);
    expect(p.todaySteps, 0);
  });

  test(
    'failed first water write restores missing rather than recorded zero',
    () async {
      final key = 'water_intake_${dayKey(day)}';
      LocalPreferences.rejectWriteKeyForTests = key;
      await p.setWaterIntake(0);
      expect(p.persistenceError, contains('не сохранено'));
      expect(p.hasRecordedWater, isFalse);
      expect(p.storage.local.getKeys(), isNot(contains(key)));
    },
  );

  testWidgets(
    'water and balance screens distinguish missing data from zero on 320px',
    (tester) async {
      tester.view.physicalSize = const Size(320, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Consumer<AppDataProvider>(
                  builder: (context, model, _) => Column(
                    children: [
                      DailyBalanceCard(provider: model),
                      FluidWaterCard(provider: model),
                      WaterQuickCard(provider: model),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Питание за этот день не записано'), findsOneWidget);
      expect(find.textContaining('Вода за день не записана.'), findsOneWidget);
      expect(
        find.textContaining('Не записана · цель не подтверждена'),
        findsNWidgets(2),
      );
      expect(find.textContaining('Белки ещё'), findsNothing);
      expect(find.textContaining('2500'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.runAsync(() => p.setWaterIntake(0));
      await tester.pumpAndSettle();
      expect(find.textContaining('Вода по записям: 0 мл'), findsOneWidget);
      expect(find.text('0 мл · цель не подтверждена'), findsNWidgets(2));
      expect(
        find.textContaining('Не записана · цель не подтверждена'),
        findsNothing,
      );
      expect(find.textContaining('2500'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.runAsync(
        () => p.addFoodEntry(
          FoodEntry(
            id: 'explicit-zero-food',
            name: 'Синтетическая запись',
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            amountGrams: 100,
            mealType: MealType.breakfast,
            date: day,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('По записям: 0 ккал.'), findsOneWidget);
      expect(find.textContaining('До ориентира по записанному:'), findsNothing);
      expect(find.textContaining('Белки ещё'), findsNothing);
      expect(find.textContaining('Подтвердите цели'), findsOneWidget);
      expect(find.text('Питание за этот день не записано'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('quick actions show missing water and steps rather than zeros', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer<AppDataProvider>(
              builder: (_, model, __) => QuickActionButtons(provider: model),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Нет записи'), findsNWidgets(2));
    expect(find.text('0'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await p.setWaterIntake(0);
      await p.setSteps(0);
    });
    await tester.pump();
    expect(find.text('Нет записи'), findsNothing);
    expect(find.text('0'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'nutrition summary and detail do not invent calories for an empty day',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: const MaterialApp(home: NutritionScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Питание за этот день не записано'), findsOneWidget);
      expect(find.text('По записям · ориентир с тренировками'), findsNothing);
      await tester.tap(find.text('Питание за этот день не записано'));
      await tester.pumpAndSettle();
      expect(find.text('За этот день еда ещё не добавлена.'), findsOneWidget);
      expect(find.textContaining('по записям / ориентир'), findsNothing);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => p.addFoodEntry(
          FoodEntry(
            id: 'zero-in-nutrition',
            name: 'Синтетическая запись',
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            amountGrams: 100,
            mealType: MealType.breakfast,
            date: day,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('По записям · цель не подтверждена'), findsOneWidget);
      expect(find.text('По записям · ориентир с тренировками'), findsNothing);
      expect(find.text('Питание за этот день не записано'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'detailed dashboard avoids invented values and overflow at ${width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ChangeNotifierProvider<AppDataProvider>.value(
            value: p,
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: const Scaffold(body: DashboardScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Питание за этот день не записано.'), findsWidgets);
        expect(find.byType(CircularCalorieIndicator), findsNothing);
        expect(find.byType(MacroProgressBar), findsNothing);
        expect(find.text('ВЫБРАННЫЙ ДЕНЬ'), findsOneWidget);
        expect(find.text('Вес не подтверждён'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
