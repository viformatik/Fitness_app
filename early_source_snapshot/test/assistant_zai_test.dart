import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/assistant_hub.dart';
import 'package:fitness_tracker/smart/assistant_service.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const syntheticCatalog = <String, dynamic>{
  'models': [
    {
      'provider': 'zai',
      'id': 'glm-4.7-flash',
      'name': 'GLM-4.7-Flash',
      'status': 'catalog',
    },
  ],
  'providers': [
    {'provider': 'zai', 'state': 'candidates'},
  ],
  'promptVersion': 'fitness-assistant-2',
  'systemInstruction': 'Синтетические системные правила.',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Z.ai candidates are parsed, named and never confused with another provider',
    () {
      final catalog = AssistantCatalog.parse({
        ...syntheticCatalog,
        'models': [
          ...(syntheticCatalog['models'] as List),
          ...(syntheticCatalog['models'] as List),
          {
            'provider': 'unknown',
            'id': 'glm-4.7-flash',
            'name': 'unknown',
            'status': 'catalog',
          },
        ],
      });
      expect(catalog.models.length, 1);
      expect(catalog.models.single.key, 'zai|glm-4.7-flash');
      expect(catalog.providerStates['zai'], 'candidates');
      expect(assistantProviderLabel('zai'), 'Z.ai');
      expect(assistantPrivacyNotice('zai'), contains('передан Z.ai'));
    },
  );

  test(
    'Z.ai request preview has exact messages, without implicit age or diary',
    () {
      final catalog = AssistantCatalog.parse(syntheticCatalog);
      final req = buildAssistantRequest(
        model: catalog.models.single,
        catalog: catalog,
        question: 'Синтетический вопрос?',
        adultConfirmed: true,
        history: const [],
      );
      final messages = previewAssistantMessages(req, catalog.systemInstruction);
      expect(req['provider'], 'zai');
      expect(req['model'], 'glm-4.7-flash');
      expect(req.containsKey('ageYears'), isFalse);
      expect(req.containsKey('entries'), isFalse);
      expect(messages.first['content'], req['systemInstruction']);
      expect(jsonDecode(messages.last['content'] as String), {
        'question': 'Синтетический вопрос?',
      });
    },
  );

  testWidgets('Z.ai shows provider and privacy before any confirmed send', (
    tester,
  ) async {
    LocalPreferences.memoryForTests = true;
    SharedPreferences.setMockInitialValues({});
    final p = AppDataProvider();
    await p.init();
    addTearDown(p.dispose);
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final before = jsonEncode(p.storage.local.snapshot());
    final requests = <Map<String, dynamic>>[];
    final service = AssistantService(
      owner: () => 'synthetic-user',
      invoke: (raw) async {
        final req = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
        requests.add(req);
        return req['action'] == 'models'
            ? syntheticCatalog
            : {
                'text': 'Синтетический ответ.',
                'provider': req['provider'],
                'model': req['model'],
              };
      },
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppDataProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                AssistantHubPanel(
                  service: service,
                  initialQuestion: 'Синтетический вопрос?',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> tapVisible(Finder target) async {
      await tester.ensureVisible(target);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await tester.tap(target);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tapVisible(find.text('Получить список моделей'));
    expect(find.text('Z.ai: кандидаты, доступ не проверен'), findsOneWidget);
    await tapVisible(find.byType(DropdownButtonFormField<String>));
    await tapVisible(find.text('Z.ai · GLM-4.7-Flash').last);
    await tapVisible(find.text('Подтверждаю, что мне 18 лет или больше'));
    await tapVisible(find.text('Проверить и отправить'));
    expect(find.text('Проверить перед отправкой'), findsOneWidget);
    expect(find.textContaining('Поставщик: Z.ai'), findsOneWidget);
    expect(find.textContaining('Запрос будет передан Z.ai'), findsOneWidget);
    expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
    await tapVisible(find.text('Отмена'));
    expect(requests.where((r) => r['action'] == 'ask'), isEmpty);
    await tapVisible(find.text('Проверить и отправить'));
    await tapVisible(find.text('Согласен и отправить'));
    final sent = requests.where((r) => r['action'] == 'ask').single;
    expect(sent['provider'], 'zai');
    expect(sent['model'], 'glm-4.7-flash');
    expect(sent['mode'], 'chat');
    expect(sent.containsKey('entries'), isFalse);
    expect(sent.containsKey('ageYears'), isFalse);
    expect(sent['history'], isEmpty);
    expect(jsonEncode(p.storage.local.snapshot()), before);
    expect(find.text('Ответ модели'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
