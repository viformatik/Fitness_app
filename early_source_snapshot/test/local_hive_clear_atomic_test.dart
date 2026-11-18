// Synthetic LocalPreferences clear test using a disposable Hive directory.
// No account, cloud service, real diary or device database is accessed.
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
  const consent = '_ai_consent_fixture';
  const unrelated = '_unrelated_fixture';
  late Directory directory;
  late LocalPreferences store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fitness_clear_batch_');
    LocalPreferences.memoryForTests = false;
    LocalPreferences.directoryForTests = directory.path;
    store = await LocalPreferences.open();
    await store.setInt(water, 1);
    await store.setInt(steps, 2);
    await store.setBool(workout, false);
    await store.setString(consent, 'synthetic consent');
    await store.setString(unrelated, 'retain');
    await store.setString(
      LocalPreferences.importJournalKey,
      '${LocalPreferences.importCommittedPrefix}{"data":{}}',
    );
  });

  tearDown(() async {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    await LocalPreferences.close();
    LocalPreferences.directoryForTests = null;
    await directory.delete(recursive: true);
  });

  test('failure before the batch leaves every selected key unchanged', () async {
    final before = {
      water: store.get(water),
      steps: store.get(steps),
      workout: store.get(workout),
      consent: store.get(consent),
    };
    final visited = <String>[];
    var notices = 0;
    LocalPreferences.onAppWrite = () => notices++;
    LocalPreferences.beforeWriteForTests = (key) async {
      visited.add(key);
      if (key == water) throw StateError('Synthetic deletion failure');
    };
    await expectLater(
      store.runExclusiveImport(
        () => store.clear(),
        blockLocalPrivacyWrites: true,
      ),
      throwsStateError,
    );
    expect(visited.indexOf(steps), lessThan(visited.indexOf(water)));
    expect({for (final key in before.keys) key: store.get(key)}, before);
    expect(notices, 0);
    expect(LocalPreferences.importInProgress, isFalse);
    LocalPreferences.beforeWriteForTests = null;
    await LocalPreferences.close();
    final reopened = await LocalPreferences.open();
    expect({for (final key in before.keys) key: reopened.get(key)}, before);
  });

  test('successful batch removes app and privacy keys but not journal', () async {
    final notices = <Map<String, Object?>>[];
    LocalPreferences.onAppWrite = () => notices.add({
          water: store.get(water),
          steps: store.get(steps),
          workout: store.get(workout),
          consent: store.get(consent),
        });
    await store.runExclusiveImport(
      () => store.clear(),
      blockLocalPrivacyWrites: true,
    );
    expect(notices, [
      {water: null, steps: null, workout: null, consent: null},
    ]);
    expect(store.getString(unrelated), 'retain');
    expect(store.hasImportBackup, isTrue);
    await LocalPreferences.close();
    final reopened = await LocalPreferences.open();
    expect(reopened.snapshot(), isEmpty);
    expect(reopened.get(consent), isNull);
    expect(reopened.getString(unrelated), 'retain');
    expect(reopened.hasImportBackup, isTrue);
  });

  test('import-style clear preserves privacy keys and signals once', () async {
    var notices = 0;
    LocalPreferences.onAppWrite = () => notices++;
    await store.runExclusiveImport(() => store.clear(includeLocalAi: false));
    expect(store.snapshot(), isEmpty);
    expect(store.getString(consent), 'synthetic consent');
    expect(notices, 1);
    await LocalPreferences.close();
    final reopened = await LocalPreferences.open();
    expect(reopened.snapshot(), isEmpty);
    expect(reopened.getString(consent), 'synthetic consent');
  });

  test('full clear keeps all values if backup deletion fails', () async {
    final journal = store.getString(LocalPreferences.importJournalKey);
    var notices = 0;
    LocalPreferences.onAppWrite = () => notices++;
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == LocalPreferences.importJournalKey) {
        throw StateError('Synthetic backup deletion failure');
      }
    };
    await expectLater(
      store.runExclusiveImport(
        () => store.clear(includeCommittedImportBackup: true),
        blockLocalPrivacyWrites: true,
      ),
      throwsStateError,
    );
    expect(store.getInt(water), 1);
    expect(store.getInt(steps), 2);
    expect(store.getBool(workout), isFalse);
    expect(store.getString(consent), 'synthetic consent');
    expect(store.getString(LocalPreferences.importJournalKey), journal);
    expect(notices, 0);
    LocalPreferences.beforeWriteForTests = null;
    await LocalPreferences.close();
    final reopened = await LocalPreferences.open();
    expect(reopened.getInt(water), 1);
    expect(reopened.getInt(steps), 2);
    expect(reopened.getString(consent), 'synthetic consent');
    expect(reopened.getString(LocalPreferences.importJournalKey), journal);
  });

  test('backup deletion requires a full gate and never removes a pending journal',
      () async {
    await expectLater(
      store.clear(includeCommittedImportBackup: true),
      throwsStateError,
    );
    await expectLater(
      store.runExclusiveImport(
        () => store.clear(includeCommittedImportBackup: true),
      ),
      throwsStateError,
    );
    await expectLater(
      store.runExclusiveImport(
        () => store.clear(
          includeLocalAi: false,
          includeCommittedImportBackup: true,
        ),
        blockLocalPrivacyWrites: true,
      ),
      throwsStateError,
    );
    expect(store.getInt(water), 1);
    expect(store.hasImportBackup, isTrue);
    await store.setString(LocalPreferences.importJournalKey, 'P1:synthetic');
    await expectLater(
      store.runExclusiveImport(
        () => store.clear(includeCommittedImportBackup: true),
        blockLocalPrivacyWrites: true,
      ),
      throwsA(isA<ImportRecoveryRequired>()),
    );
    expect(store.getInt(water), 1);
    expect(store.getString(LocalPreferences.importJournalKey), 'P1:synthetic');
  });

  test('late checkpoint write cannot recreate a backup during full clear',
      () async {
    final started = Completer<void>(), release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    final clearing = store.runExclusiveImport(
      () => store.clear(includeCommittedImportBackup: true),
      blockLocalPrivacyWrites: true,
    );
    await started.future.timeout(const Duration(seconds: 5));
    final stale = store
        .setString(LocalPreferences.importJournalKey, 'C1:late')
        .then<bool>((_) => false, onError: (Object _, StackTrace __) => true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } finally {
      if (!release.isCompleted) release.complete();
      await clearing;
      expect(await stale, isTrue);
    }
    expect(store.snapshot(), isEmpty);
    expect(store.get(LocalPreferences.importJournalKey), isNull);
    expect(store.get(consent), isNull);
  });

  test('gated clear rejects stale write, then permits explicit retry', () async {
    final started = Completer<void>(), release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    final clearing = store.runExclusiveImport(
      () => store.clear(),
      blockLocalPrivacyWrites: true,
    );
    await started.future.timeout(const Duration(seconds: 5));
    final stale = store.setInt(steps, 99).then<bool>((_) => false,
        onError: (Object _, StackTrace __) => true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // No selected value changes before the whole clear reaches the backend.
      expect(store.getInt(steps), 2);
      expect(store.getInt(water), 1);
    } finally {
      if (!release.isCompleted) release.complete();
      await clearing;
      expect(await stale, isTrue);
    }
    expect(store.snapshot(), isEmpty);
    LocalPreferences.beforeWriteForTests = null;
    expect(await store.setInt(steps, 77), isTrue);
    await LocalPreferences.close();
    final reopened = await LocalPreferences.open();
    expect(reopened.getInt(steps), 77);
    expect(reopened.getInt(water), isNull);
  });
}
