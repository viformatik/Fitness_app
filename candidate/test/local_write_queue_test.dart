import 'dart:async';
import 'dart:io';

import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'food_entries_2026-10-25';

  Future<void> exercise(LocalPreferences a, LocalPreferences b) async {
    await a.setString(key, 'original');
    final started = Completer<void>();
    final release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (written) async {
      if (written == key && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    final guarded = a.compareAndPut(key, 'original', 'guarded');
    await started.future;
    final laterDirect = b.setString(key, 'later-direct');
    await Future<void>.delayed(Duration.zero);
    expect(b.getString(key), 'original');
    release.complete();
    expect(await guarded, isTrue);
    expect(await laterDirect, isTrue);
    expect(a.getString(key), 'later-direct');

    final started2 = Completer<void>();
    final release2 = Completer<void>();
    LocalPreferences.beforeWriteForTests = (written) async {
      if (written == key && !started2.isCompleted) {
        started2.complete();
        await release2.future;
      }
    };
    final direct = a.setString(key, 'direct-first');
    await started2.future;
    final stale = b.compareAndPut(key, 'later-direct', 'stale-guarded');
    release2.complete();
    await direct;
    expect(await stale, isFalse);
    expect(a.getString(key), 'direct-first');

    final started3 = Completer<void>();
    final release3 = Completer<void>();
    LocalPreferences.beforeWriteForTests = (written) async {
      if (written == key && !started3.isCompleted) {
        started3.complete();
        await release3.future;
      }
    };
    final removing = a.remove(key);
    await started3.future;
    final afterRemove = b.compareAndPut(key, 'direct-first', 'stale-again');
    release3.complete();
    await removing;
    expect(await afterRemove, isFalse);
    expect(a.getString(key), isNull);
    LocalPreferences.beforeWriteForTests = null;
  }

  Future<void> exerciseBatch(LocalPreferences a, LocalPreferences b) async {
    const document = 'workout_entries_2026-10-25';
    const flag = 'workout_completed_2026-10-25';
    const water = 'water_intake_2026-10-25';
    await a.setString(document, 'old');
    await a.setBool(flag, false);
    await a.setInt(water, 0);
    final started = Completer<void>();
    final release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == document && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    final batch = a.putBatch({document: 'batch', flag: true});
    await started.future;
    final laterFlag = b.setBool(flag, false);
    final laterDocument = b.setString(document, 'later');
    await Future<void>.delayed(Duration.zero);
    expect(a.getString(document), 'old');
    expect(a.getBool(flag), isFalse);
    release.complete();
    await Future.wait([batch, laterFlag, laterDocument]);
    expect(a.getString(document), 'later');
    expect(a.getBool(flag), isFalse);

    LocalPreferences.beforeWriteForTests = null;
    await Future.wait([
      a.putBatch({document: 'first', flag: true}),
      b.putBatch({flag: false, water: 100}),
      a.putBatch({document: 'last', water: 200}),
    ]).timeout(const Duration(seconds: 5));
    expect(a.getString(document), 'last');
    expect(a.getBool(flag), isFalse);
    expect(a.getInt(water), 200);

    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == flag) throw StateError('Synthetic pre-batch failure');
    };
    await expectLater(
      b.putBatch({document: 'must-not-commit', flag: true}),
      throwsStateError,
    );
    expect(a.getString(document), 'last');
    expect(a.getBool(flag), isFalse);
    LocalPreferences.beforeWriteForTests = null;
    expect(await a.putBatch({document: 'after-failure', flag: true}), isTrue);
    expect(a.getString(document), 'after-failure');
    expect(a.getBool(flag), isTrue);
  }

  test('direct, conditional and batched writes serialize in memory', () async {
    SharedPreferences.setMockInitialValues({});
    LocalPreferences.memoryForTests = true;
    final store = await LocalPreferences.open();
    try {
      await exercise(store, store);
      await exerciseBatch(store, store);
      LocalPreferences.rejectWriteKeyForTests = key;
      await expectLater(store.setString(key, 'bad'), throwsStateError);
      LocalPreferences.rejectWriteKeyForTests = null;
      expect(await store.compareAndPut(key, null, 'recovered'), isTrue);
      expect(store.getString(key), 'recovered');
    } finally {
      LocalPreferences.beforeWriteForTests = null;
      LocalPreferences.rejectWriteKeyForTests = null;
      LocalPreferences.memoryForTests = false;
    }
  });

  test('batch freezes values and signals only after the whole write', () async {
    SharedPreferences.setMockInitialValues({});
    LocalPreferences.memoryForTests = true;
    final store = await LocalPreferences.open();
    const document = 'workout_entries_2026-10-25';
    const flag = 'workout_completed_2026-10-25';
    final started = Completer<void>();
    final release = Completer<void>();
    final observed = <List<Object?>>[];
    try {
      LocalPreferences.onAppWrite = () =>
          observed.add([store.get(document), store.get(flag)]);
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == document && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final values = <String, Object>{document: 'frozen', flag: true};
      final saving = store.putBatch(values);
      await started.future;
      values[document] = 'mutated';
      values[flag] = false;
      expect(observed, isEmpty);
      release.complete();
      expect(await saving, isTrue);
      expect(observed, [
        <Object?>['frozen', true],
      ]);

      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == flag) throw StateError('Synthetic failure');
      };
      await expectLater(
        store.putBatch({document: 'not-saved', flag: false}),
        throwsStateError,
      );
      expect(observed, [
        <Object?>['frozen', true],
      ]);
      expect(store.getString(document), 'frozen');
      expect(store.getBool(flag), isTrue);
    } finally {
      LocalPreferences.onAppWrite = null;
      LocalPreferences.beforeWriteForTests = null;
      LocalPreferences.memoryForTests = false;
    }
  });

  test(
    'two wrappers share single and batch queues around a real Hive box',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('fitness_queue_');
      LocalPreferences.memoryForTests = false;
      LocalPreferences.directoryForTests = directory.path;
      try {
        final a = await LocalPreferences.open();
        final b = await LocalPreferences.open();
        await exercise(a, b);
        await exerciseBatch(a, b);
        await a.setString(key, 'persisted');
        await LocalPreferences.close();
        final reopened = await LocalPreferences.open();
        expect(reopened.getString(key), 'persisted');
        expect(
          reopened.getString('workout_entries_2026-10-25'),
          'after-failure',
        );
        expect(reopened.getBool('workout_completed_2026-10-25'), isTrue);
        expect(reopened.getInt('water_intake_2026-10-25'), 200);
      } finally {
        LocalPreferences.beforeWriteForTests = null;
        await LocalPreferences.close();
        LocalPreferences.directoryForTests = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
