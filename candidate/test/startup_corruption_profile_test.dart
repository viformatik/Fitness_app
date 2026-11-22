// Disposable synthetic storage only. No real diary, cloud or network.
import 'package:fitness_tracker/legacy.dart' as app;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'damaged profile fails closed without replacing it with defaults',
    (tester) async {
      const foodKey = 'user_profile';
      const waterKey = 'water_intake_2001-02-03';
      const bad = 'SYNTHETIC_BROKEN_JSON';
      const privacy = 'PRIVATE_FIXTURE_ONLY';
      SharedPreferences.setMockInitialValues({
        foodKey: bad,
        waterKey: 750,
        '_ai_consent_synthetic': privacy,
      });
      LocalPreferences.memoryForTests = true;
      LocalPreferences.directoryForTests = null;
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.unbindLocalForTests();
      Object? startupError;
      try {
        await tester.runAsync(() async {
          try {
            await app.main();
          } catch (e) {
            startupError = e;
          }
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          startupError,
          isNull,
          reason: 'Show a safe screen, not a blank launch',
        );
        expect(find.text('Не удалось открыть дневник'), findsOneWidget);
        expect(find.textContaining(bad), findsNothing);
        expect(find.textContaining(privacy), findsNothing);
        expect(
          LocalPreferences.onAppWrite,
          isNull,
          reason: 'No sync binding on failure',
        );
        expect(app.StorageService().local.get(foodKey), bad);
        expect(app.StorageService().local.get(waterKey), 750);
        expect(
          app.StorageService().local.get('_ai_consent_synthetic'),
          privacy,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        SmartRemote.instance.unbindLocalForTests();
        await tester.runAsync(() async => LocalPreferences.close());
        LocalPreferences.memoryForTests = false;
      }
    },
  );
}
