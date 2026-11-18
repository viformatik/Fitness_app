import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/home_simple.dart' show SimpleHomeScreen;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart' show SmartHub;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

FoodEntry food(DateTime date, double caloriesPer100g) => FoodEntry(
  name: 'Синтетический продукт',
  caloriesPer100g: caloriesPer100g,
  proteinPer100g: 0,
  fatPer100g: 0,
  carbsPer100g: 0,
  amountGrams: 100,
  mealType: MealType.snack,
  date: date,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;
  late DateTime today;
  late DateTime yesterday;
  late DateTime waterOnlyDay;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
    final now = DateTime.now();
    today = DateTime(now.year, now.month, now.day, 12);
    yesterday = DateTime(now.year, now.month, now.day - 1, 12);
    waterOnlyDay = DateTime(now.year, now.month, now.day - 2, 12);
    AppTheme.configure({});
  });

  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    provider.dispose();
    AppTheme.configure({});
  });

  test('import preserves excluded local AI state on success', () async {
    final local = provider.storage.local;
    final privateValues = <String, String>{
      '_ai_drafts_test': 'draft',
      '_ai_favorites_test': 'favorite',
      '_ai_consent_test': 'consent',
      '_ai_undo_test': 'undo',
    };
    for (final entry in privateValues.entries) {
      await local.setString(entry.key, entry.value);
    }
    final exported = await provider.storage.exportData();
    expect(
      (exported['data'] as Map).keys.where((k) => k.toString().startsWith('_')),
      isEmpty,
    );
    expect(await provider.storage.importData(exported), isTrue);
    for (final entry in privateValues.entries) {
      expect(local.getString(entry.key), entry.value, reason: entry.key);
    }
  });

  test(
    'import preserves excluded local AI state after a write fails',
    () async {
      final local = provider.storage.local;
      await local.setString('_ai_favorites_test', 'favorite');
      await local.setString('_ai_consent_test', 'consent');
      await provider.setWaterIntake(250);
      final old = local.snapshot();
      final failedKey = 'steps_${dayKey(yesterday)}';
      LocalPreferences.rejectWriteKeyForTests = failedKey;
      await expectLater(
        provider.storage.importData({
          'data': {failedKey: 123},
        }),
        throwsStateError,
      );
      expect(local.snapshot(), old);
      expect(local.getString('_ai_favorites_test'), 'favorite');
      expect(local.getString('_ai_consent_test'), 'consent');
    },
  );

  test(
    'fractional daily calories stay exact both immediately and after reload',
    () async {
      await provider.setSelectedDate(yesterday);
      await provider.addFoodEntry(food(yesterday, 100.4));
      var log = provider.dayLogs.firstWhere(
        (e) => dayKey(e.date) == dayKey(yesterday),
      );
      expect(log.calories, closeTo(100.4, 1e-9));
      final before = provider.storage.local.snapshot();
      await provider.reloadAll();
      log = provider.dayLogs.firstWhere(
        (e) => dayKey(e.date) == dayKey(yesterday),
      );
      expect(log.calories, closeTo(100.4, 1e-9));
      expect(provider.storage.local.snapshot(), before);
    },
  );

  test('presence flags survive explicit zeros, deletion and reload', () async {
    await provider.setSelectedDate(today);
    await provider.setWaterIntake(0);
    await provider.setSteps(0);
    final zero = food(today, 0);
    await provider.addFoodEntry(zero);
    var log = provider.dayLogs.firstWhere(
      (e) => dayKey(e.date) == dayKey(today),
    );
    expect(log.hasFoodRecord, isTrue);
    expect(log.hasWaterRecord, isTrue);
    expect(log.hasStepsRecord, isTrue);
    expect(log.calories, 0);
    await provider.deleteFoodEntry(zero.id);
    log = provider.dayLogs.firstWhere((e) => dayKey(e.date) == dayKey(today));
    expect(log.hasFoodRecord, isFalse);
    expect(log.hasWaterRecord, isTrue);
    expect(log.hasStepsRecord, isTrue);
    await provider.reloadAll();
    log = provider.dayLogs.firstWhere((e) => dayKey(e.date) == dayKey(today));
    expect(log.hasFoodRecord, isFalse);
    expect(log.hasWaterRecord, isTrue);
    expect(log.hasStepsRecord, isTrue);
    expect(log.water, 0);
    expect(log.steps, 0);
  });

  testWidgets(
    'food chart distinguishes no record from recorded zero and averages recorded days',
    (tester) async {
      final zero = food(today, 0);
      await tester.runAsync(() async {
        await provider.setSelectedDate(waterOnlyDay);
        await provider.setWaterIntake(200);
        await provider.setSelectedDate(yesterday);
        await provider.addFoodEntry(food(yesterday, 100.4));
        await provider.setSelectedDate(today);
        await provider.addFoodEntry(zero);
        await provider.reloadAll();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: ProgressScreen())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byType(BarChart), 300);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Среднее по 2 дн. с записью: 50 ккал'),
        findsOneWidget,
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      final bars = chart.data.barGroups;
      expect(bars[bars.length - 3].barRods, isEmpty); // only water, no food
      expect(bars[bars.length - 2].barRods.single.toY, closeTo(100.4, 1e-9));
      expect(bars.last.barRods.single.toY, 0); // explicitly recorded zero
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await provider.deleteFoodEntry(zero.id);
        await provider.reloadAll();
        expect((await provider.storage.getFoodEntries(today)), isEmpty);
      });
    },
  );

  testWidgets(
    'no measurements or profile must not show fictional weights or goals',
    (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: WeightScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Пока нет ни одной записи'), findsOneWidget);
      final richStrings = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .toList();
      expect(
        richStrings.any((s) => s.contains('85.9') || s.contains('75.0')),
        isFalse,
      );
    },
  );

  testWidgets(
    'first weight entry starts empty rather than with a fictional measurement',
    (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: WeightScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить вес').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('Добавить').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Введите вес больше 0'), findsOneWidget);
      expect(provider.weightEntries, isEmpty);
      await tester.enterText(find.byType(TextField).first, 'NaN');
      await tester.tap(find.text('Добавить').last);
      await tester.pumpAndSettle();
      expect(provider.weightEntries, isEmpty);
      await tester.enterText(find.byType(TextField).first, '86,5');
      await tester.runAsync(() async {
        await tester.tap(find.text('Добавить').last);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(provider.weightEntries.single.weight, 86.5);
    },
  );

  testWidgets('auto-created profile does not silently confirm a target', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await provider.addWeightEntry(WeightEntry(weight: 86, date: today));
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: const MaterialApp(home: WeightScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<WeightChart>(find.byType(WeightChart)).targetWeight,
      isNull,
    );
    expect(find.textContaining('Цель не подтверждена'), findsOneWidget);
    await tester.runAsync(
      () => provider.updateProfile(provider.profile.copyWith(targetWeight: 82)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<WeightChart>(find.byType(WeightChart)).targetWeight,
      82,
    );
  });

  testWidgets(
    'legacy target remains stored but unconfirmed until explicitly saved',
    (tester) async {
      await tester.runAsync(() async {
        final oldProfile = UserProfile(targetWeight: 78).toJson()
          ..remove('targetWeightConfirmed');
        await provider.storage.local.setString(
          'user_profile',
          jsonEncode(oldProfile),
        );
        await provider.storage.local.setString(
          'weight_entries',
          jsonEncode([WeightEntry(weight: 85, date: today).toJson()]),
        );
        await provider.reloadAll();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: WeightScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(provider.profile.targetWeight, 78); // the old value was not erased
      expect(
        tester.widget<WeightChart>(find.byType(WeightChart)).targetWeight,
        isNull,
      );
      expect(find.textContaining('Цель не подтверждена'), findsOneWidget);
      await tester.runAsync(
        () =>
            provider.updateProfile(provider.profile.copyWith(targetWeight: 78)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<WeightChart>(find.byType(WeightChart)).targetWeight,
        78,
      );
    },
  );

  test('a confirmation flag cannot invent a missing or invalid target', () {
    expect(
      UserProfile.fromJson({
        'targetWeightConfirmed': true,
      }).targetWeightConfirmed,
      isFalse,
    );
    expect(
      UserProfile.fromJson({
        'targetWeightConfirmed': true,
        'targetWeight': -1,
      }).targetWeightConfirmed,
      isFalse,
    );
    expect(
      UserProfile.fromJson({
        'targetWeightConfirmed': true,
        'targetWeight': 80,
      }).targetWeightConfirmed,
      isTrue,
    );
  });

  test(
    'weight goal confirmation survives reload but not an old-client rewrite',
    () async {
      await provider.updateProfile(provider.profile.copyWith(targetWeight: 83));
      expect(provider.profile.targetWeightConfirmed, isTrue);
      await provider.reloadAll();
      expect(provider.profile.targetWeightConfirmed, isTrue);
      final oldClientProfile =
          Map<String, dynamic>.from(
              provider.storage.local.decoded('user_profile') as Map,
            )
            ..remove('targetWeightConfirmed')
            ..['targetWeight'] = 81;
      await provider.storage.local.setString(
        'user_profile',
        jsonEncode(oldClientProfile),
      );
      await provider.reloadAll();
      expect(provider.profile.targetWeight, 81);
      expect(provider.profile.targetWeightConfirmed, isNull);
      await provider.updateProfile(
        provider.profile.copyWith(currentWeight: 82),
      );
      expect(provider.profile.targetWeightConfirmed, isNull);
    },
  );

  testWidgets(
    'weight goal can be confirmed from the existing settings screen',
    (tester) async {
      await tester.runAsync(
        () => provider.addWeightEntry(WeightEntry(weight: 86, date: today)),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: WeightScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Проверить цель'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Целевой вес'));
      await tester.tap(find.text('Целевой вес'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '82');
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить').last);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(provider.profile.targetWeightConfirmed, isTrue);
      expect(provider.profile.targetWeight, 82);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<WeightChart>(find.byType(WeightChart)).targetWeight,
        82,
      );
    },
  );

  testWidgets('weight gain target is not marked reached below goal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await provider.updateProfile(provider.profile.copyWith(targetWeight: 90));
      await provider.addWeightEntry(WeightEntry(weight: 80, date: yesterday));
      await provider.addWeightEntry(WeightEntry(weight: 85, date: today));
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: const MaterialApp(home: WeightScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Разница'), findsOneWidget);
    expect(find.text('Достигнуто'), findsNothing);
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('weight loss progress uses the signed direction', (tester) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await provider.updateProfile(provider.profile.copyWith(targetWeight: 80));
      await provider.addWeightEntry(WeightEntry(weight: 90, date: yesterday));
      await provider.addWeightEntry(WeightEntry(weight: 85, date: today));
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: const MaterialApp(home: WeightScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('50%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'weight chart start is the first real measurement, not a constant',
    (tester) async {
      await tester.runAsync(() async {
        await provider.addWeightEntry(
          WeightEntry(weight: 61.3, date: yesterday),
        );
        await provider.addWeightEntry(WeightEntry(weight: 62.8, date: today));
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: WeightScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final chart = tester.widget<WeightChart>(find.byType(WeightChart));
      expect(chart.startWeight, 61.3);
      expect(chart.entries.map((e) => e.weight), [61.3, 62.8]);
    },
  );

  testWidgets(
    'imported measurements without profile do not invent a goal line',
    (tester) async {
      await tester.runAsync(() async {
        await provider.storage.local.setString(
          'weight_entries',
          jsonEncode([
            WeightEntry(weight: 61.3, date: yesterday).toJson(),
            WeightEntry(weight: 62.8, date: today).toJson(),
          ]),
        );
        await provider.reloadAll();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: WeightScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final chart = tester.widget<WeightChart>(find.byType(WeightChart));
      expect(chart.startWeight, 61.3);
      expect(chart.targetWeight, isNull);
      expect(
        tester
            .widget<LineChart>(find.byType(LineChart))
            .data
            .lineBarsData
            .length,
        2,
      );
      expect(find.textContaining('Цель:'), findsNothing);
    },
  );

  test(
    'system theme keeps a legacy-readable theme and respects older-client edits',
    () {
      const settings = {
        'theme': 'dark',
        'themeFollowSystem': true,
        'systemThemeFallback': 'dark',
      };
      validateAppDocument('smart_settings', jsonEncode(settings));
      AppTheme.configure(settings, platformBrightness: Brightness.light);
      expect(AppTheme.darkTheme.brightness, Brightness.light);
      AppTheme.configure(settings, platformBrightness: Brightness.dark);
      expect(AppTheme.darkTheme.brightness, Brightness.dark);
      final fromOldClient = {...settings, 'theme': 'light'};
      expect(AppTheme.followsSystem(fromOldClient), isFalse);
      AppTheme.configure(fromOldClient, platformBrightness: Brightness.dark);
      expect(AppTheme.darkTheme.brightness, Brightness.light);
      expect(
        () => validateAppDocument(
          'smart_settings',
          jsonEncode({...settings, 'themeFollowSystem': 'yes'}),
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'system theme responds to device changes without altering the stored manual fallback',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.runAsync(
        () => provider.updateSmartSettings({
          'theme': 'oled',
          'themeFollowSystem': true,
          'systemThemeFallback': 'oled',
        }),
      );
      await tester.pumpWidget(MyApp(provider: provider));
      await tester.pumpAndSettle();
      expect(AppTheme.darkTheme.brightness, Brightness.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(AppTheme.darkTheme.brightness, Brightness.light);
      expect(provider.smartSettings['theme'], 'oled');
      expect(provider.smartSettings['themeFollowSystem'], isTrue);
      // The day tip can move quick actions below the lazy ListView's fold.
      await tester.scrollUntilVisible(
        find.text('Добавить еду'),
        200,
        scrollable: find.descendant(
          of: find.byType(SimpleHomeScreen),
          matching: find.byType(Scrollable),
        ).first,
      );
      expect(find.text('Добавить еду'), findsOneWidget);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(AppTheme.darkTheme.brightness, Brightness.dark);
    },
  );

  testWidgets(
    'appearance controls select system and manual theme while keeping legacy values',
    (tester) async {
      await tester.runAsync(
        () => provider.updateSmartSettings({'theme': 'oled'}),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: SmartHub()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Системная'), 350);
      await tester.tap(find.text('Системная'));
      await tester.pumpAndSettle();
      expect(provider.smartSettings['theme'], 'oled');
      expect(provider.smartSettings['themeFollowSystem'], isTrue);
      expect(provider.smartSettings['systemThemeFallback'], 'oled');
      await tester.tap(find.text('Светлая'));
      await tester.pumpAndSettle();
      expect(provider.smartSettings['theme'], 'light');
      expect(provider.smartSettings['themeFollowSystem'], isFalse);
    },
  );

  testWidgets('desktop rail and mobile bar share the selected existing page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MyApp(provider: provider));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.text('Дневник'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      1,
    );
    final diaryElementBeforeResize = tester.element(
      find.byType(NutritionScreen),
    );
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(NavigationRail), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    expect(
      tester.widget<PageView>(find.byType(PageView).first).controller!.page,
      1,
    );
    expect(
      tester.element(find.byType(NutritionScreen)),
      same(diaryElementBeforeResize),
    );
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      1,
    );
    expect(
      tester.widget<PageView>(find.byType(PageView).first).controller!.page,
      1,
    );
    expect(
      tester.element(find.byType(NutritionScreen)),
      same(diaryElementBeforeResize),
    );
    await tester.tap(find.text('Ещё').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Всё остальное — здесь'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape rail is scrollable without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MyApp(provider: provider));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).scrollable,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px home labels remain visible without ellipsis', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MyApp(provider: provider));
    await tester.pumpAndSettle();
    for (final label in [
      'Нет записей',
      'Не записана',
      'Не записаны',
      'Вода +250 мл',
    ]) {
      final finder = find.text(label);
      if (finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          finder,
          200,
          scrollable: find.descendant(
            of: find.byType(SimpleHomeScreen),
            matching: find.byType(Scrollable),
          ).first,
        );
      }
      expect(finder, findsWidgets, reason: 'Missing $label');
      final text = tester.widget<Text>(finder.first);
      expect(text.overflow, isNot(TextOverflow.ellipsis), reason: label);
    }
    expect(tester.takeException(), isNull);
  });
}
