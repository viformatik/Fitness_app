// Newly reconstructed local candidate tests; no real Supabase, diary or keys.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fitness_tracker/smart/catalog.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> item() => {
  'name': 'Продукт синтетический',
  'calories': 52,
  'protein': 2.8,
  'fat': 2.5,
  'carbs': 4.7,
  'micros': <String, Object>{},
};
String body(
  List<Object?> items, {
  Object? version = FoodCatalog.onlineNormalizationVersion,
  Object? partial = false,
}) => jsonEncode({
  'normalizationVersion': version,
  'partial': partial,
  'items': items,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => SmartRemote.instance.client = null);

  test('old, malformed, missing and oversized card contracts fail closed', () {
    for (final encoded in [
      jsonEncode({'items': []}),
      body([], version: 'fitness-off-mass-units-1'),
      body([], version: null),
      body([], partial: 'false'),
      body(List.generate(4, (_) => item())),
    ]) {
      expect(
        () => FoodCatalog.parseOnlineResult(encoded),
        throwsFormatException,
      );
    }
  });

  test(
    'implausible macros and unsupported micronutrients are not presented as confirmed',
    () {
      final first = item()
        ..['protein'] = 80
        ..['fat'] = 40;
      final second = item()
        ..['barcode'] = '12345678\n'
        ..['micros'] = {
          'sugars': 5,
          'saturatedFat': 3,
          'fiber': 200,
          'sodium': 54,
          'vitaminA': 123,
        };
      final result = FoodCatalog.parseOnlineResult(body([first, second]));
      expect(result.partial, isTrue);
      expect(result.items, hasLength(1));
      expect(result.items.single.barcode, isNull);
      expect(result.items.single.micros, {'sodium': 54});
      expect(result.items.single.microsEstimated, isTrue);
      expect(result.items.single.note, contains('100 г, а не на 100 мл'));
    },
  );

  test('non-Cyrillic, empty, malformed and impossible rows signal partial', () {
    final result = FoodCatalog.parseOnlineResult(
      body([
        {
          'name': 'Only Latin',
          'calories': 1,
          'protein': 0,
          'fat': 0,
          'carbs': 0,
        },
        {'name': 'Молоко', 'calories': 1, 'protein': -1, 'fat': 0, 'carbs': 0},
        null,
      ]),
    );
    expect(result.items, isEmpty);
    expect(result.partial, isTrue);
  });

  test('untrusted origin and token syntax fail before any request', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('', 200);
    });
    for (final origin in [
      'http://example.invalid',
      'https://user@example.invalid',
      'https://example.invalid/arbitrary',
      'https://example.invalid/?secret=1',
      'https://example.invalid/#fragment',
    ]) {
      await expectLater(
        FoodCatalog.searchOnline(
          'тест',
          client: client,
          baseUrl: origin,
          testAccessToken: 'synthetic-token',
        ),
        throwsA(isA<StateError>()),
      );
    }
    for (final token in ['', 'x\ny', 'a' * 4097]) {
      await expectLater(
        FoodCatalog.searchOnline(
          'тест',
          client: client,
          baseUrl: 'https://example.invalid',
          testAccessToken: token,
        ),
        throwsA(isA<StateError>()),
      );
    }
    expect(calls, 0);
    client.close();
  });

  test(
    'an active session cannot be routed through an injected client or test override',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        throw StateError('Unexpected network');
      });
      final supa = SupabaseClient(
        'https://synthetic.invalid',
        'synthetic-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: client,
      );
      try {
        await supa.auth.setInitialSession(
          jsonEncode({
            'access_token': 'synthetic-active-session',
            'token_type': 'bearer',
            'user': {'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},
          }),
        );
        SmartRemote.instance.client = supa;
        expect(supa.auth.currentSession, isNotNull);
        await expectLater(
          FoodCatalog.searchOnline(
            'тест',
            client: client,
            baseUrl: 'https://untrusted.invalid',
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          FoodCatalog.searchOnline(
            'тест',
            client: client,
            baseUrl: 'https://untrusted.invalid',
            testAccessToken: 'synthetic-active-session',
          ),
          throwsA(isA<StateError>()),
        );
        expect(calls, 0);
      } finally {
        SmartRemote.instance.client = null;
        await supa.dispose();
        client.close();
      }
    },
  );

  test(
    'a streamed body without declared length stops at the size cap',
    () async {
      final client = MockClient.streaming(
        (_, __) async => http.StreamedResponse(
          Stream.fromIterable([Uint8List(131072), Uint8List(131073)]),
          200,
        ),
      );
      await expectLater(
        FoodCatalog.searchOnline(
          'тест',
          client: client,
          baseUrl: 'https://example.invalid',
          testAccessToken: 'synthetic-token',
        ),
        throwsA(isA<StateError>()),
      );
      client.close();
    },
  );

  test(
    'invalid UTF-8 fails and network error messages do not expose a token',
    () async {
      final badText = MockClient(
        (_) async => http.Response.bytes([0xC0, 0xAF], 200),
      );
      await expectLater(
        FoodCatalog.searchOnline(
          'тест',
          client: badText,
          baseUrl: 'https://example.invalid',
          testAccessToken: 'synthetic-token',
        ),
        throwsA(isA<StateError>()),
      );
      badText.close();
      final failure = MockClient(
        (_) async =>
            throw http.ClientException('synthetic-token private-query'),
      );
      try {
        await FoodCatalog.searchOnline(
          'тест',
          client: failure,
          baseUrl: 'https://example.invalid',
          testAccessToken: 'synthetic-token',
        );
        fail('Expected a network failure');
      } catch (e) {
        expect(e, isA<StateError>());
        expect(e.toString(), isNot(contains('synthetic-token')));
        expect(e.toString(), isNot(contains('private-query')));
      } finally {
        failure.close();
      }
    },
  );
}
