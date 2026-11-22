import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/home_simple.dart';
import 'package:fitness_tracker/smart/journal_overview.dart';
import 'package:fitness_tracker/smart/journal_overview_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/section_screens.dart';
import 'package:fitness_tracker/smart/sleep.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const day = '2026-10-25';
  final date = DateTime(2026, 10, 25);
  String raw(int minutes, {String entryDay = '2026-10-25'}) =>
      encodeSleepDay(SleepDay(day: entryDay, minutes: minutes));

  test('strict calendar dates, source, duration, keys and forward data', () {
    expect(validSleepDay('2024-02-29'), isTrue);
    expect(validSleepDay('2026-02-29'), isFalse);
    expect(validSleepDay('0000-01-01'), isFalse);
    expect(validSleepDay('2026-13-01'), isFalse);
    expect(validSleepDay('2026-1-01'), isFalse);
    final zero = raw(0), max = raw(1440);
    validateSleepDocument('sleep_day_$day', zero);
    validateSleepDocument('sleep_day_$day', max);
    expect(
      SleepDay.fromJson(jsonDecode(zero) as Map<String, dynamic>).minutes,
      0,
    );
    expect(formatSleepMinutes(450), '7 ч 30 мин');
    expect(formatSleepMinutes(0), '0 ч 0 мин');
    for (final n in [-1, 1441]) {
      expect(() => raw(n), throwsFormatException);
    }
    final correct = SleepDay(day: day, minutes: 450).toJson();
    for (final data in [
      {...correct, 'minutes': 1.5},
      {...correct, 'minutes': '450'},
      {...correct, 'source': 'health'},
      {...correct, 'version': 2},
      {...correct, 'newUnknownField': 'must not be discarded'},
      {...correct, 'day': '2026-02-30'},
    ]) {
      expect(
        () => validateSleepDocument('sleep_day_$day', jsonEncode(data)),
        throwsFormatException,
      );
    }
    expect(
      () => validateSleepDocument('sleep_day_2026-10-24', raw(10)),
      throwsFormatException,
    );
    expect(
      () => validateSleepDocument('sleep_day_2026-02-30', null),
      throwsFormatException,
    );
    expect(
      () => validateSleepDocument('sleep_day_$day', {'minutes': 5}),
      throwsFormatException,
    );
    expect(LocalPreferences.appKey('sleep_day_$day'), isTrue);
    expect(LocalPreferences.appKey('sleep_day_foo'), isFalse);
  });

  test(
    'averages use only recorded days, explicit zero is not missing, AI excludes sleep',
    () {
      final docs = <String, Object?>{
        'sleep_day_2026-10-25': raw(450),
        'sleep_day_2026-10-26': raw(0, entryDay: '2026-10-26'),
        'sleep_day_2026-10-28': '{broken',
        'sleep_day_2026-10-29': raw(600, entryDay: '2026-10-29'),
      };
      final summary = summarizeSleep(docs, date, DateTime(2026, 10, 28));
      expect(summary.recordedDays, 2);
      expect(summary.unreadableDays, 1);
      expect(summary.totalMinutes, 450);
      expect(summary.averageMinutes, 225);
      final empty = summarizeSleep(
        docs,
        DateTime(2026, 10, 27),
        DateTime(2026, 10, 27),
      );
      expect(empty.recordedDays, 0);
      expect(empty.averageMinutes, isNull);
      expect(
        () => summarizeSleep(docs, date, DateTime(2026, 10, 24)),
        throwsArgumentError,
      );
      final overview = summarizeJournal(docs, date, DateTime(2026, 10, 28));
      expect(overview.sleep.recordedDays, 2);
      expect(overview.sleep.unreadableDays, 1);
      final request = overview.request({'food', 'training'}, 'Разбор');
      expect(jsonEncode(request), isNot(contains('sleep')));
      expect(jsonEncode(request), isNot(contains('450')));
    },
  );

  group('offline sleep storage and editor', () {
    late AppDataProvider provider;
    setUp(() async {
      LocalPreferences.memoryForTests = true;
      LocalPreferences.rejectWriteKeyForTests = null;
      SharedPreferences.setMockInitialValues({});
      provider = AppDataProvider();
      await provider.init();
      await provider.setSelectedDate(date);
    });
    tearDown(() {
      LocalPreferences.rejectWriteKeyForTests = null;
      LocalPreferences.onAppWrite = null;
      provider.dispose();
    });

    test(
      'queued compare-and-swap, failure and delete never lose another edit',
      () async {
        final key = sleepDocumentKey(date);
        var notifications = 0;
        provider.addListener(() => notifications++);
        expect(readSleepDay(provider.storage.local, date).value, isNull);
        await provider.storage.writeSleepDocument(key, null, raw(450));
        expect(notifications, 1);
        Future<bool> edit() async {
          try {
            await provider.storage.writeSleepDocument(key, raw(450), raw(420));
            return true;
          } on StateError {
            return false;
          }
        }

        final outcomes = await Future.wait([
          edit(),
          provider.storage.local.compareAndPut(key, raw(450), raw(480)),
        ]);
        expect(outcomes.where((v) => v), hasLength(1));
        final saved = provider.storage.local.getString(key)!;
        expect([raw(420), raw(480)], contains(saved));
        var authorized = true;
        final guarded = provider.storage.local.compareAndPut(
          key,
          saved,
          raw(100),
          authorizationGuard: () => authorized,
        );
        authorized = false;
        await expectLater(guarded, throwsStateError);
        expect(provider.storage.local.getString(key), saved);
        await expectLater(
          provider.storage.writeSleepDocument(key, raw(450), null),
          throwsStateError,
        );
        expect(provider.storage.local.getString(key), saved);
        LocalPreferences.rejectWriteKeyForTests = key;
        await expectLater(
          provider.storage.writeSleepDocument(key, saved, raw(390)),
          throwsStateError,
        );
        expect(provider.storage.local.getString(key), saved);
        LocalPreferences.rejectWriteKeyForTests = null;
        await provider.storage.writeSleepDocument(key, saved, null);
        expect(provider.storage.local.getString(key), isNull);
        expect(readSleepDay(provider.storage.local, date).value, isNull);
      },
    );

    test(
      'JSON backup preserves sleep and existing food; malformed import rejected',
      () async {
        final key = sleepDocumentKey(date);
        await provider.storage.writeSleepDocument(key, null, raw(450));
        final food = FoodEntry(
          id: 'food-backup',
          name: 'Яблоко',
          amountGrams: 100,
          caloriesPer100g: 52,
          proteinPer100g: .3,
          fatPer100g: .2,
          carbsPer100g: 14,
          mealType: MealType.lunch,
          date: date,
        );
        await provider.addFoodEntry(food);
        final backup = await provider.storage.exportData();
        final data = Map<String, dynamic>.from(backup['data'] as Map);
        expect(data[key], raw(450));
        expect(data.keys, contains('food_entries_$day'));
        final malformed = {...data, key: '{broken'};
        await expectLater(
          provider.storage.importData({'data': malformed}),
          throwsFormatException,
        );
        expect(provider.storage.local.getString(key), raw(450));
        await provider.storage.writeSleepDocument(key, raw(450), raw(0));
        expect(await provider.storage.importData({'data': data}), isTrue);
        expect(provider.storage.local.getString(key), raw(450));
        expect(
          (await provider.storage.getFoodEntries(date)).single.name,
          'Яблоко',
        );
      },
    );

    Future<void> mount(
      WidgetTester tester,
      Size size, {
      bool existing = false,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(body: ManualActivityScreen()),
          ),
        ),
      );
      await tester.pump();
      final button = find.text(existing ? 'Изменить сон' : 'Записать сон');
      await tester.scrollUntilVisible(
        button,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'manual sleep saves, remains distinct from absence, and can be deleted',
      (tester) async {
        await mount(tester, const Size(320, 740));
        expect(find.text('За выбранный день не записан.'), findsOneWidget);
        await tester.tap(find.text('Записать сон'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Часы (0–24)'),
          '24',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Минуты (0–59)'),
          '1',
        );
        await tester.tap(find.text('Сохранить'));
        await tester.pump();
        expect(find.textContaining('не более 24 часов'), findsOneWidget);
        expect(readSleepDay(provider.storage.local, date).value, isNull);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Часы (0–24)'),
          '7',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Минуты (0–59)'),
          '30',
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Сохранить'));
          await provider.storage.pendingMutations;
        });
        await tester.pumpAndSettle();
        expect(find.text('7 ч 30 мин · введено вручную'), findsOneWidget);
        await tester.tap(find.text('Изменить сон'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Часы (0–24)'),
          '0',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Минуты (0–59)'),
          '0',
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Сохранить'));
          await provider.storage.pendingMutations;
        });
        await tester.pumpAndSettle();
        expect(find.text('0 ч 0 мин · введено вручную'), findsOneWidget);
        expect(readSleepDay(provider.storage.local, date).value!.minutes, 0);
        await tester.tap(find.text('Изменить сон'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Удалить запись'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Отмена').last);
        await tester.pumpAndSettle();
        expect(readSleepDay(provider.storage.local, date).value!.minutes, 0);
        await tester.runAsync(() => tester.tap(find.text('Удалить запись')));
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('Удалить').last));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
          await provider.storage.pendingMutations;
        });
        await tester.pumpAndSettle();
        expect(readSleepDay(provider.storage.local, date).value, isNull);
        expect(find.text('За выбранный день не записан.'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('home, calendar and local overview show the recorded value', (
      tester,
    ) async {
      final key = sleepDocumentKey(date);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(body: SimpleHomeScreen(openTab: (_) {})),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Не записан'), findsOneWidget);
      await tester.runAsync(
        () => provider.storage.writeSleepDocument(key, null, raw(450)),
      );
      await tester.pump();
      expect(find.text('7 ч 30 мин'), findsOneWidget);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: JournalCalendarScreen(
                openDiary: () {},
                openTraining: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Сон: 7 ч 30 мин · вручную'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Сон: 7 ч 30 мин · вручную'), findsOneWidget);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(home: JournalOverviewScreen(provider: provider)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => provider.storage.pendingMutations);
      await tester.pump();
      expect(
        find.textContaining('1 дн. с записью · среднее 7 ч 30 мин'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('sleep editor is usable on a short landscape screen', (
      tester,
    ) async {
      await mount(tester, const Size(900, 320));
      await tester.tap(find.text('Записать сон'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final hours = find.widgetWithText(TextFormField, 'Часы (0–24)');
      await tester.ensureVisible(hours);
      await tester.enterText(hours, '7');
      final minutes = find.widgetWithText(TextFormField, 'Минуты (0–59)');
      await tester.ensureVisible(minutes);
      await tester.enterText(minutes, '15');
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await provider.storage.pendingMutations;
      });
      await tester.pumpAndSettle();
      expect(readSleepDay(provider.storage.local, date).value!.minutes, 435);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'stale editor and corrupt record never overwrite original data',
      (tester) async {
        final key = sleepDocumentKey(date);
        await tester.runAsync(
          () => provider.storage.writeSleepDocument(key, null, raw(420)),
        );
        await mount(tester, const Size(390, 844), existing: true);
        await tester.tap(find.text('Изменить сон'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => provider.storage.writeSleepDocument(key, raw(420), raw(480)),
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Часы (0–24)'),
          '9',
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Сохранить'));
          await provider.storage.pendingMutations;
        });
        await tester.pump();
        expect(find.textContaining('Запись изменилась.'), findsOneWidget);
        expect(provider.storage.local.getString(key), raw(480));
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => provider.storage.local.setString(key, '{invalid'),
        );
        await tester.runAsync(provider.refresh);
        await tester.pump();
        expect(find.textContaining('не удалось прочитать'), findsOneWidget);
        expect(find.text('Изменить сон'), findsNothing);
        expect(provider.storage.local.getString(key), '{invalid');
        expect(tester.takeException(), isNull);
      },
    );
  });
}
