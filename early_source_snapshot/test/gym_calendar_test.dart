import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/gym_calendar.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:fitness_tracker/smart/gym_plan.dart';
import 'package:fitness_tracker/smart/gym_ui.dart';
import 'package:fitness_tracker/smart/home_simple.dart';
import 'package:fitness_tracker/smart/journal_overview_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/section_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

GymSession fixture(String id, DateTime date, {bool completed = false}) {
  final session = gymPlan().firstWhere((d) => d.id == 'tue').start(id, date);
  final exercise = session.blocks.first.exercises.first;
  exercise.sets.add(
    GymSet(
      index: 1,
      exerciseName: exercise.name,
      recordedAt: date.add(const Duration(minutes: 2)),
      reps: 8,
      weightKg: 27.25,
    ),
  );
  if (completed) session.finish(date.add(const Duration(minutes: 30)));
  return session;
}

String encoded(GymSession session) => jsonEncode(session.toJson());
String sessionKey(GymSession session) => '$gymSessionPrefix${session.id}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'only valid gym sessions are grouped by local start day, without merging',
    () {
      final today = DateTime(2026, 10, 20, 23, 55);
      final sameDay = fixture(
        'second',
        DateTime(2026, 10, 20, 8),
        completed: true,
      );
      final crossesMidnight = fixture('first', today, completed: true);
      final tomorrow = fixture('third', DateTime(2026, 10, 21, 8));
      final docs = <String, Object?>{
        sessionKey(crossesMidnight): encoded(crossesMidnight),
        sessionKey(sameDay): encoded(sameDay),
        sessionKey(tomorrow): encoded(tomorrow),
        'gym_session_corrupt': '{bad json',
        'gym_session_wrong_id': encoded(fixture('real_id', today)),
        'gym_session_deleted': null,
        'food_entries_2026-10-20': '{not gym data}',
      };
      final result = indexGymSessions(docs);
      expect(result.unreadable, 2);
      expect(result.sessions, hasLength(3));
      expect(result.forDate(today).map((s) => s.id), ['first', 'second']);
      expect(result.forDate(today).every((s) => s.completed), isTrue);
      expect(result.forDate(today).first.setCount, 1);
      expect(result.forDate(DateTime(2026, 10, 21)).single.id, 'third');
      expect(result.forDate(DateTime(2026, 10, 22)), isEmpty);
      expect(() => result.sessions.clear(), throwsUnsupportedError);
      expect(() => result.forDate(today).clear(), throwsUnsupportedError);
      // Reading is non-destructive even for unreadable documents.
      expect(docs['gym_session_corrupt'], '{bad json');
    },
  );

  group('shared storage notifications', () {
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
      LocalPreferences.onAppWrite = null;
      provider.dispose();
    });

    test(
      'only successful gym writes notify; stale or failed writes preserve data',
      () async {
        final session = fixture('notice', DateTime(2026, 10, 20, 10));
        final key = sessionKey(session), raw = encoded(session);
        var changes = 0;
        provider.addListener(() => changes++);
        await provider.storage.writeGymDocument(key, null, raw);
        expect(changes, 1);
        expect(provider.storage.local.getString(key), raw);
        await expectLater(
          provider.storage.writeGymDocument(key, null, raw),
          throwsStateError,
        );
        expect(changes, 1);
        LocalPreferences.rejectWriteKeyForTests = key;
        final finished = session.clone()..finish(DateTime(2026, 10, 20, 11));
        await expectLater(
          provider.storage.writeGymDocument(key, raw, encoded(finished)),
          throwsStateError,
        );
        expect(changes, 1);
        expect(provider.storage.local.getString(key), raw);
        LocalPreferences.rejectWriteKeyForTests = null;
        await provider.storage.writeGymDocument(key, raw, encoded(finished));
        expect(changes, 2);
        await provider.storage.writeGymDocument(key, encoded(finished), null);
        expect(changes, 3);
        expect(provider.storage.local.getString(key), isNull);
      },
    );

    test(
      'calendar cache observes direct sync/import/delete writes too',
      () async {
        final store = provider.storage.local;
        final empty = readGymCalendar(store);
        expect(identical(readGymCalendar(store), empty), isTrue);
        final session = fixture('sync', DateTime(2026, 10, 20, 10));
        await store.setString(sessionKey(session), encoded(session));
        final imported = readGymCalendar(store);
        expect(identical(imported, empty), isFalse);
        expect(imported.sessions.single.id, 'sync');
        await store.setString(sessionKey(session), '{bad');
        final invalid = readGymCalendar(store);
        expect(invalid.sessions, isEmpty);
        expect(invalid.unreadable, 1);
        await store.remove(sessionKey(session));
        final removed = readGymCalendar(store);
        expect(removed.sessions, isEmpty);
        expect(removed.unreadable, 0);
      },
    );

    testWidgets(
      'calendar updates after a write and opens the existing session',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        final list = find.byType(Scrollable).first;
        final empty = find.text('Зал и подтягивания: нет записей');
        await tester.scrollUntilVisible(empty, 250, scrollable: list);
        expect(empty, findsOneWidget);
        final now = provider.selectedDate;
        final session = fixture(
          'calendar',
          DateTime(now.year, now.month, now.day, 9),
        );
        await tester.runAsync(
          () => provider.storage.writeGymDocument(
            sessionKey(session),
            null,
            encoded(session),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final count = find.text('Записи зала и подтягиваний: 1');
        await tester.scrollUntilVisible(count, 220, scrollable: list);
        expect(count, findsOneWidget);
        expect(
          find.textContaining('не завершено · подходов: 1'),
          findsOneWidget,
        );
        expect(find.textContaining('не суммируются'), findsOneWidget);
        final row = find.byKey(const ValueKey('calendar-gym-calendar'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(GymSessionScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'unreadable gym record is never presented as a definite empty day',
      (tester) async {
        await provider.storage.local.setString('gym_session_broken', '{bad');
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
          find.textContaining('часть истории не прочитана'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Зал и подтягивания: нет записей'), findsNothing);
        expect(
          find.textContaining('Не удалось прочитать записей зала: 1'),
          findsOneWidget,
        );
        expect(provider.storage.local.getString('gym_session_broken'), '{bad');
      },
    );

    testWidgets('home and local overview refresh after gym changes', (
      tester,
    ) async {
      final now = provider.selectedDate;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(body: SimpleHomeScreen(openTab: (_) {})),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('Тренировки: нет записей за выбранный день.'),
        findsOneWidget,
      );
      final session = fixture(
        'dashboard',
        DateTime(now.year, now.month, now.day, 9),
      );
      await tester.runAsync(
        () => provider.storage.writeGymDocument(
          sessionKey(session),
          null,
          encoded(session),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('записи зала и подтягиваний: 1'),
        findsOneWidget,
      );
      await tester.runAsync(
        () => provider.addWorkoutEntry(
          WorkoutEntry(
            id: 'manual-overlap',
            type: WorkoutType.strength,
            durationMinutes: 30,
            caloriesBurned: 0,
            date: now,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Ручные тренировки: записей — 1 · записи зала'),
        findsOneWidget,
      );
      expect(
        find.textContaining('могут относиться к одному занятию'),
        findsOneWidget,
      );
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
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('1 занятий зала'), findsOneWidget);
      final second = fixture(
        'another',
        DateTime(now.year, now.month, now.day, 10),
      );
      await tester.runAsync(() async {
        await provider.storage.writeGymDocument(
          sessionKey(second),
          null,
          encoded(second),
        );
        // Overview deliberately debounces provider changes. The write runs in
        // real async, so its timer must also run on that clock in widget tests.
        await Future<void>.delayed(const Duration(milliseconds: 350));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('2 занятий зала'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
