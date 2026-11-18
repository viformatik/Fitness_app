// Synthetic ordering tests for different LocalPreferences keys on one real,
// temporary Hive box. They never open a user diary or connect to a service.
import 'dart:async';
import 'dart:io';

import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const water = 'water_intake_2026-10-25';
  const steps = 'steps_2026-10-25';
  const workout = 'workout_completed_2026-10-25';
  late Directory directory;
  late LocalPreferences a;
  late LocalPreferences b;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fitness_global_queue_');
    LocalPreferences.memoryForTests = false;
    LocalPreferences.directoryForTests = directory.path;
    a = await LocalPreferences.open();
    b = await LocalPreferences.open();
    await a.setInt(water, 1);
    await a.setInt(steps, 2);
    await a.setBool(workout, false);
  });

  tearDown(() async {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    await LocalPreferences.close();
    LocalPreferences.directoryForTests = null;
    await directory.delete(recursive: true);
  });

  test('different keys on the same Hive box do not enter concurrently', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var secondEntered = false;
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water) {
        if (!started.isCompleted) started.complete();
        await release.future;
      } else if (key == steps) {
        secondEntered = true;
      }
    };
    final first = a.setInt(water, 11);
    await started.future;
    final second = b.setInt(steps, 22);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(secondEntered, isFalse,
          reason: 'The first Hive operation has not completed yet.');
      expect(a.getInt(steps), 2);
    } finally {
      if (!release.isCompleted) release.complete();
      await Future.wait([first, second]);
    }
    expect(secondEntered, isTrue);
    expect(a.getInt(water), 11);
    expect(a.getInt(steps), 22);
    await LocalPreferences.close();
    final reopened = await LocalPreferences.open();
    expect(reopened.getInt(water), 11);
    expect(reopened.getInt(steps), 22);
  });

  test('a failed write is reported and does not poison the next key', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var secondEntered = false;
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water) {
        if (!started.isCompleted) started.complete();
        await release.future;
        throw StateError('Synthetic failure before Hive');
      } else if (key == steps) {
        secondEntered = true;
      }
    };
    final first = a.setInt(water, 11).then<bool>((_) => false,
        onError: (Object _, StackTrace __) => true);
    await started.future;
    final second = b.setInt(steps, 22);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(secondEntered, isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
    }
    expect(a.getInt(water), 1);
    expect(a.getInt(steps), 22);
    LocalPreferences.beforeWriteForTests = null;
    await LocalPreferences.close();
    final reopened = await LocalPreferences.open();
    expect(reopened.getInt(water), 1);
    expect(reopened.getInt(steps), 22);
  });

  test('batch, conditional read and removal share the real-box queue', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var removalEntered = false;
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water && !started.isCompleted) {
        started.complete();
        await release.future;
      } else if (key == steps) {
        removalEntered = true;
      }
    };
    final batch = a.putBatch({water: 11, workout: true});
    await started.future;
    final removing = b.remove(steps);
    final matching = b.matchesQueued(workout, true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(removalEntered, isFalse);
      expect(a.getInt(steps), 2);
      expect(a.getBool(workout), isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      await batch;
      await removing;
      expect(await matching, isTrue);
    }
    expect(a.getInt(water), 11);
    expect(a.getInt(steps), isNull);
    expect(a.getBool(workout), isTrue);
  });

  test('import gate drains queued writes and rejects stale later actions', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    final first = a.setInt(water, 11);
    await started.future;
    var importEntered = false;
    final importing = a.runExclusiveImport(() async {
      importEntered = true;
      expect(a.getInt(water), 11);
      await a.setInt(steps, 33);
    });
    final rejected = b.setInt(steps, 44).then<bool>((_) => false,
        onError: (Object _, StackTrace __) => true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(importEntered, isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      await first;
      await importing;
      expect(await rejected, isTrue);
    }
    expect(importEntered, isTrue);
    expect(a.getInt(water), 11);
    expect(a.getInt(steps), 33);
  });
}
