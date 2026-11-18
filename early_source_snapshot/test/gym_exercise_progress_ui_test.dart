import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/gym_exercise_history.dart';
import 'package:fitness_tracker/smart/gym_exercise_history_ui.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

GymSession workout(
  String id,
  DateTime time,
  String name,
  int reps,
  double weight, {
  String mode = 'unknown',
}) => GymSession(
  id: id,
  planDay: 'manual',
  title: 'Тестовое занятие $id',
  startedAt: time,
  warmup: '',
  cardioPlan: '',
  note: 'synthetic secret session note',
  blocks: [
    GymBlock(
      id: 'A',
      title: 'Тестовый блок',
      restMinSeconds: 30,
      restMaxSeconds: 60,
      exercises: [
        GymExercise(
          id: 'A1',
          name: name,
          plannedSets: 1,
          sets: [
            GymSet(
              index: 1,
              recordedAt: time.add(const Duration(minutes: 1)),
              exerciseName: name,
              reps: reps,
              weightKg: weight,
              pullupMode: mode,
              note: 'synthetic secret set note',
            ),
          ],
        ),
      ],
    ),
  ],
);

String key(GymSession session) => '$gymSessionPrefix${session.id}';
String raw(GymSession session) => jsonEncode(session.toJson());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit opt-in, fresh data, missing values and no diary writes',
    (tester) async {
      LocalPreferences.memoryForTests = true;
      LocalPreferences.onAppWrite = null;
      SharedPreferences.setMockInitialValues({});
      final provider = AppDataProvider();
      await provider.init();
      addTearDown(() {
        LocalPreferences.onAppWrite = null;
        LocalPreferences.memoryForTests = false;
        provider.dispose();
      });
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final start = DateTime.utc(2026, 10, 10, 10);
      final first = workout('old', start, 'Тестовая тяга', 8, 50);
      final second = workout(
        'middle',
        start.add(const Duration(days: 1)),
        'Тестовая тяга',
        6,
        60,
      );
      final third = workout(
        'new',
        start.add(const Duration(days: 2)),
        'Тестовая тяга',
        5,
        70,
      );
      final pull = workout(
        'pull',
        start,
        'Подтягивания',
        6,
        15,
        mode: 'weighted',
      );
      final store = provider.storage.local;
      await tester.runAsync(() async {
        await store.setString(key(first), raw(first));
        await store.setString(key(second), raw(second));
        await store.setString(key(pull), raw(pull));
        await store.setString('gym_session_bad', '{invalid');
      });
      var diaryWrites = 0;
      LocalPreferences.onAppWrite = () => diaryWrites++;
      Widget screen(String name) => MaterialApp(
        home: GymExerciseHistoryScreen(
          provider: provider,
          exerciseKey: exerciseHistoryKey(name),
          initialName: name,
        ),
      );
      await tester.pumpWidget(screen('Тестовая тяга'));
      await tester.pumpAndSettle();
      expect(find.text('Оценка прогресса и 1ПМ'), findsOneWidget);
      await tester.tap(find.text('Оценка прогресса и 1ПМ'));
      await tester.pumpAndSettle();
      expect(find.text('Условная оценка 1ПМ'), findsOneWidget);
      expect(
        find.textContaining('Не пробуйте максимальный вес'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Запас повторений формула не учитывает'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Не доводите подход до отказа'),
        findsOneWidget,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.text('Приблизительная оценка 1ПМ'), findsNothing);

      await tester.tap(find.text('Оценка прогресса и 1ПМ'));
      await tester.pumpAndSettle();
      // The history may change while the confirmation is open. The read-only
      // result must use the current store after the user accepts.
      await tester.runAsync(() => store.setString(key(third), raw(third)));
      expect(diaryWrites, 1); // Only the intentional synthetic edit above.
      diaryWrites = 0;
      final before = {for (final k in store.getKeys()) k: store.get(k)};
      await tester.tap(find.text('Показать оценку'));
      await tester.pumpAndSettle();
      expect(find.text('Приблизительная оценка 1ПМ'), findsOneWidget);
      expect(find.textContaining('оценка 81,7 кг'), findsOneWidget);
      expect(find.textContaining('оценка 72,0 кг'), findsOneWidget);
      expect(
        find.textContaining('Условная разница оценок: +13,4%'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Не удалось прочитать занятий: 1'),
        findsWidgets,
      );
      expect(find.textContaining('synthetic secret'), findsNothing);
      expect({for (final k in store.getKeys()) k: store.get(k)}, before);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(screen('Подтягивания'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Оценка прогресса и 1ПМ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать оценку'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Нет подходящих записей'), findsOneWidget);
      expect(
        find.textContaining('не означает нулевой результат'),
        findsOneWidget,
      );
      expect(find.textContaining('Условная разница оценок'), findsNothing);
      expect({for (final k in store.getKeys()) k: store.get(k)}, before);
      expect(diaryWrites, 0);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();

      final tieA = workout('tie_a', start, 'Тестовый присед', 6, 20);
      final tieB = workout('tie_b', start, 'Тестовый присед', 6, 50);
      await tester.runAsync(() async {
        await store.setString(key(tieA), raw(tieA));
        await store.setString(key(tieB), raw(tieB));
      });
      expect(diaryWrites, 2);
      diaryWrites = 0;
      final tieBefore = {for (final k in store.getKeys()) k: store.get(k)};
      await tester.pumpWidget(screen('Тестовый присед'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Оценка прогресса и 1ПМ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать оценку'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'У нескольких последних подходящих занятий одинаковое время',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Их последовательность неизвестна'),
        findsOneWidget,
      );
      expect(find.textContaining('Условная разница оценок'), findsNothing);
      expect({for (final k in store.getKeys()) k: store.get(k)}, tieBefore);
      expect(diaryWrites, 0);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();

      final tieLatest = workout(
        'tie_latest',
        start.add(const Duration(days: 1)),
        'Тестовый присед',
        6,
        60,
      );
      await tester.runAsync(
        () => store.setString(key(tieLatest), raw(tieLatest)),
      );
      expect(diaryWrites, 1);
      diaryWrites = 0;
      final tieLatestBefore = {
        for (final k in store.getKeys()) k: store.get(k),
      };
      await tester.tap(find.text('Оценка прогресса и 1ПМ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать оценку'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Несколько предыдущих подходящих занятий имеют одинаковое время',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('оценка 72,0 кг'), findsOneWidget);
      expect(find.textContaining('Условная разница оценок'), findsNothing);
      expect({
        for (final k in store.getKeys()) k: store.get(k),
      }, tieLatestBefore);
      expect(diaryWrites, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
