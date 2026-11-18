import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/gym_exercise_history.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:fitness_tracker/smart/gym_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/section_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The editor test has its own process: its modal animation mixes Flutter's
// fake clock with an asynchronous singleton mutation queue. This avoids leaving
// a future from a disposed fake-async zone for another test file to await. It
// still verifies the actual document and resulting exercise screen.
GymSession session(String id, DateTime day, List<GymExercise> exercises) =>
    GymSession(
      id: id,
      planDay: 'manual',
      title: 'Учебное занятие',
      startedAt: day,
      warmup: '',
      cardioPlan: '',
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
GymExercise exercise(String id, String name) =>
    GymExercise(id: id, name: name, plannedSets: 3);
String encoded(GymSession value) => jsonEncode(value.toJson());
String key(GymSession value) => '$gymSessionPrefix${value.id}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 20, 9);
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

  testWidgets('an exercise added in a session appears without a second store', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final workout = session('create', day, [exercise('A1', 'Исходная тяга')]);
    final before = encoded(workout);
    await tester.runAsync(
      () => provider.storage.writeGymDocument(key(workout), null, before),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          home: GymSessionScreen(provider: provider, sessionId: workout.id),
        ),
      ),
    );
    await tester.runAsync(() async {
      await provider.storage.pendingMutations;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Список'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final add = find.text('Добавить свой блок');
    await tester.scrollUntilVisible(
      add,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Новое упражнение'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Своя новая тяга');
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final raw = provider.storage.local.getString(key(workout));
    expect(raw, isNot(before));
    final saved = readExerciseHistory(
      provider.storage.local,
    ).forName('Своя новая тяга')!;
    expect(saved.sessions.single.listedInSession, isTrue);
    expect(saved.recordedSets, 0);
    expect(
      provider.storage.local.getKeys().where((k) => k.contains('exercise')),
      isEmpty,
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
    await tester.enterText(find.byType(TextField).first, 'Своя новая тяга');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ExpansionTile),
        matching: find.text('Своя новая тяга'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Подходы пока не записаны'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
