// Regression for the historical "import -> new provider -> init()" scenario.
// Synthetic data only; the Hive-backed case uses a temporary directory.
import 'dart:async';
import 'dart:io';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const water = 'water_intake_2026-10-25';

  Future<void> scenario({bool expectPersistedBackup = false}) async {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SharedPreferences.setMockInitialValues({});
    final first = AppDataProvider();
    await first.init().timeout(const Duration(seconds: 10));
    await first.storage.local.setInt(water, 250);
    await first.storage.importData({'data': {water: 800}});
    final second = AppDataProvider();
    await second.init().timeout(const Duration(seconds: 10));
    expect(second.isLoading, isFalse);
    expect(second.storage.local.hasPendingImport, isFalse);
    if (expectPersistedBackup) {
      expect(second.storage.local.hasImportBackup, isTrue);
    }
  }

  test('in-memory store: init completes after an import in the same process',
      () async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    addTearDown(() {
      LocalPreferences.memoryForTests = false;
      SmartRemote.instance.busy = false;
    });
    await scenario();
  });

  test('Hive-backed store: init completes after an import in the same process',
      () async {
    final dir = await Directory.systemTemp.createTemp('fitness_import_init_');
    LocalPreferences.memoryForTests = false;
    LocalPreferences.directoryForTests = dir.path;
    addTearDown(() async {
      await LocalPreferences.close();
      await dir.delete(recursive: true);
      LocalPreferences.directoryForTests = null;
      LocalPreferences.memoryForTests = false;
      SmartRemote.instance.busy = false;
    });
    await scenario(expectPersistedBackup: true);
  });
}
