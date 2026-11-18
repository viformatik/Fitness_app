import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/ai_actions.dart';
import 'package:fitness_tracker/smart/ai_drafts.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _water = 'water_intake_2026-10-25';
const _steps = 'steps_2026-10-25';
const _draft = <String, dynamic>{
  'name': 'Тестовое блюдо',
  'grams': 100.0,
  'calories': 80.0,
  'protein': 4.0,
  'fat': 2.0,
  'carbs': 10.0,
  'meal': 'lunch',
};

// Attach an error handler immediately while the exclusive operation is paused.
Future<Object?> _outcome(Future<dynamic> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

Future<SupabaseClient> _syntheticClient() async {
  final client = SupabaseClient(
    'https://clear-test.example.invalid',
    'test-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.setInitialSession(
    jsonEncode({
      'access_token': 'synthetic-only',
      'token_type': 'bearer',
      'user': {
        'id': 'owner',
        'app_metadata': {},
        'user_metadata': {},
        'aud': 'authenticated',
        'created_at': '2026-10-25T00:00:00Z',
      },
    }),
  );
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SharedPreferences.setMockInitialValues({});
    SmartRemote.instance.client = null;
    SmartRemote.instance.busy = false;
    provider = AppDataProvider();
    await provider.init();
  });

  tearDown(() async {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SmartRemote.instance.client = null;
    SmartRemote.instance.busy = false;
    provider.dispose();
  });

  test(
    'full clear rejects all overlapping local AI and voice writes',
    () async {
      final store = provider.storage.local;
      await store.setInt(_water, 250); // First key to be deleted.
      await AiConsent(store, 'old').accept();
      await AiFavorites(store, 'old').save('Набор', [_draft]);
      await AiDraftCache(store, 'old').remember([_draft]);
      await AiUndoStore(store, 'old').remember([
        {'id': 'one', 'date': '2026-10-25'},
      ]);
      await store.setString('_voice_notice_v1', 'accepted');

      final started = Completer<void>();
      final release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == _water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      try {
        final clearing = provider.storage.clearAll();
        await started.future.timeout(const Duration(seconds: 5));
        expect(LocalPreferences.importInProgress, isTrue);
        // The raw approval is still waiting for deletion, but it must not
        // authorize a new request while the user-confirmed clear is active.
        expect(store.getString('_ai_consent_old'), isNotNull);
        expect(AiConsent(store, 'old').accepted, isFalse);
        final attempts = <String, Future<Object?>>{
          'consent': _outcome(
            AiConsent(store, 'new').accept(authorizationGuard: () => true),
          ),
          'draft': _outcome(AiDraftCache(store, 'new').remember([_draft])),
          'favorites': _outcome(
            AiFavorites(store, 'new').save('Набор', [_draft]),
          ),
          'undo': _outcome(
            AiUndoStore(store, 'new').remember([
              {'id': 'two', 'date': '2026-10-25'},
            ]),
          ),
          'voice': _outcome(store.setString('_voice_notice_v1', 'accepted')),
          'mixed batch': _outcome(
            store.putBatch({'_ai_drafts_batch': 'new', '_other_batch': 'new'}),
          ),
          'app document': _outcome(store.setInt(_steps, 999)),
        };
        // Unrelated internal state is not removed by clear; the gate does not
        // pretend to cover every possible Hive key.
        expect(await store.setString('_unrelated_local', 'retained'), isTrue);
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await clearing.timeout(const Duration(seconds: 5));
        for (final item in attempts.entries) {
          expect(
            await item.value.timeout(const Duration(seconds: 5)),
            isA<StateError>(),
            reason: item.key,
          );
        }
        expect(store.snapshot(), isEmpty);
        expect(store.getKeys().where((key) => key.startsWith('_ai_')), isEmpty);
        expect(store.getString('_voice_notice_v1'), isNull);
        expect(store.getString('_other_batch'), isNull);
        expect(store.getString('_unrelated_local'), 'retained');
        expect(AiConsent(store, 'new').accepted, isFalse);
        // A new explicit consent after the operation remains possible.
        await AiConsent(store, 'new').accept(authorizationGuard: () => true);
        expect(AiConsent(store, 'new').accepted, isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
        LocalPreferences.beforeWriteForTests = null;
      }
    },
  );

  test(
    'pre-existing queued AI write completes before clear snapshots keys',
    () async {
      final store = provider.storage.local;
      final started = Completer<void>();
      final release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == '_ai_favorites_prior' && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      try {
        final before = store.setString('_ai_favorites_prior', 'old');
        await started.future.timeout(const Duration(seconds: 5));
        final clearing = provider.storage.clearAll();
        // clearAll schedules its exclusive operation on the mutation queue.
        await Future<void>.delayed(Duration.zero);
        expect(LocalPreferences.importInProgress, isTrue);
        final late = _outcome(store.setString('_ai_drafts_after', 'stale'));
        release.complete();
        await before.timeout(const Duration(seconds: 5));
        await clearing.timeout(const Duration(seconds: 5));
        expect(
          await late.timeout(const Duration(seconds: 5)),
          isA<StateError>(),
        );
        expect(store.getString('_ai_favorites_prior'), isNull);
        expect(store.getString('_ai_drafts_after'), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        LocalPreferences.beforeWriteForTests = null;
      }
    },
  );

  test(
    'normal import preserves AI state and allows immediate consent revocation',
    () async {
      final store = provider.storage.local;
      await store.setInt(_water, 250);
      final consent = AiConsent(store, 'old');
      await consent.accept();
      await AiFavorites(store, 'old').save('До импорта', [_draft]);
      await store.setString('_voice_notice_v1', 'accepted');
      final started = Completer<void>();
      final release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == _water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      try {
        final importing = provider.storage.importData({
          'data': {_water: 800},
        });
        await started.future.timeout(const Duration(seconds: 5));
        expect(LocalPreferences.importInProgress, isTrue);
        expect(consent.accepted, isTrue);
        await consent.revoke().timeout(const Duration(seconds: 5));
        expect(consent.accepted, isFalse);
        await AiFavorites(store, 'new').save('Во время импорта', [_draft]);
        release.complete();
        expect(await importing.timeout(const Duration(seconds: 5)), isTrue);
        expect(store.getInt(_water), 800);
        expect(AiFavorites(store, 'old').read(), hasLength(1));
        expect(AiFavorites(store, 'new').read(), hasLength(1));
        expect(store.getString('_voice_notice_v1'), 'accepted');
        expect(consent.accepted, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        LocalPreferences.beforeWriteForTests = null;
      }
    },
  );

  test('failed clear releases the gate and reports the failure', () async {
    final store = provider.storage.local;
    await store.setInt(_water, 250);
    await AiConsent(store, 'old').accept();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == '_ai_consent_old')
        throw StateError('Synthetic delete failure');
    };
    await expectLater(provider.storage.clearAll(), throwsStateError);
    expect(LocalPreferences.importInProgress, isFalse);
    // Clearing is not an atomic transaction: failure does not imply rollback.
    LocalPreferences.beforeWriteForTests = null;
    await AiConsent(store, 'new').accept();
    expect(AiConsent(store, 'new').accepted, isTrue);
    await provider.storage.clearAll();
    expect(store.getKeys().where((key) => key.startsWith('_ai_')), isEmpty);
  });

  test('full clear preserves a malformed committed checkpoint', () async {
    final store = provider.storage.local;
    await store.setInt(_water, 250);
    const malformed = 'C1:{broken';
    await store.setString(LocalPreferences.importJournalKey, malformed);
    final generation = store.diaryGeneration;
    await expectLater(
      provider.storage.clearAll(),
      throwsA(isA<ImportRecoveryRequired>()),
    );
    expect(store.getInt(_water), 250);
    expect(store.getString(LocalPreferences.importJournalKey), malformed);
    expect(store.diaryGeneration, generation);
    expect(LocalPreferences.importInProgress, isFalse);
  });

  testWidgets('stored AI and voice approvals cannot start while clearing', (
    tester,
  ) async {
    final store = provider.storage.local;
    late SupabaseClient client;
    late Completer<void> started, release;
    await tester.runAsync(() async {
      started = Completer<void>();
      release = Completer<void>();
      await store.setInt(_water, 250);
      client = await _syntheticClient();
      SmartRemote.instance.client = client;
      await AiConsent(store, 'owner').accept();
      await store.setString('_voice_notice_v1', 'accepted');
    });
    bool? aiAllowed, voiceAllowed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () async {
                    aiAllowed = await ensureAiConsent(context, store, 'owner');
                  },
                  child: const Text('Проверить ИИ'),
                ),
                TextButton(
                  onPressed: () async {
                    voiceAllowed = await ensureVoiceNotice(context, store);
                  },
                  child: const Text('Проверить диктовку'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == _water && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    late Future<void> clearing;
    try {
      await tester.runAsync(() async {
        clearing = provider.storage.clearAll();
        await started.future.timeout(const Duration(seconds: 5));
      });
      await tester.tap(find.text('Проверить ИИ'));
      await tester.tap(find.text('Проверить диктовку'));
      await tester.pumpAndSettle();
      expect(aiAllowed, isFalse);
      expect(voiceAllowed, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(() async {
        release.complete();
        await clearing.timeout(const Duration(seconds: 5));
      });
      expect(AiConsent(store, 'owner').accepted, isFalse);
      expect(store.getString('_voice_notice_v1'), isNull);
    } finally {
      if (!release.isCompleted) release.complete();
      LocalPreferences.beforeWriteForTests = null;
      SmartRemote.instance.client = null;
      await tester.runAsync(() => client.dispose());
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('an open consent dialog is refused if clear starts first', (
    tester,
  ) async {
    final store = provider.storage.local;
    late SupabaseClient client;
    late Completer<void> started, release;
    await tester.runAsync(() async {
      started = Completer<void>();
      release = Completer<void>();
      await store.setInt(_water, 250);
      client = await _syntheticClient();
      SmartRemote.instance.client = client;
    });
    bool? allowed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                allowed = await ensureAiConsent(context, store, 'owner');
              },
              child: const Text('Открыть согласие'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть согласие'));
    await tester.pumpAndSettle();
    expect(find.text('Мне 18+, запомнить'), findsOneWidget);
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == _water && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    late Future<void> clearing;
    try {
      await tester.runAsync(() async {
        clearing = provider.storage.clearAll();
        await started.future.timeout(const Duration(seconds: 5));
      });
      await tester.tap(find.text('Мне 18+, запомнить'));
      await tester.pumpAndSettle();
      expect(allowed, isFalse);
      await tester.runAsync(() async {
        release.complete();
        await clearing.timeout(const Duration(seconds: 5));
      });
      expect(store.getString('_ai_consent_owner'), isNull);
      expect(AiConsent(store, 'owner').accepted, isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      LocalPreferences.beforeWriteForTests = null;
      SmartRemote.instance.client = null;
      await tester.runAsync(() => client.dispose());
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  test('real temporary Hive box stays cleared on reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fitness_clear_ai_',
    );
    await LocalPreferences.close();
    LocalPreferences.memoryForTests = false;
    LocalPreferences.directoryForTests = directory.path;
    try {
      await provider.storage.init();
      var store = provider.storage.local;
      await store.setInt(_water, 250);
      await AiConsent(store, 'old').accept();
      await store.setString('_voice_notice_v1', 'accepted');
      final started = Completer<void>();
      final release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == _water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      try {
        final clearing = provider.storage.clearAll();
        await started.future.timeout(const Duration(seconds: 5));
        final late = _outcome(AiConsent(store, 'new').accept());
        release.complete();
        await clearing.timeout(const Duration(seconds: 5));
        expect(
          await late.timeout(const Duration(seconds: 5)),
          isA<StateError>(),
        );
      } finally {
        if (!release.isCompleted) release.complete();
        LocalPreferences.beforeWriteForTests = null;
      }
      await LocalPreferences.close();
      await provider.storage.init();
      store = provider.storage.local;
      expect(store.snapshot(), isEmpty);
      expect(AiConsent(store, 'old').accepted, isFalse);
      expect(AiConsent(store, 'new').accepted, isFalse);
      expect(store.getString('_voice_notice_v1'), isNull);
    } finally {
      LocalPreferences.beforeWriteForTests = null;
      await LocalPreferences.close();
      LocalPreferences.memoryForTests = true;
      LocalPreferences.directoryForTests = null;
      await directory.delete(recursive: true);
    }
  });
}
