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

  testWidgets('backup panel reports an unsafe snapshot and does not share it', (
    tester,
  ) async {
    late AppDataProvider provider;
    await tester.runAsync(() async {
      provider = await setup();
    });
    var shareCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const share = MethodChannel('dev.fluttercommunity.plus/share');
    messenger.setMockMethodCallHandler(share, (call) async {
      shareCalls++;
      return null;
    });
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BackupPanel(provider: provider)),
        ),
      );
      await tester.tap(find.text('Экспорт JSON'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Не удалось безопасно создать копию'),
        findsOneWidget,
      );
      expect(shareCalls, 0);
      expect(provider.storage.local.get(water), {'unexpected': true});
      await tester.pump();
    } finally {
      messenger.setMockMethodCallHandler(share, null);
      await tester.runAsync(() => cleanup(provider));
    }
  });
}
