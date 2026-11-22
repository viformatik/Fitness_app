// Temporary synthetic path and storage only; no real diary or network.
import 'dart:io';

import 'package:fitness_tracker/legacy.dart' as app;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/startup_recovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('failed store open never exports an older singleton wrapper', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    LocalPreferences.clearImportRecoveryFailure();
    SmartRemote.instance.unbindLocalForTests();
    late Directory temp;
    late app.AppDataProvider oldProvider;
    try {
      await tester.runAsync(() async {
        oldProvider = app.AppDataProvider();
        await oldProvider.init();
        await oldProvider.storage.local.setInt('water_intake_2001-02-03', 750);
        oldProvider.dispose();
        temp = await Directory.systemTemp.createTemp('fitness_startup_test_');
        await File('${temp.path}/not_a_directory').writeAsString('SYNTHETIC');
      });
      LocalPreferences.memoryForTests = false;
      LocalPreferences.directoryForTests = '${temp.path}/not_a_directory';
      await tester.runAsync(() => app.main());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(StartupRecoveryScreen), findsOneWidget);
      expect(find.text('Не удалось открыть дневник'), findsOneWidget);
      expect(find.text('Подготовить копию'), findsNothing);
      expect(
        find.textContaining('доступ к локальному хранилищу'),
        findsOneWidget,
      );
      expect(LocalPreferences.onAppWrite, isNull);
      expect(
        File('${temp.path}/not_a_directory').readAsStringSync(),
        'SYNTHETIC',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      SmartRemote.instance.unbindLocalForTests();
      await tester.runAsync(() async {
        await LocalPreferences.close();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      LocalPreferences.directoryForTests = null;
      LocalPreferences.memoryForTests = false;
    }
  });
}
