import 'dart:convert';
import 'dart:math' as math;

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/assistant_hub.dart';
import 'package:fitness_tracker/smart/assistant_service.dart';
import 'package:fitness_tracker/smart/diary_ai.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestAuthEvents extends ChangeNotifier {
  void changed() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final date = DateTime(2026, 10, 20);
  final food = FoodEntry(
    id: 'secret-local-id',
    name: 'Яблоко синтетическое',
    amountGrams: 150,
    caloriesPer100g: 52,
    proteinPer100g: .3,
    fatPer100g: .2,
    carbsPer100g: 14,
    mealType: MealType.lunch,
    date: date,
    micros: {'vitaminC': 6},
  );
  final snapshot = DiaryAiSnapshot(
    firstDay: date,
    lastDay: date,
    entries: [food],
  );
  const model = AssistantModel('openrouter', 'example/model:free', 'Example');
  const catalog = AssistantCatalog(
    models: [model],
    providerStates: {'openrouter': 'catalog'},
    promptVersion: 'fitness-assistant-2',
    systemInstruction: 'Обычные правила.',
    actionInstruction: 'Точные правила режима предложений.',
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
    'promptVersion': 'fitness-assistant-2',
    'systemInstruction': 'Обычные правила.',
    'actionInstruction': 'Точные правила режима предложений.',
  };
  Map<String, dynamic> action({
    String kind = 'update',
    String ref = 'f1',
    String day = '2026-10-20',
    String reason = 'Проверьте по упаковке.',
    Map<String, dynamic> patch = const {
      'grams': 200,
      'micros': {'vitaminD': 2},
    },
  }) => {
    'kind': kind,
    'ref': ref,
    'day': day,
    'reason': reason,
    'patch': patch,
  };
  Map<String, dynamic> response(List<Map<String, dynamic>> actions) => {
    'analysis': 'Для указанной порции проверьте состав; данные неполные.',
    'actions': actions,
  };
  AssistantAnswer answer(Object raw, {bool truncated = false}) =>
      AssistantAnswer(jsonEncode(raw), truncated: truncated);
  late AppDataProvider provider;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    provider.dispose();
  });

  test(
    'proposal request and exact preview use action instruction, not personal ids',
    () {
      final request = buildAssistantRequest(
        model: model,
        catalog: catalog,
        question: 'Исправь порцию',
        adultConfirmed: true,
        history: [],
        food: snapshot,
        proposeCorrections: true,
        replaceKnownMicros: false,
      );
      expect(request['mode'], 'nutrition_actions');
      expect(request['replaceKnownMicros'], false);
      expect(request['systemInstruction'], catalog.actionInstruction);
      expect(jsonEncode(request), isNot(contains('secret-local-id')));
      final messages = previewAssistantMessages(
        request,
        request['systemInstruction'] as String,
      );
      expect(messages.first['content'], catalog.actionInstruction);
      final body = jsonDecode(messages.last['content'] as String) as Map;
      expect(body['replaceKnownMicros'], false);
      expect((body['entries'] as List).single['portionTotals']['calories'], 78);
      expect(
        () => buildAssistantRequest(
          model: model,
          catalog: catalog,
          question: '?',
          adultConfirmed: true,
          history: [],
          proposeCorrections: true,
        ),
        throwsArgumentError,
      );
      const oldServer = AssistantCatalog(
        models: [model],
        providerStates: {},
        promptVersion: 'old',
        systemInstruction: 'old',
      );
      expect(
        () => buildAssistantRequest(
          model: model,
          catalog: oldServer,
          question: '?',
          adultConfirmed: true,
          history: [],
          food: snapshot,
          proposeCorrections: true,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'correction mode can propose adding to an empty day; analysis-only cannot',
    () {
      final empty = DiaryAiSnapshot(firstDay: date, lastDay: date, entries: []);
      final request = buildAssistantRequest(
        model: model,
        catalog: catalog,
        question: 'Я съел грушу 100 г',
        adultConfirmed: true,
        history: [],
        food: empty,
        proposeCorrections: true,
      );
      expect(request['entries'], isEmpty);
      expect(
        () => buildAssistantRequest(
          model: model,
          catalog: catalog,
          question: 'Разбери',
          adultConfirmed: true,
          history: [],
          food: empty,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'validated proposal is local, unselected and preserves known vitamins',
    () {
      final parsed = parseAssistantCorrections(
        answer(
          response([
            action(
              patch: {
                'grams': 200,
                'micros': {'vitaminC': 99, 'vitaminD': 2},
              },
            ),
          ]),
        ),
        snapshot,
        replaceKnownMicros: false,
      );
      final suggestion = parsed.suggestions.single;
      expect(suggestion.selected, false);
      expect(suggestion.proposed!.id, 'secret-local-id');
      expect(suggestion.proposed!.micros, {'vitaminC': 6, 'vitaminD': 2});
      expect(suggestion.proposed!.microsEstimated, true);
      expect(food.amountGrams, 150);
      expect(food.micros, {'vitaminC': 6});
      final replacement = parseAssistantCorrections(
        answer(
          response([
            action(
              patch: {
                'micros': {'vitaminC': 9},
              },
            ),
          ]),
        ),
        snapshot,
        replaceKnownMicros: true,
      );
      expect(replacement.suggestions.single.proposed!.micros['vitaminC'], 9);
    },
  );

  test(
    'untrusted malformed, hidden, stale-reference and truncated outputs fail closed',
    () {
      final bad = <Object>[
        {
          ...response([action()]),
          'extra': true,
        },
        response([
          {...action(), 'extra': true},
        ]),
        response([action(reason: '  ')]),
        response([action(ref: 'not-the-ref')]),
        response([action(day: '2026-10-21')]),
        response([action(), action()]),
        response([
          action(patch: {'grams': 0}),
        ]),
        response([
          action(
            patch: {
              'micros': {'unknown': 1},
            },
          ),
        ]),
        response([
          action(patch: {'unexpected': 1}),
        ]),
        response([
          action(patch: {'meal': 'invalid'}),
        ]),
        response([
          action(kind: 'delete', patch: {'grams': 2}),
        ]),
        response([
          action(kind: 'add', ref: '', patch: {'name': 'Еда'}),
        ]),
      ];
      for (final raw in bad) {
        expect(
          () => parseAssistantCorrections(
            answer(raw),
            snapshot,
            replaceKnownMicros: false,
          ),
          throwsFormatException,
          reason: jsonEncode(raw),
        );
      }
      expect(
        () => parseAssistantCorrections(
          const AssistantAnswer('```json {} ```'),
          snapshot,
          replaceKnownMicros: false,
        ),
        throwsFormatException,
      );
      expect(
        () => parseAssistantCorrections(
          answer(response([action()]), truncated: true),
          snapshot,
          replaceKnownMicros: false,
        ),
        throwsFormatException,
      );
    },
  );

  Future<void> showPanel(
    WidgetTester tester,
    AssistantService service, {
    Size size = const Size(320, 850),
    String initialQuestion = 'Исправь порцию',
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                AssistantHubPanel(
                  service: service,
                  initialNutritionRange: DateTimeRange(start: date, end: date),
                  initialQuestion: initialQuestion,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder f) async {
    if (f.evaluate().isEmpty && find.byType(ListView).evaluate().isNotEmpty) {
      final found = find.descendant(
        of: find.byType(ListView).last,
        matching: find.byType(Scrollable),
      );
      if (found.evaluate().isNotEmpty) {
        tester.state<ScrollableState>(found.first).position.jumpTo(0);
        await tester.pump(const Duration(milliseconds: 200));
      }
    }
    for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
      final scrollables = find.descendant(
        of: find.byType(ListView).last,
        matching: find.byType(Scrollable),
      );
      if (scrollables.evaluate().isEmpty) break;
      final scroll = tester.state<ScrollableState>(scrollables.first);
      scroll.position.jumpTo(
        math.min(scroll.position.maxScrollExtent, scroll.position.pixels + 260),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(f, findsOneWidget);
    await tester.ensureVisible(f);
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await reveal(tester, f);
    await tester.runAsync(() async {
      await tester.tap(f);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> setupProposal(
    WidgetTester tester,
    AssistantService service, {
    Size size = const Size(320, 850),
    bool hasFood = true,
    String initialQuestion = 'Исправь порцию',
  }) async {
    if (hasFood)
      await tester.runAsync(() => provider.storage.addFoodBatch([food]));
    await showPanel(
      tester,
      service,
      size: size,
      initialQuestion: initialQuestion,
    );
    await tap(tester, find.text('Получить список моделей'));
    await tap(tester, find.byType(DropdownButtonFormField<String>));
    await tap(tester, find.text('OpenRouter · Example').last);
    await tap(tester, find.text('Предложить исправления записей'));
    await tap(tester, find.text('Подтверждаю, что мне 18 лет или больше'));
    await tap(tester, find.text('Проверить и отправить'));
  }

  Future<List<FoodEntry>> stored(WidgetTester tester) async =>
      (await tester.runAsync(() => provider.storage.getFoodEntries(date)))!;
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets(
    'preview, explicit selection, cancel, confirm and undo on narrow screen',
    (tester) async {
      final requests = <Map<String, dynamic>>[];
      final service = AssistantService(
        owner: () => 'account-a',
        invoke: (request) async {
          requests.add(jsonDecode(jsonEncode(request)) as Map<String, dynamic>);
          return request['action'] == 'models'
              ? rawCatalog
              : {
                  'text': jsonEncode(response([action()])),
                  'provider': request['provider'],
                  'model': request['model'],
                };
        },
      );
      await setupProposal(tester, service);
      expect(find.text('Проверить перед отправкой'), findsOneWidget);
      final preview = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? '')
          .join('\n');
      expect(preview, contains('Точные правила режима предложений.'));
      expect(preview, contains('"replaceKnownMicros": false'));
      expect(preview, isNot(contains('secret-local-id')));
      expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
      await tap(tester, find.text('Согласен и отправить'));
      expect(
        requests.where((r) => r['action'] == 'ask').single['mode'],
        'nutrition_actions',
      );
      await reveal(tester, find.text('Предложения ИИ'));
      expect((await stored(tester)).single.amountGrams, 150);
      await tap(tester, find.text('Изменить предложение'));
      final portionField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Вес порции, г',
      );
      await reveal(tester, portionField);
      await tester.enterText(portionField, '225');
      await tap(tester, find.text('Применить'));
      expect((await stored(tester)).single.amountGrams, 150);
      await reveal(tester, find.textContaining('Порция, г: 150 → 225'));
      await tap(tester, find.byType(CheckboxListTile).last);
      await tap(tester, find.textContaining('Применить отмеченное за'));
      expect(find.text('Подтвердить'), findsOneWidget);
      expect((await stored(tester)).single.amountGrams, 150);
      await tap(tester, find.text('Отмена'));
      expect((await stored(tester)).single.amountGrams, 150);
      await tap(tester, find.textContaining('Применить отмеченное за'));
      await tap(tester, find.text('Подтвердить'));
      expect((await stored(tester)).single.amountGrams, 225);
      expect((await stored(tester)).single.micros['vitaminD'], 2);
      await tap(tester, find.text('Отменить последнее применение'));
      expect((await stored(tester)).single.toJson(), food.toJson());
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('proposal review and editor fit a short landscape screen', (
    tester,
  ) async {
    final service = AssistantService(
      owner: () => 'account-a',
      invoke: (request) async => request['action'] == 'models'
          ? rawCatalog
          : {
              'text': jsonEncode(response([action()])),
              'provider': request['provider'],
              'model': request['model'],
            },
    );
    await setupProposal(tester, service, size: const Size(900, 320));
    await tap(tester, find.text('Согласен и отправить'));
    await tap(tester, find.text('Изменить предложение'));
    expect(find.text('Уточнить продукт'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tap(tester, find.text('Отмена'));
    expect((await stored(tester)).single.amountGrams, 150);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'unrelated record added after analysis invalidates all proposed edits',
    (tester) async {
      final service = AssistantService(
        owner: () => 'account-a',
        invoke: (request) async => request['action'] == 'models'
            ? rawCatalog
            : {
                'text': jsonEncode(response([action()])),
                'provider': request['provider'],
                'model': request['model'],
              },
      );
      await setupProposal(tester, service);
      await tap(tester, find.text('Согласен и отправить'));
      await reveal(tester, find.text('Предложения ИИ'));
      final unrelated = FoodEntry(
        id: 'new-record',
        name: 'Новая запись',
        amountGrams: 30,
        caloriesPer100g: 50,
        proteinPer100g: 1,
        fatPer100g: 1,
        carbsPer100g: 1,
        mealType: MealType.snack,
        date: date,
      );
      await tester.runAsync(() => provider.storage.addFoodBatch([unrelated]));
      await tap(tester, find.byType(CheckboxListTile).last);
      await tap(tester, find.textContaining('Применить отмеченное за'));
      await tap(tester, find.text('Подтвердить'));
      final all = await stored(tester);
      expect(all.length, 2);
      expect(all.first.amountGrams, 150);
      expect(
        find.textContaining('Дневник за выбранный период изменился'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'adding an explicitly described food needs confirmation and is reversible',
    (tester) async {
      final proposed = action(
        kind: 'add',
        ref: '',
        patch: {
          'name': 'Груша',
          'grams': 100,
          'calories': 50,
          'protein': .4,
          'fat': .2,
          'carbs': 12,
          'meal': 'snack',
          'micros': {'vitaminC': 4},
        },
      );
      final service = AssistantService(
        owner: () => 'account-a',
        invoke: (request) async => request['action'] == 'models'
            ? rawCatalog
            : {
                'text': jsonEncode(response([proposed])),
                'provider': request['provider'],
                'model': request['model'],
              },
      );
      await setupProposal(
        tester,
        service,
        hasFood: false,
        initialQuestion: 'Я съел 100 г груши. Добавь запись.',
      );
      await tap(tester, find.text('Согласен и отправить'));
      await tap(tester, find.byType(CheckboxListTile).last);
      await tap(tester, find.textContaining('Применить отмеченное за'));
      expect(await stored(tester), isEmpty);
      await tap(tester, find.text('Подтвердить'));
      final entries = await stored(tester);
      expect(entries.length, 1);
      expect(entries.single.name, 'Груша');
      expect(entries.single.timeKnown, false);
      expect(entries.single.microsEstimated, true);
      await tap(tester, find.text('Отменить последнее применение'));
      expect(await stored(tester), isEmpty);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('repeated confirmation executes only one write', (tester) async {
    final service = AssistantService(
      owner: () => 'account-a',
      invoke: (request) async => request['action'] == 'models'
          ? rawCatalog
          : {
              'text': jsonEncode(response([action()])),
              'provider': request['provider'],
              'model': request['model'],
            },
    );
    await setupProposal(tester, service);
    await tap(tester, find.text('Согласен и отправить'));
    await tap(tester, find.byType(CheckboxListTile).last);
    await tap(tester, find.textContaining('Применить отмеченное за'));
    var writes = 0;
    LocalPreferences.onAppWrite = () => writes++;
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Подтвердить'))
        .onPressed!;
    await tester.runAsync(() async {
      confirm();
      confirm();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
    expect((await stored(tester)).single.amountGrams, 200);
    expect(writes, 1);
    expect(find.text('Предложения ИИ'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('delete requires final confirmation and can be undone', (
    tester,
  ) async {
    final service = AssistantService(
      owner: () => 'account-a',
      invoke: (request) async => request['action'] == 'models'
          ? rawCatalog
          : {
              'text': jsonEncode(response([action(kind: 'delete', patch: {})])),
              'provider': request['provider'],
              'model': request['model'],
            },
    );
    await setupProposal(tester, service);
    await tap(tester, find.text('Согласен и отправить'));
    await tap(tester, find.byType(CheckboxListTile).last);
    await tap(tester, find.textContaining('Применить отмеченное за'));
    expect(find.textContaining('Будут удалены записи: 1'), findsOneWidget);
    expect((await stored(tester)).length, 1);
    await tap(tester, find.text('Подтвердить'));
    expect(await stored(tester), isEmpty);
    await tap(tester, find.text('Отменить последнее применение'));
    expect((await stored(tester)).single.toJson(), food.toJson());
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('invalid model JSON never opens a review or changes records', (
    tester,
  ) async {
    final service = AssistantService(
      owner: () => 'account-a',
      invoke: (request) async => request['action'] == 'models'
          ? rawCatalog
          : {
              'text': '{"analysis":"missing actions"}',
              'provider': request['provider'],
              'model': request['model'],
            },
    );
    await setupProposal(tester, service);
    await tap(tester, find.text('Согласен и отправить'));
    expect(find.text('Предложения ИИ'), findsNothing);
    expect(find.textContaining('Предложения недоступны'), findsOneWidget);
    expect((await stored(tester)).single.amountGrams, 150);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('underage change before final confirmation blocks application', (
    tester,
  ) async {
    final service = AssistantService(
      owner: () => 'account-a',
      invoke: (request) async => request['action'] == 'models'
          ? rawCatalog
          : {
              'text': jsonEncode(response([action()])),
              'provider': request['provider'],
              'model': request['model'],
            },
    );
    await setupProposal(tester, service);
    await tap(tester, find.text('Согласен и отправить'));
    await tap(tester, find.byType(CheckboxListTile).last);
    await tap(tester, find.textContaining('Применить отмеченное за'));
    await tester.runAsync(
      () => provider.updateProfile(provider.profile.copyWith(ageYears: 17)),
    );
    await tap(tester, find.text('Подтвердить'));
    expect((await stored(tester)).single.amountGrams, 150);
    await reveal(tester, find.textContaining('Изменения не применены'));
    expect(find.textContaining('Изменения не применены'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'account switch closes nested nutrient editor and review editor',
    (tester) async {
      var owner = 'account-a';
      final events = TestAuthEvents();
      final service = AssistantService(
        owner: () => owner,
        authChanges: events,
        invoke: (request) async => request['action'] == 'models'
            ? rawCatalog
            : {
                'text': jsonEncode(response([action()])),
                'provider': request['provider'],
                'model': request['model'],
              },
      );
      await setupProposal(tester, service);
      await tap(tester, find.text('Согласен и отправить'));
      expect(tester.takeException(), isNull, reason: 'после открытия обзора');
      await tap(tester, find.text('Изменить предложение'));
      expect(
        tester.takeException(),
        isNull,
        reason: 'после открытия редактора',
      );
      expect(find.text('Уточнить продукт'), findsOneWidget);
      await tap(tester, find.textContaining('Витамины и минералы на 100 г'));
      expect(
        tester.takeException(),
        isNull,
        reason: 'после открытия микронутриентов',
      );
      expect(find.text('Микронутриенты на 100 г'), findsOneWidget);
      owner = 'account-b';
      events.changed();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Микронутриенты на 100 г'), findsNothing);
      expect(find.text('Уточнить продукт'), findsNothing);
      expect(find.textContaining('Предложения очищены'), findsOneWidget);
      expect((await stored(tester)).single.amountGrams, 150);
      expect(tester.takeException(), isNull);
      await close(tester);
      events.dispose();
    },
  );

  testWidgets(
    'account switch closes confirmation and clears private proposals',
    (tester) async {
      var owner = 'account-a';
      final events = TestAuthEvents();
      final service = AssistantService(
        owner: () => owner,
        authChanges: events,
        invoke: (request) async => request['action'] == 'models'
            ? rawCatalog
            : {
                'text': jsonEncode(response([action()])),
                'provider': request['provider'],
                'model': request['model'],
              },
      );
      await setupProposal(tester, service);
      await tap(tester, find.text('Согласен и отправить'));
      await reveal(tester, find.text('Предложения ИИ'));
      await tap(tester, find.byType(CheckboxListTile).last);
      await tap(tester, find.textContaining('Применить отмеченное за'));
      expect(find.text('Подтвердить'), findsOneWidget);
      owner = 'account-b';
      events.changed();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Подтвердить'), findsNothing);
      expect(find.textContaining('Предложения очищены'), findsOneWidget);
      expect((await stored(tester)).single.amountGrams, 150);
      expect(tester.takeException(), isNull);
      await close(tester);
      events.dispose();
    },
  );
}
