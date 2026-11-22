import 'dart:convert';
import 'dart:typed_data';
import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/catalog.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/local_catalog.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/photo.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:fitness_tracker/smart/voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> sampleDraft() => {
  'name': 'Творог',
  'grams': 150.0,
  'calories': 90.0,
  'protein': 12.0,
  'fat': 4.0,
  'carbs': 4.0,
  'meal': 'breakfast',
  'assumptions': 'Проверьте порцию',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
  });
  tearDown(() {
    SmartRemote.instance.client = null;
    provider.dispose();
  });

  test('Offline catalog is Cyrillic, local and preserves exact ТХК values', () {
    final foods = FoodDatabase.allFoods;
    expect(foods.every((f) => FoodCatalog.hasCyrillic(f.name)), isTrue);
    expect(localCatalogFoods.length, 99);
    expect(
      localCatalogFoods.every((f) => f.source == FoodCatalog.pmrSource),
      isTrue,
    );
    final exact = localCatalogFoods.where(
      (f) => (f.note ?? '').contains('официальному каталогу ТХК'),
    );
    expect(exact.length, 94);
    expect(
      exact.every((f) => (f.sourceUrl ?? '').contains('tirhleb.com')),
      isTrue,
    );
    expect(foods.every((f) => f.micros.isEmpty), isTrue,
        reason: 'Unconfirmed micronutrients are not invented');
    expect(foods.any((f) => !f.micros.containsKey('vitaminB12')), isTrue);
    expect(foods.every((f) => f.calories.isFinite && f.calories >= 0), isTrue);
    expect(microLabels.length, 24);
    expect(vitaminKeys.length, 13);
  });

  test('Russian synonyms, filters, nutrient density and unknown values', () {
    final foods = [
      FoodItem(
        'Курица грудка',
        165,
        31,
        3.6,
        0,
        {'vitaminC': 12, 'sugars': 0},
        'Птица',
        FoodCatalog.pmrSource,
        null,
        null,
        null,
        null,
        'chicken',
      ),
      FoodItem(
        'Гречка ядрица',
        343,
        13,
        3,
        70,
        {'fiber': 10, 'vitaminC': 1},
        'Крупы',
        FoodCatalog.pmrSource,
        null,
        null,
        null,
        null,
        'buckwheat',
      ),
      FoodItem(
        'Торт сахарный',
        450,
        4,
        20,
        60,
        {'sugars': 40},
        'Сладости',
        FoodCatalog.localSource,
      ),
      FoodItem(
        'Неизвестная конфета',
        400,
        3,
        15,
        70,
        <String, double>{},
        'Сладости',
        FoodCatalog.offSource,
      ),
    ];
    final chicken = FoodCatalog.filter(foods, query: 'курица');
    expect(chicken.single.name, contains('Курица'));
    expect(
      FoodCatalog.filter(foods, query: 'grechka').single.name,
      contains('Гречка'),
    );
    final lowSugar = FoodCatalog.filter(foods, lowSugar: true);
    expect(lowSugar.any((f) => f.name == 'Неизвестная конфета'), isFalse);
    expect(lowSugar.any((f) => f.name == 'Торт'), isFalse);
    final vitamin = FoodCatalog.filter(
      foods,
      nutrient: 'vitaminC',
      sort: FoodCatalog.nutrientSort,
    );
    expect(vitamin, hasLength(2));
    expect(vitamin.first.name, contains('Курица'));
    final protein = FoodCatalog.filter(foods, sort: FoodCatalog.proteinSort);
    expect(protein.first.protein, 31);
  });

  test(
    'Online catalog response rejects incomplete macros and keeps ODbL provenance',
    () {
      final items = FoodCatalog.parseOnlineResponse(
        jsonEncode({
          'items': [
            {
              'name': 'Йогурт Активиа',
              'calories': 49,
              'protein': 4.9,
              'fat': 0.1,
              'carbs': 7,
              'micros': {'sodium': 100, 'bogus': -5, 'vitaminC': 'NaN'},
              'category': 'Йогурты',
              'brand': 'Данон',
              'barcode': '5060058334101',
            },
            {'name': 'Без макросов', 'calories': 10, 'protein': 0, 'fat': 0},
            {
              'name': 'Опасный продукт',
              'calories': -1,
              'protein': 0,
              'fat': 0,
              'carbs': 0,
            },
            {
              'name': 'English only product',
              'calories': 10,
              'protein': 1,
              'fat': 1,
              'carbs': 1,
            },
          ],
        }),
      );
      expect(items, hasLength(1));
      expect(items.single.source, FoodCatalog.offSource);
      expect(items.single.brand, 'Данон');
      expect(items.single.barcode, '5060058334101');
      expect(items.single.micros, {'sodium': 100});
    },
  );

  test('Online search uses the read-only proxy with a bounded query', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/functions/v1/food-search');
      expect(request.url.queryParameters['q'], 'Активиа');
      expect(request.headers['Authorization'], isNull);
      return http.Response(
        jsonEncode({
          'items': [
            {
              'name': 'Йогурт Активиа',
              'calories': 49,
              'protein': 4.9,
              'fat': 0.1,
              'carbs': 7,
              'micros': <String, dynamic>{},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final found = await FoodCatalog.searchOnline(
      'Активиа',
      client: client,
      baseUrl: 'https://example.supabase.co',
    );
    expect(found.single.name, 'Йогурт Активиа');
    await expectLater(
      FoodCatalog.searchOnline(
        'x',
        client: client,
        baseUrl: 'https://example.supabase.co',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'Voice locale uses ru-RU on web and friendly fallback on permission error',
    () {
      expect(resolveSpeechLocale(web: true, locales: const ['en-US']), 'ru-RU');
      expect(
        resolveSpeechLocale(web: false, locales: const ['en-US', 'ru_RU']),
        'ru-RU',
      );
      expect(
        acceptVoiceResult(listening: true, session: 3, currentSession: 3),
        isTrue,
      );
      expect(
        acceptVoiceResult(listening: false, session: 3, currentSession: 3),
        isFalse,
      );
      expect(
        acceptVoiceResult(listening: true, session: 2, currentSession: 3),
        isFalse,
      );
      final error = friendlyVoiceError(
        SpeechRecognitionError('not-allowed', false),
      );
      expect(error, contains('микрофон'));
      expect(error, contains('клавиатуре'));
    },
  );

  test('Large photo is safely re-encoded to a small JPEG', () {
    final source = img.Image(width: 1200, height: 900, numChannels: 3);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(
          x,
          y,
          (x * 7 + y) % 256,
          (x * y) % 256,
          (x + y * 3) % 256,
        );
      }
    }
    final original = Uint8List.fromList(img.encodeJpg(source, quality: 100));
    final result = compressPhotoSync(
      PhotoInput(original, maxBytes: 300000, maxDimension: 900),
    );
    expect(result.mime, 'image/jpeg');
    expect(result.width, lessThanOrEqualTo(900));
    expect(result.height, lessThanOrEqualTo(900));
    expect(result.bytes.length, lessThan(600000));
    expect(result.originalBytes, original.length);
  });

  test('Catalog food can be pinned to My products with new vitamins', () async {
    final food = FoodItem(
      'Тестовый продукт с витамином C',
      50,
      3,
      1,
      8,
      {'vitaminC': 40, 'folate': 30},
      'Фрукты',
      FoodCatalog.pmrSource,
      null,
      null,
      null,
      null,
      'vitamin C',
    );
    await provider.saveCustomFood(food);
    final found = provider.searchFoods('vitamin C').single;
    expect(found.source, FoodCatalog.mySource);
    expect(found.micros['vitaminC'], 40);
    expect(found.micros['folate'], 30);
    await provider.refresh();
    expect(provider.searchFoods('vitamin C').single.micros['vitaminC'], 40);
  });

  testWidgets(
    'AI chat clears text after successful processing and keeps history',
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
      await AiConsent(provider.storage.local, 'ui-test-account').accept();
      var calls = 0;
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
                      }) async {
                        calls++;
                        expect(text, 'Творог 150 г');
                        expect(mode, 'food');
                        return [sampleDraft()];
                      },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.maxLines == 3,
      );
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Творог 150 г');
      final submit = find.text('Разобрать и проверить');
      await tester.ensureVisible(submit);
      await tester.runAsync(() async {
        await tester.tap(submit);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.widget<TextField>(field).controller!.text, '');
      expect(
        find.textContaining('Подготовлен черновик: 1 поз.'),
        findsOneWidget,
      );
      expect(find.text('Открыть черновик'), findsOneWidget);
      expect(find.byType(AiReviewDialog), findsOneWidget);
    },
  );
}
