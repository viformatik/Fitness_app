// Disposable synthetic data; no live cloud or real diary.
import 'package:fitness_tracker/legacy.dart' as app;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/startup_recovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('a clean startup retains the normal diary and sync binding', (
    tester,
  ) async {
    const waterKey = 'water_intake_2001-02-03';
    SharedPreferences.setMockInitialValues({waterKey: 750});
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    LocalPreferences.clearImportRecoveryFailure();
    SmartRemote.instance.unbindLocalForTests();
    app.AppDataProvider? provider;
    try {
      await tester.runAsync(() => app.main());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(app.MyApp), findsOneWidget);
      expect(find.byType(StartupRecoveryScreen), findsNothing);
      provider = tester.widget<app.MyApp>(find.byType(app.MyApp)).provider;
      expect(provider.startupStorageOpened, isTrue);
      expect(provider.storage.local.get(waterKey), 750);
      expect(LocalPreferences.onAppWrite, isNotNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      SmartRemote.instance.unbindLocalForTests();
      provider?.dispose();
      await tester.runAsync(() async => LocalPreferences.close());
      LocalPreferences.memoryForTests = false;
    }
  });
}
