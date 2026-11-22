import 'dart:async';
import 'dart:convert';
import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/journal_overview_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestJournalStorage implements StorageService {
  final StorageService base;
  _TestJournalStorage(this.base);
  @override
  LocalPreferences get local => base.local;
  @override
  Future<void> get pendingMutations => Future<void>.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestJournalProvider extends AppDataProvider {
  final StorageService testStorage;
  final DateTime testDate;
  _TestJournalProvider(StorageService base, this.testDate)
    : testStorage = _TestJournalStorage(base);
  @override
  StorageService get storage => testStorage;
  @override
  DateTime get selectedDate => testDate;
}

final d1 = DateTime(2026, 10, 20, 10);
final d2 = DateTime(2026, 10, 21, 10);
FoodEntry food(
  DateTime day, {
  String name = 'Яблоко',
  String id = 'secret-id',
  double grams = 150,
  bool estimated = false,
}) => FoodEntry(
  id: id,
  name: name,
  caloriesPer100g: 52,
  proteinPer100g: .3,
  fatPer100g: .2,
  carbsPer100g: 14,
  amountGrams: grams,
  mealType: MealType.snack,
  date: day,
  micros: const {'vitaminC': 6},
  microsEstimated: estimated,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'review can be cancelled and only confirmed selected summary is sent',
    (tester) async {
      LocalPreferences.memoryForTests = true;
      SharedPreferences.setMockInitialValues({});
      final base = AppDataProvider();
      await base.init();
      final p = _TestJournalProvider(base.storage, d2);
      await p.storage.local.setString(
        'food_entries_2026-10-20',
        jsonEncode([food(d1).toJson()]),
      );
      final before = jsonEncode(p.storage.local.snapshot());
      final sent = <Map<String, dynamic>>[];
      final fake = MockClient((request) async {
        sent.add(Map<String, dynamic>.from(jsonDecode(request.body)));
        return http.Response(
          jsonEncode({
            'summary': 'Тестовый ответ',
            'observations': ['Есть записи'],
            'suggestions': ['Проверьте'],
            'limitations': ['Данных мало'],
          }),
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
      await tester.runAsync(() async {
        await client.auth.setInitialSession(
          jsonEncode({
            'access_token': 'fake',
            'token_type': 'bearer',
            'user': {
              'id': 'mock-account',
              'aud': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-10-21T00:00:00Z',
            },
          }),
        );
        await AiConsent(p.storage.local, 'mock-account').accept();
      });
      SmartRemote.instance.client = client;
      await tester.binding.setSurfaceSize(const Size(390, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> tapReal(Finder f) async {
        await tester.ensureVisible(f);
        await tester.runAsync(() async {
          await tester.tap(f);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump(const Duration(milliseconds: 300));
      }

      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<AppDataProvider>.value(
            value: p,
            child: MaterialApp(home: JournalOverviewScreen(provider: p)),
          ),
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        final button = find.text('Подготовить анализ ИИ');
        // The local food breakdown pushes this lazy ListView child below the
        // first viewport. Build it by scrolling before trying ensureVisible.
        await tester.scrollUntilVisible(
          button,
          300,
          scrollable: find
              .descendant(
                of: find.byType(JournalOverviewScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tapReal(button);
        expect(find.text('Проверить перед отправкой'), findsOneWidget);
        expect(sent, isEmpty);
        expect(find.textContaining('Яблоко'), findsWidgets);
        await tapReal(find.text('Отмена').last);
        expect(sent, isEmpty);
        await tapReal(button);
        await tapReal(find.text('Отправить в Gemini'));
        expect(sent, hasLength(1));
        expect(jsonEncode(sent.single), contains('Яблоко'));
        expect(jsonEncode(sent.single), isNot(contains('secret-id')));
        expect(jsonEncode(p.storage.local.snapshot()), before);
        expect(find.text('Тестовый ответ'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        SmartRemote.instance.client = null;
        unawaited(client.dispose());
        fake.close();
        p.dispose();
        base.dispose();
      }
    },
  );
}
