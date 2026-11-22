// Synthetic malformed checkpoint; no real diary or network.
import 'package:fitness_tracker/legacy.dart' as app;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/startup_recovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'unfinished import uses its dedicated recovery and stays blocked',
    (tester) async {
      const journal = 'P1:SYNTHETIC_INVALID_CHECKPOINT';
      const waterKey = 'water_intake_2001-02-03';
      SharedPreferences.setMockInitialValues({
        LocalPreferences.importJournalKey: journal,
        waterKey: 750,
      });
      LocalPreferences.memoryForTests = true;
      LocalPreferences.directoryForTests = null;
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.unbindLocalForTests();
      try {
        await tester.runAsync(() => app.main());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(app.ImportRecoveryScreen), findsOneWidget);
        expect(find.byType(StartupRecoveryScreen), findsNothing);
        expect(find.text('Импорт был прерван'), findsOneWidget);
        expect(LocalPreferences.onAppWrite, isNull);
        expect(app.StorageService().local.get(waterKey), 750);
        expect(
          app.StorageService().local.get(LocalPreferences.importJournalKey),
          journal,
        );
        expect(app.StorageService().local.hasPendingImport, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        SmartRemote.instance.unbindLocalForTests();
        await tester.runAsync(() async => LocalPreferences.close());
        LocalPreferences.clearImportRecoveryFailure();
        LocalPreferences.memoryForTests = false;
      }
    },
  );
}
