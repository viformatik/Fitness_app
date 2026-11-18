import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/workout_ui.dart';
import 'package:fitness_tracker/smart/engine.dart' as smart;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The real storage queue is tested separately; this synchronous provider avoids
// crossing fake-async/real-async zones while exercising review and UI decisions.
class WidgetWorkoutProvider extends AppDataProvider {
  final items = <WorkoutEntry>[];
  @override
  List<WorkoutEntry> get todayWorkoutEntries => List.unmodifiable(items);
  @override
  int get todayWorkoutCalorieCredit =>
      items.fold(0, (v, e) => v + e.budgetCalories);
  @override
  int get todayCaloriesBurned => items.fold(0, (v, e) => v + e.caloriesBurned);
  @override
  NutritionTargets get macroTargets {
    var b = super.macroTargets;
    if (metabolism.adaptMacros)
      for (final e in items) {
        b =
            b +
            smart.MetabolicSettings.workoutBonus(e.budgetCalories, e.type.name);
      }
    return b;
  }

  @override
  Future<void> addWorkoutEntry(WorkoutEntry e) async {
    items.add(e);
    notifyListeners();
  }

  @override
  Future<void> updateWorkoutEntry(WorkoutEntry e) async {
    final i = items.indexWhere((x) => x.id == e.id);
    if (i >= 0) items[i] = e;
    notifyListeners();
  }

  @override
  Future<void> deleteWorkoutEntry(String id) async {
    items.removeWhere((e) => e.id == id);
    notifyListeners();
  }
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 25);
  late WidgetWorkoutProvider p;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = WidgetWorkoutProvider();
    await p.init();
    await p.setSelectedDate(day);
    await p.updateProfile(
      const UserProfile(
        currentWeight: 80,
        currentWeightConfirmed: true,
        dailyCaloriesMin: 2000,
        dailyCaloriesMax: 2000,
        calorieGoalConfirmed: true,
        proteinGoalConfirmed: true,
        fatGoalConfirmed: true,
        carbsGoalConfirmed: true,
        targetProtein: 100,
        targetFat: 60,
        targetCarbs: 250,
      ),
    );
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    p.dispose();
  });
  Future<void> frame(WidgetTester t, {WorkoutEntry? edit}) async {
    t.view.physicalSize = const Size(500, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showWorkoutEditor(ctx, p, entry: edit),
                child: const Text('Открыть тест'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Открыть тест'));
    await t.pumpAndSettle();
  }

  Future<void> fill(WidgetTester t) async {
    await t.tap(find.byType(DropdownButtonFormField<String>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Силовая · обычная, несколько упражнений').last);
    await t.pumpAndSettle();
    await t.enterText(field('Минуты').first, '60');
    await t.tap(find.text('Добавить упражнение'));
    await t.pump();
    await t.enterText(field('Название упражнения').first, 'Жим');
    await t.enterText(field('Подходы').first, '3');
    await t.enterText(field('Повторения').first, '10');
    await t.enterText(field('Внешний вес, кг (необ.)').first, '30');
    await t.pump();
  }

  testWidgets('Quick tap opens editor without silently writing old 500 kcal', (
    t,
  ) async {
    t.view.physicalSize = const Size(500, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuickActionButtons(provider: p)),
      ),
    );
    await t.tap(find.text('Тренировка'));
    await t.pumpAndSettle();
    expect(find.text('Новая тренировка'), findsOneWidget);
    expect(p.todayWorkoutEntries, isEmpty);
    expect(p.adjustedCaloriesTarget, 2000);
  });
  testWidgets('Manual entry: preview, cancel, confirm, totals and credit', (
    t,
  ) async {
    await t.runAsync(() => p.updateSmartSettings({'adaptMacros': true}));
    await frame(t);
    await fill(t);
    await t.tapAt(t.getCenter(find.byType(Slider)));
    await t.pump();
    expect(
      find.textContaining('Учитывать в дневном лимите: 50%'),
      findsOneWidget,
    );
    await t.tap(find.text('Проверить и добавить'));
    await t.pumpAndSettle();
    expect(find.text('Проверить тренировку'), findsOneWidget);
    expect(p.todayWorkoutEntries, isEmpty);
    expect(find.textContaining('Примерно активных: 200 ккал'), findsOneWidget);
    expect(find.textContaining('Известный объём: 900 кг'), findsOneWidget);
    expect(
      find.textContaining('Дневной лимит: 2000 → 2100 ккал'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Ориентир БЖУ после сохранения:'),
      findsOneWidget,
    );
    await t.tap(find.text('Назад').last);
    await t.pumpAndSettle();
    expect(p.todayWorkoutEntries, isEmpty);
    expect(
      t.widget<TextField>(field('Название упражнения').first).controller!.text,
      'Жим',
    );
    await t.tap(find.text('Проверить и добавить'));
    await t.pumpAndSettle();
    await t.tap(find.text('Добавить').last);
    await t.pumpAndSettle();
    expect(p.todayWorkoutEntries, hasLength(1));
    expect(p.todayWorkoutEntries.single.caloriesBurned, 200);
    expect(p.todayWorkoutEntries.single.details!.budgetPercent, 50);
    expect(p.todayWorkoutCalorieCredit, 100);
    expect(p.adjustedCaloriesTarget, 2100);
    expect(p.todayWorkoutEntries.single.details!.volumeKg, 900);
  });
  testWidgets('workout preview never invents missing calorie or macro goals', (
    t,
  ) async {
    await t.runAsync(() async {
      await p.storage.local.setString(
        'user_profile',
        '{"currentWeight":80,"currentWeightConfirmed":true}',
      );
      await p.reloadAll();
      await p.updateSmartSettings({'adaptMacros': true});
    });
    expect(p.adjustedCaloriesTarget, isNull);
    expect(p.targetProteinToday, isNull);
    await frame(t);
    await fill(t);
    await t.tap(find.text('Проверить и добавить'));
    await t.pumpAndSettle();
    expect(p.todayWorkoutEntries, isEmpty);
    expect(find.textContaining('Цель калорий не подтверждена'), findsOneWidget);
    expect(find.textContaining('Б не подтверждена'), findsOneWidget);
    expect(find.textContaining('null'), findsNothing);
    await t.tap(find.text('Добавить').last);
    await t.pumpAndSettle();
    expect(p.todayWorkoutEntries, hasLength(1));
    expect(p.adjustedCaloriesTarget, isNull);
    expect(p.targetProteinToday, isNull);
    expect(p.targetFatToday, isNull);
    expect(p.targetCarbsToday, isNull);
    expect(t.takeException(), isNull);
  });
  testWidgets('Changed daily goal during preview blocks stale confirmation', (
    t,
  ) async {
    await frame(t);
    await fill(t);
    await t.tap(find.text('Проверить и добавить'));
    await t.pumpAndSettle();
    await t.runAsync(
      () => p.addWorkoutEntry(
        WorkoutEntry(
          type: WorkoutType.cardio,
          durationMinutes: 10,
          caloriesBurned: 50,
          date: day,
        ),
      ),
    );
    await t.runAsync(() async {
      await t.tap(find.text('Добавить').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();
    expect(p.todayWorkoutEntries, hasLength(1));
    expect(find.textContaining('Дневные цели изменились'), findsOneWidget);
  });
  testWidgets(
    'Legacy edit starts with original calories and requires confirmation',
    (t) async {
      final old = WorkoutEntry(
        id: 'legacy',
        type: WorkoutType.strength,
        durationMinutes: 70,
        caloriesBurned: 500,
        date: day,
      );
      await t.runAsync(() => p.addWorkoutEntry(old));
      await frame(t, edit: old);
      expect(
        t.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      expect(
        t.widget<TextField>(field('Активные калории, ккал')).controller!.text,
        '500',
      );
      expect(
        t.widget<TextField>(field('Ваш вес, кг')).controller!.text,
        isEmpty,
      );
      await t.tap(find.text('Проверить и сохранить'));
      await t.pumpAndSettle();
      expect(find.text('Проверить изменения'), findsOneWidget);
      expect(p.todayWorkoutEntries.single.details, isNull);
      await t.tap(find.text('Сохранить').last);
      await t.pumpAndSettle();
      expect(p.todayWorkoutEntries.single.caloriesBurned, 500);
      expect(p.adjustedCaloriesTarget, 2500);
      expect(p.todayWorkoutEntries.single.details!.calorieMode, 'manual');
      expect(p.todayWorkoutEntries.single.details!.weightKg, isNull);
    },
  );
  testWidgets(
    'Removing one of multiple exercise rows preserves the other row',
    (t) async {
      await frame(t);
      await t.tap(find.text('Добавить упражнение'));
      await t.pump();
      await t.enterText(field('Название упражнения').first, 'Первое');
      await t.tap(find.text('Добавить упражнение'));
      await t.pump();
      await t.enterText(field('Название упражнения').last, 'Второе');
      await t.tap(find.byTooltip('Удалить упражнение 1'));
      await t.pump();
      expect(
        t
            .widget<TextField>(field('Название упражнения').first)
            .controller!
            .text,
        'Второе',
      );
      expect(t.takeException(), isNull);
    },
  );
}
