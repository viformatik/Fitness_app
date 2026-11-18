import 'dart:async';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/catalog_ui.dart';
import 'package:fitness_tracker/smart/gym_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/section_screens.dart';
import 'package:fitness_tracker/smart/ui.dart' show AiChatScreen, SmartHub;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
    AppTheme.configure({});
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    provider.dispose();
    AppTheme.configure({});
  });

  test(
    'failed steps write restores saved value and reports an error',
    () async {
      await provider.setSteps(1200);
      LocalPreferences.rejectWriteKeyForTests =
          'steps_${dayKey(provider.selectedDate)}';
      await provider.setSteps(1300);
      expect(provider.todaySteps, 1200);
      expect(provider.persistenceError, isNotNull);
      expect(await provider.storage.getSteps(provider.selectedDate), 1200);
      LocalPreferences.rejectWriteKeyForTests = null;
      await provider.setSteps(1400);
      expect(provider.todaySteps, 1400);
      expect(provider.persistenceError, isNull);
      await provider.reloadAll();
      expect(provider.todaySteps, 1400);
    },
  );

  test(
    'steps writes are ordered, validated and remain attached to their day',
    () async {
      final today = provider.selectedDate;
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      await Future.wait([
        provider.setSteps(200),
        provider.addSteps(1000),
        provider.addSteps(1000),
      ]);
      expect(await provider.storage.getSteps(today), 2200);
      await expectLater(provider.setSteps(-1), throwsArgumentError);
      expect(provider.todaySteps, 2200);
      final pending = provider.setSteps(2300);
      await provider.setSelectedDate(yesterday);
      await pending;
      expect(provider.todaySteps, 0);
      await provider.setSelectedDate(today);
      expect(provider.todaySteps, 2300);
    },
  );

  Future<void> start(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MyApp(provider: provider));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> mobileSection(WidgetTester tester, String name) async {
    await tester.tap(find.text('Разделы').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final drawer = find.byType(Drawer);
    final target = find.descendant(of: drawer, matching: find.text(name));
    final scrollable = find
        .descendant(of: drawer, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(target, 200, scrollable: scrollable);
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets(
    'desktop rail exposes twelve existing or explicitly limited sections',
    (tester) async {
      await start(tester, const Size(1200, 900));
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(12));
      final labels = rail.destinations
          .map((e) => (e.label as Text).data)
          .toList();
      expect(labels, [
        'Сегодня',
        'Дневник',
        'Тренировка',
        'Обзор',
        'Каталог продуктов',
        'Рецепты',
        'Упражнения',
        'Активность',
        'Календарь',
        'ИИ-помощник',
        'Профиль',
        'Настройки',
      ]);
      expect(rail.scrollable, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile menu opens catalog, recipes and original gym plan', (
    tester,
  ) async {
    await start(tester, const Size(390, 844));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
      hasLength(5),
    );
    await mobileSection(tester, 'Каталог продуктов');
    expect(find.byType(FoodCatalogScreen), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );
    await mobileSection(tester, 'Рецепты');
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(find.text('Соберите первое блюдо'), findsOneWidget);
    await tester.tap(find.text('Новый'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Ингредиенты'), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await mobileSection(tester, 'Упражнения');
    expect(find.byType(PlanExercisesScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Жим лёжа');
    await tester.pump();
    final press = find.descendant(
      of: find.byType(ExpansionTile),
      matching: find.text('Жим лёжа'),
    );
    expect(press, findsOneWidget);
    await tester.tap(press);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Жим гантелей лёжа'), findsWidgets);
    await tester.tap(find.text('Открыть программу тренировок'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(GymHomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visited catalog search is retained when changing sections', (
    tester,
  ) async {
    await start(tester, const Size(390, 844));
    await mobileSection(tester, 'Каталог продуктов');
    final input = find.byType(TextField).first;
    await tester.enterText(input, 'Витебский');
    await tester.pump(const Duration(milliseconds: 400));
    await mobileSection(tester, 'Активность');
    expect(find.byType(ManualActivityScreen), findsOneWidget);
    await mobileSection(tester, 'Каталог продуктов');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Витебский',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('quick steps update the shared activity and calendar', (
    tester,
  ) async {
    await start(tester, const Size(390, 844));
    await mobileSection(tester, 'Активность');
    expect(find.text('Шаги: не записаны'), findsOneWidget);
    await tester.tap(find.text('Добавить шаги или тренировку'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      await tester.tap(find.text('Добавить 1 000 шагов'));
      await provider.storage.pendingMutations;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(provider.todaySteps, 1000);
    expect(find.text('Шаги: 1 000'), findsOneWidget);
    await mobileSection(tester, 'Календарь');
    expect(find.text('Шаги: 1 000'), findsOneWidget);
    expect(
      await tester.runAsync(
        () => provider.storage.getSteps(provider.selectedDate),
      ),
      1000,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity shows save failure and restores the previous steps', (
    tester,
  ) async {
    await tester.runAsync(() => provider.setSteps(100));
    await start(tester, const Size(320, 640));
    await mobileSection(tester, 'Активность');
    LocalPreferences.rejectWriteKeyForTests =
        'steps_${dayKey(provider.selectedDate)}';
    await tester.tap(find.text('Добавить шаги или тренировку'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      final done = Completer<void>();
      void listener() {
        if (provider.persistenceError != null &&
            provider.todaySteps == 100 &&
            !done.isCompleted)
          done.complete();
      }

      provider.addListener(listener);
      await tester.tap(find.text('Добавить 1 000 шагов'));
      await done.future.timeout(const Duration(seconds: 2));
      provider.removeListener(listener);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Шаги: 100'), findsOneWidget);
    expect(find.textContaining('Изменение не сохранено'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar includes saved records outside its usual date window', (
    tester,
  ) async {
    final today = provider.selectedDate;
    final old = DateTime(1899, 5, 1);
    final future = DateTime(today.year + 10, 6, 1);
    await tester.runAsync(() async {
      await provider.setSelectedDate(old);
      await provider.setSteps(50);
      await provider.setSelectedDate(future);
      await provider.setWaterIntake(100);
      await provider.setSelectedDate(today);
    });
    await start(tester, const Size(390, 844));
    await mobileSection(tester, 'Календарь');
    final picker = tester.widget<CalendarDatePicker>(
      find.byType(CalendarDatePicker),
    );
    expect(picker.firstDate.isAfter(old), isFalse);
    expect(picker.lastDate.isBefore(future), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'activity and calendar distinguish no entries from recorded zero',
    (tester) async {
      await tester.runAsync(() async {
        await provider.setSteps(0);
        await provider.setWaterIntake(0);
      });
      await start(tester, const Size(390, 844));
      await mobileSection(tester, 'Активность');
      expect(find.text('Шаги: 0'), findsOneWidget);
      expect(find.text('Вода: 0 мл'), findsOneWidget);
      expect(
        find.text('Подключение Health пока не поддерживается.'),
        findsOneWidget,
      );
      await mobileSection(tester, 'Календарь');
      expect(find.byType(JournalCalendarScreen), findsOneWidget);
      expect(find.text('Питание: нет записей'), findsOneWidget);
      expect(find.text('Шаги: 0'), findsOneWidget);
      expect(find.text('Вода: 0 мл'), findsOneWidget);
      final date = provider.selectedDate;
      final previous = DateTime(date.year, date.month, date.day - 1);
      await tester.runAsync(() async {
        final updated = Completer<void>();
        void listener() {
          if (!updated.isCompleted) updated.complete();
        }

        provider.addListener(listener);
        tester
            .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
            .onDateChanged(previous);
        await updated.future.timeout(const Duration(seconds: 2));
        provider.removeListener(listener);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Шаги: не записаны'), findsOneWidget);
      expect(find.text('Вода: не записана'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '320px section pages and recipe editor have no layout exceptions',
    (tester) async {
      await start(tester, const Size(320, 640));
      for (final section in [
        'Каталог продуктов',
        'Рецепты',
        'Упражнения',
        'Активность',
        'Календарь',
      ]) {
        await mobileSection(tester, section);
        expect(tester.takeException(), isNull, reason: section);
        if (section == 'Рецепты') {
          await tester.tap(find.text('Новый'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull, reason: 'редактор рецепта');
          await tester.binding.handlePopRoute();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
        }
      }
    },
  );

  testWidgets('an extra section survives a desktop and mobile resize', (
    tester,
  ) async {
    await start(tester, const Size(390, 844));
    await mobileSection(tester, 'Упражнения');
    await tester.enterText(find.byType(TextField).first, 'подтягивания');
    await tester.pump();
    final original = tester.element(find.byType(PlanExercisesScreen));
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      6,
    );
    expect(tester.element(find.byType(PlanExercisesScreen)), same(original));
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'подтягивания',
    );
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );
    expect(tester.element(find.byType(PlanExercisesScreen)), same(original));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the short desktop rail scrolls to and opens its last destination',
    (tester) async {
      await start(tester, const Size(900, 320));
      final rail = find.byType(NavigationRail);
      final target = find.descendant(
        of: rail,
        matching: find.text('Настройки'),
      );
      final scrollable = find
          .descendant(of: rail, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(target, 250, scrollable: scrollable);
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartHub), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320px AI, profile and settings remain navigable', (
    tester,
  ) async {
    await start(tester, const Size(320, 640));
    for (final section in ['ИИ-помощник', 'Профиль', 'Настройки']) {
      await mobileSection(tester, section);
      expect(tester.takeException(), isNull, reason: section);
    }
  });

  testWidgets('short landscape activity sheet scrolls instead of overflowing', (
    tester,
  ) async {
    await start(tester, const Size(900, 320));
    tester
        .widget<NavigationRail>(find.byType(NavigationRail))
        .onDestinationSelected!(7);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final button = find.text('Добавить шаги или тренировку');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Добавить 1 000 шагов'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI, profile and settings reuse existing screens', (
    tester,
  ) async {
    await start(tester, const Size(390, 844));
    await mobileSection(tester, 'ИИ-помощник');
    expect(find.byType(AiChatScreen), findsOneWidget);
    await mobileSection(tester, 'Профиль');
    expect(find.byType(SettingsScreen), findsOneWidget);
    await mobileSection(tester, 'Настройки');
    expect(find.byType(SmartHub), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
