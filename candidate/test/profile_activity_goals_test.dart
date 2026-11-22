import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart'
    show BadgePanel, DailyBalanceCard, FluidWaterCard, MacroTrendPanel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider p;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    p.dispose();
  });

  test(
    'fresh water and steps goals are unknown and do not write defaults',
    () async {
      expect(p.storage.local.getString('user_profile'), isNull);
      expect(p.profile.dailyWaterGoalMl, isNull);
      expect(p.profile.dailyStepsGoal, isNull);
      expect(p.confirmedWaterGoal, isNull);
      expect(p.confirmedStepsGoal, isNull);
      await p.setWaterIntake(0);
      await p.setSteps(0);
      expect(p.hasRecordedWater, isTrue);
      expect(p.hasRecordedSteps, isTrue);
      expect(p.waterProgress, isNull);
      expect(p.stepsProgress, isNull);
      expect(p.storage.local.getString('user_profile'), isNull);
    },
  );

  test(
    'legacy numbers are preserved read-only and stay unconfirmed on unrelated edits',
    () async {
      const raw =
          '{"dailyWaterGoalMl":2500,"dailyStepsGoal":10000,"height":180}';
      await p.storage.local.setString('user_profile', raw);
      await p.reloadAll();
      expect(p.storage.local.getString('user_profile'), raw);
      expect(p.profile.dailyWaterGoalMl, 2500);
      expect(p.profile.dailyStepsGoal, 10000);
      expect(p.confirmedWaterGoal, isNull);
      expect(p.confirmedStepsGoal, isNull);
      await p.updateProfile(p.profile.copyWith(ageYears: 24));
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(saved['dailyWaterGoalMl'], 2500);
      expect(saved['dailyStepsGoal'], 10000);
      expect(saved['waterGoalConfirmed'], isFalse);
      expect(saved['stepsGoalConfirmed'], isFalse);
      await p.reloadAll();
      expect(p.confirmedWaterGoal, isNull);
      expect(p.confirmedStepsGoal, isNull);
    },
  );

  test(
    'explicitly reviewing old values binds snapshots and survives reload',
    () async {
      await p.storage.local.setString(
        'user_profile',
        '{"dailyWaterGoalMl":2500,"dailyStepsGoal":10000}',
      );
      await p.reloadAll();
      await p.updateProfile(
        p.profile.copyWith(dailyWaterGoalMl: 2500, dailyStepsGoal: 10000),
      );
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(saved['waterGoalConfirmed'], isTrue);
      expect(saved['waterGoalConfirmedValue'], 2500);
      expect(saved['stepsGoalConfirmed'], isTrue);
      expect(saved['stepsGoalConfirmedValue'], 10000);
      await p.setWaterIntake(1250);
      await p.setSteps(5000);
      await p.reloadAll();
      expect(p.confirmedWaterGoal, 2500);
      expect(p.confirmedStepsGoal, 10000);
      expect(p.waterProgress, 0.5);
      expect(p.stepsProgress, 0.5);
    },
  );

  test(
    'missing, stale or stripped snapshots fail closed independently',
    () async {
      await p.updateProfile(
        p.profile.copyWith(dailyWaterGoalMl: 2200, dailyStepsGoal: 8000),
      );
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!)
              as Map<String, dynamic>;
      saved['dailyWaterGoalMl'] =
          2600; // simulated old writer kept stale snapshot
      await p.storage.local.setString('user_profile', jsonEncode(saved));
      await p.reloadAll();
      expect(p.profile.dailyWaterGoalMl, 2600);
      expect(p.confirmedWaterGoal, isNull);
      expect(p.confirmedStepsGoal, 8000);
      saved.remove('stepsGoalConfirmedValue');
      await p.storage.local.setString('user_profile', jsonEncode(saved));
      await p.reloadAll();
      expect(p.profile.dailyStepsGoal, 8000);
      expect(p.confirmedStepsGoal, isNull);
      await p.updateProfile(p.profile.copyWith(ageYears: 30));
      final normalized =
          jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(normalized['waterGoalConfirmed'], isFalse);
      expect(normalized['stepsGoalConfirmed'], isFalse);
      expect(normalized['dailyWaterGoalMl'], 2600);
      expect(normalized['dailyStepsGoal'], 8000);
    },
  );

  test(
    'a stale activity-goal edit is rejected without overwriting newer raw profile',
    () async {
      await p.updateProfile(p.profile.copyWith(dailyWaterGoalMl: 2200));
      const newer = '{"dailyWaterGoalMl":2700,"dailyStepsGoal":9000}';
      await p.storage.local.setString('user_profile', newer);
      await expectLater(
        p.updateProfile(p.profile.copyWith(dailyStepsGoal: 8000)),
        throwsA(isA<ProfileEditException>()),
      );
      expect(p.storage.local.getString('user_profile'), newer);
      expect(p.profile.dailyWaterGoalMl, 2700);
      expect(p.confirmedWaterGoal, isNull);
      expect(p.confirmedStepsGoal, isNull);
    },
  );

  test(
    'synthetic backup restores confirmed activity goals without changing recorded data',
    () async {
      await p.updateProfile(
        p.profile.copyWith(dailyWaterGoalMl: 2300, dailyStepsGoal: 8500),
      );
      await p.setWaterIntake(500);
      await p.setSteps(1234);
      final originalProfile = p.storage.local.getString('user_profile');
      final backup = await p.exportDataJson();
      await p.updateProfile(p.profile.copyWith(dailyWaterGoalMl: 2700));
      expect(await p.importDataJson(backup), isNull);
      await p.reloadAll();
      expect(p.storage.local.getString('user_profile'), originalProfile);
      expect(p.confirmedWaterGoal, 2300);
      expect(p.confirmedStepsGoal, 8500);
      expect(p.todayWaterIntake, 500);
      expect(p.todaySteps, 1234);
    },
  );

  test('workout credit changes only independently confirmed goals', () async {
    await p.updateProfile(p.profile.copyWith(targetProtein: 100));
    await p.updateSmartSettings({'adaptMacros': true});
    await p.addWorkoutEntry(
      WorkoutEntry(
        type: WorkoutType.strength,
        durationMinutes: 40,
        caloriesBurned: 200,
        date: p.selectedDate,
      ),
    );
    expect(p.todayWorkoutCalorieCredit, 200);
    expect(p.baseCaloriesTarget, isNull);
    expect(p.adjustedCaloriesTarget, isNull);
    expect(p.targetProteinToday, 120);
    expect(p.targetFatToday, isNull);
    expect(p.targetCarbsToday, isNull);
    await p.updateProfile(
      p.profile.copyWith(dailyCaloriesMin: 2000, dailyCaloriesMax: 2000),
    );
    expect(p.adjustedCaloriesTarget, 2200);
    expect(p.targetProteinToday, 120);
  });

  test(
    'quick workout requires explicitly supplied values, not old 500 kcal',
    () async {
      expect(p.todayWorkoutEntries, isEmpty);
      await p.quickAddWorkout(durationMinutes: 12, caloriesBurned: 0);
      expect(p.todayWorkoutEntries.single.durationMinutes, 12);
      expect(p.todayWorkoutEntries.single.caloriesBurned, 0);
      await p.reloadAll();
      expect(p.todayWorkoutEntries.single.caloriesBurned, 0);
    },
  );

  testWidgets(
    'water editor shows an old value for review and saves confirmation',
    (t) async {
      await t.runAsync(() async {
        await p.storage.local.setString(
          'user_profile',
          '{"dailyWaterGoalMl":2500}',
        );
        await p.reloadAll();
      });
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('Цель по воде'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text('Цель по воде'));
      await t.pumpAndSettle();
      expect(
        t.widget<TextField>(find.byType(TextField).last).controller!.text,
        '2500',
      );
      expect(find.textContaining('Прежнее значение сохранено'), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.text('Сохранить').last);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();
      expect(p.confirmedWaterGoal, 2500);
      expect(p.confirmedStepsGoal, isNull);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('water screens compare only after explicit confirmation', (
    t,
  ) async {
    await t.runAsync(() async {
      await p.storage.local.setString(
        'user_profile',
        '{"dailyWaterGoalMl":2500}',
      );
      await p.reloadAll();
      await p.setWaterIntake(1000);
    });
    await t.binding.setSurfaceSize(const Size(390, 1200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
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
                builder: (_, model, __) => Column(
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
    await t.pumpAndSettle();
    expect(find.textContaining('Вода по записям: 1000 мл'), findsOneWidget);
    expect(find.textContaining('цель не подтверждена'), findsWidgets);
    expect(find.textContaining('2500'), findsNothing);
    expect(find.textContaining('2 500'), findsNothing);
    await t.runAsync(
      () => p.updateProfile(p.profile.copyWith(dailyWaterGoalMl: 2500)),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('Вода: 1000 / 2500 мл'), findsOneWidget);
    expect(find.text('1000 / 2500 мл'), findsOneWidget);
    expect(find.text('1 000 / 2 500 мл'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('water streak remains locked until a goal is confirmed', (
    t,
  ) async {
    await t.runAsync(() async {
      final today = DateTime.now();
      for (var i = 0; i < 7; i++) {
        await p.setSelectedDate(today.subtract(Duration(days: i)));
        await p.setWaterIntake(5000);
      }
    });
    await t.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Consumer<AppDataProvider>(
                builder: (_, model, __) => BadgePanel(provider: model),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final tile = find.ancestor(
      of: find.text('Водный баланс: 7 дней подряд'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.lock_outline)),
      findsOneWidget,
    );
    await t.runAsync(
      () => p.updateProfile(p.profile.copyWith(dailyWaterGoalMl: 2500)),
    );
    await t.pumpAndSettle();
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.verified)),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('macro trend distinguishes missing goals from missed goals', (
    t,
  ) async {
    await t.runAsync(
      () => p.addFoodEntry(
        FoodEntry(
          name: 'Синтетическая запись',
          caloriesPer100g: 100,
          proteinPer100g: 10,
          fatPer100g: 5,
          carbsPer100g: 8,
          amountGrams: 100,
          mealType: MealType.breakfast,
          date: p.selectedDate,
        ),
      ),
    );
    await t.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Consumer<AppDataProvider>(
                builder: (_, model, __) => MacroTrendPanel(provider: model),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.textContaining('положительных подтверждённых целей 0 из 3'),
      findsOneWidget,
    );
    var tips = t
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((w) => w.message ?? '')
        .toList();
    expect(tips.any((m) => m.contains('нет доступных целей БЖУ')), isTrue);
    expect(tips.any((m) => m.contains('0/3 БЖУ')), isFalse);
    await t.runAsync(
      () => p.updateProfile(p.profile.copyWith(targetProtein: 100)),
    );
    await t.pumpAndSettle();
    expect(
      find.textContaining('положительных подтверждённых целей 1 из 3'),
      findsOneWidget,
    );
    tips = t
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((w) => w.message ?? '')
        .toList();
    expect(tips.any((m) => m.contains('0/1 доступных целей БЖУ')), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'fresh legacy workout dialog has no prefilled calories or duration',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AddWorkoutDialog(provider: p)),
        ),
      );
      await t.pumpAndSettle();
      final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.length, 3);
      expect(fields[0].controller!.text, isEmpty);
      expect(fields[1].controller!.text, isEmpty);
      await t.tap(find.text('Добавить'));
      await t.pumpAndSettle();
      expect(p.todayWorkoutEntries, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
}
