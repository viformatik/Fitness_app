// Regression for HANDOFF §4.2: after an import in one provider, a fresh
// provider's init() plus diary reads must complete in the same process.
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
  final date = DateTime.parse('2026-10-25');
  // A guard against a hung suite, NOT the proof of correctness: the assertions
  // below also require that init() finished and that diary reads return data.
  const guard = Duration(seconds: 20);

  Future<void> scenario({bool expectPersistedBackup = false}) async {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SharedPreferences.setMockInitialValues({});
    final first = AppDataProvider();
    await first.init().timeout(guard);
    await first.storage.local.setInt(water, 250);
    await first.storage
        .importData({'data': {water: 800}})
        .timeout(guard);

    final second = AppDataProvider();
    await second.init().timeout(guard);
    expect(second.isLoading, isFalse);
    expect(second.storage.local.hasPendingImport, isFalse);

    // The historical hang was located after open(), inside reloadAll().
    // Exercise every documented stage with a bounded wait and read results.
    final food = await second.storage.getFoodEntries(date).timeout(guard);
    final waterValue = await second.storage.getWaterIntake(date).timeout(guard);
    final logs = await second.storage.getDayLogs().timeout(guard);
    final snapshot = second.storage.local.snapshot();
    expect(food, isA<List<FoodEntry>>());
    expect(waterValue, isA<int>());
    expect(logs, isA<List<DayLog>>());
    expect(snapshot, isA<Map<String, dynamic>>());
    if (expectPersistedBackup) {
      // The Hive-backed store is shared by both wrappers in this isolate.
      expect(second.storage.local.hasImportBackup, isTrue);
      expect(waterValue, 800);
    }
  }

  test(
      'an import followed by a fresh provider must not hang (in-memory store)',
      () async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    addTearDown(() {
      LocalPreferences.memoryForTests = false;
      SmartRemote.instance.busy = false;
    });
    await scenario();
  });

  test(
      'an import followed by a fresh provider must not hang (Hive-backed store)',
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
