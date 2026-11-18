// Synthetic Chromium + real Hive/IndexedDB test; NOT a production restore.
// Only run through Flutter's test runner with its automatically-created,
// disposable browser profile. Never point it at a user profile or real site.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/ai_drafts.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Object?> outcome(Future<dynamic> operation) async {
  try {
    await operation;
    return null;
  } catch (error) {
    return error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'isolated browser Hive rejects privacy writes overlapping clear',
    () async {
      const enabled = bool.fromEnvironment('FITNESS_SYNTHETIC_WEB_TEST');
      if (!enabled ||
          !kIsWeb ||
          !{'127.0.0.1', 'localhost'}.contains(html.window.location.hostname)) {
        throw StateError(
          'Only the disposable loopback browser test is allowed',
        );
      }
      const water = 'water_intake_2026-10-25';
      const item = <String, dynamic>{
        'name': 'Тестовое блюдо',
        'grams': 100.0,
        'calories': 80.0,
        'protein': 4.0,
        'fat': 2.0,
        'carbs': 10.0,
        'meal': 'lunch',
      };
      SharedPreferences.setMockInitialValues({});
      LocalPreferences.memoryForTests = false;
      // Hive's web backend ignores a filesystem path. This non-null value only
      // enables the fault-interleaving hook in this disposable test profile.
      LocalPreferences.directoryForTests = 'synthetic-web-test-only';
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.client = null;
      SmartRemote.instance.busy = false;
      final provider = AppDataProvider();
      final started = Completer<void>();
      final release = Completer<void>();
      Future<void>? clearing;
      try {
        await provider.init();
        var store = provider.storage.local;
        await store.setInt(water, 250);
        await AiConsent(store, 'old').accept();
        await store.setString('_voice_notice_v1', 'accepted');
        LocalPreferences.beforeWriteForTests = (key) async {
          if (key == water && !started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        clearing = provider.storage.clearAll();
        await started.future.timeout(const Duration(seconds: 10));
        expect(store.getString('_ai_consent_old'), isNotNull);
        expect(AiConsent(store, 'old').accepted, isFalse);
        final attempts = <Future<Object?>>[
          outcome(
            AiConsent(store, 'new').accept(authorizationGuard: () => true),
          ),
          outcome(AiDraftCache(store, 'new').remember([item])),
          outcome(AiFavorites(store, 'new').save('Набор', [item])),
          outcome(
            AiUndoStore(store, 'new').remember([
              {'id': 'entry', 'date': '2026-10-25'},
            ]),
          ),
          outcome(store.setString('_voice_notice_v1', 'accepted')),
          outcome(store.putBatch({'_ai_drafts_batch': 'new', '_other': 'new'})),
          outcome(store.setInt('steps_2026-10-25', 999)),
        ];
        release.complete();
        await clearing.timeout(const Duration(seconds: 10));
        for (final attempt in attempts) {
          expect(
            await attempt.timeout(const Duration(seconds: 10)),
            isA<StateError>(),
          );
        }
        expect(store.snapshot(), isEmpty);
        expect(store.getKeys().where((k) => k.startsWith('_ai_')), isEmpty);
        expect(store.getString('_voice_notice_v1'), isNull);
        expect(store.getString('_other'), isNull);
        LocalPreferences.beforeWriteForTests = null;
        await LocalPreferences.close();
        await provider.storage.init();
        store = provider.storage.local;
        expect(store.snapshot(), isEmpty);
        expect(AiConsent(store, 'old').accepted, isFalse);
        expect(AiConsent(store, 'new').accepted, isFalse);
        expect(store.getString('_voice_notice_v1'), isNull);
        await AiConsent(store, 'new').accept(authorizationGuard: () => true);
        await LocalPreferences.close();
        await provider.storage.init();
        expect(AiConsent(provider.storage.local, 'new').accepted, isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
        final pending = clearing;
        if (pending != null) {
          try {
            await pending.timeout(const Duration(seconds: 10));
          } catch (_) {}
        }
        LocalPreferences.beforeWriteForTests = null;
        await LocalPreferences.close();
        LocalPreferences.directoryForTests = null;
        LocalPreferences.clearImportRecoveryFailure();
        SmartRemote.instance.busy = false;
        provider.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
