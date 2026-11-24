import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const water = 'water_intake_2026-10-25';
  const steps = 'steps_2026-10-25';
  late AppDataProvider p;

  Map<String, dynamic> previousCopy(AppDataProvider provider) =>
      jsonDecode(provider.storage.importBackupJson()!) as Map<String, dynamic>;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
  });

  tearDown(() async {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SmartRemote.instance.busy = false;
    p.dispose();
  });

  test('a failed repeated import keeps the previous recovery copy', () async {
    final local = p.storage.local;
    await local.setInt(water, 250);
    expect(
      await p.storage.importData({'data': {water: 800}}),
      isTrue,
    );
    expect(previousCopy(p)['data'], {water: 250});

    var failed = false;
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == steps && !failed) {
        failed = true;
        throw StateError('synthetic import failure');
      }
    };
    await expectLater(
      p.storage.importData({'data': {steps: 400}}),
      throwsStateError,
    );
    LocalPreferences.beforeWriteForTests = null;

    // The rollback restored the latest diary and promoted the older C2 copy
    // back into the single C1 slot instead of losing it.
    expect(local.getInt(water), 800);
    expect(local.hasPendingImport, isFalse);
    expect(local.hasImportBackup, isTrue);
    expect(previousCopy(p)['data'], {water: 250});
    expect(local.get(LocalPreferences.importPrevJournalKey), isNull);
  });

  test('recovery after a failed rollback restores both diary and prior copy',
      () async {
    final local = p.storage.local;
    await local.setInt(water, 250);
    expect(
      await p.storage.importData({'data': {water: 800}}),
      isTrue,
    );

    var importFailed = false;
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == steps && !importFailed) {
        importFailed = true;
        throw StateError('synthetic import failure');
      }
      if (key == water && importFailed) {
        throw StateError('synthetic rollback failure');
      }
    };
    await expectLater(
      p.storage.importData({'data': {steps: 400}}),
      throwsA(isA<ImportRecoveryRequired>()),
    );
    expect(local.hasPendingImport, isTrue);
    expect(local.get(LocalPreferences.importPrevJournalKey), isNotNull);

    LocalPreferences.beforeWriteForTests = null;
    await p.storage.recoverPendingImport();

    expect(local.hasPendingImport, isFalse);
    expect(local.getInt(water), 800);
    expect(local.hasImportBackup, isTrue);
    expect(previousCopy(p)['data'], {water: 250});
    expect(local.get(LocalPreferences.importPrevJournalKey), isNull);
  });

  test('a retained C2 copy alone still counts as an import backup', () async {
    final local = p.storage.local;
    const older = {
      'version': 1,
      'data': {water: 250},
    };
    await local.setString(
      LocalPreferences.importPrevJournalKey,
      '${LocalPreferences.importPrevCommittedPrefix}${jsonEncode(older)}',
    );
    expect(local.hasImportBackup, isTrue);
    expect(local.hasPendingImport, isFalse);
    expect(previousCopy(p)['data'], {water: 250});
    // Clear-all validates both slots before removing them.
    await p.clearAllData();
    expect(local.get(LocalPreferences.importPrevJournalKey), isNull);
  });
}
