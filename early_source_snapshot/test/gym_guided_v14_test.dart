import 'package:fitness_tracker/smart/gym_guided.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:fitness_tracker/smart/gym_plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GymSet row(GymExercise e, int index, {int reps = 8}) => GymSet(
  index: index,
  recordedAt: DateTime.utc(2026, 10, 25, 9),
  exerciseName: e.name,
  reps: reps,
);

void main() {
  final at = DateTime.utc(2026, 10, 25, 9);

  test('guided order is A1 then A2 then the next round', () {
    final s = gymDay('tue').start('guided', at);
    var next = gymNextGuidedStep(s)!;
    expect((next.block.id, next.exercise.id, next.index), ('A', 'A1', 1));
    next.exercise.sets.add(row(next.exercise, next.index));
    expect(gymHasNextInRound(next.block, next.exercise.id, next.index), isTrue);
    next = gymNextGuidedStep(s)!;
    expect((next.exercise.id, next.index), ('A2', 1));
    next.exercise.sets.add(row(next.exercise, next.index));
    expect(
      gymHasNextInRound(next.block, next.exercise.id, next.index),
      isFalse,
    );
    next = gymNextGuidedStep(s)!;
    expect((next.exercise.id, next.index), ('A1', 2));
    expect(gymGuidedProgress(s).done, 2);
    expect(gymGuidedProgress(s).total, 18);
  });

  test(
    'unequal pairs skip missing slots and optional test is not automatic',
    () {
      final s = gymDay('thu').start('unequal', at);
      s.blocks = [s.block('B')];
      for (var i = 1; i <= 2; i++) {
        var next = gymNextGuidedStep(s)!;
        expect((next.exercise.id, next.index), ('B1', i));
        next.exercise.sets.add(row(next.exercise, i));
        expect(gymHasNextInRound(next.block, next.exercise.id, i), isTrue);
        next = gymNextGuidedStep(s)!;
        expect((next.exercise.id, next.index), ('B2', i));
        next.exercise.sets.add(row(next.exercise, i));
        expect(gymHasNextInRound(next.block, next.exercise.id, i), isFalse);
      }
      final next = gymNextGuidedStep(s)!;
      expect((next.exercise.id, next.index), ('B2', 3));
      expect(gymHasNextInRound(next.block, next.exercise.id, 3), isFalse);
      next.exercise.sets.add(row(next.exercise, 3));
      expect(gymNextGuidedStep(s), isNull);
      expect(gymGuidedProgress(s), (done: 5, total: 5));
      final sunday = gymDay('sun').start('sunday', at);
      expect(gymNextGuidedStep(sunday)!.block.optional, isFalse);
      expect(gymNextGuidedStep(sunday)!.block.id, 'A');
      expect(gymResumeStartedOptional(sunday), isNull);
      final warmup = sunday.block('T0').exercises.single;
      warmup.sets.add(row(warmup, 1, reps: 5));
      expect(gymNextOptionalStep(sunday, 'T0')!.block.id, 'T1');
      expect(gymResumeStartedOptional(sunday.clone())!.block.id, 'T1');
      final mainExercise = sunday.block('A').exercises.first;
      mainExercise.sets.add(
        GymSet(
          index: 1,
          recordedAt: at.add(const Duration(seconds: 1)),
          exerciseName: mainExercise.name,
          reps: 8,
        ),
      );
      expect(gymResumeStartedOptional(sunday), isNull);
      warmup.sets[0] = GymSet(
        index: 1,
        recordedAt: at.add(const Duration(seconds: 2)),
        exerciseName: warmup.name,
        reps: 5,
      );
      expect(gymResumeStartedOptional(sunday.clone())!.block.id, 'T1');
      final test = sunday.block('T1').exercises.single;
      test.sets.add(row(test, 1, reps: 7));
      expect(gymResumeStartedOptional(sunday), isNull);
      expect(gymNextGuidedStep(gymDay('sat').start('sat', at)), isNull);
    },
  );

  test(
    'timer metadata round-trips, old documents load, adjustments and clear work',
    () {
      final s = gymDay('tue').start('clock', at);
      s.startRest(at, 15, s.block('A').title, isTransition: true, blockId: 'A');
      var copy = s.clone();
      expect(copy.restIsTransition, isTrue);
      expect(copy.restTotalSeconds, 15);
      expect(copy.restBlockId, 'A');
      expect(copy.restRemainingAt(at.add(const Duration(seconds: 5))), 10);
      copy.pauseRest(at.add(const Duration(seconds: 5)));
      copy.adjustRest(at, 15);
      expect(copy.restRemainingAt(at.add(const Duration(days: 1))), 25);
      expect(copy.restTotalSeconds, 25);
      copy.resumeRest(at.add(const Duration(days: 1)));
      expect(
        copy.clone().restRemainingAt(
          at.add(const Duration(days: 1, seconds: 7)),
        ),
        18,
      );
      copy.clearRest();
      expect(copy.restBlockId, isNull);
      expect(copy.restTotalSeconds, isNull);
      expect(copy.restIsTransition, isFalse);
      final legacy = s.toJson()
        ..remove('restBlockId')
        ..remove('restTotalSeconds')
        ..remove('restIsTransition');
      copy = GymSession.fromJson(legacy);
      expect(copy.restRemainingAt(at), 15);
      expect(copy.restIsTransition, isFalse);
      expect(copy.restTotalSeconds, isNull);
    },
  );

  testWidgets('one exercise, decimal inputs and explicit save', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = gymDay('tue').start('widget', at);
    final step = gymNextGuidedStep(s)!;
    GymSet? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: GymGuidedExerciseScreen(
          session: s,
          step: step,
          latest: null,
          now: at,
          busy: false,
          onSave: (value) async {
            saved = value;
            return true;
          },
          onOverview: () {},
          onReplace: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Жим лёжа'), findsOneWidget);
    expect(find.text('Тяга горизонтальная'), findsNothing);
    expect(find.text('Подход 1 из 3'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '8');
    await tester.enterText(find.byType(TextField).at(1), '27,25');
    await tester.tap(find.text('Записать подход'));
    await tester.pumpAndSettle();
    expect(saved?.reps, 8);
    expect(saved?.weightKg, 27.25);
    expect(saved?.exerciseName, 'Жим лёжа');
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard leaves save available and unsaved data is protected', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final s = gymDay('tue').start('keyboard', at);
    final step = gymNextGuidedStep(s)!;
    var openedOverview = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: const EdgeInsets.only(bottom: 260)),
          child: child!,
        ),
        home: GymGuidedExerciseScreen(
          key: const ValueKey('keyboard-test'),
          session: s,
          step: step,
          latest: null,
          now: at,
          busy: false,
          onOverview: () => openedOverview++,
          onReplace: () {},
          onSave: (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '8');
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.text('Записать подход')).dy,
      lessThanOrEqualTo(568 - 260),
    );
    await tester.tap(find.text('Список'));
    await tester.pumpAndSettle();
    expect(find.text('Подход ещё не записан'), findsOneWidget);
    await tester.tap(find.text('Остаться'));
    await tester.pumpAndSettle();
    expect(openedOverview, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long timer fits a narrow screen with larger text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final s = gymDay('tue').start('long', at);
    s.startRest(at, 86400, s.blocks.first.title, blockId: 'A');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: GymRestScreen(
          session: s,
          next: gymNextGuidedStep(s),
          now: at,
          busy: false,
          onOverview: () {},
          onAdjustDown: () {},
          onAdjustUp: () {},
          onPauseResume: () {},
          onEditTime: () {},
          onSkip: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2:00:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty set is rejected and full-screen timer has manual controls',
    (tester) async {
      tester.view.physicalSize = const Size(320, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final s = gymDay('tue').start('timer_ui', at);
      final step = gymNextGuidedStep(s)!;
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: GymGuidedExerciseScreen(
            session: s,
            step: step,
            latest: null,
            now: at,
            busy: false,
            onSave: (_) async {
              saves++;
              return true;
            },
            onOverview: () {},
            onReplace: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Записать подход'));
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(find.text('Укажите повторения или время подхода'), findsOneWidget);
      expect(tester.takeException(), isNull);
      step.exercise.sets.add(row(step.exercise, step.index));
      s.startRest(
        at,
        15,
        step.block.title,
        isTransition: true,
        blockId: step.block.id,
      );
      var paused = 0, plus = 0, full = 0, skipped = 0, edited = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: GymRestScreen(
            session: s,
            next: gymNextGuidedStep(s),
            now: at,
            busy: false,
            onOverview: () {},
            onAdjustDown: () {},
            onAdjustUp: () => plus++,
            onPauseResume: () => paused++,
            onEditTime: () => edited++,
            onSkip: () => skipped++,
            onFullRest: () => full++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Переход'), findsOneWidget);
      expect(find.text('0:15'), findsOneWidget);
      expect(find.text('Тяга горизонтальная'), findsOneWidget);
      await tester.tap(find.text('+15 с'));
      await tester.tap(find.text('Пауза'));
      await tester.ensureVisible(find.text('Изменить время'));
      await tester.tap(find.text('Изменить время'));
      await tester.ensureVisible(find.text('Полный отдых'));
      await tester.tap(find.text('Полный отдых'));
      await tester.tap(find.text('Пропустить и продолжить'));
      await tester.pumpAndSettle();
      expect((plus, paused, edited, full, skipped), (1, 1, 1, 1, 1));
      expect(tester.takeException(), isNull);
    },
  );
}
