import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
  });

  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    provider.dispose();
  });

  test('old profile has unknown age and preserves existing fields', () {
    final old = UserProfile.fromJson({
      'height': 181,
      'currentWeight': 78,
      'targetWeight': 76,
      'targetWeightConfirmed': true,
    });
    expect(old.ageYears, isNull);
    expect(old.height, 181);
    expect(old.targetWeightConfirmed, isTrue);
    // New clients emit null explicitly; old clients omit the field entirely.
    expect(old.toJson().containsKey('ageYears'), isTrue);
    expect(old.toJson()['ageYears'], isNull);
  });

  test('age roundtrips, stays on unrelated edits and can be removed', () {
    final profile = const UserProfile().copyWith(ageYears: 18);
    final read = UserProfile.fromJson(jsonDecode(jsonEncode(profile.toJson())));
    expect(read.ageYears, 18);
    expect(read.copyWith(height: 182).ageYears, 18);
    final removed = read.copyWith(clearAge: true);
    expect(removed.ageYears, isNull);
    expect(removed.toJson().containsKey('ageYears'), isTrue);
    expect(removed.toJson()['ageYears'], isNull);
  });

  test('invalid age cannot enter through imported profile', () {
    for (final value in [0, -1, 121, 18.5, '18']) {
      expect(
        () => validateAppDocument(
          'user_profile',
          jsonEncode({'ageYears': value}),
        ),
        throwsFormatException,
        reason: '$value',
      );
    }
  });

  test('explicit age persists across reload and export', () async {
    await provider.updateProfile(provider.profile.copyWith(ageYears: 18));
    final backup = await provider.storage.exportData();
    expect((backup['data'] as Map)['user_profile'], contains('"ageYears":18'));
    await provider.reloadAll();
    expect(provider.profile.ageYears, 18);
    await provider.updateProfile(provider.profile.copyWith(clearAge: true));
    expect(
      provider.storage.local.getString('user_profile'),
      contains('"ageYears":null'),
    );
    await provider.reloadAll();
    expect(provider.profile.ageYears, isNull);
  });

  test('failed age write restores previous in-memory profile', () async {
    await provider.updateProfile(provider.profile.copyWith(ageYears: 18));
    LocalPreferences.rejectWriteKeyForTests = 'user_profile';
    await expectLater(
      provider.updateProfile(provider.profile.copyWith(ageYears: 19)),
      throwsStateError,
    );
    expect(provider.profile.ageYears, 18);
    expect(
      UserProfile.fromJson(
        jsonDecode(provider.storage.local.getString('user_profile')!),
      ).ageYears,
      18,
    );
  });

  testWidgets(
    'nutrition setting reports a write failure without pretending to save',
    (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final original = provider.profile.targetProtein;
      await tester.ensureVisible(find.text('Белки'));
      await tester.tap(find.text('Белки'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '123');
      LocalPreferences.rejectWriteKeyForTests = 'user_profile';
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить').last);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(provider.profile.targetProtein, original);
      expect(
        find.text('Не удалось сохранить параметр профиля.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an open nutrition editor preserves a newer profile age', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Белки'));
    await tester.tap(find.text('Белки'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => provider.updateProfile(provider.profile.copyWith(ageYears: 29)),
    );
    await tester.enterText(find.byType(TextField).last, '123');
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить').last);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(provider.profile.ageYears, 29);
    expect(provider.profile.targetProtein, 123);
    final stored =
        jsonDecode(provider.storage.local.getString('user_profile')!) as Map;
    expect(stored['ageYears'], 29);
    expect(stored['targetProtein'], 123);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calorie range setting reports a write failure', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final original = provider.profile.dailyCaloriesMin;
    await tester.ensureVisible(find.text('Калории'));
    await tester.tap(find.text('Калории'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '1500');
    await tester.enterText(find.byType(TextField).last, '2100');
    LocalPreferences.rejectWriteKeyForTests = 'user_profile';
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить').last);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(provider.profile.dailyCaloriesMin, original);
    expect(find.text('Не удалось сохранить параметр профиля.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('setting warns when a newer profile contains unknown fields', (
    tester,
  ) async {
    final raw = jsonEncode({
      'ageYears': 29,
      'futureProfile': {'keep': true},
    });
    await tester.runAsync(() async {
      await provider.storage.local.setString('user_profile', raw);
      await provider.reloadAll();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Возраст'));
    await tester.tap(find.text('Возраст'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '30');
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить').last);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Профиль содержит данные неизвестного'),
      findsOneWidget,
    );
    expect(provider.storage.local.getString('user_profile'), raw);
    expect(provider.profile.ageYears, 29);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings edits, validates and removes age on 320px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Возраст'));
    await tester.tap(find.text('Возраст'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Обновляйте его после дня рождения'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).last, '121');
    await tester.tap(find.text('Сохранить').last);
    await tester.pumpAndSettle();
    expect(find.text('Укажите целое число от 1 до 120'), findsOneWidget);
    expect(provider.profile.ageYears, isNull);
    await tester.enterText(find.byType(TextField).last, '18');
    await tester.tap(find.text('Сохранить').last);
    await tester.pumpAndSettle();
    expect(provider.profile.ageYears, 18);
    expect(find.text('18 полных лет'), findsOneWidget);
    await tester.tap(find.text('Возраст'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить возраст'));
    await tester.pumpAndSettle();
    expect(provider.profile.ageYears, isNull);
    expect(tester.takeException(), isNull);
  });
}
