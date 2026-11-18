import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../legacy.dart';
import 'assistant_service.dart';
import 'diary_ai.dart';
import 'diary_ai_ui.dart';
import 'local_store.dart';

/// A new panel inside the existing AI screen, not a second diary or storage.
/// Each cloud request has its own exact preview/confirmation. No automatic writes.
class AssistantHubPanel extends StatefulWidget {
  final String? initialQuestion;
  final DateTimeRange? initialNutritionRange;
  final AssistantService? service;
  const AssistantHubPanel({
    super.key,
    this.initialQuestion,
    this.initialNutritionRange,
    this.service,
  });
  @override
  State<AssistantHubPanel> createState() => _AssistantHubPanelState();
}

class _Message {
  final String role, text;
  final bool truncated;
  const _Message(this.role, this.text, {this.truncated = false});
}

class _AssistantHubPanelState extends State<AssistantHubPanel> {
  late final AssistantService service;
  late final TextEditingController question;
  late DateTime first, last;
  late bool nutrition;
  AssistantCatalog? catalog;
  String? selectedKey, error, owner;
  final messages = <_Message>[];
  bool busy = false, adult = false, includeAge = false, includeHistory = false;
  bool proposeCorrections = false, replaceKnownMicros = false;
  bool previewOpen = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    service = widget.service ?? AssistantService.live();
    final selected = context.read<AppDataProvider>().selectedDate;
    first = widget.initialNutritionRange?.start ?? selected;
    last = widget.initialNutritionRange?.end ?? selected;
    nutrition = widget.initialNutritionRange != null;
    question = TextEditingController(
      text:
          widget.initialQuestion ??
          (nutrition
              ? 'Разбери конкретные записанные порции и предложи обоснованные варианты, что изменить в будущем питании.'
              : ''),
    );
    owner = service.owner();
    service.authChanges?.addListener(_authChanged);
  }

  void _authChanged() {
    final next = service.owner();
    if (owner == next) return;
    owner = next;
    generation++;
    if (!mounted) return;
    if (previewOpen) {
      previewOpen = false;
      Navigator.of(context, rootNavigator: true).pop(false);
    }
    setState(() {
      catalog = null;
      selectedKey = null;
      messages.clear();
      question.clear();
      adult = false;
      includeAge = false;
      includeHistory = false;
      proposeCorrections = false;
      replaceKnownMicros = false;
      error =
          'Аккаунт изменился. История и выбор модели очищены; обновите список.';
    });
  }

  @override
  void dispose() {
    service.authChanges?.removeListener(_authChanged);
    question.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    if (busy) return;
    final account = service.owner();
    if (owner != account) {
      _authChanged();
      return;
    }
    if (account == null) {
      setState(
        () => error =
            'Для ИИ сначала войдите в аккаунт в разделе «Ещё → Синхронизация».',
      );
      return;
    }
    final requestGeneration = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await service.listModels();
      if (!mounted ||
          requestGeneration != generation ||
          account != service.owner())
        return;
      setState(() {
        catalog = result;
        selectedKey = null; // An explicit model selection is always required.
        if (result.models.isEmpty)
          error =
              'Модели не настроены или недоступны. Проверьте настройки провайдера и повторите позже.';
      });
    } catch (_) {
      if (mounted && requestGeneration == generation)
        setState(
          () => error =
              'Не удалось получить список моделей. Проверьте сеть, сервер, вход и лимит.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pickRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      initialDateRange: DateTimeRange(start: first, end: last),
      helpText: 'Период записей питания для ИИ',
    );
    if (range != null && mounted)
      setState(() {
        first = range.start;
        last = range.end;
      });
  }

  List<Map<String, String>> _historyForRequest() {
    if (!includeHistory) return [];
    final chosen = <_Message>[];
    var length = 0;
    for (final item in messages.reversed) {
      if (chosen.length == 6 ||
          item.text.length > 2500 ||
          length + item.text.length > 8000)
        break;
      chosen.add(item);
      length += item.text.length;
    }
    return [
      for (final item in chosen.reversed)
        {'role': item.role, 'text': item.text},
    ];
  }

  Future<DiaryAiSnapshot?> _foodSnapshot(AppDataProvider provider) async {
    if (!nutrition) return null;
    final entries = await provider.storage.getFoodEntriesInRange(
      first,
      last,
      maxEntries: DiaryAiSnapshot.maxEntries,
    );
    return DiaryAiSnapshot(firstDay: first, lastDay: last, entries: entries);
  }

  Future<void> _ask() async {
    if (busy) return;
    final provider = context.read<AppDataProvider>();
    final account = service.owner();
    if (owner != account) {
      _authChanged();
      return;
    }
    if (account == null) {
      setState(() => error = 'Для ИИ сначала войдите в аккаунт.');
      return;
    }
    final age = provider.profile.ageYears;
    if (!adult || (age != null && age < 18)) {
      setState(
        () => error =
            'Для этого ИИ необходимо подтвердить возраст 18 лет или больше.',
      );
      return;
    }
    final currentCatalog = catalog;
    final matching =
        currentCatalog?.models.where((m) => m.key == selectedKey).toList() ??
        [];
    if (currentCatalog == null || matching.length != 1) {
      setState(() => error = 'Обновите список и явно выберите модель.');
      return;
    }
    final privacyEpoch = LocalPreferences.privacyEpoch;
    final localOwner = provider.storage.local.getString('_bound_user');
    if (nutrition && localOwner != null && localOwner != account) {
      setState(
        () => error =
            'Этот локальный дневник связан с другим аккаунтом. Запрос не отправлен.',
      );
      return;
    }
    final model = matching.single,
        text = question.text,
        capturedHistory = _historyForRequest();
    final ageIncluded = includeAge;
    final chosenAge = ageIncluded ? age : null;
    final wantCorrections = nutrition && proposeCorrections;
    final replaceKnown = wantCorrections && replaceKnownMicros;
    final requestGeneration = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final food = await _foodSnapshot(provider);
      final request = buildAssistantRequest(
        model: model,
        catalog: currentCatalog,
        question: text,
        adultConfirmed: adult,
        history: capturedHistory,
        ageYears: chosenAge,
        food: food,
        proposeCorrections: wantCorrections,
        replaceKnownMicros: replaceKnown,
      );
      if (!mounted ||
          requestGeneration != generation ||
          account != service.owner())
        return;
      if (!LocalPreferences.privacyEpochIsCurrent(privacyEpoch)) {
        throw StateError(
          'Настройки конфиденциальности изменились. Проверьте запрос заново.',
        );
      }
      final approved = await _preview(model, request);
      if (approved != true || !mounted) return;
      if (requestGeneration != generation ||
          account != service.owner() ||
          !LocalPreferences.privacyEpochIsCurrent(privacyEpoch) ||
          (nutrition &&
              provider.storage.local.getString('_bound_user') != localOwner) ||
          (provider.profile.ageYears != null &&
              provider.profile.ageYears! < 18) ||
          (ageIncluded && provider.profile.ageYears != chosenAge)) {
        throw StateError(
          'Аккаунт или возраст изменился. Запрос отменён; проверьте данные заново.',
        );
      }
      if (nutrition) {
        if (provider.storage.local.getString('_bound_user') != localOwner) {
          throw StateError('Привязка дневника изменилась. Запрос отменён.');
        }
        final fresh = await _foodSnapshot(provider);
        if (!mounted ||
            requestGeneration != generation ||
            account != service.owner())
          return;
        final check = buildAssistantRequest(
          model: model,
          catalog: currentCatalog,
          question: text,
          adultConfirmed: adult,
          history: capturedHistory,
          ageYears: chosenAge,
          food: fresh,
          proposeCorrections: wantCorrections,
          replaceKnownMicros: replaceKnown,
        );
        if (jsonEncode(check) != jsonEncode(request)) {
          throw StateError(
            'Дневник изменился после предпросмотра. Проверьте записи и отправьте заново.',
          );
        }
      }
      if (requestGeneration != generation ||
          account != service.owner() ||
          !LocalPreferences.privacyEpochIsCurrent(privacyEpoch) ||
          (nutrition &&
              provider.storage.local.getString('_bound_user') != localOwner) ||
          (provider.profile.ageYears != null &&
              provider.profile.ageYears! < 18) ||
          (ageIncluded && provider.profile.ageYears != chosenAge)) {
        throw StateError(
          'Аккаунт, привязка, возраст или настройки конфиденциальности изменились. Запрос отменён.',
        );
      }
      final answer = await service.ask(request);
      if (!mounted ||
          requestGeneration != generation ||
          account != service.owner())
        return;
      if (!LocalPreferences.privacyEpochIsCurrent(privacyEpoch) ||
          (nutrition &&
              provider.storage.local.getString('_bound_user') != localOwner)) {
        throw StateError(
          'Дневник или настройки конфиденциальности изменились. Ответ скрыт.',
        );
      }
      if (wantCorrections) {
        if (food == null ||
            provider.storage.local.getString('_bound_user') != localOwner ||
            (provider.profile.ageYears != null &&
                provider.profile.ageYears! < 18) ||
            (ageIncluded && provider.profile.ageYears != chosenAge)) {
          throw StateError(
            'Аккаунт, привязка или возраст изменились. Ответ не применён.',
          );
        }
        late final DiaryAiResult plan;
        try {
          plan = parseAssistantCorrections(
            answer,
            food,
            replaceKnownMicros: replaceKnown,
          );
        } on FormatException catch (e) {
          setState(() {
            messages.add(_Message('user', text.trim()));
            messages.add(
              _Message('assistant', answer.text, truncated: answer.truncated),
            );
            error = '${e.message} Предложения недоступны; дневник не изменён.';
          });
          return;
        }
        setState(() {
          messages.add(_Message('user', text.trim()));
          messages.add(_Message('assistant', plan.analysis));
        });
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => DiaryAiScreen.review(
              provider: provider,
              snapshot: food,
              result: plan,
              owner: account,
              ownerReader: service.owner,
              accountChanges: service.authChanges,
              authorizationGuard: () =>
                  service.owner() == account &&
                  LocalPreferences.privacyEpochIsCurrent(privacyEpoch) &&
                  provider.storage.local.getString('_bound_user') ==
                      localOwner &&
                  (localOwner == null || localOwner == account) &&
                  (provider.profile.ageYears == null ||
                      provider.profile.ageYears! >= 18) &&
                  (!ageIncluded || provider.profile.ageYears == chosenAge),
            ),
          ),
        );
      } else {
        setState(() {
          messages.add(_Message('user', text.trim()));
          messages.add(
            _Message('assistant', answer.text, truncated: answer.truncated),
          );
        });
      }
    } on ArgumentError catch (e) {
      if (mounted && requestGeneration == generation)
        setState(() => error = '${e.message}');
    } on StateError catch (e) {
      if (mounted && requestGeneration == generation)
        setState(() => error = e.message);
    } catch (_) {
      if (mounted && requestGeneration == generation)
        setState(
          () => error =
              'Не удалось выполнить запрос. Проверьте сеть, настройки провайдера и лимит.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool?> _preview(
    AssistantModel model,
    Map<String, dynamic> request,
  ) async {
    final instruction = request['systemInstruction'] as String;
    final upstream = previewAssistantMessages(request, instruction);
    final context = const JsonEncoder.withIndent(
      '  ',
    ).convert(jsonDecode(upstream.last['content'] as String));
    final history = const JsonEncoder.withIndent(
      '  ',
    ).convert(upstream.sublist(1, upstream.length - 1));
    final raw = const JsonEncoder.withIndent('  ').convert(request);
    previewOpen = true;
    try {
      return await showDialog<bool>(
        context: this.context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Проверить перед отправкой'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Поставщик: ${assistantProviderLabel(model.provider)}\nМодель: ${model.name} (${model.id})',
                  ),
                  const SizedBox(height: 8),
                  Text(assistantPrivacyNotice(model.provider)),
                  const SizedBox(height: 8),
                  const Text(
                    'Питание и возраст могут быть чувствительными данными. Не указывайте диагнозы, лекарства, адрес или контакты. Передавайте только то, чем готовы поделиться.',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Контекст, который увидит модель',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SelectableText(context),
                  const SizedBox(height: 8),
                  const Text(
                    'История, которая увидит модель',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SelectableText(history),
                  const SizedBox(height: 8),
                  const Text(
                    'Системные правила для модели',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SelectableText(instruction),
                  const SizedBox(height: 8),
                  const Text(
                    'Полный запрос на сервер Fitness Smart',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SelectableText(raw),
                  const SizedBox(height: 8),
                  const Text(
                    'Сервер добавляет рассчитанные итоги порций и правила, показанные выше. Запрос не изменяет дневник. Ответ может ошибаться и не является медицинской консультацией.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Согласен и отправить'),
            ),
          ],
        ),
      );
    } finally {
      previewOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AppDataProvider>().profile;
    final current = catalog;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Модели и подробный анализ',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Выберите настроенного поставщика и модель. Приложение не переключает модель автоматически, но цены и маршрутизация зависят от поставщика. Каждый запрос требует подтверждения.',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : _loadModels,
              icon: const Icon(Icons.refresh),
              label: const Text('Получить список моделей'),
            ),
            const Text('Загрузка списка входит в общий лимит ИИ аккаунта.'),
            if (current != null) ...[
              const SizedBox(height: 8),
              for (final item in current.providerStates.entries)
                Text(
                  '${assistantProviderLabel(item.key)}: ${item.value == 'catalog'
                      ? 'каталог получен'
                      : item.value == 'candidates'
                      ? 'кандидаты, доступ не проверен'
                      : item.value == 'catalog_unavailable'
                      ? 'каталог недоступен'
                      : 'не настроен'}',
                ),
              if (current.models.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: selectedKey,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Выберите модель',
                  ),
                  items: [
                    for (final model in current.models)
                      DropdownMenuItem(
                        value: model.key,
                        child: Text(
                          '${assistantProviderLabel(model.provider)} · ${model.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => selectedKey = value),
                ),
                const Text(
                  'Каталог не гарантирует доступ к модели, подходящие условия или качество её ответов.',
                ),
              ],
            ],
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: nutrition,
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      nutrition = v;
                      if (!v) {
                        proposeCorrections = false;
                        replaceKnownMicros = false;
                      }
                    }),
              title: const Text('Добавить записи питания'),
              subtitle: const Text(
                'До 60 записей за выбранный период; без реальных ID и заметок.',
              ),
            ),
            if (nutrition)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : _pickRange,
                    icon: const Icon(Icons.date_range),
                    label: const Text('Выбрать период'),
                  ),
                  Text('${dayKey(first)} — ${dayKey(last)}'),
                ],
              ),
            if (nutrition)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: proposeCorrections,
                onChanged: busy
                    ? null
                    : (value) => setState(() {
                        proposeCorrections = value;
                        if (!value) replaceKnownMicros = false;
                      }),
                title: const Text('Предложить исправления записей'),
                subtitle: const Text(
                  'Только для ошибок или прямо запрошенных изменений. Ничего не записывается без просмотра и подтверждения.',
                ),
              ),
            if (nutrition && proposeCorrections)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: replaceKnownMicros,
                onChanged: busy
                    ? null
                    : (value) => setState(() => replaceKnownMicros = value),
                title: const Text(
                  'Предлагать замену известных витаминов и минералов',
                ),
                subtitle: const Text(
                  'По умолчанию сохраняются уже известные значения. Любая оценка требует проверки.',
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: includeAge,
              onChanged: busy || profile.ageYears == null
                  ? null
                  : (v) => setState(() => includeAge = v),
              title: const Text('Добавить мой возраст'),
              subtitle: Text(
                profile.ageYears == null
                    ? 'Возраст не указан в настройках.'
                    : 'Указано: ${profile.ageYears}. По умолчанию возраст не отправляется.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: includeHistory,
              onChanged: busy
                  ? null
                  : (v) => setState(() => includeHistory = v),
              title: const Text('Добавить историю диалога'),
              subtitle: const Text(
                'До шести последних коротких сообщений; предыдущие записи дневника сами не добавляются.',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: adult,
              onChanged: busy ? null : (v) => setState(() => adult = v == true),
              title: const Text('Подтверждаю, что мне 18 лет или больше'),
            ),
            TextField(
              controller: question,
              enabled: !busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Ваш вопрос',
                border: OutlineInputBorder(),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton.icon(
              onPressed: busy ? null : _ask,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined),
              label: const Text('Проверить и отправить'),
            ),
            const SizedBox(height: 8),
            if (messages.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => setState(() => messages.clear()),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Очистить историю'),
                ),
              ),
              for (final message in messages)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.role == 'user' ? 'Вы' : 'Ответ модели',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SelectableText(message.text),
                      if (message.truncated)
                        const Text(
                          'Ответ остановлен по лимиту длины и может быть неполным.',
                        ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            const Text(
              'История хранится только на этом экране. Предложения ИИ не меняют дневник без вашего отдельного подтверждения.',
            ),
          ],
        ),
      ),
    );
  }
}
