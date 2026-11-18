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
  const water = 'water_intake_2026-10-25';

  Future<AppDataProvider> setup() async {
    SharedPreferences.setMockInitialValues({});
    LocalPreferences.memoryForTests = true;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.clearImportRecoveryFailure();
    SmartRemote.instance.busy = false;
    final provider = AppDataProvider();
    await provider.init();
    await provider.storage.local.put(water, {'unexpected': true});
    return provider;
  }

  Future<void> cleanup(AppDataProvider provider) async {
    provider.dispose();
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    await LocalPreferences.close();
    SmartRemote.instance.busy = false;
  }

  testWidgets('settings reports an unsafe snapshot without copying it', (
    tester,
  ) async {
    late AppDataProvider provider;
    await tester.runAsync(() async {
      provider = await setup();
    });
    var clipboardCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardCalls++;
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
      await tester.tap(find.text('Экспортировать в JSON'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Не удалось безопасно создать копию'),
        findsOneWidget,
      );
      expect(clipboardCalls, 0);
      expect(provider.storage.local.get(water), {'unexpected': true});
      // Drain the StorageService tail in its owning test zone.
      await tester.pump();
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      await tester.runAsync(() => cleanup(provider));
    }
  });
}
