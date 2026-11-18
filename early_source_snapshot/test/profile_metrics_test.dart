import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart' show SmartHub;
import 'package:fitness_tracker/smart/workout_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder workoutField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

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

  test('fresh and legacy body values remain unknown until confirmed', () {
    final fresh = const UserProfile();
    expect(fresh.heightConfirmed, isFalse);
    expect(fresh.currentWeightConfirmed, isFalse);
    final legacy = UserProfile.fromJson({
      'height': 181,
      'currentWeight': 78,
      'targetWeight': 76,
    });
    expect(legacy.height, 181);
    expect(legacy.currentWeight, 78);
    expect(legacy.heightConfirmed, isNull);
    expect(legacy.currentWeightConfirmed, isNull);
    expect(legacy.toJson()['height'], 181);
    expect(legacy.toJson()['currentWeight'], 78);
    expect(legacy.toJson().containsKey('heightConfirmed'), isFalse);
    expect(legacy.toJson().containsKey('currentWeightConfirmed'), isFalse);
  });

  test('flags cannot confirm missing measurements, explicit edit does', () {
    final invalid = UserProfile.fromJson({
      'heightConfirmed': true,
      'currentWeightConfirmed': true,
    });
    expect(invalid.heightConfirmed, isFalse);
    expect(invalid.currentWeightConfirmed, isFalse);
    final height = invalid.copyWith(height: 180);
    expect(height.heightConfirmed, isTrue);
    expect(height.currentWeightConfirmed, isFalse);
    final both = height.copyWith(currentWeight: 80);
    expect(both.currentWeightConfirmed, isTrue);
    final read = UserProfile.fromJson(jsonDecode(jsonEncode(both.toJson())));
    expect(read.heightConfirmed, isTrue);
    expect(read.currentWeightConfirmed, isTrue);
  });

  test(
    'actual weight entry confirms the profile weight and survives reload',
    () async {
      final day = DateTime(2026, 10, 20);
      await p.addWeightEntry(WeightEntry(date: day, weight: 79.25));
      expect(p.profile.currentWeight, 79.25);
      expect(p.profile.currentWeightConfirmed, isTrue);
      await p.reloadAll();
      expect(p.profile.currentWeight, 79.25);
      expect(p.profile.currentWeightConfirmed, isTrue);
      expect(p.weightEntries.single.weight, 79.25);
    },
  );

  test(
    'automatic metabolism never uses legacy defaults without confirmation',
    () async {
      await p.updateSmartSettings({
        'automatic': true,
        'age': 30,
        'activity': 1.2,
        'goalDelta': 0,
      });
      expect(p.metabolism.automatic, isTrue);
      expect(p.automaticMetabolismActive, isFalse);
      expect(p.baseCaloriesTarget, isNull);
      expect(p.macroTargets.protein, isNull);
      await p.updateProfile(
        p.profile.copyWith(ageYears: 30, height: 180, currentWeight: 80),
      );
      expect(
        p.automaticMetabolismActive,
        isFalse,
        reason: 'Settings also require explicit confirmation.',
      );
      await p.updateSmartSettings({
        ...p.smartSettings,
        'metabolismConfirmed': true,
      });
      expect(p.automaticMetabolismActive, isTrue);
      expect(p.baseCaloriesTarget, 2136);
      await p.updateProfile(p.profile.copyWith(ageYears: 31));
      expect(p.metabolism.age, 31);
      expect(p.baseCaloriesTarget, 2130);
      await p.updateProfile(p.profile.copyWith(clearAge: true));
      expect(p.automaticMetabolismActive, isFalse);
      expect(p.baseCaloriesTarget, isNull);
    },
  );

  test(
    'Katch needs confirmed fat percentage and never runs for a minor',
    () async {
      await p.updateProfile(
        p.profile.copyWith(ageYears: 18, height: 180, currentWeight: 80),
      );
      await p.updateSmartSettings({
        'automatic': true,
        'metabolismConfirmed': true,
        'useKatch': true,
        'bodyFat': 20,
        'activity': 1.2,
      });
      expect(p.automaticMetabolismActive, isFalse);
      await p.updateSmartSettings({
        ...p.smartSettings,
        'bodyFatConfirmed': true,
      });
      expect(p.automaticMetabolismActive, isTrue);
      expect(p.baseCaloriesTarget, closeTo(1752.4 * 1.2, 1e-9));
      await p.updateProfile(p.profile.copyWith(ageYears: 17));
      expect(p.automaticMetabolismActive, isFalse);
      expect(p.baseCaloriesTarget, isNull);
    },
  );

  Future<void> showSettings(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('320px settings do not display invented height, weight or BMI', (
    t,
  ) async {
    await showSettings(t);
    expect(find.text('175 см'), findsNothing);
    expect(find.text('85.9 кг'), findsNothing);
    expect(find.textContaining('ИМТ 28.0'), findsNothing);
    expect(find.text('Для ИМТ подтвердите рост и вес'), findsOneWidget);
    await t.ensureVisible(find.text('Рост'));
    await t.tap(find.text('Рост'));
    await t.pumpAndSettle();
    expect(
      t.widget<TextField>(find.byType(TextField).last).controller!.text,
      isEmpty,
    );
    await t.enterText(find.byType(TextField).last, '180');
    await t.tap(find.text('Сохранить').last);
    await t.pumpAndSettle();
    expect(p.profile.heightConfirmed, isTrue);
    expect(p.profile.height, 180);
    await t.ensureVisible(find.text('Текущий вес'));
    await t.tap(find.text('Текущий вес'));
    await t.pumpAndSettle();
    expect(
      t.widget<TextField>(find.byType(TextField).last).controller!.text,
      isEmpty,
    );
    await t.enterText(find.byType(TextField).last, '80');
    await t.tap(find.text('Сохранить').last);
    await t.pumpAndSettle();
    expect(p.profile.currentWeightConfirmed, isTrue);
    await t.scrollUntilVisible(
      find.text('ИМТ 24.7 · оценка по профилю'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('ИМТ 24.7 · оценка по профилю'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('failed profile write shows an error without confirming height', (
    t,
  ) async {
    await showSettings(t);
    await t.ensureVisible(find.text('Рост'));
    await t.tap(find.text('Рост'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, '180');
    LocalPreferences.rejectWriteKeyForTests = 'user_profile';
    await t.runAsync(() async {
      await t.tap(find.text('Сохранить').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();
    expect(p.profile.heightConfirmed, isFalse);
    expect(find.text('Не удалось сохранить параметр профиля.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'old height remains available for explicit review, not silently confirmed',
    (t) async {
      await t.runAsync(() async {
        await p.storage.local.setString(
          'user_profile',
          jsonEncode({'height': 181, 'currentWeight': 78, 'targetWeight': 75}),
        );
        await p.reloadAll();
      });
      await showSettings(t);
      expect(find.text('181 см'), findsNothing);
      await t.ensureVisible(find.text('Рост'));
      await t.tap(find.text('Рост'));
      await t.pumpAndSettle();
      expect(
        t.widget<TextField>(find.byType(TextField).last).controller!.text,
        '181.0',
      );
      expect(
        find.textContaining('Значение из старого профиля'),
        findsOneWidget,
      );
      await t.tap(find.text('Отмена').last);
      await t.pumpAndSettle();
      expect(p.profile.height, 181);
      expect(p.profile.heightConfirmed, isNull);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('new workout does not prefill an unconfirmed weight', (t) async {
    await t.binding.setSurfaceSize(const Size(500, 2200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(home: WorkoutEditorScreen(provider: p)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      workoutField('Ваш вес, кг'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      t.widget<TextField>(workoutField('Ваш вес, кг')).controller!.text,
      isEmpty,
    );
    expect(
      find.text('Вес для дня тренировки; пусто — неизвестен.'),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('confirmed profile weight is offered for a new workout', (
    t,
  ) async {
    await t.runAsync(
      () => p.updateProfile(p.profile.copyWith(currentWeight: 80)),
    );
    await t.binding.setSurfaceSize(const Size(500, 2200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(home: WorkoutEditorScreen(provider: p)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      workoutField('Ваш вес, кг'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      t.widget<TextField>(workoutField('Ваш вес, кг')).controller!.text,
      '80.0',
    );
    expect(t.takeException(), isNull);
  });

  Future<void> showMetabolism(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(500, 2200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: const MaterialApp(home: SmartHub()),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('BMR, цель и адаптация'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('BMR, цель и адаптация'));
    await t.pumpAndSettle();
  }

  Finder metabolismField(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );

  Future<void> applyMetabolism(WidgetTester t) async {
    await t.runAsync(() async {
      await t.tap(find.text('Применить'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();
  }

  testWidgets('manual metabolism settings do not invent age or body fat', (
    t,
  ) async {
    await showMetabolism(t);
    final ageField = metabolismField('Возраст, 1–120 (необ.)');
    expect(t.widget<TextField>(ageField).controller!.text, isEmpty);
    expect(
      t.widget<TextField>(metabolismField('Жир тела, 3–65%')).controller!.text,
      isEmpty,
    );
    await applyMetabolism(t);
    expect(p.profile.ageYears, isNull);
    expect(p.smartSettings.containsKey('age'), isFalse);
    expect(p.smartSettings.containsKey('bodyFat'), isFalse);
    expect(p.automaticMetabolismActive, isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('metabolism UI requires body metrics before activation', (
    t,
  ) async {
    await showMetabolism(t);
    await t.tap(find.text('Автоцель калорий'));
    await t.pumpAndSettle();
    await t.enterText(metabolismField('Возраст, 18–100'), '18');
    await applyMetabolism(t);
    expect(find.text('Метаболизм и цели'), findsOneWidget);
    expect(find.textContaining('Сначала подтвердите рост и вес'), findsWidgets);
    expect(p.automaticMetabolismActive, isFalse);
    expect(p.profile.ageYears, isNull);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'confirmed metrics and age activate the reviewed Mifflin estimate',
    (t) async {
      await t.runAsync(
        () =>
            p.updateProfile(p.profile.copyWith(height: 180, currentWeight: 80)),
      );
      await showMetabolism(t);
      await t.tap(find.text('Автоцель калорий'));
      await t.pumpAndSettle();
      await t.enterText(metabolismField('Возраст, 18–100'), '18');
      await applyMetabolism(t);
      expect(p.profile.ageYears, 18);
      expect(p.smartSettings['metabolismConfirmed'], isTrue);
      expect(p.smartSettings['bodyFatConfirmed'], isFalse);
      expect(p.automaticMetabolismActive, isTrue);
      expect(p.baseCaloriesTarget, 2208);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('failed metabolism settings write does not activate auto goal', (
    t,
  ) async {
    await t.runAsync(
      () => p.updateProfile(p.profile.copyWith(height: 180, currentWeight: 80)),
    );
    await showMetabolism(t);
    await t.tap(find.text('Автоцель калорий'));
    await t.pumpAndSettle();
    await t.enterText(metabolismField('Возраст, 18–100'), '18');
    LocalPreferences.rejectWriteKeyForTests = 'smart_settings';
    await applyMetabolism(t);
    expect(
      p.profile.ageYears,
      18,
      reason: 'The separately entered age was already saved.',
    );
    expect(p.automaticMetabolismActive, isFalse);
    expect(find.text('Метаболизм и цели'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('Katch cannot apply until body fat is explicitly entered', (
    t,
  ) async {
    await t.runAsync(
      () => p.updateProfile(
        p.profile.copyWith(ageYears: 18, height: 180, currentWeight: 80),
      ),
    );
    await showMetabolism(t);
    await t.tap(find.text('Автоцель калорий'));
    await t.pumpAndSettle();
    await t.tap(find.text('Katch–McArdle (нужен % жира)'));
    await t.pumpAndSettle();
    await applyMetabolism(t);
    expect(find.text('Метаболизм и цели'), findsOneWidget);
    expect(p.automaticMetabolismActive, isFalse);
    await t.enterText(metabolismField('Жир тела, 3–65%'), '20');
    await applyMetabolism(t);
    expect(p.smartSettings['bodyFatConfirmed'], isTrue);
    expect(p.automaticMetabolismActive, isTrue);
    expect(p.baseCaloriesTarget, closeTo(1752.4 * 1.2, 1e-9));
    expect(t.takeException(), isNull);
  });

  testWidgets('old automatic settings show the fallback explanation', (
    t,
  ) async {
    await t.runAsync(() => p.updateSmartSettings({'automatic': true}));
    await t.binding.setSurfaceSize(const Size(500, 2200));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: const MaterialApp(home: SmartHub()),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.textContaining('Автоцель приостановлена'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Автоцель приостановлена'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
