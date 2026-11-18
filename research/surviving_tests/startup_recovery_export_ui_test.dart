// Synthetic records and fake sharing only; no real diary, cloud or filesystem.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/startup_recovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
// Only used to intercept the platform channel in this isolated widget test.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart'
    show SharePlatform;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeShare extends SharePlatform {
  final List<String> payloads = [];
  int attempts = 0;
  bool failNext = false;

  @override
  Future<ShareResult> share(ShareParams params) async {
    attempts++;
    if (failNext) {
      failNext = false;
      throw StateError('SYNTHETIC_SHARE_ERROR');
    }
    final file = params.files!.single;
    payloads.add(utf8.decode(await file.readAsBytes()));
    return const ShareResult('synthetic', ShareResultStatus.success);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit salvage, cancellation and failures do not alter storage',
    (tester) async {
      const badKey = 'food_entries_2001-02-03';
      const waterKey = 'water_intake_2001-02-03';
      const bad = 'SYNTHETIC_BROKEN_JSON';
      const privateKey = '_ai_consent_synthetic';
      const privateValue = 'PRIVATE_FIXTURE_ONLY';
      final fake = _FakeShare();
      final oldPlatform = SharePlatform.instance;
      // SharePlus.instance is lazy: install the fake before the first share.
      SharePlatform.instance = fake;
      SharedPreferences.setMockInitialValues({});
      LocalPreferences.memoryForTests = true;
      LocalPreferences.directoryForTests = null;
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.unbindLocalForTests();
      late AppDataProvider provider;
      try {
        await tester.runAsync(() async {
          provider = AppDataProvider();
          await provider.init();
          await provider.storage.local.setString(badKey, bad);
          await provider.storage.local.setInt(waterKey, 750);
          await provider.storage.local.setString(privateKey, privateValue);
        });
        final local = provider.storage.local;
        final baseline = local.snapshot();
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: StartupRecoveryScreen(
              storage: provider.storage,
              canReadStorage: true,
            ),
          ),
        );
        Future<void> tapVisible(String label) async {
          final target = find.text(label);
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pump();
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pumpAndSettle();
        }

        await tapVisible('Подготовить копию');
        expect(fake.attempts, 0);
        expect(
          find.textContaining('не прошли проверку импортёра'),
          findsOneWidget,
        );
        expect(find.textContaining(bad), findsNothing);
        expect(find.textContaining(privateValue), findsNothing);
        await tapVisible('Отмена');
        expect(fake.attempts, 0);
        expect(local.snapshot(), baseline);
        await tapVisible('Подготовить копию');
        await tapVisible('Сохранить непроверенную копию');
        expect(fake.attempts, 1);
        expect(fake.payloads, hasLength(1));
        final data = (jsonDecode(fake.payloads.single) as Map)['data'] as Map;
        expect(data[badKey], bad);
        expect(data[waterKey], 750);
        expect(fake.payloads.single, isNot(contains(privateValue)));
        expect(local.snapshot(), baseline);
        expect(local.get(privateKey), privateValue);
        expect(
          find.textContaining('Проверьте, появился ли файл'),
          findsOneWidget,
        );

        // A stale or unavailable store must never be offered for export.
        await tester.pumpWidget(
          MaterialApp(
            home: StartupRecoveryScreen(
              storage: provider.storage,
              canReadStorage: false,
            ),
          ),
        );
        expect(find.text('Подготовить копию'), findsNothing);
        expect(
          find.textContaining('доступ к локальному хранилищу'),
          findsOneWidget,
        );
        expect(fake.attempts, 1);
        expect(local.snapshot(), baseline);

        // An unsupported type must fail closed, with no partial file or data in
        // the message. The synthetic map is intentionally outside export types.
        await tester.runAsync(() async {
          await local.put('steps_2001-02-03', {'x': 'SYNTHETIC_UNSUPPORTED'});
        });
        final unsupported = local.snapshot();
        await tester.pumpWidget(
          MaterialApp(
            home: StartupRecoveryScreen(
              storage: provider.storage,
              canReadStorage: true,
            ),
          ),
        );
        await tapVisible('Подготовить копию');
        expect(
          find.textContaining('Не удалось подготовить копию'),
          findsOneWidget,
        );
        expect(find.textContaining('SYNTHETIC_UNSUPPORTED'), findsNothing);
        expect(find.text('Сохранить непроверенную копию'), findsNothing);
        expect(fake.attempts, 1);
        expect(local.snapshot(), unsupported);

        // A valid-format snapshot is still called unverified; a platform error
        // must be visible, never reported as a successful saved file.
        await tester.runAsync(() async {
          await local.remove('steps_2001-02-03');
          await local.remove(badKey);
        });
        await tapVisible('Подготовить копию');
        expect(
          find.textContaining('полнота и восстановление не проверены'),
          findsOneWidget,
        );
        fake.failNext = true;
        await tapVisible('Сохранить непроверенную копию');
        expect(fake.attempts, 2);
        expect(find.textContaining('Не удалось передать файл'), findsOneWidget);
        expect(find.text('Сохранить непроверенную копию'), findsOneWidget);
        expect(local.get(waterKey), 750);
        expect(local.get(privateKey), privateValue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        SharePlatform.instance = oldPlatform;
        SmartRemote.instance.unbindLocalForTests();
        await tester.runAsync(() async {
          provider.dispose();
          await LocalPreferences.close();
        });
        LocalPreferences.memoryForTests = false;
      }
    },
  );
}
