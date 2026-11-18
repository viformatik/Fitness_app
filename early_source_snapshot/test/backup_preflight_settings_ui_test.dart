// Synthetic widget tests only; no real diary, account, server, or network.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const food = 'food_entries_2026-10-25';
  const water = 'water_intake_2026-10-25';

  testWidgets(
    'settings warns before copying but retains an explicit salvage path',
    (tester) async {
      late AppDataProvider provider;
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
        await provider.storage.local.setInt(water, 750);
        await provider.storage.local.setString(food, 'SYNTHETIC_BROKEN_JSON');
        await provider.storage.local.setString(
          '_ai_consent_synthetic',
          'PRIVATE_FIXTURE_ONLY',
        );
      });
      final before = provider.storage.local.snapshot();
      final copied = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<AppDataProvider>.value(
            value: provider,
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await tester.scrollUntilVisible(
          find.text('Экспортировать в JSON'),
          350,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text('Экспортировать в JSON'));
        await tester.pumpAndSettle();
        Future<void> open() async {
          await tester.tap(find.text('Экспортировать в JSON'));
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pumpAndSettle();
        }

        await open();
        expect(
          find.text('Копия не прошла предварительную проверку'),
          findsOneWidget,
        );
        expect(copied, isEmpty);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(copied, isEmpty);
        expect(provider.storage.local.snapshot(), before);
        await open();
        await tester.tap(find.text('Сохранить непроверенную'));
        await tester.pumpAndSettle();
        expect(copied, hasLength(1));
        final exported = jsonDecode(copied.single) as Map;
        expect((exported['data'] as Map)[water], 750);
        expect((exported['data'] as Map)[food], 'SYNTHETIC_BROKEN_JSON');
        expect(copied.single, isNot(contains('PRIVATE_FIXTURE_ONLY')));
        expect(find.textContaining('Копия непроверенная'), findsOneWidget);
        expect(provider.storage.local.snapshot(), before);
        await tester.pump();
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
