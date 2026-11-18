import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/diary_ai.dart';
import 'package:fitness_tracker/smart/diary_ai_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final day = DateTime(2026, 10, 28);
FoodEntry entry({
  String id = 'private-id',
  String name = 'Яблоко',
  DateTime? date,
  double grams = 150,
  Map<String, double> micros = const {'vitaminC': 6},
}) => FoodEntry(
  id: id,
  name: name,
  date: date ?? day,
  loggedAt: DateTime(2026, 10, 28, 12, 30),
  timeKnown: true,
  caloriesPer100g: 52,
  proteinPer100g: .3,
  fatPer100g: .2,
  carbsPer100g: 14,
  amountGrams: grams,
  mealType: MealType.snack,
  micros: micros,
);
DiaryAiSnapshot snap([List<FoodEntry>? entries]) => DiaryAiSnapshot(
  firstDay: DateTime(2026, 10, 1),
  lastDay: DateTime(2026, 10, 31),
  entries: entries ?? [entry()],
);
Map<String, dynamic> action({
  String kind = 'update',
  String ref = 'f1',
  String date = '2026-10-28',
  Map<String, dynamic> patch = const {},
}) => {
  'kind': kind,
  'ref': ref,
  'day': date,
  'reason': 'Сверьте оценку',
  'patch': patch,
};
Map<String, dynamic> response(List<Map<String, dynamic>> actions) => {
  'analysis': 'Данные неполные; проверьте состав.',
  'actions': actions,
};
Map<String, dynamic> addPatch() => {
  'name': 'Груша',
  'grams': 100,
  'calories': 45,
  'protein': .5,
  'fat': .2,
  'carbs': 10,
  'meal': 'snack',
  'micros': {'vitaminC': 3},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    SmartRemote.instance.client = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    p.dispose();
  });

  test(
    'only pseudonymous selected foods leave the device, bounded by range and 60 records',
    () {
      final request = snap().request('Проверь', replaceKnownMicros: false);
      expect(request.keys.toSet(), {
        'mode',
        'text',
        'firstDay',
        'lastDay',
        'replaceKnownMicros',
        'entries',
      });
      final encoded = jsonEncode(request);
      expect(encoded, contains('f1'));
      expect(encoded, isNot(contains('private-id')));
      expect(encoded, isNot(contains('loggedAt')));
      expect(encoded, isNot(contains('weight')));
      expect(encoded, isNot(contains('supplement')));
      expect(
        () => DiaryAiSnapshot(
          firstDay: day,
          lastDay: day,
          entries: List.generate(61, (i) => entry(id: '$i')),
        ),
        throwsArgumentError,
      );
      expect(
        () => DiaryAiSnapshot(
          firstDay: day,
          lastDay: day,
          entries: [entry(date: DateTime(2026, 9, 1))],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'missing vitamins are merged, known values survive by default, original is untouched',
    () {
      final original = entry();
      final s = snap([original]);
      final out = validateDiaryAiResult(
        response([
          action(
            patch: {
              'micros': {'vitaminC': 100, 'vitaminD': 2},
            },
          ),
        ]),
        s,
        replaceKnownMicros: false,
      );
      expect(original.micros, {'vitaminC': 6});
      expect(out.suggestions.single.proposed!.micros, {
        'vitaminC': 6,
        'vitaminD': 2,
      });
      expect(out.suggestions.single.proposed!.microsEstimated, isTrue);
      expect(out.suggestions.single.proposed!.amountGrams, 150);
      expect(out.suggestions.single.selected, isFalse);
    },
  );

  test(
    'explicit replacement can change known vitamins and edited quantities',
    () {
      final out = validateDiaryAiResult(
        response([
          action(
            patch: {
              'grams': 200,
              'micros': {'vitaminC': 8},
            },
          ),
        ]),
        snap(),
        replaceKnownMicros: true,
      );
      final e = out.suggestions.single.proposed!;
      expect(e.amountGrams, 200);
      expect(e.micros['vitaminC'], 8);
      expect(e.id, 'private-id');
      expect(e.timeKnown, isTrue);
      expect(e.loggedAt, DateTime(2026, 10, 28, 12, 30));
    },
  );

  test('unchanged known values do not produce fake changes', () {
    final out = validateDiaryAiResult(
      response([
        action(
          patch: {
            'micros': {'vitaminC': 20},
          },
        ),
      ]),
      snap(),
      replaceKnownMicros: false,
    );
    expect(out.suggestions, isEmpty);
  });

  test(
    'add and delete are proposals only, with stable local ID and unknown time',
    () {
      final s = snap();
      final out = validateDiaryAiResult(
        response([
          action(kind: 'delete'),
          action(kind: 'add', ref: '', date: '2026-10-29', patch: addPatch()),
        ]),
        s,
        replaceKnownMicros: false,
      );
      expect(out.suggestions.map((e) => e.kind), ['delete', 'add']);
      final added = out.suggestions.last.proposed!;
      expect(added.id, isNot('private-id'));
      expect(added.date, DateTime(2026, 10, 29));
      expect(added.timeKnown, isFalse);
      expect(added.microsEstimated, isTrue);
      expect(s.byRef['f1']!.name, 'Яблоко');
    },
  );

  test(
    'rejects forged references, moved dates, duplicates and malformed add',
    () {
      final s = snap();
      for (final bad in [
        [action(ref: 'f77')],
        [action(date: '2026-10-29')],
        [action(), action(kind: 'delete')],
        [
          action(kind: 'add', ref: '', patch: {'name': 'Груша'}),
        ],
        [
          action(patch: {'grams': -1}),
        ],
        [
          action(
            patch: {
              'micros': {'vitaminD': -3},
            },
          ),
        ],
        [
          action(patch: {'profile': 80}),
        ],
      ]) {
        expect(
          () => validateDiaryAiResult(
            response(bad),
            s,
            replaceKnownMicros: false,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'range scan reads only selected food documents and enforces size',
    () async {
      await p.storage.addFoodBatch([entry()]);
      await p.storage.addFoodBatch([
        entry(id: 'old', date: DateTime(2025, 1, 1)),
      ]);
      final rows = await p.storage.getFoodEntriesInRange(
        DateTime(2026, 10, 1),
        DateTime(2026, 10, 31),
      );
      expect(rows.map((e) => e.id), ['private-id']);
      await p.storage.addFoodBatch(
        List.generate(61, (i) => entry(id: 'n$i', date: DateTime(2026, 11, 1))),
      );
      await expectLater(
        p.storage.getFoodEntriesInRange(
          DateTime(2026, 11, 1),
          DateTime(2026, 11, 1),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'one-day update/add/delete are atomic, reversible and preserve other days',
    () async {
      final a = entry(), b = entry(id: 'b', name: 'Банан');
      await p.storage.addFoodBatch([a, b]);
      final outside = entry(id: 'outside', date: DateTime(2026, 10, 27));
      await p.storage.addFoodBatch([outside]);
      final changed = a.copyWith(
        amountGrams: 200,
        micros: {'vitaminD': 2, 'vitaminC': 6},
        microsEstimated: true,
      );
      final added = entry(id: 'new', name: 'Груша', grams: 100);
      await p.applyReviewedFoodChanges(
        date: day,
        expected: {a.id: a, b.id: b},
        changes: {a.id: changed, b.id: null},
        additions: [added],
      );
      var current = await p.storage.getFoodEntries(day);
      expect(current.map((e) => e.id), ['private-id', 'new']);
      expect(current.first.amountGrams, 200);
      expect(
        (await p.storage.getFoodEntries(outside.date)).single.id,
        'outside',
      );
      await p.applyReviewedFoodChanges(
        date: day,
        expected: {changed.id: changed, added.id: added},
        changes: {changed.id: a, added.id: null},
        additions: [b],
      );
      current = await p.storage.getFoodEntries(day);
      expect(current.map((e) => e.id), ['private-id', 'b']);
      expect(current.first.toJson(), a.toJson());
    },
  );

  test(
    'stale snapshot aborts the entire day, including proposed deletions and additions',
    () async {
      final a = entry(), b = entry(id: 'b', name: 'Банан');
      await p.storage.addFoodBatch([a, b]);
      final userEdit = a.copyWith(amountGrams: 350);
      await p.storage.updateFoodEntry(userEdit);
      await expectLater(
        p.applyReviewedFoodChanges(
          date: day,
          expected: {a.id: a, b.id: b},
          changes: {a.id: a.copyWith(amountGrams: 200), b.id: null},
          additions: [entry(id: 'new')],
        ),
        throwsStateError,
      );
      final current = await p.storage.getFoodEntries(day);
      expect(current.map((e) => e.id), ['private-id', 'b']);
      expect(current.first.amountGrams, 350);
    },
  );

  test(
    'a simultaneous local sync pull does not get overwritten by a stale asynchronous read',
    () async {
      final original = entry();
      await p.storage.addFoodBatch([original]);
      final aiEdit = original.copyWith(amountGrams: 200);
      final syncEdit = original.copyWith(amountGrams: 350);
      final applied = p.storage.applyReviewedFoodChanges(
        date: day,
        expected: {original.id: original},
        changes: {original.id: aiEdit},
        additions: [],
      );
      final syncDone = Completer<void>();
      scheduleMicrotask(() async {
        try {
          await p.storage.local.setString(
            'food_entries_${dayKey(day)}',
            jsonEncode([syncEdit.toJson()]),
          );
          syncDone.complete();
        } catch (e, st) {
          syncDone.completeError(e, st);
        }
      });
      await Future.wait([applied, syncDone.future]);
      expect((await p.storage.getFoodEntries(day)).single.amountGrams, 350);
    },
  );

  test(
    'write failure and cross-day plans cannot partly mutate the diary',
    () async {
      final a = entry();
      await p.storage.addFoodBatch([a]);
      LocalPreferences.rejectWriteKeyForTests = 'food_entries_${dayKey(day)}';
      await expectLater(
        p.applyReviewedFoodChanges(
          date: day,
          expected: {a.id: a},
          changes: {a.id: null},
          additions: [entry(id: 'new')],
        ),
        throwsStateError,
      );
      expect((await p.storage.getFoodEntries(day)).single.toJson(), a.toJson());
      LocalPreferences.rejectWriteKeyForTests = null;
      await expectLater(
        p.applyReviewedFoodChanges(
          date: day,
          expected: {},
          changes: {},
          additions: [entry(id: 'other', date: DateTime(2026, 10, 27))],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'mock transport validates result and sends no private identifiers',
    () async {
      Map<String, dynamic>? sent;
      final fake = MockClient((request) async {
        sent = Map<String, dynamic>.from(jsonDecode(request.body));
        return http.Response(
          jsonEncode(
            response([
              action(patch: {'grams': 200}),
            ]),
          ),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final client = SupabaseClient(
        'https://mock.invalid',
        'public-test',
        httpClient: fake,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.setInitialSession(
        jsonEncode({
          'access_token': 'fake',
          'token_type': 'bearer',
          'user': {
            'id': 'mock-account',
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
            'created_at': '2026-10-28T00:00:00Z',
          },
        }),
      );
      SmartRemote.instance.client = client;
      try {
        final plan = await SmartRemote.instance.analyzeDiary(
          snapshot: snap(),
          question: 'Исправь порцию',
          replaceKnownMicros: false,
        );
        expect(plan.suggestions.single.proposed!.amountGrams, 200);
        expect(jsonEncode(sent), isNot(contains('private-id')));
        expect(sent!['mode'], 'diary');
        expect(p.todayFoodEntries, isEmpty);
      } finally {
        SmartRemote.instance.client = null;
        await client.dispose();
        fake.close();
      }
    },
  );

  testWidgets(
    'mobile review does not change food without selection and final confirmation',
    (tester) async {
      final original = entry();
      await tester.runAsync(() async {
        await p.storage.addFoodBatch([original]);
        await p.reloadAll();
      });
      final fake = MockClient(
        (request) async => http.Response(
          jsonEncode(
            response([
              action(
                patch: {
                  'grams': 200,
                  'micros': {'vitaminD': 2},
                },
              ),
            ]),
          ),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      );
      final client = SupabaseClient(
        'https://mock.invalid',
        'public-test',
        httpClient: fake,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await tester.runAsync(
        () => client.auth.setInitialSession(
          jsonEncode({
            'access_token': 'fake',
            'token_type': 'bearer',
            'user': {
              'id': 'mock-account',
              'aud': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-10-28T00:00:00Z',
            },
          }),
        ),
      );
      SmartRemote.instance.client = client;
      await tester.runAsync(
        () => AiConsent(p.storage.local, 'mock-account').accept(),
      );
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> reveal(Finder f) async {
        for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
          final scroll = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          scroll.position.jumpTo(
            math.min(
              scroll.position.maxScrollExtent,
              scroll.position.pixels + 260,
            ),
          );
          await tester.pumpAndSettle();
        }
        expect(f, findsOneWidget);
        await tester.ensureVisible(f);
        await tester.pump(const Duration(milliseconds: 200));
      }

      Future<void> tap(Finder f) async {
        await reveal(f);
        await tester.runAsync(() async {
          await tester.tap(f);
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });
        await tester.pumpAndSettle();
      }

      Future<FoodEntry> stored() async =>
          (await tester.runAsync(() => p.storage.getFoodEntries(day)))!.single;
      try {
        await tester.pumpWidget(MaterialApp(home: DiaryAiScreen(provider: p)));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();
        await tap(find.text('Отправить запрос ИИ'));
        expect(find.text('Анализ ИИ'), findsOneWidget);
        expect((await stored()).amountGrams, 150);
        await reveal(find.textContaining('Порция, г: 150 → 200'));
        expect(find.textContaining('Порция, г: 150 → 200'), findsOneWidget);
        await tap(find.byType(CheckboxListTile).last);
        await tester.runAsync(
          () => AiConsent(p.storage.local, 'mock-account').revoke(),
        );
        await tap(find.textContaining('Применить отмеченное за'));
        expect(find.text('Подтвердить'), findsNothing);
        expect((await stored()).amountGrams, 150);
        await tester.runAsync(
          () => AiConsent(p.storage.local, 'mock-account').accept(),
        );
        // Fresh consent does not resurrect the result from before revocation.
        await tap(find.textContaining('Применить отмеченное за'));
        expect(find.text('Подтвердить'), findsNothing);
        expect((await stored()).amountGrams, 150);
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        await tap(find.text('Отправить запрос ИИ'));
        await tap(find.byType(CheckboxListTile).last);
        await tap(find.textContaining('Применить отмеченное за'));
        expect(find.text('Подтвердить'), findsOneWidget);
        expect((await stored()).amountGrams, 150);
        await tap(find.text('Подтвердить'));
        expect((await stored()).amountGrams, 200);
        expect((await stored()).micros['vitaminD'], 2);
        // Revoking AI consent must never prevent a local safety undo.
        await tester.runAsync(
          () => AiConsent(p.storage.local, 'mock-account').revoke(),
        );
        await tap(find.text('Отменить последнее применение'));
        expect((await stored()).toJson(), original.toJson());
        expect(tester.takeException(), isNull);
      } finally {
        SmartRemote.instance.client = null;
        unawaited(client.dispose());
        fake.close();
      }
    },
  );

  testWidgets('consent cancellation or account switch never sends diary data', (
    tester,
  ) async {
    final original = entry();
    final calls = <String>[];
    final fake = MockClient((request) async {
      calls.add(request.url.path);
      return http.Response(
        jsonEncode(response([])),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    SupabaseClient makeClient(String user) => SupabaseClient(
      'https://mock.invalid',
      'public-test',
      httpClient: fake,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final a = makeClient('a'), b = makeClient('b');
    Future<void> initClient(SupabaseClient c, String id) =>
        c.auth.setInitialSession(
          jsonEncode({
            'access_token': 'fake-$id',
            'token_type': 'bearer',
            'user': {
              'id': id,
              'aud': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-10-28T00:00:00Z',
            },
          }),
        );
    await tester.runAsync(() async {
      await p.storage.addFoodBatch([original]);
      await p.reloadAll();
      await initClient(a, 'account-a');
      await initClient(b, 'account-b');
    });
    SmartRemote.instance.client = a;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> reveal(Finder f) async {
      for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
        final sc = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        sc.position.jumpTo(
          math.min(sc.position.maxScrollExtent, sc.position.pixels + 260),
        );
        await tester.pumpAndSettle();
      }
      expect(f, findsOneWidget);
      await tester.ensureVisible(f);
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> tap(Finder f) async {
      await reveal(f);
      await tester.runAsync(() async {
        await tester.tap(f);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pump(const Duration(milliseconds: 300));
    }

    try {
      await tester.pumpWidget(MaterialApp(home: DiaryAiScreen(provider: p)));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      await tap(find.text('Что будет отправлено'));
      expect(find.textContaining('На 100 г: 52.0 ккал'), findsOneWidget);
      expect(find.textContaining('Витамин C, мг: 6.0'), findsOneWidget);
      await tap(find.text('Отправить запрос ИИ'));
      expect(find.text('AI · одно согласие'), findsOneWidget);
      expect(calls, isEmpty);
      await tap(find.text('Не сейчас'));
      expect(calls, isEmpty);
      await tap(find.text('Отправить запрос ИИ'));
      expect(find.text('AI · одно согласие'), findsOneWidget);
      SmartRemote.instance.client = b;
      await tap(find.text('Мне 18+, запомнить'));
      expect(calls, isEmpty);
      expect(AiConsent(p.storage.local, 'account-a').accepted, isFalse);
      expect(AiConsent(p.storage.local, 'account-b').accepted, isFalse);
      final saved = (await tester.runAsync(
        () => p.storage.getFoodEntries(day),
      ))!.single;
      expect(saved.toJson(), original.toJson());
      expect(tester.takeException(), isNull);
    } finally {
      SmartRemote.instance.client = null;
      unawaited(a.dispose());
      unawaited(b.dispose());
      fake.close();
    }
  });
}
