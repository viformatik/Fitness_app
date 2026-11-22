import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart' show DailyBalanceCard;
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
    p.dispose();
  });

  test(
    'empty profile does not turn inherited defaults into personal goals',
    () {
      expect(p.storage.local.getString('user_profile'), isNull);
      expect(p.baseCaloriesTarget, isNull);
      expect(p.adjustedCaloriesTarget, isNull);
      expect(p.caloriesRemaining, isNull);
      expect(p.targetProteinToday, isNull);
      expect(p.targetFatToday, isNull);
      expect(p.targetCarbsToday, isNull);
      expect(p.caloriesProgress, isNull);
    },
  );

  test(
    'old numeric values survive unchanged but are not automatically used',
    () async {
      const raw =
          '{"dailyCaloriesMin":1900,"dailyCaloriesMax":2100,"targetProtein":120,"targetFat":70,"targetCarbs":260,"height":181}';
      await p.storage.local.setString('user_profile', raw);
      await p.reloadAll();
      expect(p.profile.dailyCaloriesMin, 1900);
      expect(p.profile.targetProtein, 120);
      expect(p.storage.local.getString('user_profile'), raw);
      expect(p.baseCaloriesTarget, isNull);
      expect(p.targetProteinToday, isNull);
      expect(p.targetFatToday, isNull);
      expect(p.targetCarbsToday, isNull);
    },
  );

  test(
    'explicitly saving even the old defaults materializes and confirms only those fields',
    () async {
      await p.updateProfile(
        p.profile.copyWith(
          dailyCaloriesMin: 1750,
          dailyCaloriesMax: 1800,
          targetProtein: 150,
        ),
      );
      final raw = jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(raw['dailyCaloriesMin'], 1750);
      expect(raw['dailyCaloriesMax'], 1800);
      expect(raw['calorieGoalConfirmed'], isTrue);
      expect(raw['targetProtein'], 150);
      expect(raw['proteinGoalConfirmed'], isTrue);
      expect(raw.containsKey('targetFat'), isFalse);
      expect(raw.containsKey('targetCarbs'), isFalse);
      await p.reloadAll();
      expect(p.baseCaloriesTarget, 1775);
      expect(p.targetProteinToday, 150);
      expect(p.targetFatToday, isNull);
      expect(p.targetCarbsToday, isNull);
    },
  );

  test(
    'a confirmed zero macro is not a missing goal or a percentage',
    () async {
      await p.updateProfile(p.profile.copyWith(targetProtein: 0));
      await p.reloadAll();
      expect(p.targetProteinToday, 0);
      expect(p.proteinProgress, isNull);
      expect(p.targetFatToday, isNull);
    },
  );

  test('missing stored fields cannot be confirmed by flags alone', () async {
    await p.storage.local.setString(
      'user_profile',
      jsonEncode({
        'calorieGoalConfirmed': true,
        'proteinGoalConfirmed': true,
        'fatGoalConfirmed': true,
        'carbsGoalConfirmed': true,
      }),
    );
    await p.reloadAll();
    expect(p.baseCaloriesTarget, isNull);
    expect(p.targetProteinToday, isNull);
    expect(p.targetFatToday, isNull);
    expect(p.targetCarbsToday, isNull);
  });

  test(
    'loss of metadata by a simulated old client fails closed but keeps numbers',
    () async {
      await p.updateProfile(
        p.profile.copyWith(
          dailyCaloriesMin: 1900,
          dailyCaloriesMax: 2100,
          targetProtein: 120,
        ),
      );
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!)
              as Map<String, dynamic>;
      saved.remove('calorieGoalConfirmed');
      saved.remove('proteinGoalConfirmed');
      await p.storage.local.setString('user_profile', jsonEncode(saved));
      await p.reloadAll();
      expect(p.profile.dailyCaloriesMin, 1900);
      expect(p.profile.targetProtein, 120);
      expect(p.baseCaloriesTarget, isNull);
      expect(p.targetProteinToday, isNull);
    },
  );

  test(
    'editing an old partial profile preserves its numbers without inventing others',
    () async {
      const old = '{"dailyCaloriesMin":1911,"targetFat":68,"height":181}';
      await p.storage.local.setString('user_profile', old);
      await p.reloadAll();
      await p.updateProfile(p.profile.copyWith(ageYears: 29));
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(saved['dailyCaloriesMin'], 1911);
      expect(saved['targetFat'], 68);
      expect(saved.containsKey('dailyCaloriesMax'), isFalse);
      expect(saved.containsKey('targetProtein'), isFalse);
      expect(saved.containsKey('targetCarbs'), isFalse);
      expect(saved['calorieGoalConfirmed'], isFalse);
      expect(saved['fatGoalConfirmed'], isFalse);
      await p.reloadAll();
      expect(p.baseCaloriesTarget, isNull);
      expect(p.targetFatToday, isNull);
    },
  );

  test(
    'old writer retaining flags cannot confirm changed values with stale snapshots',
    () async {
      await p.updateProfile(
        p.profile.copyWith(
          dailyCaloriesMin: 1900,
          dailyCaloriesMax: 2100,
          targetProtein: 120,
          targetFat: 70,
        ),
      );
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!)
              as Map<String, dynamic>;
      saved['dailyCaloriesMin'] =
          1850; // changed without changing confirmation snapshots
      saved['targetProtein'] = 121;
      final oldWriter = jsonEncode(saved);
      await p.storage.local.setString('user_profile', oldWriter);
      await p.reloadAll();
      expect(
        p.storage.local.getString('user_profile'),
        oldWriter,
      ); // viewing is read-only
      expect(p.profile.dailyCaloriesMin, 1850);
      expect(p.profile.targetProtein, 121);
      expect(p.baseCaloriesTarget, isNull);
      expect(p.targetProteinToday, isNull);
      expect(p.targetFatToday, 70); // independent unchanged confirmation
      await p.updateProfile(p.profile.copyWith(ageYears: 29));
      final normalized =
          jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(normalized['dailyCaloriesMin'], 1850);
      expect(normalized['targetProtein'], 121);
      expect(normalized['calorieGoalConfirmed'], isFalse);
      expect(normalized['proteinGoalConfirmed'], isFalse);
      expect(normalized['fatGoalConfirmed'], isTrue);
    },
  );

  test(
    'changing just one calorie bound invalidates the old confirmation',
    () async {
      await p.updateProfile(
        p.profile.copyWith(dailyCaloriesMin: 1900, dailyCaloriesMax: 2100),
      );
      expect(p.baseCaloriesTarget, 2000);
      await p.updateProfile(p.profile.copyWith(dailyCaloriesMin: 1950));
      await p.reloadAll();
      expect(p.profile.dailyCaloriesMin, 1950);
      expect(p.profile.dailyCaloriesMax, 2100);
      expect(p.baseCaloriesTarget, isNull);
    },
  );

  test(
    'stale local profile edit is rejected without overwriting the new raw values',
    () async {
      await p.updateProfile(p.profile.copyWith(targetProtein: 120));
      const newer = '{"targetProtein":135,"dailyCaloriesMin":1950}';
      await p.storage.local.setString('user_profile', newer);
      await expectLater(
        p.updateProfile(p.profile.copyWith(ageYears: 29)),
        throwsA(isA<ProfileEditException>()),
      );
      expect(p.storage.local.getString('user_profile'), newer);
      expect(p.profile.targetProtein, 135);
      expect(p.targetProteinToday, isNull);
    },
  );

  test(
    'synthetic JSON backup restores exact confirmed profile and old unconfirmed values',
    () async {
      await p.updateProfile(
        p.profile.copyWith(
          dailyCaloriesMin: 1900,
          dailyCaloriesMax: 2100,
          targetProtein: 120,
        ),
      );
      final saved = p.storage.local.getString('user_profile');
      final backup = await p.exportDataJson();
      await p.updateProfile(p.profile.copyWith(targetProtein: 145));
      expect(await p.importDataJson(backup), isNull);
      expect(p.storage.local.getString('user_profile'), saved);
      expect(p.baseCaloriesTarget, 2000);
      expect(p.targetProteinToday, 120);

      const old =
          '{"dailyCaloriesMin":1888,"dailyCaloriesMax":2112,"targetProtein":121}';
      final oldBackup = jsonEncode({
        'app': 'fitness_tracker',
        'version': 2,
        'data': {'user_profile': old},
      });
      expect(await p.importDataJson(oldBackup), isNull);
      expect(p.storage.local.getString('user_profile'), old);
      expect(p.profile.targetProtein, 121);
      expect(p.baseCaloriesTarget, isNull);
      expect(p.targetProteinToday, isNull);
    },
  );

  testWidgets(
    'new calorie editor starts empty and cancel does not store a goal',
    (t) async {
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Калории'));
      await t.tap(find.text('Калории'));
      await t.pumpAndSettle();
      final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.length, 2);
      expect(fields[0].controller!.text, isEmpty);
      expect(fields[1].controller!.text, isEmpty);
      await t.tap(find.text('Отмена').last);
      await t.pumpAndSettle();
      expect(p.storage.local.getString('user_profile'), isNull);
      expect(p.baseCaloriesTarget, isNull);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'old calorie range is shown for review and same values can be confirmed',
    (t) async {
      const raw = '{"dailyCaloriesMin":1900,"dailyCaloriesMax":2100}';
      await t.runAsync(() async {
        await p.storage.local.setString('user_profile', raw);
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
      await t.ensureVisible(find.text('Калории'));
      expect(find.text('1900–2100 ккал · не подтверждено'), findsOneWidget);
      await t.tap(find.text('Калории'));
      await t.pumpAndSettle();
      final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields[0].controller!.text, '1900');
      expect(fields[1].controller!.text, '2100');
      await t.runAsync(() async {
        await t.tap(find.text('Сохранить').last);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await t.pumpAndSettle();
      expect(p.baseCaloriesTarget, 2000);
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(saved['calorieGoalConfirmed'], isTrue);
      expect(saved['dailyCaloriesMin'], 1900);
      expect(saved['dailyCaloriesMax'], 2100);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('recorded food remains visible without unconfirmed goal advice', (
    t,
  ) async {
    await t.runAsync(
      () => p.addFoodEntry(
        FoodEntry(
          name: 'Тестовая еда',
          caloriesPer100g: 500,
          proteinPer100g: 10,
          fatPer100g: 10,
          carbsPer100g: 10,
          amountGrams: 100,
          mealType: MealType.breakfast,
          date: p.selectedDate,
        ),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DailyBalanceCard(provider: p)),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('По записям: 500 ккал'), findsOneWidget);
    expect(find.textContaining('До ориентира'), findsNothing);
    expect(find.textContaining('выше ориентира'), findsNothing);
    expect(find.textContaining('Подтвердите цели'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
