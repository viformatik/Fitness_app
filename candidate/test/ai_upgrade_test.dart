import 'dart:async';
import 'dart:convert';
import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/ai_drafts.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Json draft({
  String name = 'Творог',
  double grams = 150,
  String meal = 'lunch',
}) => {
  'name': name,
  'grams': grams,
  'calories': 200.0,
  'protein': 20.0,
  'fat': 8.0,
  'carbs': 12.0,
  'meal': meal,
  'assumptions': 'Вес указан пользователем',
};
FoodEntry entry(DateTime day, {String? id, double grams = 100}) => FoodEntry(
  id: id,
  name: 'Творог',
  caloriesPer100g: 200,
  proteinPer100g: 20,
  fatPer100g: 8,
  carbsPer100g: 12,
  amountGrams: grams,
  mealType: MealType.lunch,
  date: day,
  timeKnown: false,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 26);
  late AppDataProvider p;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
    await p.setSelectedDate(day);
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    p.dispose();
  });

  test('AI totals are for consumed portions, not per-100-g sum', () {
    final totals = AiPortionTotals.fromItems([draft(), draft(grams: 50)]);
    expect(totals.grams, 200);
    expect(totals.calories, 400);
    expect(totals.protein, 40);
    expect(totals.fat, 16);
    expect(totals.carbs, 24);
  });
  test(
    'Response validation rejects non-finite, negative, huge and zero portions',
    () {
      for (final v in [double.nan, double.infinity, -1, 0, 20001]) {
        expect(
          () => validateAiItems([
            {...draft(), 'grams': v},
          ]),
          throwsFormatException,
        );
      }
      expect(
        () => validateAiItems([
          {...draft(), 'protein': 1001},
        ]),
        throwsFormatException,
      );
      expect(
        () => validateAiItems(List.generate(31, (_) => draft())),
        throwsFormatException,
      );
    },
  );
  test(
    'Normalization defaults unknown meal and discards private fields / IDs',
    () {
      final item = validateAiItems([
        {
          ...draft(meal: 'invented'),
          '_entryId': 'private',
          'image': 'photo',
          'token': 'secret',
        },
      ]).single;
      expect(item['meal'], 'snack');
      expect(item.containsKey('image'), false);
      expect(item.containsKey('_entryId'), false);
      expect(item.containsKey('token'), false);
    },
  );
  test(
    'Clear Russian setup / quota / auth messages never expose minified exception',
    () {
      expect(
        aiServerErrorMessage(503, {
          'error': 'GEMINI_API_KEY is not configured',
        }),
        contains('Supabase'),
      );
      expect(
        aiServerErrorMessage(429, {
          'error': 'AI limit reached: 15 requests per hour',
        }),
        contains('15'),
      );
      expect(aiServerErrorMessage(401, null), contains('Войдите'));
      final networkError = aiServerErrorMessage(0, null);
      expect(networkError, contains('облако временно недоступно'));
      expect(networkError, contains('проблема с интернетом'));
      expect(networkError, isNot(contains('Проверьте интернет')));
      expect(
        aiServerErrorMessage(502, {'error': 'private backend stack'}),
        isNot(contains('private')),
      );
    },
  );
  test(
    'Draft cache is bounded, deduplicated and isolated by account',
    () async {
      final a = AiDraftCache(p.storage.local, 'A'),
          b = AiDraftCache(p.storage.local, 'B');
      for (var i = 0; i < 8; i++) {
        await a.remember([draft(name: 'Блюдо $i')]);
      }
      expect(a.read(), hasLength(5));
      expect(b.read(), isEmpty);
      await a.remember([draft(name: 'Блюдо 7')]);
      expect(a.read(), hasLength(5));
      expect((a.read().first['items'] as List).first['name'], 'Блюдо 7');
      expect(p.storage.local.snapshot().containsKey(a.key), false);
    },
  );
  test(
    'Optional corrupt cache does not break diary; clear removes all device drafts',
    () async {
      final a = AiDraftCache(p.storage.local, 'A');
      await p.storage.local.setString(
        a.key,
        jsonEncode([
          {
            'items': [
              {'name': 'broken'},
            ],
          },
        ]),
      );
      expect(a.read(), isEmpty);
      await a.remember([draft()]);
      await p.storage.local.clear();
      expect(a.read(), isEmpty);
    },
  );
  test(
    'Batch is one day, preserves existing data and is idempotent after reload',
    () async {
      await p.addFoodEntry(entry(day, id: 'existing'));
      final batch = [
        entry(day, id: 'a', grams: 150),
        entry(day, id: 'b', grams: 50),
      ];
      await p.addFoodEntriesBatch(batch);
      await p.reloadAll();
      await p.addFoodEntriesBatch(batch);
      expect(p.todayFoodEntries, hasLength(3));
      expect(p.todayCaloriesConsumed, 600);
      expect(
        p.todayFoodEntries.where((e) => e.id == 'a').single.timeKnown,
        false,
      );
    },
  );
  test('Invalid batch never writes the valid prefix', () async {
    await expectLater(
      p.addFoodEntriesBatch([entry(day), entry(day, grams: -1)]),
      throwsArgumentError,
    );
    expect(await p.storage.getFoodEntries(day), isEmpty);
  });
  test(
    'Failed batch write leaves no partial entries and retry saves once',
    () async {
      final batch = [entry(day, id: 'stable-1'), entry(day, id: 'stable-2')];
      LocalPreferences.rejectWriteKeyForTests = 'food_entries_${dayKey(day)}';
      await expectLater(p.addFoodEntriesBatch(batch), throwsStateError);
      expect(p.todayFoodEntries, isEmpty);
      expect(await p.storage.getFoodEntries(day), isEmpty);
      expect(p.persistenceError, isNotNull);
      LocalPreferences.rejectWriteKeyForTests = null;
      await p.addFoodEntriesBatch(batch);
      await p.addFoodEntriesBatch(batch);
      expect(p.todayFoodEntries, hasLength(2));
      expect(p.persistenceError, isNull);
    },
  );
  test('Mixed dates are rejected before any write', () async {
    await expectLater(
      p.addFoodEntriesBatch([
        entry(day),
        entry(day.add(const Duration(days: 1))),
      ]),
      throwsArgumentError,
    );
    expect(await p.storage.getFoodEntries(day), isEmpty);
  });
  test('Concurrent single entry and AI batch preserve both', () async {
    await Future.wait([
      p.addFoodEntry(entry(day, id: 'single')),
      p.addFoodEntriesBatch([
        entry(day, id: 'batch1'),
        entry(day, id: 'batch2'),
      ]),
    ]);
    await p.reloadAll();
    expect(p.todayFoodEntries.map((e) => e.id).toSet(), {
      'single',
      'batch1',
      'batch2',
    });
  });

  Future<void> openReview(WidgetTester tester, {String? owner}) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<int>(
                context: context,
                barrierDismissible: false,
                builder: (_) => AiReviewDialog(
                  items: [draft()],
                  provider: p,
                  date: day,
                  owner: owner,
                ),
              ),
              child: const Text('Открыть черновик'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть черновик'));
    await tester.pumpAndSettle();
  }

  Future<void> prepareAccount(WidgetTester tester) async {
    final client = (await tester.runAsync(() async {
      final client = SupabaseClient(
        'https://ai-review-test.example.invalid',
        'test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.setInitialSession(
        jsonEncode({
          'access_token': 'test-only',
          'token_type': 'bearer',
          'user': {
            'id': 'review-owner',
            'app_metadata': {},
            'user_metadata': {},
            'aud': 'authenticated',
            'created_at': '2026-10-25T00:00:00Z',
          },
        }),
      );
      await AiConsent(p.storage.local, 'review-owner').accept();
      return client;
    }))!;
    SmartRemote.instance.client = client;
    addTearDown(() async {
      SmartRemote.instance.client = null;
      await client.dispose();
    });
  }

  testWidgets('revoking consent leaves the reviewed draft unsaved', (
    tester,
  ) async {
    await prepareAccount(tester);
    await openReview(tester, owner: 'review-owner');
    await tester.runAsync(
      () => AiConsent(p.storage.local, 'review-owner').revoke(),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Добавить 1 · 300 ккал'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Аккаунт или согласие изменились'),
      findsOneWidget,
    );
    expect(find.byType(AiReviewDialog), findsOneWidget);
    expect(p.todayFoodEntries, isEmpty);
    expect(p.storage.local.getString('food_entries_${dayKey(day)}'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'consent revoked while a reviewed save waits prevents the write',
    (tester) async {
      await prepareAccount(tester);
      await openReview(tester, owner: 'review-owner');
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
        await AiConsent(p.storage.local, 'review-owner').revoke();
        release.complete();
        await blocker;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Аккаунт или согласие изменились'),
        findsOneWidget,
      );
      expect(p.storage.local.getString(key), '[]');
      expect(p.todayFoodEntries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'response after consent revocation is not accepted into a draft',
    (tester) async {
      await prepareAccount(tester);
      late Completer<void> started;
      late Completer<List<Json>> result;
      await tester.runAsync(() async {
        started = Completer<void>();
        result = Completer<List<Json>>();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AiFoodPanel(
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
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.maxLines == 3,
      );
      await tester.enterText(field, 'Творог 150 г');
      final submit = find.text('Разобрать и проверить');
      await tester.ensureVisible(submit);
      await tester.runAsync(() async {
        await tester.tap(submit);
        await started.future;
        await AiConsent(p.storage.local, 'review-owner').revoke();
        result.complete([draft()]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Согласие отозвано'), findsOneWidget);
      expect(find.byType(AiReviewDialog), findsNothing);
      expect(tester.widget<TextField>(field).controller!.text, 'Творог 150 г');
      expect(AiDraftCache(p.storage.local, 'review-owner').read(), isEmpty);
      expect(p.todayFoodEntries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Review displays consumed calories and scaling only changes mass',
    (tester) async {
      await openReview(tester);
      expect(find.text('300 ккал · 150 г'), findsOneWidget);
      await tester.tap(find.text('Всё ×2'));
      await tester.pumpAndSettle();
      expect(find.text('600 ккал · 300 г'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.tap(find.text('Добавить 1 · 600 ккал'));
        await p.storage.pendingMutations;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Проверить и добавить'), findsNothing);
      expect(p.todayFoodEntries.single.amountGrams, 300);
      expect(p.todayFoodEntries.single.caloriesPer100g, 200);
    },
  );
  testWidgets('Review captures target date despite provider navigation', (
    tester,
  ) async {
    await openReview(tester);
    final otherDay = day.add(const Duration(days: 1));
    await tester.runAsync(() => p.setSelectedDate(otherDay));
    await tester.runAsync(() async {
      await tester.tap(find.text('Добавить 1 · 300 ккал'));
      await p.storage.pendingMutations;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(await p.storage.getFoodEntries(day), hasLength(1));
      expect(await p.storage.getFoodEntries(otherDay), isEmpty);
    });
    expect(p.selectedDate, otherDay);
  });
  testWidgets(
    'Removing last draft disables saving; no diary changes on close',
    (tester) async {
      await openReview(tester);
      await tester.ensureVisible(find.byTooltip('Убрать из результата'));
      await tester.tap(find.byTooltip('Убрать из результата'));
      await tester.pumpAndSettle();
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Добавить 0 · 0 ккал'),
      );
      expect(save.onPressed, isNull);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(p.todayFoodEntries, isEmpty);
    },
  );
}
