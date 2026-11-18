// Synthetic pasted JSON only; no real clipboard, diary, account or network.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'invalid pasted JSON is rejected before the replacement confirmation',
    (tester) async {
      late AppDataProvider provider;
      const water = 'water_intake_2026-10-25';
      const food = 'food_entries_2026-10-25';
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
        await provider.storage.local.setInt(water, 500);
      });
      final before = provider.storage.local.snapshot();
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<AppDataProvider>.value(
            value: provider,
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await tester.scrollUntilVisible(
          find.text('Импортировать из JSON'),
          350,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text('Импортировать из JSON'));
        await tester.pumpAndSettle();
        Future<void> enter(String text) async {
          await tester.tap(find.text('Импортировать из JSON'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), text);
          await tester.tap(find.text('Импортировать').last);
          await tester.pumpAndSettle();
        }

        await enter(
          jsonEncode({
            'app': 'fitness_tracker',
            'data': {water: 750, food: 'NOT_VALID_JSON'},
          }),
        );
        expect(find.text('Заменить данные?'), findsNothing);
        expect(
          find.textContaining('Копия не прошла проверку импортёра'),
          findsOneWidget,
        );
        expect(provider.storage.local.snapshot(), before);
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        await enter(
          jsonEncode({
            'app': 'fitness_tracker',
            'data': {water: 750, food: '[]'},
          }),
        );
        expect(find.text('Заменить данные?'), findsOneWidget);
        expect(provider.storage.local.snapshot(), before);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(provider.storage.local.snapshot(), before);
        await tester.pump();
      } finally {
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
