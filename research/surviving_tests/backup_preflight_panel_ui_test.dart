// Synthetic widget tests only; no real diary, account, server, or network.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/ui.dart' show BackupPanel;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'JSON, CSV and previous checkpoint warn before sharing or copying',
    (tester) async {
      late AppDataProvider provider;
      const water = 'water_intake_2026-10-25';
      const food = 'food_entries_2026-10-25';
      late String checkpoint;
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
        await local.setInt(water, 750);
        await local.setString(food, 'SYNTHETIC_BROKEN_JSON');
        await local.setString('_ai_consent_synthetic', 'PRIVATE_FIXTURE_ONLY');
        checkpoint =
            'C1:${jsonEncode({
              'version': 1,
              'data': {water: 500, food: 'SYNTHETIC_PREVIOUS_BAD'},
            })}';
        await local.setString(LocalPreferences.importJournalKey, checkpoint);
      });
      final before = provider.storage.local.snapshot();
      final copied = <String>[];
      var shareCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const share = MethodChannel('dev.fluttercommunity.plus/share');
      messenger.setMockMethodCallHandler(share, (call) async {
        shareCalls++;
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData')
          copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: BackupPanel(provider: provider),
              ),
            ),
          ),
        );
        for (final label in ['Экспорт JSON', 'Экспорт CSV']) {
          await tester.tap(find.text(label));
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
          expect(
            find.text('Копия не прошла предварительную проверку'),
            findsOneWidget,
          );
          expect(shareCalls, 0);
          expect(copied, isEmpty);
          await tester.tap(find.text('Отмена'));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('Скопировать копию до импорта'));
        await tester.tap(find.text('Скопировать копию до импорта'));
        await tester.pumpAndSettle();
        expect(
          find.text('Копия не прошла предварительную проверку'),
          findsOneWidget,
        );
        expect(copied, isEmpty);
        await tester.tap(find.text('Сохранить непроверенную'));
        await tester.pumpAndSettle();
        expect(copied, hasLength(1));
        expect((jsonDecode(copied.single) as Map)['data'], {
          water: 500,
          food: 'SYNTHETIC_PREVIOUS_BAD',
        });
        expect(copied.single, isNot(contains('PRIVATE_FIXTURE_ONLY')));
        expect(provider.storage.local.snapshot(), before);
        expect(
          provider.storage.local.get(LocalPreferences.importJournalKey),
          checkpoint,
        );
        expect(shareCalls, 0);
        await tester.pump();
      } finally {
        messenger.setMockMethodCallHandler(share, null);
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
