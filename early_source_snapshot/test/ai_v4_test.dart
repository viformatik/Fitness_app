import 'dart:convert';
import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/ai_actions.dart';
import 'package:fitness_tracker/smart/ai_drafts.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Json sampleDraft() => {
  'name': 'Йогурт',
  'grams': 150.0,
  'calories': 90.0,
  'protein': 6.0,
  'fat': 3.0,
  'carbs': 10.0,
  'meal': 'breakfast',
  'assumptions': 'Проверьте этикетку',
};
FoodEntry sampleEntry(DateTime date, String id, {double grams = 150}) =>
    FoodEntry(
      id: id,
      name: 'Йогурт',
      caloriesPer100g: 90,
      proteinPer100g: 6,
      fatPer100g: 3,
      carbsPer100g: 10,
      amountGrams: grams,
      mealType: MealType.breakfast,
      date: date,
      timeKnown: false,
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider p;
  final day = DateTime(2026, 10, 27);
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
    p.dispose();
  });
  test(
    'Consent persists per policy/account, can be revoked, never exported',
    () async {
      final a = AiConsent(p.storage.local, 'a'),
          b = AiConsent(p.storage.local, 'b');
      expect(a.accepted, false);
      await a.accept();
      expect(AiConsent(p.storage.local, 'a').accepted, true);
      expect(b.accepted, false);
      expect(p.storage.local.snapshot().containsKey(a.key), false);
      await a.revoke();
      expect(a.accepted, false);
    },
  );
  test(
    'Changed policy/provider never silently reuses earlier consent',
    () async {
      final a = AiConsent(p.storage.local, 'a');
      for (final value in [
        {
          'version': AiConsent.policyVersion - 1,
          'provider': 'gemini',
          'adult': true,
        },
        {
          'version': AiConsent.policyVersion,
          'provider': 'other',
          'adult': true,
        },
        {
          'version': AiConsent.policyVersion,
          'provider': 'gemini',
          'adult': false,
        },
      ]) {
        await p.storage.local.setString(a.key, jsonEncode(value));
        expect(a.accepted, false);
      }
    },
  );
  test(
    'Favorite replaces same name, survives recent clear, strips images and IDs',
    () async {
      final fav = AiFavorites(p.storage.local, 'a');
      await fav.save('Завтрак', [
        {...sampleDraft(), 'image': 'private', '_entryId': 'do-not-reuse'},
      ]);
      await fav.save('завтрак', [
        {...sampleDraft(), 'grams': 200},
      ]);
      await AiDraftCache(p.storage.local, 'a').clear();
      expect(fav.read(), hasLength(1));
      final row = (fav.read().single['items'] as List).single as Map;
      expect(row['grams'], 200);
      expect(row.containsKey('image'), false);
      expect(row.containsKey('_entryId'), false);
      expect(AiFavorites(p.storage.local, 'b').read(), isEmpty);
    },
  );
  test('Favorites are capped without silently losing pinned sets', () async {
    final f = AiFavorites(p.storage.local, 'a');
    for (var i = 0; i < 20; i++) {
      await f.save('Набор $i', [sampleDraft()]);
    }
    await expectLater(f.save('21-й', [sampleDraft()]), throwsStateError);
    expect(f.read(), hasLength(20));
    await f.remove('Набор 0');
    await f.save('21-й', [sampleDraft()]);
    expect(f.read(), hasLength(20));
  });
  test(
    'Refinement shares only normalized current draft, not photo/profile/history/IDs',
    () {
      final body = buildAiFoodRequest(
        mode: 'refine',
        text: 'Без сахара, 200 г',
        previousItems: [
          {
            ...sampleDraft(),
            '_entryId': 'old',
            'profile': {'weight': 80},
            'image': 'private',
          },
        ],
      );
      expect(body.keys.toSet(), {'text', 'mode', 'previousItems'});
      final row = (body['previousItems'] as List).single as Map;
      expect(row.containsKey('profile'), false);
      expect(row.containsKey('_entryId'), false);
      expect(
        () => buildAiFoodRequest(
          mode: 'refine',
          text: 'ещё',
          previousItems: [],
          image: [1],
        ),
        throwsArgumentError,
      );
    },
  );
  test('Label requires photo; mode and MIME are strict', () {
    expect(
      () => buildAiFoodRequest(mode: 'label', text: 'этикетка'),
      throwsArgumentError,
    );
    expect(
      buildAiFoodRequest(
        mode: 'label',
        image: [1, 2],
        text: 'Съел половину',
      )['mode'],
      'label',
    );
    expect(
      () => buildAiFoodRequest(mode: 'other', text: 'food'),
      throwsArgumentError,
    );
    expect(
      () => buildAiFoodRequest(image: [1], mime: 'image/heic'),
      throwsArgumentError,
    );
  });
  test(
    'Undo removes exact last batch, keeps unrelated food, and is idempotent',
    () async {
      final added = [sampleEntry(day, 'one'), sampleEntry(day, 'two')];
      await p.addFoodEntriesBatch(added);
      await p.addFoodEntry(sampleEntry(day, 'keep'));
      await p.undoFoodEntriesBatch(added);
      expect(p.todayFoodEntries.single.id, 'keep');
      await p.undoFoodEntriesBatch(added);
      expect(p.todayFoodEntries.single.id, 'keep');
    },
  );
  test(
    'Undo refuses whole batch when one product changed, preserving all edits',
    () async {
      final added = [sampleEntry(day, 'one'), sampleEntry(day, 'two')];
      await p.addFoodEntriesBatch(added);
      await p.updateFoodEntry(sampleEntry(day, 'one', grams: 200));
      await expectLater(p.undoFoodEntriesBatch(added), throwsStateError);
      expect(p.todayFoodEntries, hasLength(2));
      expect(p.todayFoodEntries.first.amountGrams, 200);
    },
  );
  test(
    'Undo writes atomically; failed write changes neither disk nor view',
    () async {
      final added = [sampleEntry(day, 'one'), sampleEntry(day, 'two')];
      await p.addFoodEntriesBatch(added);
      LocalPreferences.rejectWriteKeyForTests = 'food_entries_${dayKey(day)}';
      await expectLater(p.undoFoodEntriesBatch(added), throwsStateError);
      expect(p.todayFoodEntries, hasLength(2));
      expect(await p.storage.getFoodEntries(day), hasLength(2));
      LocalPreferences.rejectWriteKeyForTests = null;
      await p.undoFoodEntriesBatch(added);
      expect(p.todayFoodEntries, isEmpty);
    },
  );
  test(
    'Undo remains on original day after navigating to another date',
    () async {
      final added = [sampleEntry(day, 'one')];
      await p.addFoodEntriesBatch(added);
      final other = day.add(const Duration(days: 1));
      await p.setSelectedDate(other);
      await p.addFoodEntry(sampleEntry(other, 'keep'));
      await p.undoFoodEntriesBatch(added);
      expect(p.selectedDate, other);
      expect(p.todayFoodEntries.single.id, 'keep');
      expect(await p.storage.getFoodEntries(day), isEmpty);
    },
  );
  test(
    'Full data clearing removes consent, favorites, recents and undo metadata',
    () async {
      await AiConsent(p.storage.local, 'a').accept();
      await AiFavorites(p.storage.local, 'a').save('Набор', [sampleDraft()]);
      await AiUndoStore(
        p.storage.local,
        'a',
      ).remember([sampleEntry(day, 'one').toJson()]);
      await AiDraftCache(p.storage.local, 'a').remember([sampleDraft()]);
      await p.storage.local.clear();
      expect(
        p.storage.local.getKeys().where((e) => e.startsWith('_ai_')),
        isEmpty,
      );
    },
  );
  testWidgets(
    '18+ dialog once, skipped next request; revoke restores confirmation',
    (tester) async {
      final client = (await tester.runAsync(() async {
        final client = SupabaseClient(
          'https://ui-test.example.invalid',
          'test-public-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        await client.auth.setInitialSession(
          jsonEncode({
            'access_token': 'ui-test-only',
            'token_type': 'bearer',
            'user': {
              'id': 'ui-test-account',
              'app_metadata': {},
              'user_metadata': {},
              'aud': 'authenticated',
              'created_at': '2026-10-27T00:00:00Z',
            },
          }),
        );
        return client;
      }))!;
      SmartRemote.instance.client = client;
      addTearDown(() async {
        SmartRemote.instance.client = null;
        await client.dispose();
      });
      var approved = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  TextButton(
                    onPressed: () async {
                      if (await ensureAiConsent(
                        context,
                        p.storage.local,
                        'ui-test-account',
                      ))
                        setState(() => approved++);
                    },
                    child: Text('Запрос $approved'),
                  ),
                  AiPrivacyControls(
                    store: p.storage.local,
                    owner: 'ui-test-account',
                    busy: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Запрос 0'));
      await tester.pumpAndSettle();
      expect(find.text('AI · одно согласие'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Мне 18+, запомнить'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(approved, 1);
      await tester.runAsync(() async {
        await tester.tap(find.text('Запрос 1'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(approved, 2);
      expect(find.text('AI · одно согласие'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('Отозвать согласие на AI'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запрос 2'));
      await tester.pumpAndSettle();
      expect(find.text('AI · одно согласие'), findsOneWidget);
      await tester.tap(find.text('Не сейчас'));
      await tester.pumpAndSettle();
      expect(approved, 2);
    },
  );
}
