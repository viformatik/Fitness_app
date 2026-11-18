// Verifies only a synthetic example reconstructed after an environment reset.
// The original lab prototype source is missing; this fixture's SHA-256 matches
// the earlier manifest, but that does not restore the lost HTML/JS prototype.
// This is NOT a released recovery tool and never reads real data.
import 'dart:convert';
import 'dart:io';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'synthetic prototype snapshot imports and retains pre-import checkpoint',
    () async {
      LocalPreferences.memoryForTests = true;
      LocalPreferences.directoryForTests = null;
      LocalPreferences.beforeWriteForTests = null;
      LocalPreferences.rejectWriteKeyForTests = null;
      LocalPreferences.clearImportRecoveryFailure();
      SharedPreferences.setMockInitialValues({});
      final provider = AppDataProvider();
      try {
        await provider.init();
        final local = provider.storage.local;
        await local.setInt('water_intake_2026-10-24', 600);
        await local.setString('_ai_consent_synthetic', 'local-only');
        final before = local.snapshot();
        final raw = await File(
          'checks/recovery_prototype/synthetic_import_example.json',
        ).readAsString();
        final fixture = jsonDecode(raw) as Map<String, dynamic>;
        expect(fixture['app'], 'fitness_tracker');
        expect(fixture['version'], 2);
        expect(fixture['data'], {
          'food_entries_2026-10-25': '[]',
          'steps_2026-10-25': 100,
          'water_intake_2026-10-25': 250,
          'workout_completed_2026-10-25': false,
          'workout_entries_2026-10-25': '[]',
        });
        expect(await provider.importDataJson(raw), isNull);
        expect(local.snapshot(), fixture['data']);
        expect(
          (jsonDecode(provider.storage.importBackupJson()!) as Map)['data'],
          before,
        );
        expect(local.getString('_ai_consent_synthetic'), 'local-only');
        expect(local.importSyncPaused, isTrue);
      } finally {
        LocalPreferences.beforeWriteForTests = null;
        LocalPreferences.rejectWriteKeyForTests = null;
        LocalPreferences.clearImportRecoveryFailure();
        SmartRemote.instance.busy = false;
        provider.dispose();
        LocalPreferences.memoryForTests = false;
      }
    },
  );
}
