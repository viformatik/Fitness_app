import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/assistant_hub.dart';
import 'package:fitness_tracker/smart/assistant_service.dart';
import 'package:fitness_tracker/smart/diary_ai.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/section_screens.dart';
import 'package:fitness_tracker/smart/ui.dart' show AiChatScreen, AiFoodPanel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthEvents extends ChangeNotifier {
  void changed() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final date = DateTime(2026, 10, 20);
  final item = FoodEntry(
    id: 'secret-real-id',
    name: 'Тестовое яблоко',
    amountGrams: 150,
    caloriesPer100g: 100,
    proteinPer100g: 10,
    fatPer100g: 2,
    carbsPer100g: 8,
    mealType: MealType.lunch,
    date: date,
    micros: const {'fiber': 1},
    microsEstimated: true,
  );
  const model = AssistantModel('openrouter', 'example/model:free', 'Example');
  const catalog = AssistantCatalog(
    models: [model],
    providerStates: {'openrouter': 'catalog'},
    promptVersion: 'fitness-assistant-1',
    systemInstruction: 'Системное правило теста.',
  );
  final snapshot = DiaryAiSnapshot(
    firstDay: date,
    lastDay: date,
    entries: [item],
  );
  const rawCatalog = <String, dynamic>{
    'models': [
      {
        'provider': 'openrouter',
        'id': 'example/model:free',
        'name': 'Example',
        'status': 'catalog',
      },
    ],
    'providers': [
      {'provider': 'openrouter', 'state': 'catalog'},
    ],
    'promptVersion': 'fitness-assistant-1',
    'systemInstruction': 'Системное правило теста.',
  };
  late AppDataProvider p;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
  });
  tearDown(() => p.dispose());

  test(
    'request contains selected exact portions, optional age and no real ID',
    () {
      final req = buildAssistantRequest(
        model: model,
        catalog: catalog,
        question: 'Что изменить?',
        adultConfirmed: true,
        history: [],
        food: snapshot,
      );
      expect(req['mode'], 'nutrition');
      expect(req.containsKey('ageYears'), isFalse);
      expect(jsonEncode(req), isNot(contains('secret-real-id')));
      expect(jsonEncode(req), isNot(contains('85.9')));
      final row = (req['entries'] as List).single as Map;
      expect(row['grams'], 150);
      expect(row['microsEstimated'], true);
      expect((row['micros'] as Map)['fiber'], 1);
      final upstream = previewAssistantMessages(req, catalog.systemInstruction);
      final context = jsonDecode(upstream.last['content'] as String) as Map;
      expect((context['entries'] as List).single['portionTotals'], {
        'calories': 150.0,
        'protein': 15.0,
        'fat': 3.0,
        'carbs': 12.0,
      });
      expect(context.containsKey('ageYears'), isFalse);
      expect(upstream.first['content'], 'Системное правило теста.');
      final withAge = buildAssistantRequest(
        model: model,
        catalog: catalog,
        question: '?',
        adultConfirmed: true,
        history: [],
        food: snapshot,
        ageYears: 18,
      );
      expect(withAge['ageYears'], 18);
      expect(
        () => buildAssistantRequest(
          model: model,
          catalog: catalog,
          question: '?',
          adultConfirmed: true,
          history: [],
          ageYears: 17,
        ),
        throwsArgumentError,
      );
      expect(
        () => buildAssistantRequest(
          model: model,
          catalog: catalog,
          question: '?',
          adultConfirmed: false,
          history: [],
        ),
        throwsArgumentError,
      );
    },
  );

  test('catalog is bounded, deduplicated and rejects unknown providers', () {
    final parsed = AssistantCatalog.parse({
      ...rawCatalog,
      'models': [
        ...(rawCatalog['models'] as List),
        ...(rawCatalog['models'] as List),
        {
          'provider': 'unknown',
          'id': 'bad',
          'name': 'bad',
          'status': 'catalog',
        },
        {'provider': 'groq', 'id': 'missing-status', 'name': 'bad'},
      ],
    });
    expect(parsed.models.length, 1);
    expect(parsed.models.single.key, model.key);
    expect(
      () => AssistantCatalog.parse({'models': [], 'providers': []}),
      throwsFormatException,
    );
  });

  Future<void> showPanel(
    WidgetTester tester,
    AssistantService service, {
    bool nutrition = true,
    Size size = const Size(320, 850),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                AssistantHubPanel(
                  service: service,
                  initialNutritionRange: nutrition
                      ? DateTimeRange(start: date, end: date)
                      : null,
                  initialQuestion: 'Проверь конкретные порции',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(f);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    // Busy indicator intentionally animates while the preview is open, so
    // pumpAndSettle cannot be used here.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> chooseModel(WidgetTester tester) async {
    await tapVisible(tester, find.text('Получить список моделей'));
    await tapVisible(tester, find.byType(DropdownButtonFormField<String>));
    await tapVisible(tester, find.text('OpenRouter · Example').last);
  }

  Future<void> adultConfirm(WidgetTester tester) async {
    await tapVisible(
      tester,
      find.text('Подтверждаю, что мне 18 лет или больше'),
    );
  }

  Future<void> closePanel(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets(
    '320px preview, cancellation and confirmed request stay read-only',
    (tester) async {
      await p.updateProfile(p.profile.copyWith(ageYears: 18));
      await tester.runAsync(() => p.storage.saveFoodEntries(date, [item]));
      final before = jsonEncode(p.storage.local.snapshot());
      final requests = <Map<String, dynamic>>[];
      final service = AssistantService(
        owner: () => 'user-one',
        invoke: (req) async {
          requests.add(jsonDecode(jsonEncode(req)) as Map<String, dynamic>);
          return req['action'] == 'models'
              ? rawCatalog
              : {
                  'text': 'Ответ по записанной порции.',
                  'provider': req['provider'],
                  'model': req['model'],
                };
        },
      );
      await showPanel(tester, service);
      await chooseModel(tester);
      await adultConfirm(tester);
      await tapVisible(tester, find.text('Добавить мой возраст'));
      await tapVisible(tester, find.text('Проверить и отправить'));
      expect(find.text('Проверить перед отправкой'), findsOneWidget);
      final preview = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? '')
          .join('\n');
      expect(preview, contains('Тестовое яблоко'));
      expect(preview, contains('"ageYears": 18'));
      expect(preview, contains('"calories": 150'));
      expect(preview, isNot(contains('secret-real-id')));
      expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
      await tapVisible(tester, find.text('Отмена'));
      expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
      await tapVisible(tester, find.text('Проверить и отправить'));
      await tapVisible(tester, find.text('Согласен и отправить'));
      final sent = requests.where((r) => r['action'] == 'ask').single;
      expect(sent['ageYears'], 18);
      expect(sent['history'], isEmpty);
      expect(jsonEncode(sent), isNot(contains('secret-real-id')));
      expect(jsonEncode(p.storage.local.snapshot()), before);
      expect(find.text('Ответ модели'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await closePanel(tester);
    },
  );
  testWidgets('truncated provider response is visibly marked incomplete', (
    tester,
  ) async {
    final service = AssistantService(
      owner: () => 'one',
      invoke: (req) async => req['action'] == 'models'
          ? rawCatalog
          : {
              'text': 'Неполная рекомендация',
              'provider': req['provider'],
              'model': req['model'],
              'truncated': true,
            },
    );
    await showPanel(tester, service, nutrition: false);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    await tapVisible(tester, find.text('Согласен и отправить'));
    expect(find.text('Неполная рекомендация'), findsOneWidget);
    expect(
      find.text('Ответ остановлен по лимиту длины и может быть неполным.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('changed diary after preview is not sent', (tester) async {
    await tester.runAsync(() => p.storage.saveFoodEntries(date, [item]));
    final requests = <Map<String, dynamic>>[];
    final service = AssistantService(
      owner: () => 'user-one',
      invoke: (req) async {
        requests.add(req);
        return req['action'] == 'models'
            ? rawCatalog
            : {
                'text': 'unexpected',
                'provider': req['provider'],
                'model': req['model'],
              };
      },
    );
    await showPanel(tester, service);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    await tester.runAsync(
      () => p.storage.saveFoodEntries(date, [
        item,
        FoodEntry.fromJson({
          ...item.toJson(),
          'id': 'second-item',
          'name': 'Другое',
        }),
      ]),
    );
    await tapVisible(tester, find.text('Согласен и отправить'));
    expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
    expect(
      find.textContaining('Дневник изменился после предпросмотра'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('account switch closes preview and never sends it', (
    tester,
  ) async {
    await tester.runAsync(() => p.storage.saveFoodEntries(date, [item]));
    var owner = 'one';
    final events = AuthEvents();
    final requests = <Map<String, dynamic>>[];
    final service = AssistantService(
      owner: () => owner,
      authChanges: events,
      invoke: (req) async {
        requests.add(req);
        return rawCatalog;
      },
    );
    await showPanel(tester, service);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    expect(find.text('Проверить перед отправкой'), findsOneWidget);
    owner = 'two';
    events.changed();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Проверить перед отправкой'), findsNothing);
    expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
    expect(find.textContaining('Аккаунт изменился'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await closePanel(tester);
    events.dispose();
  });

  testWidgets(
    'stored underage value blocks sending even when age not selected',
    (tester) async {
      await p.updateProfile(p.profile.copyWith(ageYears: 17));
      final calls = <Map<String, dynamic>>[];
      final service = AssistantService(
        owner: () => 'one',
        invoke: (req) async {
          calls.add(req);
          return rawCatalog;
        },
      );
      await showPanel(tester, service, nutrition: false);
      await chooseModel(tester);
      await adultConfirm(tester);
      await tapVisible(tester, find.text('Проверить и отправить'));
      expect(
        find.textContaining('необходимо подтвердить возраст'),
        findsOneWidget,
      );
      expect(calls.where((r) => r['action'] == 'ask'), isEmpty);
      expect(tester.takeException(), isNull);
      await closePanel(tester);
    },
  );

  testWidgets('changed age after preview is not sent', (tester) async {
    await p.updateProfile(p.profile.copyWith(ageYears: 18));
    await tester.runAsync(() => p.storage.saveFoodEntries(date, [item]));
    final requests = <Map<String, dynamic>>[];
    final service = AssistantService(
      owner: () => 'one',
      invoke: (req) async {
        requests.add(req);
        return rawCatalog;
      },
    );
    await showPanel(tester, service);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Добавить мой возраст'));
    await tapVisible(tester, find.text('Проверить и отправить'));
    await tester.runAsync(
      () => p.updateProfile(p.profile.copyWith(ageYears: 19)),
    );
    await tapVisible(tester, find.text('Согласен и отправить'));
    expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
    expect(
      find.textContaining('Аккаунт или возраст изменился'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('another account cannot submit a bound local diary', (
    tester,
  ) async {
    await p.storage.local.setString('_bound_user', 'different-user');
    final requests = <Map<String, dynamic>>[];
    final service = AssistantService(
      owner: () => 'one',
      invoke: (req) async {
        requests.add(req);
        return rawCatalog;
      },
    );
    await showPanel(tester, service);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    expect(find.textContaining('связан с другим аккаунтом'), findsOneWidget);
    expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('history is sent only after opting in and is shown in preview', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final service = AssistantService(
      owner: () => 'one',
      invoke: (req) async {
        requests.add(jsonDecode(jsonEncode(req)) as Map<String, dynamic>);
        return req['action'] == 'models'
            ? rawCatalog
            : {
                'text': 'Первый ответ.',
                'provider': req['provider'],
                'model': req['model'],
              };
      },
    );
    await showPanel(tester, service, nutrition: false);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    await tapVisible(tester, find.text('Согласен и отправить'));
    expect(
      requests.where((r) => r['action'] == 'ask').single['history'],
      isEmpty,
    );
    await tapVisible(tester, find.text('Добавить историю диалога'));
    await tapVisible(tester, find.text('Проверить и отправить'));
    final preview = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(preview, contains('Первый ответ.'));
    await tapVisible(tester, find.text('Согласен и отправить'));
    final history =
        requests.where((r) => r['action'] == 'ask').last['history'] as List;
    expect(history.length, 2);
    expect(history[0]['role'], 'user');
    expect(history[1]['text'], 'Первый ответ.');
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('preview remains usable in short landscape', (tester) async {
    final service = AssistantService(
      owner: () => 'one',
      invoke: (req) async => rawCatalog,
    );
    await showPanel(
      tester,
      service,
      nutrition: false,
      size: const Size(900, 320),
    );
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    expect(find.text('Проверить перед отправкой'), findsOneWidget);
    expect(find.text('Отмена'), findsOneWidget);
    expect(find.text('Согласен и отправить'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tapVisible(tester, find.text('Отмена'));
    await closePanel(tester);
  });

  testWidgets('clear invalidates an open per-request model preview', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final service = AssistantService(
      owner: () => 'user-one',
      invoke: (req) async {
        requests.add(req);
        return req['action'] == 'models'
            ? rawCatalog
            : {
                'text': 'Старый ответ',
                'provider': req['provider'],
                'model': req['model'],
              };
      },
    );
    await showPanel(tester, service, nutrition: false);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    expect(find.text('Согласен и отправить'), findsOneWidget);
    await tester.runAsync(() => p.storage.clearAll());
    await tapVisible(tester, find.text('Согласен и отправить'));
    expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
    expect(find.text('Старый ответ'), findsNothing);
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('clear hides an already sent model response', (tester) async {
    late Completer<void> started;
    late Completer<Map<String, dynamic>> response;
    await tester.runAsync(() async {
      started = Completer<void>();
      response = Completer<Map<String, dynamic>>();
    });
    final service = AssistantService(
      owner: () => 'user-one',
      invoke: (req) {
        if (req['action'] == 'models') return Future.value(rawCatalog);
        started.complete();
        return response.future;
      },
    );
    await showPanel(tester, service, nutrition: false);
    await chooseModel(tester);
    await adultConfirm(tester);
    await tapVisible(tester, find.text('Проверить и отправить'));
    await tapVisible(tester, find.text('Согласен и отправить'));
    await tester.runAsync(() async {
      await started.future.timeout(const Duration(seconds: 5));
      await p.storage.clearAll();
      response.complete({
        'text': 'Поздний ответ',
        'provider': model.provider,
        'model': model.id,
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Поздний ответ'), findsNothing);
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('old food/photo draft panel remains accessible in AI screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: const MaterialApp(home: AiChatScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(AiFoodPanel),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AiFoodPanel), findsOneWidget);
    expect(find.text('AI-чат · текст / фото / голос'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });

  testWidgets('exercise opens existing AI screen with a specific question', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(body: PlanExercisesScreen(openTraining: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byType(ExpansionTile).first);
    await tapVisible(tester, find.text('Спросить ИИ об упражнении').first);
    expect(find.byType(AiChatScreen), findsOneWidget);
    final screen = tester.widget<AiChatScreen>(find.byType(AiChatScreen));
    expect(
      screen.initialQuestion,
      contains('Как безопасно выполнять упражнение'),
    );
    expect(find.byType(AssistantHubPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await closePanel(tester);
  });
}
