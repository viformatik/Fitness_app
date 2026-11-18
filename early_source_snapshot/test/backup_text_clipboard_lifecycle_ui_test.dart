// Synthetic late clipboard result and a narrow viewport; no user files.
import 'dart:async';

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
  testWidgets(
    'closing text import before clipboard returns does not use a disposed controller',
    (tester) async {
      late AppDataProvider provider;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        LocalPreferences.memoryForTests = true;
        LocalPreferences.directoryForTests = null;
        LocalPreferences.clearImportRecoveryFailure();
        SmartRemote.instance.busy = false;
        provider = AppDataProvider();
        await provider.init();
        await provider.storage.local.setInt('water_intake_2026-10-25', 500);
      });
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      final requested = Completer<void>();
      final response = Completer<Object?>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          if (!requested.isCompleted) requested.complete();
          return response.future;
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
          find.text('Импортировать из JSON'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text('Импортировать из JSON'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Импортировать из JSON'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Вставить из буфера'));
        await tester.pump();
        expect(requested.isCompleted, isTrue);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(find.text('Импорт данных'), findsNothing);
        response.complete({'text': 'LATE_SYNTHETIC_VALUE'});
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(provider.storage.local.getInt('water_intake_2026-10-25'), 500);
      } finally {
        if (!response.isCompleted) response.complete(null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() async {
          provider.dispose();
          LocalPreferences.onAppWrite = null;
          await LocalPreferences.close();
          SmartRemote.instance.busy = false;
          LocalPreferences.memoryForTests = false;
        });
      }
    },
  );
}
