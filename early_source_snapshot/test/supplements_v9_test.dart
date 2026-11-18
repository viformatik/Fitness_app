import 'dart:convert';
import 'dart:io';

import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/ai_drafts.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/csv_reader.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/mobile_extras.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/supplement_ui.dart';
import 'package:fitness_tracker/smart/supplements.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final day = DateTime(2026, 10, 28);
SupplementEntry supplement({
  String id = 'creatine',
  String name = 'Креатин',
  double quantity = 5,
  String unit = 'g',
  String nutrient = 'creatine',
  double? strength,
  String strengthUnit = '',
  Map<String, double> composition = const {},
  DateTime? date,
  String source = 'manual',
}) => SupplementEntry(
  id: id,
  name: name,
  quantity: quantity,
  unit: unit,
  nutrientKey: nutrient,
  strength: strength,
  strengthUnit: strengthUnit,
  compositionPerUnit: composition,
  date: date ?? day,
  source: source,
);
Json aiSupplement({double quantity = 5, String unit = 'g'}) => {
  'name': 'Креатин',
  'quantity': quantity,
  'unit': unit,
  'nutrientKey': 'creatine',
  'strength': 0,
  'strengthUnit': 'unknown',
  'assumptions': 'Проверьте количество',
};
Json aiFood({
  Map<String, double> micros = const {'vitaminC': 40, 'vitaminB12': .04},
}) => {
  'name': 'Яблоко',
  'grams': 150.0,
  'calories': 52.0,
  'protein': .3,
  'fat': .2,
  'carbs': 14.0,
  'meal': 'snack',
  'assumptions': 'Оценка',
  'micros': micros,
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
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    p.dispose();
  });

  test(
    'Explicit creatine amounts and strengths convert without food calories',
    () {
      expect(supplement().creatineGrams, 5);
      expect(supplement(quantity: 5000, unit: 'mg').creatineGrams, 5);
      expect(
        supplement(
          quantity: 2,
          unit: 'capsule',
          strength: 500,
          strengthUnit: 'mg',
        ).creatineGrams,
        1,
      );
      expect(supplement(quantity: 2, unit: 'capsule').creatineGrams, isNull);
      expect(supplement(quantity: 1, unit: 'iu').creatineGrams, isNull);
    },
  );
  test(
    'D2/D3 40 IU = 1 mcg; unrelated IU and ambiguous vitamin A stay unknown',
    () {
      expect(
        supplement(
          name: 'Витамин D3',
          nutrient: 'vitaminD',
          quantity: 2000,
          unit: 'iu',
        ).microTotals,
        {'vitaminD': 50},
      );
      expect(
        supplement(
          name: 'Кальцифедиол 25(OH)D',
          nutrient: 'vitaminD',
          quantity: 2000,
          unit: 'iu',
        ).microTotals,
        isEmpty,
      );
      expect(
        supplement(
          name: 'Витамин A',
          nutrient: 'vitaminA',
          quantity: 1000,
          unit: 'iu',
        ).microTotals,
        isEmpty,
      );
      expect(
        supplement(
          name: 'Витамин A',
          nutrient: 'vitaminA',
          quantity: 1000,
          unit: 'mcg',
        ).microTotals,
        isEmpty,
      );
      expect(
        supplement(
          name: 'Витамин E',
          nutrient: 'vitaminE',
          quantity: 1000,
          unit: 'iu',
        ).microTotals,
        isEmpty,
      );
      expect(
        supplement(
          name: 'D',
          nutrient: 'vitaminD',
          quantity: 2,
          unit: 'capsule',
          strength: 1000,
          strengthUnit: 'iu',
        ).microTotals,
        {'vitaminD': 50},
      );
    },
  );
  test('Explicit composition per unit wins and preserves known zero', () {
    final e = supplement(
      name: 'Комплекс',
      nutrient: 'other',
      unit: 'tablet',
      quantity: 2,
      composition: {'vitaminA': 400, 'vitaminC': 30, 'calcium': 0},
    );
    expect(e.microTotals, {'vitaminA': 800, 'vitaminC': 60, 'calcium': 0});
    expect(
      supplementMicroTotals([
        e,
        supplement(name: 'C', nutrient: 'vitaminC', quantity: 500, unit: 'mg'),
      ]),
      {'vitaminA': 800, 'vitaminC': 560, 'calcium': 0},
    );
    expect(e.microTotals.containsKey('vitaminD'), isFalse);
    expect(
      supplement(
        name: 'Биотин',
        nutrient: 'biotin',
        quantity: 1,
        unit: 'mg',
      ).microTotals['biotin'],
      1000,
    );
    expect(
      supplement(
        name: 'B5',
        nutrient: 'pantothenicAcid',
        quantity: 1000,
        unit: 'mcg',
      ).microTotals['pantothenicAcid'],
      1,
    );
  });
  test(
    'Form validation rejects negative, nonfinite, unknown units and invented zero dose',
    () {
      final original = supplement().toJson();
      for (final bad in [0, -1, double.nan, double.infinity, 1000001]) {
        expect(
          () => SupplementEntry.fromJson({...original, 'quantity': bad}),
          throwsFormatException,
        );
      }
      expect(
        () => SupplementEntry.fromJson({...original, 'unit': 'unknown'}),
        throwsFormatException,
      );
      expect(
        () => SupplementEntry.fromJson({
          ...original,
          'compositionPerUnit': {'vitaminC': -1},
        }),
        throwsFormatException,
      );
      expect(
        () => SupplementEntry.fromJson({
          ...original,
          'compositionPerUnit': {'untrusted': 4},
        }),
        throwsFormatException,
      );
      expect(
        () => SupplementEntry.fromJson({
          ...original,
          'strength': 1,
          'strengthUnit': 'unknown',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'AI supplement draft preserves unknown and a photo alone never records consumption',
    () {
      final recognized = [
        aiSupplement(),
        aiSupplement(quantity: 0, unit: 'unknown'),
      ];
      final normal = prepareAiSupplementReview(
        recognized,
        hasTakenDescription: true,
      );
      expect(normal.first['quantity'], 5);
      expect(normal.last['quantity'], 0);
      expect(normal.last['unit'], '');
      final photo = prepareAiSupplementReview(
        recognized,
        hasTakenDescription: false,
      );
      expect(photo.every((e) => e['quantity'] == 0 && e['unit'] == ''), isTrue);
      expect(
        () => validateAiSupplements([
          {'name': 'x', 'quantity': -1},
        ]),
        throwsFormatException,
      );
      expect(
        () => validateAiSupplements([
          {'name': 'x', 'quantity': double.nan},
        ]),
        throwsFormatException,
      );
      expect(
        () => validateAiSupplements(List.generate(31, (_) => aiSupplement())),
        throwsFormatException,
      );
      final request = buildAiSupplementRequest(text: '  креатин 5 г  ');
      expect(request, {'mode': 'supplement', 'text': 'креатин 5 г'});
      expect(() => buildAiSupplementRequest(), throwsArgumentError);
      expect(
        () =>
            buildAiSupplementRequest(text: 'x', image: [0], mime: 'image/gif'),
        throwsArgumentError,
      );
    },
  );
  test(
    'AI micros: per 100g, allowlist, unknown ≠ zero, invalid values rejected',
    () {
      final row = validateAiItems([
        {
          ...aiFood(),
          'micros': {
            'vitaminC': 40,
            'vitaminB12': .04,
            'fiber': 0,
            'unknown': 999,
          },
          'secret': 'discard',
        },
      ]).single;
      expect(row['micros'], {
        'vitaminC': 40.0,
        'vitaminB12': .04,
        'fiber': 0.0,
      });
      expect(row.containsKey('secret'), isFalse);
      expect((row['micros'] as Map).containsKey('iron'), isFalse);
      for (final value in [-1, double.nan, double.infinity, 100001]) {
        expect(
          () => validateAiItems([
            {
              ...aiFood(),
              'micros': {'iron': value},
            },
          ]),
          throwsFormatException,
        );
      }
      expect(
        validateAiItems([
          {...aiFood(), 'micros': null},
        ]).single['micros'],
        isEmpty,
      );
      final total = aggregateMicros([
        {'micros': row['micros'], 'amountGrams': 150},
      ]);
      expect(total['vitaminC']!.value, 60);
      expect(total['vitaminB12']!.value, closeTo(.06, .000001));
      expect(formatNutrient(.06), '0.06');
      expect(formatNutrient(.00003), isNot('0'));
    },
  );
  test(
    'Existing micro data is not overwritten; AI replacement is only a draft',
    () {
      expect(
        mergeMicronutrientEstimates(
          {'vitaminC': 17, 'iron': 0},
          {'vitaminC': 99, 'iron': 4, 'vitaminD': 3},
        ),
        {'vitaminC': 17, 'iron': 0, 'vitaminD': 3},
      );
      final request = buildAiFoodRequest(
        text: 'измени вес',
        mode: 'refine',
        previousItems: [aiFood()],
      );
      expect(((request['previousItems'] as List).single as Map)['micros'], {
        'vitaminC': 40.0,
        'vitaminB12': .04,
      });
      expect(
        buildAiFoodRequest(text: 'яблоко', mode: 'micronutrients')['mode'],
        'micronutrients',
      );
    },
  );
  test(
    'Persist, edit, delete, selected-day isolation and no calorie/food coverage distortion',
    () async {
      await p.addFoodEntry(
        FoodEntry(
          id: 'food',
          name: 'Яблоко',
          caloriesPer100g: 50,
          proteinPer100g: 1,
          fatPer100g: 1,
          carbsPer100g: 10,
          amountGrams: 200,
          mealType: MealType.snack,
          date: day,
          micros: const {'vitaminC': 10},
        ),
      );
      final a = supplement();
      final d = supplement(
        id: 'd',
        name: 'D',
        nutrient: 'vitaminD',
        quantity: 2000,
        unit: 'iu',
      );
      await p.addSupplementEntriesBatch([a, d]);
      await p.addSupplementEntriesBatch([a]);
      expect(p.todaySupplementEntries, hasLength(2));
      expect(p.todayCaloriesConsumed, 100);
      final food = aggregateMicros(p.todayFoodEntries.map((e) => e.toJson()));
      expect(food['vitaminD']!.coverage, 0);
      expect(supplementMicroTotals(p.todaySupplementEntries)['vitaminD'], 50);
      final next = day.add(const Duration(days: 1));
      await p.setSelectedDate(next);
      expect(p.todaySupplementEntries, isEmpty);
      await p.addSupplementEntriesBatch([
        supplement(id: 'otherday', date: next),
      ]);
      await p.setSelectedDate(day);
      expect(p.todaySupplementEntries, hasLength(2));
      await p.updateSupplementEntry(supplement(quantity: 3));
      expect(p.todaySupplementEntries.first.creatineGrams, 3);
      await p.deleteSupplementEntry(d);
      expect(p.todaySupplementEntries.single.id, 'creatine');
      expect(
        (await p.storage.getSupplementEntries(next)).single.id,
        'otherday',
      );
    },
  );
  test(
    'Failed write leaves previous data; retry does not create duplicates',
    () async {
      await p.addSupplementEntriesBatch([supplement()]);
      LocalPreferences.rejectWriteKeyForTests =
          'supplement_entries_${dayKey(day)}';
      await expectLater(
        p.addSupplementEntriesBatch([supplement(id: 'two')]),
        throwsStateError,
      );
      expect(p.todaySupplementEntries.single.id, 'creatine');
      LocalPreferences.rejectWriteKeyForTests = null;
      await p.addSupplementEntriesBatch([supplement(id: 'two')]);
      await p.addSupplementEntriesBatch([supplement(id: 'two')]);
      expect(p.todaySupplementEntries, hasLength(2));
    },
  );
  test(
    'Date and IDs validated before import; backup excludes consent/cache',
    () async {
      await p.addSupplementEntriesBatch([supplement()]);
      await AiConsent(p.storage.local, 'one').accept();
      await p.storage.local.setString('_ai_drafts_one', 'private');
      final exported = await p.storage.exportData();
      final data = exported['data'] as Map;
      final key = 'supplement_entries_${dayKey(day)}';
      expect(data.containsKey(key), isTrue);
      expect(data.keys.where((k) => k.toString().startsWith('_')), isEmpty);
      expect(p.storage.local.snapshot()[key], data[key]);
      final csv = exportCsv(Map<String, dynamic>.from(data));
      expect(csv, contains('"supplement","2026-10-28"'));
      expect(importCsv(csv)[key], data[key]);
      expect(LocalPreferences.appKey('supplement_entries_not-a-date'), isFalse);
      final bad = jsonEncode([
        supplement(date: day.add(const Duration(days: 1))).toJson(),
      ]);
      expect(() => validateAppDocument(key, bad), throwsFormatException);
      expect(
        () => validateAppDocument(
          key,
          jsonEncode([supplement().toJson(), supplement().toJson()]),
        ),
        throwsFormatException,
      );
      await expectLater(
        p.storage.importData({
          'data': {key: bad},
        }),
        throwsFormatException,
      );
      expect((await p.storage.getSupplementEntries(day)).single.id, 'creatine');
      expect(await p.storage.importData(exported), isTrue);
      expect(
        (await p.storage.getSupplementEntries(day)).single.creatineGrams,
        5,
      );
    },
  );
  test(
    'AI provenance survives food JSON, quick food, recipes and repeat day',
    () async {
      final food = FoodEntry(
        id: 'a',
        name: 'Яблоко',
        caloriesPer100g: 50,
        proteinPer100g: 1,
        fatPer100g: 1,
        carbsPer100g: 10,
        amountGrams: 150,
        mealType: MealType.snack,
        date: day,
        micros: const {'vitaminC': 40},
        microsEstimated: true,
      );
      await p.addFoodEntriesBatch([food]);
      await p.reloadAll();
      expect(p.todayFoodEntries.single.microsEstimated, isTrue);
      expect(p.quickFoods.single.microsEstimated, isTrue);
      expect(p.quickFoods.single.toEntry(date: day).microsEstimated, isTrue);
      final copy = makePreviousDayCopies([
        food,
      ], day.add(const Duration(days: 1))).single;
      expect(copy.microsEstimated, isTrue);
      final recipe = Recipe(
        name: 'Рецепт',
        ingredients: [
          RecipeIngredient(
            name: food.name,
            grams: 100,
            caloriesPer100g: food.caloriesPer100g,
            proteinPer100g: food.proteinPer100g,
            fatPer100g: food.fatPer100g,
            carbsPer100g: food.carbsPer100g,
            micros: food.micros,
            microsEstimated: food.microsEstimated,
          ),
        ],
      );
      expect(recipe.toEntry(100, MealType.snack).microsEstimated, isTrue);
      await p.saveCustomFood(recipe.toFoodItem());
      final pinned = p
          .searchFoods('Рецепт')
          .firstWhere((f) => f.source == 'Мои продукты');
      expect(pinned.microsEstimated, isTrue);
      expect(pinned.micros['vitaminC'], 40);
      await p.addFavorite(pinned, MealType.breakfast);
      expect(
        p.favoriteFoods
            .firstWhere((f) => f.mealType == MealType.breakfast)
            .microsEstimated,
        isTrue,
      );
    },
  );
  test('Real Hive reopens supplement records', () async {
    final dir = await Directory.systemTemp.createTemp('supplement_hive_');
    LocalPreferences.memoryForTests = false;
    LocalPreferences.directoryForTests = dir.path;
    try {
      await p.storage.init();
      await p.storage.addSupplementBatch([supplement()]);
      await LocalPreferences.close();
      await p.storage.init();
      expect(
        (await p.storage.getSupplementEntries(day)).single.creatineGrams,
        5,
      );
    } finally {
      await LocalPreferences.close();
      LocalPreferences.directoryForTests = null;
      LocalPreferences.memoryForTests = true;
      await dir.delete(recursive: true);
    }
  });

  test(
    'Mock cloud sync uploads/pulls supplement document and preserves conflicts',
    () async {
      final rows = <String, Map<String, dynamic>>{};
      final fake = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/fitness_sleep_documents')) {
          return http.Response(
            jsonEncode({'code': 'PGRST205', 'message': 'Table not present'}),
            404,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (path.endsWith('/fitness_documents')) {
          return http.Response(
            jsonEncode(rows.values.toList()),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (path.endsWith('/rpc/write_fitness_document')) {
          final data = jsonDecode(request.body) as Map;
          final key = data['p_key'] as String, current = rows[key];
          if ((current?['revision']) != data['p_expected']) {
            return http.Response(
              jsonEncode({
                'code': '40001',
                'message': 'Concurrent document change',
              }),
              409,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          final next = ((current?['revision'] as int?) ?? 0) + 1;
          rows[key] = {
            'key': key,
            'payload': data['p_payload'],
            'revision': next,
          };
          return http.Response(
            '$next',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        return http.Response('Unexpected request', 500, request: request);
      });
      final client = SupabaseClient(
        'https://sync.test.invalid',
        'test-public',
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
        await p.addSupplementEntriesBatch([supplement()]);
        await SmartRemote.instance.sync(
          p.storage.local,
          validate: validateAppDocument,
        );
        final key = 'supplement_entries_${dayKey(day)}';
        expect(rows[key]!['revision'], 1);
        expect(
          jsonDecode(rows[key]!['payload'] as String).single['quantity'],
          5,
        );
        SharedPreferences.setMockInitialValues({});
        final deviceB = await LocalPreferences.open();
        await SmartRemote.instance.sync(deviceB, validate: validateAppDocument);
        expect((deviceB.decoded(key) as List).single['quantity'], 5);
        await p.updateSupplementEntry(supplement(quantity: 3));
        await deviceB.setString(
          key,
          jsonEncode([supplement(quantity: 7).toJson()]),
        );
        await SmartRemote.instance.sync(
          p.storage.local,
          validate: validateAppDocument,
        );
        await SmartRemote.instance.sync(deviceB, validate: validateAppDocument);
        expect(SmartRemote.instance.conflicts.single.key, key);
        expect((deviceB.decoded(key) as List).single['quantity'], 7);
        expect(
          jsonDecode(rows[key]!['payload'] as String).single['quantity'],
          3,
        );
      } finally {
        SmartRemote.instance.client = null;
        await client.dispose();
        fake.close();
      }
    },
  );

  test(
    'Mock AI transport uses the real client contracts without sharing profile data',
    () async {
      final requests = <Map<String, dynamic>>[];
      final fake = MockClient((request) async {
        expect(request.url.path, '/functions/v1/food-ai');
        final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        requests.add(body);
        final rows = body['mode'] == 'supplement'
            ? [aiSupplement()]
            : [aiFood()];
        return http.Response(
          jsonEncode({'items': rows}),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final client = SupabaseClient(
        'https://ai.test.invalid',
        'test-public',
        httpClient: fake,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.setInitialSession(
        jsonEncode({
          'access_token': 'fake',
          'token_type': 'bearer',
          'user': {
            'id': 'mock-ai-account',
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
            'created_at': '2026-10-28T00:00:00Z',
          },
        }),
      );
      SmartRemote.instance.client = client;
      try {
        final supplements = await SmartRemote.instance.parseSupplements(
          text: '5 г креатина',
        );
        final food = await SmartRemote.instance.parseFood(text: 'яблоко 150 г');
        expect(supplements.single['unit'], 'g');
        expect((food.single['micros'] as Map)['vitaminC'], 40);
        expect(requests[0].keys.toSet(), {'mode', 'text'});
        expect(requests[1].keys.toSet(), {'mode', 'text'});
        expect(requests[0]['mode'], 'supplement');
        expect(requests[1]['mode'], 'food');
        expect(p.todayFoodEntries, isEmpty);
        expect(p.todaySupplementEntries, isEmpty);
      } finally {
        SmartRemote.instance.client = null;
        await client.dispose();
        fake.close();
      }
    },
  );

  Future<void> mobile(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  Future<void> realTap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    '320 px AI supplement review cannot save without confirming each dose',
    (tester) async {
      await mobile(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<int>(
              context: context,
              builder: (_) => SupplementReviewDialog(
                items: [aiSupplement()],
                provider: p,
                date: day,
              ),
            ),
            child: const Text('Открыть'),
          ),
        ),
      );
      await realTap(tester, find.text('Открыть'));
      await realTap(tester, find.text('Добавить 1'));
      expect(
        find.text('Проверьте и подтвердите количество каждой добавки.'),
        findsOneWidget,
      );
      expect(p.todaySupplementEntries, isEmpty);
      await realTap(tester, find.text('Проверить дозу'));
      expect(find.text('Запись добавки'), findsOneWidget);
      await realTap(tester, find.text('Применить'));
      expect(find.text('Проверено · изменить'), findsOneWidget);
      await realTap(tester, find.text('Добавить 1'));
      expect(p.todaySupplementEntries.single.creatineGrams, 5);
      expect(p.todaySupplementEntries.single.source, 'ai');
      expect(p.todayFoodEntries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('320 px AI unknown quantity cannot be accepted until entered', (
    tester,
  ) async {
    await mobile(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<int>(
            context: context,
            builder: (_) => SupplementReviewDialog(
              items: [aiSupplement(quantity: 0, unit: 'unknown')],
              provider: p,
              date: day,
            ),
          ),
          child: const Text('Открыть'),
        ),
      ),
    );
    await realTap(tester, find.text('Открыть'));
    await realTap(tester, find.text('Проверить дозу'));
    await realTap(tester, find.text('Применить'));
    expect(find.text('Введите количество больше 0'), findsOneWidget);
    expect(p.todaySupplementEntries, isEmpty);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Сколько принято'),
      '5',
    );
    final dropdown = find.byType(DropdownButtonFormField<String>).at(1);
    await realTap(tester, dropdown);
    await realTap(tester, find.text('г').last);
    await realTap(tester, find.text('Применить'));
    await realTap(tester, find.text('Добавить 1'));
    expect(p.todaySupplementEntries.single.creatineGrams, 5);
    expect(tester.takeException(), isNull);
  });
  testWidgets('320 px manual supplement CRUD has no food side effects', (
    tester,
  ) async {
    await mobile(
      tester,
      ChangeNotifierProvider.value(
        value: p,
        child: Consumer<AppDataProvider>(
          builder: (_, provider, __) =>
              SingleChildScrollView(child: SupplementPanel(provider: provider)),
        ),
      ),
    );
    await realTap(tester, find.text('Добавить вручную'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Название'),
      'Моногидрат',
    );
    await realTap(tester, find.byType(DropdownButtonFormField<String>).first);
    await tester.scrollUntilVisible(
      find.text('Креатин'),
      -250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await realTap(tester, find.text('Креатин').last);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Сколько принято'),
      '5',
    );
    await realTap(tester, find.byType(DropdownButtonFormField<String>).at(1));
    await realTap(tester, find.text('г').last);
    await realTap(tester, find.text('Применить'));
    expect(p.todaySupplementEntries.single.creatineGrams, 5);
    expect(p.todayFoodEntries, isEmpty);
    await realTap(tester, find.byTooltip('Удалить добавку'));
    await realTap(tester, find.text('Удалить'));
    expect(p.todaySupplementEntries, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Food AI review saves micronutrients only after confirmation and marks estimate',
    (tester) async {
      await mobile(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<int>(
              context: context,
              builder: (_) =>
                  AiReviewDialog(items: [aiFood()], provider: p, date: day),
            ),
            child: const Text('Открыть'),
          ),
        ),
      );
      await realTap(tester, find.text('Открыть'));
      expect(p.todayFoodEntries, isEmpty);
      expect(find.textContaining('Витамины и минералы'), findsWidgets);
      await realTap(tester, find.text('Добавить 1 · 78 ккал'));
      expect(p.todayFoodEntries.single.micros, {
        'vitaminC': 40.0,
        'vitaminB12': .04,
      });
      expect(p.todayFoodEntries.single.microsEstimated, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
