import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/ai_drafts.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Json fakeDraft(String name) => {
  'name': name,
  'grams': 150.0,
  'calories': 200.0,
  'protein': 20.0,
  'fat': 8.0,
  'carbs': 12.0,
  'meal': 'lunch',
};

Future<SupabaseClient> fakeClient(String owner) async {
  final client = SupabaseClient(
    'https://account-test.example.invalid',
    'test-public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.setInitialSession(
    jsonEncode({
      'access_token': 'synthetic-only',
      'token_type': 'bearer',
      'user': {
        'id': owner,
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
  final day = DateTime(2026, 10, 26);
  late AppDataProvider p;
  late SupabaseClient a, b;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
    await p.setSelectedDate(day);
    a = await fakeClient('account-a');
    b = await fakeClient('account-b');
    SmartRemote.instance.client = a;
    await AiConsent(p.storage.local, 'account-a').accept();
    await AiConsent(p.storage.local, 'account-b').accept();
  });

  tearDown(() async {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    SmartRemote.instance.client = null;
    p.dispose();
    await a.dispose();
    await b.dispose();
  });

  void switchAccount(SupabaseClient? account) {
    SmartRemote.instance.client = account;
    // Production emits this from onAuthStateChange; fake clients are offline.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    SmartRemote.instance.notifyListeners();
  }

  Finder input() => find.byWidgetPredicate(
    (w) => w is TextField && w.maxLines == 3 && w.maxLength == 4000,
  );

  Future<void> showPanel(WidgetTester tester, AiFoodRequester requester) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiFoodPanel(chatMode: true, requestOverride: requester),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, Future<void> started) async {
    final button = find.text('Разобрать и проверить');
    await tester.ensureVisible(button);
    await tester.runAsync(() async {
      await tester.tap(button);
      await started;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> showReview(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => AiReviewDialog(
                  items: [fakeDraft('Личное блюдо А')],
                  provider: p,
                  date: day,
                  owner: 'account-a',
                ),
              ),
              child: const Text('Открыть проверку'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть проверку'));
    await tester.pumpAndSettle();
  }

  testWidgets('chat and unsent input are isolated and restored per account', (
    tester,
  ) async {
    late Completer<void> started;
    await tester.runAsync(() async {
      started = Completer<void>();
    });
    await showPanel(tester, ({
      required text,
      image,
      required mime,
      required mode,
    }) async {
      started.complete();
      return [fakeDraft('Личное блюдо А')];
    });
    await tester.enterText(input(), 'Описание еды А');
    await submit(tester, started.future);
    await tester.pumpAndSettle();
    expect(find.byType(AiReviewDialog), findsOneWidget);
    await tester.tap(find.text('Закрыть').last);
    await tester.pumpAndSettle();
    expect(find.text('Описание еды А'), findsOneWidget);
    await tester.enterText(input(), 'Незаконченный текст А');

    switchAccount(b);
    await tester.pumpAndSettle();
    expect(find.text('Описание еды А'), findsNothing);
    expect(find.text('Личное блюдо А'), findsNothing);
    expect(tester.widget<TextField>(input()).controller!.text, isEmpty);
    expect(AiDraftCache(p.storage.local, 'account-b').read(), isEmpty);
    await tester.enterText(input(), 'Незаконченный текст Б');

    switchAccount(a);
    await tester.pumpAndSettle();
    expect(find.text('Описание еды А'), findsOneWidget);
    expect(
      tester.widget<TextField>(input()).controller!.text,
      'Незаконченный текст А',
    );
    switchAccount(b);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(input()).controller!.text,
      'Незаконченный текст Б',
    );
    switchAccount(null);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input()).controller!.text, isEmpty);
    expect(find.text('Описание еды А'), findsNothing);
    expect(p.todayFoodEntries, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'old response cannot affect a new account or its active request',
    (tester) async {
      late Completer<void> startedA, startedB;
      late Completer<List<Json>> resultA, resultB;
      await tester.runAsync(() async {
        startedA = Completer<void>();
        startedB = Completer<void>();
        resultA = Completer<List<Json>>();
        resultB = Completer<List<Json>>();
      });
      await showPanel(tester, ({
        required text,
        image,
        required mime,
        required mode,
      }) {
        if (text == 'Запрос А') {
          startedA.complete();
          return resultA.future;
        }
        if (text == 'Запрос Б') {
          startedB.complete();
          return resultB.future;
        }
        throw StateError('Unexpected request');
      });
      await tester.enterText(input(), 'Запрос А');
      await submit(tester, startedA.future);
      switchAccount(b);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(input(), 'Запрос Б');
      await submit(tester, startedB.future);
      await tester.runAsync(() async {
        resultA.complete([fakeDraft('Ответ только А')]);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AiReviewDialog), findsNothing);
      expect(find.text('Ответ только А'), findsNothing);
      expect(find.text('Готовим черновик…'), findsOneWidget);
      expect(tester.widget<TextField>(input()).controller!.text, 'Запрос Б');
      expect(AiDraftCache(p.storage.local, 'account-a').read(), isEmpty);
      await tester.runAsync(() async {
        resultB.complete([fakeDraft('Ответ только Б')]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(AiReviewDialog), findsOneWidget);
      expect(find.text('Ответ только Б'), findsWidgets);
      expect(find.text('Ответ только А'), findsNothing);
      expect(p.todayFoodEntries, isEmpty);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('A to B to A still invalidates an earlier response', (
    tester,
  ) async {
    late Completer<void> started;
    late Completer<List<Json>> result;
    await tester.runAsync(() async {
      started = Completer<void>();
      result = Completer<List<Json>>();
    });
    await showPanel(tester, ({
      required text,
      image,
      required mime,
      required mode,
    }) {
      started.complete();
      return result.future;
    });
    await tester.enterText(input(), 'Не отправлять повторно');
    await submit(tester, started.future);
    switchAccount(b);
    await tester.pump(const Duration(milliseconds: 100));
    switchAccount(a);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      result.complete([fakeDraft('Устаревший результат')]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AiReviewDialog), findsNothing);
    expect(find.text('Устаревший результат'), findsNothing);
    expect(
      tester.widget<TextField>(input()).controller!.text,
      'Не отправлять повторно',
    );
    expect(AiDraftCache(p.storage.local, 'account-a').read(), isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('account switch closes a nested review and nutrient editor', (
    tester,
  ) async {
    await showReview(tester);
    await tester.ensureVisible(find.text('Изменить').first);
    await tester.tap(find.text('Изменить').first);
    await tester.pumpAndSettle();
    expect(find.text('Уточнить продукт'), findsOneWidget);
    await tester.ensureVisible(
      find.textContaining('Витамины и минералы на 100 г').last,
    );
    await tester.tap(find.textContaining('Витамины и минералы на 100 г').last);
    await tester.pumpAndSettle();
    expect(find.text('Микронутриенты на 100 г'), findsOneWidget);
    switchAccount(b);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Микронутриенты на 100 г'), findsNothing);
    expect(find.text('Уточнить продукт'), findsNothing);
    expect(find.byType(AiReviewDialog), findsNothing);
    expect(find.text('Личное блюдо А'), findsNothing);
    expect(p.todayFoodEntries, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'account switch invalidates a queued reviewed write even after switching back',
    (tester) async {
      await showReview(tester);
      final key = 'food_entries_${dayKey(day)}';
      await tester.runAsync(() async {
        final started = Completer<void>(), release = Completer<void>();
        LocalPreferences.beforeWriteForTests = (written) async {
          if (written == key && !started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        final blocker = p.storage.local.setString(key, '[]');
        await started.future;
        await tester.tap(find.text('Добавить 1 · 300 ккал'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        switchAccount(b);
        switchAccount(a);
        release.complete();
        await blocker;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(find.byType(AiReviewDialog), findsNothing);
      expect(p.storage.local.getString(key), '[]');
      expect(p.todayFoodEntries, isEmpty);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'switching account closes the panel review and warns about unfinished edits',
    (tester) async {
      late Completer<void> started;
      await tester.runAsync(() async {
        started = Completer<void>();
      });
      await showPanel(tester, ({
        required text,
        image,
        required mime,
        required mode,
      }) async {
        started.complete();
        return [fakeDraft('Черновик А')];
      });
      await tester.enterText(input(), 'Описание А');
      await submit(tester, started.future);
      await tester.pumpAndSettle();
      expect(find.byType(AiReviewDialog), findsOneWidget);
      switchAccount(b);
      await tester.pumpAndSettle();
      expect(find.byType(AiReviewDialog), findsNothing);
      expect(find.text('Черновик А'), findsNothing);
      expect(find.textContaining('Окно проверки закрыто'), findsOneWidget);
      expect(
        find.textContaining('не восстанавливаются автоматически'),
        findsOneWidget,
      );
      switchAccount(a);
      await tester.pumpAndSettle();
      expect(find.text('Открыть черновик'), findsOneWidget);
      expect(p.todayFoodEntries, isEmpty);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'selected photo is hidden from another account and restored on return',
    (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fitness-photo-'),
      );
      final path = '${dir!.path}/synthetic.png';
      await tester.runAsync(
        () => File(
          path,
        ).writeAsBytes(img.encodePng(img.Image(width: 3, height: 3))),
      );
      const channel = MethodChannel('plugins.flutter.io/image_picker');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'pickImage' ? path : null,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      });
      await showPanel(
        tester,
        ({required text, image, required mime, required mode}) async => [],
      );
      await tester.ensureVisible(find.text('Галерея'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Галерея'));
        await Future<void>.delayed(const Duration(milliseconds: 350));
      });
      await tester.pumpAndSettle();
      expect(find.text('Убрать фото'), findsOneWidget);
      switchAccount(b);
      await tester.pumpAndSettle();
      expect(find.text('Убрать фото'), findsNothing);
      switchAccount(a);
      await tester.pumpAndSettle();
      expect(find.text('Убрать фото'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('late image picker result cannot appear in another account', (
    tester,
  ) async {
    late Completer<void> started;
    late Completer<String?> selected;
    await tester.runAsync(() async {
      started = Completer<void>();
      selected = Completer<String?>();
    });
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) {
      if (call.method == 'pickImage') {
        started.complete();
        return selected.future;
      }
      return Future.value(null);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await showPanel(
      tester,
      ({required text, image, required mime, required mode}) async => [],
    );
    await tester.ensureVisible(find.text('Галерея'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Галерея'));
      await started.future;
    });
    await tester.pump();
    switchAccount(b);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      selected.complete('/nonexistent/synthetic-photo.png');
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(find.text('Убрать фото'), findsNothing);
    expect(find.textContaining('Не удалось'), findsNothing);
    switchAccount(a);
    await tester.pumpAndSettle();
    expect(find.text('Убрать фото'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'changing accounts while consent is open cannot approve or send the old request',
    (tester) async {
      await tester.runAsync(
        () => AiConsent(p.storage.local, 'account-a').revoke(),
      );
      var calls = 0;
      await showPanel(tester, ({
        required text,
        image,
        required mime,
        required mode,
      }) async {
        calls++;
        return [fakeDraft('Не должно появиться')];
      });
      await tester.enterText(input(), 'Личный текст А');
      final button = find.text('Разобрать и проверить');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('AI · одно согласие'), findsOneWidget);
      switchAccount(b);
      switchAccount(a);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await tester.tap(find.text('Мне 18+, запомнить'));
        await Future<void>.delayed(const Duration(milliseconds: 70));
      });
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(AiConsent(p.storage.local, 'account-a').accepted, isFalse);
      expect(
        tester.widget<TextField>(input()).controller!.text,
        'Личный текст А',
      );
      expect(find.byType(AiReviewDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('review refuses a diary bound to another account', (
    tester,
  ) async {
    await tester.runAsync(
      () => p.storage.local.setString('_bound_user', 'account-b'),
    );
    await showReview(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('Добавить 1 · 300 ккал'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
    expect(
      find.textContaining('дневник связан с другим аккаунтом'),
      findsOneWidget,
    );
    expect(p.todayFoodEntries, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'late dictation is ignored and restart is required after account change',
    (tester) async {
      const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var listenCalls = 0, cancelCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'initialize':
            return true;
          case 'locales':
            return <String>['ru_RU:Русский'];
          case 'listen':
            listenCalls++;
            return true;
          case 'cancel':
            cancelCalls++;
            return null;
          case 'stop':
            return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      Future<void> platformEvent(String method, Object value) async {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, value),
          ),
          (_) {},
        );
      }

      Future<void> words(String value) => platformEvent(
        'textRecognition',
        jsonEncode({
          'alternates': [
            {'recognizedWords': value, 'confidence': 0.9},
          ],
          'resultType': 0,
        }),
      );
      await showPanel(
        tester,
        ({required text, image, required mime, required mode}) async => [],
      );
      await tester.ensureVisible(find.text('Диктовка'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Диктовка'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await platformEvent('notifyStatus', 'listening');
        await words('Еда из диктовки А');
      });
      await tester.pump();
      expect(listenCalls, 1);
      expect(
        tester.widget<TextField>(input()).controller!.text,
        'Еда из диктовки А',
      );
      switchAccount(b);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await words('Поздний текст А');
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<TextField>(input()).controller!.text, isEmpty);
      expect(
        find.textContaining('Диктовка отключена после смены аккаунта'),
        findsOneWidget,
      );
      expect(cancelCalls, greaterThanOrEqualTo(1));
      await close(tester);
      await showPanel(
        tester,
        ({required text, image, required mime, required mode}) async => [],
      );
      final voiceButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Диктовка'),
      );
      expect(voiceButton.onPressed, isNull);
      expect(listenCalls, 1);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  test(
    'queued consent cannot be accepted after authorization is invalidated',
    () async {
      final consent = AiConsent(p.storage.local, 'account-a');
      await consent.revoke();
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == consent.key && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final blocker = p.storage.local.setString(consent.key, 'old');
      await started.future;
      var current = true;
      final accepting = consent.accept(authorizationGuard: () => current);
      final refused = expectLater(accepting, throwsStateError);
      current = false;
      release.complete();
      await blocker;
      await refused;
      expect(consent.accepted, isFalse);
      expect(p.storage.local.getString(consent.key), 'old');
    },
  );
}
