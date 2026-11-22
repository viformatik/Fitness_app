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
  test(
    'a synthetic disk-backed Hive snapshot follows the committed write',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'fitness_backup_fixture_',
      );
      LocalPreferences.memoryForTests = false;
      LocalPreferences.directoryForTests = directory.path;
      LocalPreferences.beforeWriteForTests = null;
      LocalPreferences.rejectWriteKeyForTests = null;
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.busy = false;
      final provider = AppDataProvider();
      final started = Completer<void>(), release = Completer<void>();
      Future<bool>? writing;
      try {
        await provider.init();
        final local = provider.storage.local;
        await local.setInt(water, 250);
        LocalPreferences.beforeWriteForTests = (key) async {
          if (key == water && !started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        writing = local.setInt(water, 500);
        await started.future;
        final snapshot = provider.storage.exportData();
        release.complete();
        expect(await writing, isTrue);
        expect((await snapshot)['data'], {water: 500});
        LocalPreferences.beforeWriteForTests = null;
        await LocalPreferences.close();
        final reopened = await LocalPreferences.open();
        expect(reopened.getInt(water), 500);
      } finally {
        if (!release.isCompleted) release.complete();
        if (writing != null) await writing;
        provider.dispose();
        LocalPreferences.beforeWriteForTests = null;
        LocalPreferences.onAppWrite = null;
        await LocalPreferences.close();
        LocalPreferences.directoryForTests = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
