import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/gym_exercise_history.dart';
import 'package:fitness_tracker/smart/gym_exercise_history_ui.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:fitness_tracker/smart/gym_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/section_screens.dart';
import 'package:fitness_tracker/smart/ui.dart' show AiChatScreen;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

GymSet setFor(
  String name,
  DateTime time, {
  int index = 1,
  int? reps = 8,
  int? seconds,
  double? weight,
  String mode = 'unknown',
  int? rir,
  bool isTest = false,
}) => GymSet(
  index: index,
  recordedAt: time,
  exerciseName: name,
  reps: reps,
  seconds: seconds,
  weightKg: weight,
  pullupMode: mode,
  rir: rir,
  isTest: isTest,
  note: 'private synthetic note not projected',
);

GymExercise exercise(String id, String name, [List<GymSet> sets = const []]) =>
    GymExercise(id: id, name: name, plannedSets: 3, sets: List.of(sets));

GymSession session(
  String id,
  DateTime date,
  List<GymExercise> exercises, {
  bool completed = false,
}) => GymSession(
  id: id,
  planDay: 'manual',
  title: 'Учебное занятие',
  startedAt: date,
  warmup: '',
  cardioPlan: '',
  endedAt: completed ? date.add(const Duration(minutes: 30)) : null,
  note: 'synthetic session note not projected',
  blocks: [
    GymBlock(
      id: 'A',
      title: 'Блок',
      restMinSeconds: 30,
      restMaxSeconds: 60,
      exercises: exercises,
    ),
  ],
);

String encoded(GymSession value) => jsonEncode(value.toJson());
String key(GymSession value) => '$gymSessionPrefix${value.id}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 20, 9);

  test('uses the saved set name when the exercise is later replaced', () {
    final workout = session('replacement', day, [
      exercise('A1', 'Тяга блока', [
        setFor('Подтягивания', day.add(const Duration(minutes: 1))),
        setFor('Тяга блока', day.add(const Duration(minutes: 2)), index: 2),
      ]),
    ]);
    final before = encoded(workout);
    final result = indexExerciseHistory({key(workout): before});
    final olderName = result.forName('Подтягивания')!;
    final currentName = result.forName('Тяга блока')!;
    expect(olderName.recordedSets, 1);
    expect(olderName.sessions.single.listedInSession, isFalse);
    expect(currentName.recordedSets, 1);
    expect(currentName.sessions.single.listedInSession, isTrue);
    expect(encoded(workout), before);
    expect(result.unreadable, 0);
  });

  test('empty sets are not counted as a performed exercise', () {
    final workout = session('planned', day, [exercise('A1', 'Своя тяга')]);
    final result = indexExerciseHistory({key(workout): encoded(workout)});
    final row = result.forName('Своя тяга')!;
    expect(row.sessions, hasLength(1));
    expect(row.sessions.single.listedInSession, isTrue);
    expect(row.sessions.single.sets, isEmpty);
    expect(row.recordedSets, 0);
    expect(row.sessionsWithSets, 0);
  });

  test('only case and whitespace normalize; similar names remain separate', () {
    final first = session('first', day, [
      exercise('A1', '  ЖИМ  лёжа ', [setFor('ЖИМ  лёжа', day)]),
      exercise('A2', 'Жим лежа', [setFor('Жим лежа', day)]),
      exercise('A3', 'Жим гантелей', [setFor('Жим гантелей', day)]),
    ]);
    final second = session('second', day.add(const Duration(days: 1)), [
      exercise('B1', 'жим лёжа', [setFor('жим лёжа', day)]),
    ]);
    final result = indexExerciseHistory({
      key(first): encoded(first),
      key(second): encoded(second),
    });
    expect(result.forName('Жим лёжа')!.recordedSets, 2);
    expect(result.forName('Жим лёжа')!.sessionsWithSets, 2);
    expect(result.forName('Жим лежа')!.recordedSets, 1);
    expect(result.forName('Жим гантелей')!.recordedSets, 1);
    expect(result.byName, hasLength(3));
  });

  test('same named blocks count as one session and keep all recorded sets', () {
    final workout = session('duplicates', day, [
      exercise('A1', 'Присед', [setFor('Присед', day, reps: 7, weight: 30)]),
      exercise('A2', 'присед', [
        setFor(
          'присед',
          day.add(const Duration(minutes: 2)),
          reps: 5,
          weight: 35,
        ),
      ]),
    ]);
    final row = indexExerciseHistory({
      key(workout): encoded(workout),
    }).forName('ПРИСЕД')!;
    expect(row.sessions, hasLength(1));
    expect(row.sessionsWithSets, 1);
    expect(row.recordedSets, 2);
    expect(row.sessions.single.sets.map((s) => s.weightKg), [30, 35]);
    expect(row.sessions.single.sets.map((s) => s.index), [1, 1]);
  });

  test('sorts sessions by start and sets by actual recorded time', () {
    final old = session('old', day, [
      exercise('A1', 'Тяга', [setFor('Тяга', day)]),
    ], completed: true);
    final recent = session('recent', day.add(const Duration(days: 1)), [
      exercise('A1', 'Тяга', [
        setFor(
          'Тяга',
          day.add(const Duration(days: 1, minutes: 5)),
          index: 1,
          reps: 6,
        ),
        setFor(
          'Тяга',
          day.add(const Duration(days: 1, minutes: 2)),
          index: 2,
          reps: 7,
        ),
      ]),
    ]);
    final row = indexExerciseHistory({
      key(old): encoded(old),
      key(recent): encoded(recent),
    }).forName('Тяга')!;
    expect(row.sessions.map((s) => s.id), ['recent', 'old']);
    expect(row.sessions.map((s) => s.completed), [false, true]);
    expect(row.sessions.first.sets.map((s) => s.index), [2, 1]);
  });

  test(
    'preserves unknown, explicit zero and assisted values without guessing',
    () {
      final workout = session('metrics', day, [
        exercise('A1', 'Подтягивания', [
          setFor('Подтягивания', day, reps: 0, weight: 0),
          setFor(
            'Подтягивания',
            day,
            index: 2,
            reps: 8,
            weight: 22.5,
            mode: 'assisted',
          ),
          setFor('Подтягивания', day, index: 3, reps: 6, mode: 'weighted'),
          setFor(
            'Подтягивания',
            day,
            index: 4,
            reps: 5,
            mode: 'bodyweight',
            isTest: true,
          ),
        ]),
        exercise('A2', 'Планка', [
          setFor('Планка', day, reps: null, seconds: 30),
        ]),
      ]);
      final index = indexExerciseHistory({key(workout): encoded(workout)});
      final values = index.forName('Подтягивания')!.sessions.single.sets;
      expect(
        describeRecordedExerciseSet(values[0]),
        contains('0 повт. · 0 кг, вид не указан'),
      );
      expect(
        describeRecordedExerciseSet(values[1]),
        contains('помощь 22,5 кг'),
      );
      expect(
        describeRecordedExerciseSet(values[1]),
        isNot(contains('доп. вес')),
      );
      expect(
        describeRecordedExerciseSet(values[2]),
        contains('дополнительный вес не указан'),
      );
      expect(
        describeRecordedExerciseSet(values[3]),
        contains('свой вес · технический тест'),
      );
      final timed = index.forName('Планка')!.sessions.single.sets.single;
      expect(timed.reps, isNull);
      expect(describeRecordedExerciseSet(timed), '30 с · вес не указан');
    },
  );

  test('invalid documents are counted, ignored and not changed', () {
    final workout = session('correct', day, [exercise('A1', 'Тяга')]);
    final docs = <String, Object?>{
      key(workout): encoded(workout),
      'gym_session_invalid': '{oops',
      'gym_session_wrong_id': encoded(workout),
      'gym_session_deleted': null,
      'food_entries_2026-10-20': '{other}',
    };
    final before = Map<String, Object?>.from(docs);
    final result = indexExerciseHistory(docs);
    expect(result.unreadable, 2);
    expect(result.byName.keys, ['тяга']);
    expect(docs, before);
    expect(() => result.byName.clear(), throwsUnsupportedError);
    expect(
      () => result.forName('Тяга')!.sessions.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => result.forName('Тяга')!.sessions.single.sets.clear(),
      throwsUnsupportedError,
    );
  });

  group('existing storage and screen', () {
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

    test('cache notices direct sync/import/delete document changes', () async {
      final store = provider.storage.local;
      final empty = readExerciseHistory(store);
      expect(identical(readExerciseHistory(store), empty), isTrue);
      final workout = session('cache', day, [
        exercise('A1', 'Своя тяга', [setFor('Своя тяга', day, weight: 12.75)]),
      ]);
      await store.setString(key(workout), encoded(workout));
      final saved = readExerciseHistory(store);
      expect(identical(empty, saved), isFalse);
      expect(saved.forName('Своя тяга')!.recordedSets, 1);
      await store.setString(key(workout), '{bad');
      expect(readExerciseHistory(store).unreadable, 1);
      await store.remove(key(workout));
      expect(readExerciseHistory(store).byName, isEmpty);
      expect(readExerciseHistory(store).unreadable, 0);
    });

    testWidgets(
      'custom exercise history is responsive, readable and read-only',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final workout = session('screen', day, [
          exercise('A1', 'Тестовая тяга', [
            setFor('Тестовая тяга', day, weight: 12.75),
          ]),
        ]);
        final raw = encoded(workout);
        await tester.runAsync(
          () => provider.storage.writeGymDocument(key(workout), null, raw),
        );
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: provider,
            child: MaterialApp(
              home: Scaffold(body: PlanExercisesScreen(openTraining: () {})),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Тестовая тяга');
        await tester.pumpAndSettle();
        final tile = find.descendant(
          of: find.byType(ExpansionTile),
          matching: find.text('Тестовая тяга'),
        );
        expect(tile, findsOneWidget);
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('История подходов'));
        await tester.tap(find.text('История подходов'));
        await tester.pumpAndSettle();
        expect(find.byType(GymExerciseHistoryScreen), findsOneWidget);
        expect(
          find.textContaining('Записано подходов: 1; занятий с подходами: 1'),
          findsOneWidget,
        );
        expect(find.textContaining('12,75 кг'), findsOneWidget);
        expect(find.text('Занятие в процессе'), findsOneWidget);
        expect(find.textContaining('private synthetic note'), findsNothing);
        expect(provider.storage.local.getString(key(workout)), raw);
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.text('Открыть занятие'));
        await tester.tap(find.text('Открыть занятие'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(GymSessionScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(GymExerciseHistoryScreen), findsOneWidget);
        expect(provider.storage.local.getString(key(workout)), raw);
        await tester.runAsync(
          () => provider.storage.writeGymDocument(key(workout), raw, null),
        );
        await tester.pump();
        expect(
          find.text('Это название больше не найдено в доступных занятиях.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('filters distinguish the program from saved session names', (
      tester,
    ) async {
      final workout = session('filter', day, [
        exercise('A1', 'Уникальная тяга'),
      ]);
      await tester.runAsync(
        () => provider.storage.writeGymDocument(
          key(workout),
          null,
          encoded(workout),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(body: PlanExercisesScreen(openTraining: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Уникальная тяга');
      await tester.pumpAndSettle();
      final tile = find.descendant(
        of: find.byType(ExpansionTile),
        matching: find.text('Уникальная тяга'),
      );
      expect(tile, findsOneWidget);
      await tester.ensureVisible(find.text('Из программы'));
      await tester.tap(find.text('Из программы'));
      await tester.pumpAndSettle();
      expect(tile, findsNothing);
      expect(find.text('Упражнения не найдены.'), findsOneWidget);
      await tester.tap(find.text('Из занятий'));
      await tester.pumpAndSettle();
      expect(tile, findsOneWidget);
      await tester.tap(find.text('Все'));
      await tester.pumpAndSettle();
      expect(tile, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('unreadable session is visibly flagged and remains untouched', (
      tester,
    ) async {
      final store = provider.storage.local;
      await tester.runAsync(() => store.setString('gym_session_bad', '{bad'));
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(body: PlanExercisesScreen(openTraining: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Не удалось прочитать занятий: 1'),
        findsOneWidget,
      );
      expect(store.getString('gym_session_bad'), '{bad');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('AI question uses selected exercise name, not stored history', (
      tester,
    ) async {
      final workout = session('ai', day, [
        exercise('A1', 'Своя тяга', [setFor('Своя тяга', day, weight: 12.75)]),
      ]);
      await tester.runAsync(
        () => provider.storage.writeGymDocument(
          key(workout),
          null,
          encoded(workout),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(body: PlanExercisesScreen(openTraining: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Своя тяга');
      await tester.pumpAndSettle();
      final tile = find.descendant(
        of: find.byType(ExpansionTile),
        matching: find.text('Своя тяга'),
      );
      expect(tile, findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Спросить ИИ об упражнении'));
      await tester.tap(find.text('Спросить ИИ об упражнении'));
      await tester.pumpAndSettle();
      final screen = tester.widget<AiChatScreen>(find.byType(AiChatScreen));
      expect(screen.initialQuestion, contains('Своя тяга'));
      expect(screen.initialQuestion, isNot(contains('12.75')));
      expect(screen.initialQuestion, isNot(contains('private synthetic note')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
