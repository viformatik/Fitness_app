// Synthetic interrupted-import checkpoint; no real diary or network.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'recovery checkpoint can be retained only after an honest warning',
    (tester) async {
      late AppDataProvider provider;
      const water = 'water_intake_2026-10-25';
      const food = 'food_entries_2026-10-25';
      late String journal;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        LocalPreferences.memoryForTests = true;
        LocalPreferences.directoryForTests = null;
        LocalPreferences.beforeWriteForTests = null;
        LocalPreferences.rejectWriteKeyForTests = null;
        LocalPreferences.clearImportRecoveryFailure();
        SmartRemote.instance.busy = false;
        provider = AppDataProvider();
        await provider.init();
        final local = provider.storage.local;
        await local.setInt(water, 250);
        journal =
            'P1:${jsonEncode({
              'version': 1,
              'data': {water: 500, food: 'SYNTHETIC_BROKEN_JSON'},
            })}';
        await local.setString(LocalPreferences.importJournalKey, journal);
      });
      final copied = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData')
          copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      try {
        await tester.pumpWidget(
          MaterialApp(home: ImportRecoveryScreen(storage: provider.storage)),
        );
        await tester.tap(find.text('Скопировать резервную копию'));
        await tester.pumpAndSettle();
        expect(
          find.text('Копия не прошла предварительную проверку'),
          findsOneWidget,
        );
        expect(copied, isEmpty);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(copied, isEmpty);
        await tester.tap(find.text('Скопировать резервную копию'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сохранить непроверенную'));
        await tester.pumpAndSettle();
        expect(copied, hasLength(1));
        final data = (jsonDecode(copied.single) as Map)['data'] as Map;
        expect(data, {water: 500, food: 'SYNTHETIC_BROKEN_JSON'});
        expect(
          provider.storage.local.get(LocalPreferences.importJournalKey),
          journal,
        );
        expect(provider.storage.local.getInt(water), 250);
        expect(provider.storage.local.hasPendingImport, isTrue);
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.runAsync(() async {
          provider.dispose();
          LocalPreferences.beforeWriteForTests = null;
          LocalPreferences.onAppWrite = null;
          await LocalPreferences.close();
          SmartRemote.instance.busy = false;
          LocalPreferences.memoryForTests = false;
        });
      }
    },
  );
}
