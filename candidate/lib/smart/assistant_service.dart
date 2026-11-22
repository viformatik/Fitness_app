import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'diary_ai.dart';
import 'engine.dart' show microLabels;
import 'remote.dart';

typedef AssistantInvoke =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class AssistantModel {
  final String provider, id, name;
  const AssistantModel(this.provider, this.id, this.name);
  String get key => '$provider|$id';
}

class AssistantCatalog {
  final List<AssistantModel> models;
  final Map<String, String> providerStates;
  final String promptVersion, systemInstruction;
  final String? actionInstruction;
  const AssistantCatalog({
    required this.models,
    required this.providerStates,
    required this.promptVersion,
    required this.systemInstruction,
    this.actionInstruction,
  });

  factory AssistantCatalog.parse(Map<String, dynamic> data) {
    final version = data['promptVersion'];
    final instruction = data['systemInstruction'];
    final actionInstruction = data['actionInstruction'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 100 ||
        instruction is! String ||
        instruction.isEmpty ||
        instruction.length > 8000 ||
        (actionInstruction != null &&
            (actionInstruction is! String ||
                actionInstruction.isEmpty ||
                actionInstruction.length > 8000)) ||
        data['models'] is! List ||
        data['providers'] is! List) {
      throw const FormatException('Некорректный ответ списка моделей.');
    }
    const allowed = {'cloudflare', 'groq', 'openrouter', 'sambanova', 'zai'};
    final models = <AssistantModel>[];
    final seen = <String>{};
    for (final raw in data['models'] as List) {
      if (raw is! Map ||
          !allowed.contains(raw['provider']) ||
          raw['id'] is! String ||
          raw['name'] is! String ||
          raw['status'] != 'catalog')
        continue;
      final provider = raw['provider'] as String,
          id = raw['id'] as String,
          name = raw['name'] as String;
      if (id.isEmpty || id.length > 160 || name.isEmpty || name.length > 160)
        continue;
      final model = AssistantModel(provider, id, name);
      if (seen.add(model.key)) models.add(model);
      if (models.length == 150) break;
    }
    final states = <String, String>{};
    for (final raw in data['providers'] as List) {
      if (raw is Map &&
          allowed.contains(raw['provider']) &&
          raw['state'] is String) {
        states[raw['provider'] as String] = raw['state'] as String;
      }
    }
    return AssistantCatalog(
      models: models,
      providerStates: states,
      promptVersion: version,
      systemInstruction: instruction,
      actionInstruction: actionInstruction as String?,
    );
  }
}

class AssistantAnswer {
  final String text;
  final bool truncated;
  const AssistantAnswer(this.text, {this.truncated = false});
}

/// Only authenticated edge calls; no provider API key ever exists here.
/// Optional dependencies make privacy/preview behaviour testable offline.
class AssistantService {
  final AssistantInvoke invoke;
  final String? Function() owner;
  final Listenable? authChanges;
  AssistantService({
    required this.invoke,
    required this.owner,
    this.authChanges,
  });
  factory AssistantService.live() => AssistantService(
    owner: () => SmartRemote.instance.client?.auth.currentUser?.id,
    authChanges: SmartRemote.instance,
    invoke: (request) async {
      final client = SmartRemote.instance.client;
      if (client == null || client.auth.currentUser == null) {
        throw StateError(
          'Для ИИ сначала войдите в аккаунт в разделе «Ещё → Синхронизация».',
        );
      }
      try {
        final response = await client.functions
            .invoke('assistant-ai', body: request)
            .timeout(const Duration(seconds: 90));
        final data = response.data;
        if (response.status != 200 || data is! Map)
          throw StateError('Сервис ИИ недоступен или модель отклонила запрос.');
        return Map<String, dynamic>.from(data);
      } catch (_) {
        throw StateError(
          'Сервис моделей недоступен. Проверьте подключение, настройки, лимит и выбранную модель.',
        );
      }
    },
  );

  Future<AssistantCatalog> listModels() async =>
      AssistantCatalog.parse(await invoke({'action': 'models'}));
  Future<AssistantAnswer> ask(Map<String, dynamic> request) async {
    final data = await invoke(request);
    final answer = data['text'];
    if (answer is! String ||
        answer.trim().isEmpty ||
        answer.length > 8000 ||
        (data.containsKey('truncated') && data['truncated'] is! bool) ||
        data['provider'] != request['provider'] ||
        data['model'] != request['model']) {
      throw const FormatException('Некорректный ответ модели.');
    }
    return AssistantAnswer(answer.trim(), truncated: data['truncated'] == true);
  }
}

/// Build an explicit ephemeral request. No diary IDs, notes, profile defaults,
/// workout, supplements, name or account details are included automatically.
Map<String, dynamic> buildAssistantRequest({
  required AssistantModel model,
  required AssistantCatalog catalog,
  required String question,
  required bool adultConfirmed,
  required List<Map<String, String>> history,
  int? ageYears,
  DiaryAiSnapshot? food,
  bool proposeCorrections = false,
  bool replaceKnownMicros = false,
}) {
  final text = question.trim();
  if (text.isEmpty || text.length > 2000)
    throw ArgumentError('Введите вопрос до 2000 символов.');
  if (!adultConfirmed ||
      (ageYears != null && (ageYears < 18 || ageYears > 120))) {
    throw ArgumentError('Для ИИ подтвердите, что вам 18 лет или больше.');
  }
  if (!catalog.models.any((m) => m.key == model.key))
    throw ArgumentError('Обновите список моделей.');
  if (history.length > 6 ||
      history.any(
        (h) =>
            !['user', 'assistant'].contains(h['role']) ||
            h['text'] == null ||
            h['text']!.isEmpty ||
            h['text']!.length > 2500,
      ) ||
      history.fold<int>(0, (n, h) => n + h['text']!.length) > 8000) {
    throw ArgumentError('История слишком длинная.');
  }
  if (proposeCorrections &&
      (food == null || catalog.actionInstruction == null)) {
    throw ArgumentError(
      'Этот сервер не поддерживает предложения по исправлению дневника.',
    );
  }
  if (!proposeCorrections && replaceKnownMicros) {
    throw ArgumentError('Замена показателей доступна только для предложений.');
  }
  final result = <String, dynamic>{
    'action': 'ask',
    'promptVersion': catalog.promptVersion,
    'systemInstruction': proposeCorrections
        ? catalog.actionInstruction!
        : catalog.systemInstruction,
    'provider': model.provider,
    'model': model.id,
    'mode': food == null
        ? 'chat'
        : proposeCorrections
        ? 'nutrition_actions'
        : 'nutrition',
    'question': text,
    'adultConfirmed': true,
    'history': history.map((h) => Map<String, String>.from(h)).toList(),
  };
  if (ageYears != null) result['ageYears'] = ageYears;
  if (proposeCorrections) result['replaceKnownMicros'] = replaceKnownMicros;
  if (food != null) {
    final fields = food.request(text, replaceKnownMicros: replaceKnownMicros);
    final entries = fields['entries'] as List;
    if (entries.isEmpty && !proposeCorrections)
      throw ArgumentError('В выбранном периоде нет записей питания.');
    result['firstDay'] = fields['firstDay'];
    result['lastDay'] = fields['lastDay'];
    result['entries'] = [
      for (final raw in entries)
        {
          ...Map<String, dynamic>.from(raw as Map),
          'microsEstimated': food.byRef[raw['ref']]!.microsEstimated,
        },
    ];
  }
  // Deep detached copy: preview and the request after confirmation must match.
  return Map<String, dynamic>.from(jsonDecode(jsonEncode(result)) as Map);
}

/// Exact model-facing messages for the preview, including the same per-portion
/// arithmetic and instruction as the edge function. The version binds both.
List<Map<String, dynamic>> previewAssistantMessages(
  Map<String, dynamic> request,
  String instruction,
) {
  final context = <String, dynamic>{'question': request['question']};
  if (request.containsKey('ageYears'))
    context['ageYears'] = request['ageYears'];
  if (request['mode'] == 'nutrition' ||
      request['mode'] == 'nutrition_actions') {
    context['firstDay'] = request['firstDay'];
    context['lastDay'] = request['lastDay'];
    context['entries'] = [
      for (final item in request['entries'] as List)
        {
          ...Map<String, dynamic>.from(item as Map),
          'portionTotals': {
            for (final key in ['calories', 'protein', 'fat', 'carbs'])
              key: (item[key] as num) * (item['grams'] as num) / 100,
          },
        },
    ];
    if (request['mode'] == 'nutrition_actions') {
      context['replaceKnownMicros'] = request['replaceKnownMicros'];
    }
  }
  return [
    {'role': 'system', 'content': instruction},
    for (final message in request['history'] as List)
      {'role': message['role'], 'content': message['text']},
    {'role': 'user', 'content': jsonEncode(context)},
  ];
}

/// Model output is untrusted. No prose wrappers, extra fields, hidden patches,
/// unknown nutrients or truncated JSON are allowed to become editable actions.
DiaryAiResult parseAssistantCorrections(
  AssistantAnswer answer,
  DiaryAiSnapshot snapshot, {
  required bool replaceKnownMicros,
}) {
  if (answer.truncated) {
    throw const FormatException(
      'Ответ модели обрезан. Предложения не применены.',
    );
  }
  final Object? raw;
  try {
    raw = jsonDecode(answer.text);
  } catch (_) {
    throw const FormatException(
      'Модель не вернула проверяемый JSON. Дневник не изменён.',
    );
  }
  if (raw is! Map ||
      raw.keys.toSet().length != 2 ||
      !raw.keys.toSet().containsAll({'analysis', 'actions'}) ||
      raw['actions'] is! List) {
    throw const FormatException(
      'Некорректный формат предложений. Дневник не изменён.',
    );
  }
  for (final action in raw['actions'] as List) {
    if (action is! Map ||
        action.keys.toSet().length != 5 ||
        !action.keys.toSet().containsAll({
          'kind',
          'ref',
          'day',
          'reason',
          'patch',
        }) ||
        action['reason'] is! String ||
        (action['reason'] as String).trim().isEmpty ||
        action['patch'] is! Map) {
      throw const FormatException(
        'Не удалось проверить предложенное действие.',
      );
    }
    final patch = action['patch'] as Map;
    if (action['kind'] == 'delete' && patch.isNotEmpty) {
      throw const FormatException(
        'Удаление не может содержать скрытые изменения.',
      );
    }
    if (patch.containsKey('micros')) {
      final micros = patch['micros'];
      if (micros is! Map ||
          micros.keys.any((k) => !microLabels.containsKey(k))) {
        throw const FormatException(
          'ИИ вернул неизвестные показатели состава.',
        );
      }
    }
  }
  return validateDiaryAiResult(
    raw,
    snapshot,
    replaceKnownMicros: replaceKnownMicros,
  );
}

String assistantProviderLabel(String id) =>
    const {
      'cloudflare': 'Cloudflare Workers AI',
      'groq': 'Groq',
      'openrouter': 'OpenRouter',
      'sambanova': 'SambaNova',
      'zai': 'Z.ai',
    }[id] ??
    id;

String assistantPrivacyNotice(String id) =>
    const {
      'cloudflare':
          'Cloudflare обрабатывает текст в Workers AI; стандартный режим не обучается на запросах, возможны исключения. Регион обработки и доступность моделей зависят от сервиса.',
      'groq':
          'Groq: для нового сервиса предусмотрен режим ZDR, который оператор должен отдельно включить; без него при сбоях или проверке злоупотреблений возможны журналы. Проверьте условия.',
      'openrouter':
          'OpenRouter направляет запрос выбранной модели одному из сторонних поставщиков, подходящих фильтру ZDR и без сбора данных. Настройка аккаунта ZDR only обязательна; доступность не гарантирована.',
      'sambanova':
          'SambaNova может обрабатывать и хранить данные для предоставления сервиса и соблюдения закона. Данные об использовании и условия сторонних моделей могут отличаться.',
      'zai':
          'Запрос будет передан Z.ai. Применимые условия обработки данных и исключения безопасности должны быть проверены оператором; не отправляйте лишние личные сведения.',
    }[id] ??
    'Проверьте условия обработки данных поставщика.';
