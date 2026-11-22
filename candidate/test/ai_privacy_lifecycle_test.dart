import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/ai_actions.dart';
import 'package:fitness_tracker/smart/ai_drafts.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/journal_overview_ui.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/supplements.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:fitness_tracker/smart/voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<SupabaseClient> syntheticClient({http.Client? httpClient}) async {
  final client = SupabaseClient(
    'https://privacy-lifecycle.example.invalid',
    'synthetic-key',
    httpClient: httpClient,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.setInitialSession(
    jsonEncode({
      'access_token': 'synthetic-only',
      'token_type': 'bearer',
      'user': {
        'id': 'synthetic-owner',
        'app_metadata': {},
        'user_metadata': {},
        'aud': 'authenticated',
        'created_at': '2026-10-25T00:00:00Z',
      },
    }),
  );
  return client;
}

const draft = <String, dynamic>{
  'name': 'Синтетическая порция',
  'grams': 100.0,
  'calories': 80.0,
  'protein': 4.0,
  'fat': 2.0,
  'carbs': 10.0,
  'meal': 'lunch',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;
  late SupabaseClient client;
  late LocalPreferences store;
  const owner = 'synthetic-owner';

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.clearImportRecoveryFailure();
    SharedPreferences.setMockInitialValues({});
    SmartRemote.instance.busy = false;
    provider = AppDataProvider();
    await provider.init();
    store = provider.storage.local;
    client = await syntheticClient();
    SmartRemote.instance.client = client;
  });
  tearDown(() async {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    SmartRemote.instance.client = null;
    provider.dispose();
    await client.dispose();
  });

  test('revocation is effective before delayed deletion finishes', () async {
    final consent = AiConsent(store, owner);
    await consent.accept();
    final entered = Completer<void>(), release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == consent.key && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    try {
      final revoking = consent.revoke();
      await entered.future.timeout(const Duration(seconds: 5));
      expect(store.getString(consent.key), isNotNull);
      expect(consent.accepted, isFalse);
      release.complete();
      await revoking;
      expect(consent.accepted, isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
    }
  });

  test(
    'failed revocation remains blocked until fresh explicit acceptance',
    () async {
      final consent = AiConsent(store, owner);
      await consent.accept();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == consent.key) throw StateError('Synthetic deletion failure');
      };
      await expectLater(consent.revoke(), throwsStateError);
      expect(store.getString(consent.key), isNotNull);
      expect(consent.accepted, isFalse);
      LocalPreferences.beforeWriteForTests = null;
      await consent.accept();
      expect(consent.accepted, isTrue);
    },
  );

  test(
    'queued full clear immediately blocks previously stored consent',
    () async {
      final day = DateTime(2026, 10, 25);
      final consent = AiConsent(store, owner);
      await consent.accept();
      await store.setInt('water_intake_2026-10-25', 250);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == 'water_intake_2026-10-25' && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final blocker = provider.storage.setWaterIntake(day, 250);
      await started.future.timeout(const Duration(seconds: 5));
      final clearing = provider.storage.clearAll();
      try {
        expect(LocalPreferences.localPrivacyClearInProgress, isTrue);
        expect(consent.accepted, isFalse);
        await expectLater(consent.accept(), throwsStateError);
      } finally {
        if (!release.isCompleted) release.complete();
        await blocker;
        await clearing;
      }
      expect(consent.accepted, isFalse);
    },
  );

  test(
    'queued supplement review checks its original consent at commit',
    () async {
      final consent = AiConsent(store, owner);
      await consent.accept();
      final day = DateTime(2026, 10, 25);
      const key = 'supplement_entries_2026-10-25';
      await store.setString(key, '[]');
      final blocked = Completer<void>(),
          release = Completer<void>(),
          checked = Completer<void>();
      LocalPreferences.beforeWriteForTests = (candidate) async {
        if (candidate == key && !blocked.isCompleted) {
          blocked.complete();
          await release.future;
        }
      };
      final blocker = store.setString(key, '[]');
      try {
        await blocked.future.timeout(const Duration(seconds: 5));
        final epoch = LocalPreferences.privacyEpoch;
        final saving = provider.addSupplementEntriesBatch(
          [
            SupplementEntry(
              id: 'synthetic',
              name: 'Креатин',
              quantity: 1,
              unit: 'g',
              nutrientKey: 'creatine',
              date: day,
              source: 'ai',
            ),
          ],
          authorizationGuard: () {
            if (!checked.isCompleted) checked.complete();
            return consent.validFor(epoch);
          },
        );
        final rejected = expectLater(saving, throwsStateError);
        await checked.future.timeout(const Duration(seconds: 5));
        await consent.revoke();
        await consent.accept();
        release.complete();
        await blocker;
        await rejected;
        expect(store.getString(key), '[]');
        expect(await provider.storage.getSupplementEntries(day), isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  testWidgets('consent dialog opened before a completed clear cannot approve', (
    tester,
  ) async {
    bool? approved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  approved = await ensureAiConsent(context, store, owner),
              child: const Text('Запросить согласие'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Запросить согласие'));
    await tester.pumpAndSettle();
    expect(find.text('Мне 18+, запомнить'), findsOneWidget);
    await tester.runAsync(() => provider.storage.clearAll());
    await tester.runAsync(() async {
      await tester.tap(find.text('Мне 18+, запомнить'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(approved, isFalse);
    expect(AiConsent(store, owner).accepted, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('voice notice opened before a completed clear cannot approve', (
    tester,
  ) async {
    bool? approved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  approved = await ensureVoiceNotice(context, store),
              child: const Text('Открыть уведомление'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть уведомление'));
    await tester.pumpAndSettle();
    expect(find.text('Включить диктовку'), findsOneWidget);
    await tester.runAsync(() => provider.storage.clearAll());
    await tester.runAsync(() async {
      await tester.tap(find.text('Включить диктовку'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(approved, isFalse);
    expect(store.getString('_voice_notice_v1'), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'journal rechecks consent after the pending local snapshot and before HTTP',
    (tester) async {
      final sent = <Uri>[];
      late SupabaseClient monitored;
      late Completer<void> started, release;
      final day = DateTime(2026, 10, 25);
      await tester.runAsync(() async {
        started = Completer<void>();
        release = Completer<void>();
        monitored = await syntheticClient(
          httpClient: MockClient((request) async {
            sent.add(request.url);
            return http.Response(
              jsonEncode({
                'summary': 'Синтетический ответ',
                'observations': <String>[],
                'suggestions': <String>[],
                'limitations': <String>[],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        SmartRemote.instance.client = monitored;
        await provider.setSelectedDate(day);
        await store.setInt('water_intake_2026-10-25', 250);
        await AiConsent(store, owner).accept();
      });
      tester.view.physicalSize = const Size(500, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void>? mutation;
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<AppDataProvider>.value(
            value: provider,
            child: MaterialApp(home: JournalOverviewScreen(provider: provider)),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        final analyze = find.text('Подготовить анализ ИИ');
        await tester.ensureVisible(analyze);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          await tester.tap(analyze);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Отправить в Gemini'), findsOneWidget);
        LocalPreferences.beforeWriteForTests = (key) async {
          if (key == 'water_intake_2026-10-25' && !started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        await tester.runAsync(() async {
          // The value stays identical, so the snapshot comparison alone cannot
          // detect the authorization change while its read is waiting.
          mutation = provider.storage.setWaterIntake(day, 250);
          await started.future.timeout(const Duration(seconds: 5));
          await tester.tap(find.text('Отправить в Gemini'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await AiConsent(store, owner).revoke();
          await AiConsent(store, owner).accept();
          release.complete();
          await mutation;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(sent, isEmpty);
        expect(find.text('Синтетический ответ'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        LocalPreferences.beforeWriteForTests = null;
        await tester.pumpWidget(const SizedBox.shrink());
        SmartRemote.instance.client = client;
        await tester.runAsync(() => monitored.dispose());
      }
    },
  );

  Future<void> exerciseOldFoodResponse(
    WidgetTester tester, {
    required bool clear,
  }) async {
    await tester.runAsync(() => AiConsent(store, owner).accept());
    expect(AiConsent(store, owner).accepted, isTrue);
    late Completer<void> started;
    late Completer<List<Json>> result;
    await tester.runAsync(() async {
      started = Completer<void>();
      result = Completer<List<Json>>();
    });
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiFoodPanel(
                chatMode: true,
                requestOverride:
                    ({required text, image, required mime, required mode}) {
                      started.complete();
                      return result.future;
                    },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final input = find.byWidgetPredicate(
      (w) => w is TextField && w.maxLines == 3 && w.maxLength == 4000,
    );
    await tester.enterText(input, 'Синтетический запрос');
    final submit = find.text('Разобрать и проверить');
    await tester.ensureVisible(submit);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(submit);
      await started.future.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
    await tester.runAsync(() async {
      if (clear) {
        await provider.storage.clearAll();
      } else {
        await AiConsent(store, owner).revoke();
      }
      // A new, unrelated explicit consent must not revive the older request.
      await AiConsent(store, owner).accept();
      result.complete([draft]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AiReviewDialog), findsNothing);
    expect(AiDraftCache(store, owner).read(), isEmpty);
    expect(provider.todayFoodEntries, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets(
    'revocation and later reacceptance cannot revive an old food response',
    (tester) => exerciseOldFoodResponse(tester, clear: false),
  );
  testWidgets(
    'clear and later reacceptance cannot revive an old food response',
    (tester) => exerciseOldFoodResponse(tester, clear: true),
  );

  testWidgets('clear while speech locales load prevents starting recognition', (
    tester,
  ) async {
    late Completer<void> localesStarted;
    late Completer<List<String>> locales;
    await tester.runAsync(() async {
      localesStarted = Completer<void>();
      locales = Completer<List<String>>();
    });
    const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var listenCalls = 0, cancelCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
          return true;
        case 'locales':
          if (!localesStarted.isCompleted) localesStarted.complete();
          return locales.future;
        case 'listen':
          listenCalls++;
          return true;
        case 'cancel':
          cancelCalls++;
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AiFoodPanel(
                  chatMode: true,
                  requestOverride:
                      ({
                        required text,
                        image,
                        required mime,
                        required mode,
                      }) async => [],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Диктовка'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await tester.tap(find.text('Диктовка'));
        await localesStarted.future.timeout(const Duration(seconds: 5));
        await provider.storage.clearAll();
        locales.complete(<String>['ru_RU:Русский']);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(listenCalls, 0);
      expect(cancelCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    } finally {
      if (!locales.isCompleted) locales.complete(<String>['ru_RU:Русский']);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
