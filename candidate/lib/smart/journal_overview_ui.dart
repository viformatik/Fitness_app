import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../legacy.dart';
import 'activity_trends_ui.dart';
import 'ai_actions.dart';
import 'ai_drafts.dart';
import 'ai_preferences.dart';
import 'local_store.dart';
import 'diary_ai_ui.dart';
import 'engine.dart' show microLabels;
import 'home_simple.dart' show MoreScreen;
import 'journal_ai_result.dart';
import 'journal_overview.dart';
import 'nutrition_insights_ui.dart';
import 'remote.dart';
import 'sleep.dart';
import 'ui.dart' show AiChatScreen;

/// Local facts are always available. The generative analysis is a separate,
/// explicitly previewed request and cannot write to the diary.
class JournalOverviewScreen extends StatefulWidget {
  final AppDataProvider provider;
  const JournalOverviewScreen({super.key, required this.provider});
  @override
  State<JournalOverviewScreen> createState() => _JournalOverviewScreenState();
}

class _JournalOverviewScreenState extends State<JournalOverviewScreen> {
  late DateTime first, last;
  JournalOverview? snapshot;
  JournalAiResult? result;
  String? error;
  bool loading = true, busy = false, detailsExpanded = false;
  int generation = 0;
  Timer? refreshTimer;
  bool needsRefresh = false;
  Set<String> selected = {...journalSections};
  final question = TextEditingController();

  @override
  void initState() {
    super.initState();
    final date = widget.provider.selectedDate;
    last = DateTime(date.year, date.month, date.day);
    first = DateTime(last.year, last.month, last.day - 6);
    widget.provider.addListener(_providerChanged);
    _load();
  }

  void _providerChanged() {
    if (!mounted) return;
    if (busy) {
      needsRefresh = true;
      return;
    }
    refreshTimer?.cancel();
    refreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted && !busy) _load();
    });
  }

  @override
  void didUpdateWidget(covariant JournalOverviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      oldWidget.provider.removeListener(_providerChanged);
      widget.provider.addListener(_providerChanged);
      needsRefresh = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !busy) _load();
      });
    }
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    widget.provider.removeListener(_providerChanged);
    question.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final current = ++generation;
    setState(() {
      loading = true;
      // Do not display an old snapshot under a newly selected date range.
      snapshot = null;
      error = null;
      result = null;
    });
    try {
      final loaded = await loadJournalOverview(
        widget.provider.storage,
        first,
        last,
      );
      if (mounted && generation == current) setState(() => snapshot = loaded);
    } catch (e) {
      if (mounted && generation == current)
        setState(() {
          snapshot = null;
          error = friendlyAiError(e);
        });
    } finally {
      if (mounted && generation == current) setState(() => loading = false);
    }
  }

  Future<void> _preset(int days) async {
    setState(
      () => first = DateTime(last.year, last.month, last.day - days + 1),
    );
    await _load();
  }

  Future<void> _pickRange() async {
    final range = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: first, end: last),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Период анализа',
    );
    if (range == null || !mounted) return;
    setState(() {
      first = range.start;
      last = range.end;
    });
    await _load();
  }

  Future<void> _analyze() async {
    if (busy || loading || snapshot == null) return;
    if (selected.isEmpty) {
      setState(() => error = 'Выберите хотя бы один раздел для анализа.');
      return;
    }
    final owner = SmartRemote.instance.client?.auth.currentUser?.id;
    if (owner == null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Нужен вход'),
          content: const Text(
            'Для Gemini войдите в аккаунт. Локальная сводка работает без входа и интернета.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Позже'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const MoreScreen()),
                );
              },
              child: const Text('Открыть «Ещё»'),
            ),
          ],
        ),
      );
      return;
    }
    final privacyEpoch = LocalPreferences.privacyEpoch;
    final local = widget.provider.storage.local;
    final localOwner = local.getString('_bound_user');
    if (localOwner != null && localOwner != owner) {
      setState(
        () => error = 'Дневник связан с другим аккаунтом. Запрос отменён.',
      );
      return;
    }
    bool authorized() =>
        SmartRemote.instance.client?.auth.currentUser?.id == owner &&
        local.getString('_bound_user') == localOwner &&
        AiConsent(local, owner).validFor(privacyEpoch);
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final before = snapshot!;
      final requested = before.request(selected, question.text);
      final fresh = await loadJournalOverview(
        widget.provider.storage,
        first,
        last,
      );
      if (jsonEncode(fresh.request(selected, question.text)) !=
          jsonEncode(requested)) {
        if (mounted)
          setState(() {
            snapshot = fresh;
            error =
                'Дневник изменился. Проверьте обновлённую сводку и повторите запрос.';
          });
        return;
      }
      if (!mounted) return;
      final consent = await ensureAiConsent(
        context,
        widget.provider.storage.local,
        owner,
      );
      if (!consent || !mounted) return;
      if (!authorized()) {
        throw StateError(
          'Аккаунт, привязка или согласие изменились. Ничего не отправлено.',
        );
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Проверить перед отправкой'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${formatDateRu(first)} — ${formatDateRu(last)} · ${before.periodDays} дн.',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'В Gemini уйдёт сводка выбранных разделов ниже, включая названия продуктов, упражнений и добавок, если их разделы выбраны. ФИО, фотографии, свободные заметки и идентификаторы записей отдельно не добавляются. Вопрос отправляется целиком.',
                  ),
                  const SizedBox(height: 10),
                  for (final key in journalSections.where(
                    selected.contains,
                  )) ...[
                    Text(
                      journalSectionLabels[key]!,
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    Text(_sectionDetails(before, key)),
                    const SizedBox(height: 8),
                  ],
                  if (question.text.trim().isNotEmpty) ...[
                    const Text(
                      'Вопрос:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(question.text.trim()),
                    const SizedBox(height: 8),
                  ],
                  if (before.unreadableDocuments > 0)
                    Text(
                      'Не удалось прочитать документов: ${before.unreadableDocuments}. Анализ будет неполным.',
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Бесплатный Gemini может использовать запросы и ответы для улучшения продуктов; возможен просмотр человеком. Google не разрешает передавать личные, чувствительные или конфиденциальные данные. Реальные записи дневника могут быть такими данными — не отправляйте их. Согласие не отменяет этого ограничения. Если нельзя исключить личные данные, отмените отправку; локальный обзор остаётся доступен.',
                  ),
                  ExpansionTile(
                    title: const Text('Точный формат запроса'),
                    children: [
                      SelectableText(
                        const JsonEncoder.withIndent('  ').convert(requested),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Отправить в Gemini'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      if (!authorized()) {
        throw StateError(
          'Аккаунт, привязка или согласие изменились. Ничего не отправлено.',
        );
      }
      final now = await loadJournalOverview(
        widget.provider.storage,
        first,
        last,
      );
      if (jsonEncode(now.request(selected, question.text)) !=
          jsonEncode(requested)) {
        if (mounted)
          setState(() {
            snapshot = now;
            error =
                'Дневник изменился во время проверки. Ещё раз посмотрите сводку.';
          });
        return;
      }
      if (!mounted) return;
      // The fresh overview above is asynchronous: authorization can change
      // while it is loading, so re-check immediately before invoking the API.
      if (!authorized()) {
        throw StateError(
          'Аккаунт, привязка или согласие изменились. Ничего не отправлено.',
        );
      }
      final received = await SmartRemote.instance.analyzeJournalOverview(
        requested,
      );
      if (!mounted) return;
      if (!authorized()) {
        throw StateError(
          'Аккаунт, привязка или согласие изменились. Ответ скрыт.',
        );
      }
      final latest = await loadJournalOverview(
        widget.provider.storage,
        first,
        last,
      );
      if (!mounted) return;
      if (!authorized()) {
        throw StateError(
          'Аккаунт, привязка или согласие изменились. Ответ скрыт.',
        );
      }
      if (jsonEncode(latest.request(selected, question.text)) !=
          jsonEncode(requested)) {
        setState(() {
          snapshot = latest;
          error =
              'Дневник изменился после отправки. Ответ устарел, запросите новый анализ.';
        });
        return;
      }
      setState(() => result = received);
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (needsRefresh) {
          needsRefresh = false;
          _providerChanged();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Consumer<AppDataProvider>(
    builder: (context, p, _) {
      final data = snapshot;
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: CenteredBody(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            children: [
              Text('Анализ', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 5),
              Text(
                'Весь дневник за выбранный период — в одном месте.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: const Text('7 дней'),
                    onPressed: busy ? null : () => _preset(7),
                  ),
                  ActionChip(
                    label: const Text('30 дней'),
                    onPressed: busy ? null : () => _preset(30),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.date_range, size: 17),
                    label: const Text('Выбрать период'),
                    onPressed: busy ? null : _pickRange,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${formatDateRu(first)} — ${formatDateRu(last)}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 14),
              if (loading) const LinearProgressIndicator(),
              if (data != null) ...[
                PremiumCard(
                  gradient: AppTheme.heroGradient,
                  radius: 24,
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          RoundIconBadge(
                            icon: Icons.insights_rounded,
                            color: AppTheme.primary,
                            size: 42,
                            iconSize: 21,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Локальная сводка',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Работает без интернета и ИИ',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      for (final key in journalSections)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 100,
                                child: Text(
                                  journalSectionLabels[key]!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  _sectionHeadline(data, key),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 100,
                              child: Text(
                                'Сон',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                data.sleep.recordedDays == 0
                                    ? data.sleep.unreadableDays > 0
                                          ? 'Данные неполные'
                                          : 'Нет записей'
                                    : '${data.sleep.recordedDays} дн. с записью · среднее ${formatSleepMinutes(data.sleep.averageMinutes!.round())}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (data.sleep.unreadableDays > 0)
                        Text(
                          'Не прочитано записей сна: ${data.sleep.unreadableDays}. Сводка сна может быть неполной.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const Text(
                        'Сводка сна рассчитывается на устройстве и не передаётся в ИИ.',
                      ),
                      if (data.unreadableDocuments > 0)
                        Text(
                          'Не прочитано документов: ${data.unreadableDocuments}. Сводка неполная.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const SizedBox(height: 6),
                      Text(
                        'Нет записи — не значит, что еды, воды или тренировки не было.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(fontSize: 11),
                      ),
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => detailsExpanded = !detailsExpanded),
                        icon: Icon(
                          detailsExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                        label: Text(
                          detailsExpanded
                              ? 'Скрыть подробности'
                              : 'Посмотреть подробности',
                        ),
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ActivityTrendPanel(
                  steps: data.stepsTrend,
                  sleep: data.sleepTrend,
                ),
                const SizedBox(height: 12),
                RecordedNutritionDetails(
                  insight: data.foodInsights,
                  daysWithRecords:
                      data.sections['food']!['daysWithRecords'] as int,
                ),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => AiChatScreen(
                              initialNutritionRange: DateTimeRange(
                                start: first,
                                end: last,
                              ),
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Разобрать записи с выбранной моделью ИИ'),
                ),
                if (detailsExpanded)
                  for (final key in journalSections)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                journalSectionLabels[key]!,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(_sectionDetails(data, key)),
                            ],
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, color: AppTheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Разбор с Gemini',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Этот режим видит только суммы и частые названия, но не отдельные порции или ваши цели. Поэтому он не может надёжно разобрать конкретный продукт. Сначала выбери разделы и проверь сводку перед отправкой.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      for (final key in journalSections)
                        CheckboxListTile(
                          dense: true,
                          value: selected.contains(key),
                          onChanged: busy
                              ? null
                              : (value) => setState(() {
                                  if (value == true) {
                                    selected.add(key);
                                  } else {
                                    selected.remove(key);
                                  }
                                  result = null;
                                }),
                          title: Text(journalSectionLabels[key]!),
                          subtitle: Text(_sectionHeadline(data, key)),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                    ],
                  ),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Добавить вопрос (необязательно)'),
                  children: [
                    TextField(
                      controller: question,
                      enabled: !busy,
                      maxLength: 800,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Например: на что обратить внимание?',
                        helperText:
                            'Не указывайте медицинские и другие чувствительные данные.',
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: busy || loading || selected.isEmpty
                        ? null
                        : _analyze,
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text(busy ? 'Подождите…' : 'Подготовить анализ ИИ'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 50),
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'Сначала будет предпросмотр. Сводка не изменяет записи.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: LinearProgressIndicator(),
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => DiaryAiScreen(provider: p),
                          ),
                        ),
                  icon: const Icon(Icons.edit_note_rounded),
                  label: const Text('Изменения в еде через ИИ'),
                ),
                Text(
                  'Отдельный режим: до 60 записей еды, каждый черновик нужно проверить и подтвердить.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (result != null) ...[
                const SizedBox(height: 20),
                _AiResultCard(result: result!),
              ],
            ],
          ),
        ),
      );
    },
  );
}

String _sectionHeadline(JournalOverview o, String key) {
  final s = o.sections[key]!;
  switch (key) {
    case 'food':
      return '${s['records']} записей · ${s['daysWithRecords']} дн.';
    case 'water':
      return '${s['recordedDays']} дн. с записью';
    case 'steps':
      return '${s['recordedDays']} дн. с записью';
    case 'training':
      return '${s['gymSessionsStarted']} занятий зала · ${s['manualWorkouts']} ручных';
    case 'weight':
      return '${s['measurements']} измерений';
    default:
      return '${s['records']} записей';
  }
}

String _names(Object? raw) {
  if (raw is! List || raw.isEmpty) return 'нет';
  return raw.map((e) => '${e['name']} (${e['count']})').join(', ');
}

String _micros(Object? value) {
  final data = value is Map ? value : const {};
  return data.isEmpty
      ? 'нет'
      : data.entries
            .map(
              (e) =>
                  '${microLabels[e.key] ?? e.key}: ${e.value['total']} за ${e.value['knownRecords']} записей',
            )
            .join('; ');
}

String _exerciseRows(Object? raw, {required bool gym}) {
  if (raw is! List || raw.isEmpty) return 'нет';
  return raw
      .map((e) {
        final weight = e.containsKey('minWeightKg')
            ? ', вес ${e['minWeightKg']}–${e['maxWeightKg']} кг'
            : ', вес не сопоставляется';
        return gym
            ? '${e['name']}: ${e['sets']} подходов, повторения известны в ${e['setsWithReps']}, всего ${e['totalReps']}, вес известен в ${e['setsWithWeight']}$weight${e.containsKey('lastWeightKg') ? ', последний ${e['lastWeightKg']} кг' : ''}'
            : '${e['name']}: ${e['entries']} записей, подходы и повторы известны в ${e['entriesWithSetsAndReps']}, всего повторов ${e['totalRepsKnown']}, вес известен в ${e['entriesWithWeight']}$weight';
      })
      .join('; ');
}

String _sectionDetails(JournalOverview o, String key) {
  final s = o.sections[key]!;
  switch (key) {
    case 'food':
      final known = _micros(s['micronutrients']);
      return 'Дней с записями: ${s['daysWithRecords']}; записей: ${s['records']}. '
          '${s['records'] == 0 ? 'Записей нет, питание неизвестно. ' : ''}'
          'Сумма записанного: ${s['caloriesTotal']} ккал, белки ${s['proteinTotalG']} г, жиры ${s['fatTotalG']} г, углеводы ${s['carbsTotalG']} г. '
          'Состав указан в ${s['recordsWithMicronutrients']} записях, из них оценочный — в ${s['recordsWithEstimatedMicronutrients']}. '
          'Известные микронутриенты: $known. '
          'До 10 частых продуктов: ${_names(s['commonFoodsUpTo10'])}; разных названий: ${s['uniqueFoodNames']}.';
    case 'water':
      return 'Записано дней: ${s['recordedDays']}; всего ${s['totalMl']} мл.${s['recordedDays'] == 0 ? ' Без записей потребление неизвестно.' : ''}';
    case 'steps':
      return 'Записано дней: ${s['recordedDays']}; всего ${s['totalSteps']} шагов.${s['recordedDays'] == 0 ? ' Без записей активность неизвестна.' : ''}';
    case 'training':
      return 'Дней с записями: ${s['daysWithRecords']}; ручных тренировок: ${s['manualWorkouts']}, ${s['manualMinutes']} мин, оценка расхода ${s['manualCaloriesBurnedTotal']} ккал, добавлено к лимиту ${s['manualCaloriesAddedToBudget']} ккал. '
          'До 10 ручных упражнений из ${s['manualUniqueExerciseNames']}: ${_exerciseRows(s['manualExercisesUpTo10'], gym: false)}. '
          'Занятий зала начато: ${s['gymSessionsStarted']}, завершено: ${s['gymSessionsFinished']}, записано подходов: ${s['gymRecordedSets']}. '
          'До 10 упражнений зала из ${s['gymUniqueExerciseNames']}: ${_exerciseRows(s['gymExercisesUpTo10'], gym: true)}. Вес подтягиваний отдельно не сопоставляется. '
          'Кардио: записей ${s['gymCardioEntries']}, минут ${s['gymCardioMinutes']}; дистанция известна в ${s['gymCardioKnownDistanceEntries']} записях, сумма известных ${s['gymCardioDistanceKm']} км. '
          'До 10 частых названий в двух источниках: ${_names(s['commonExerciseNamesUpTo10'])}; разных названий: ${s['uniqueExerciseNames']}. Числа — подходы зала и упоминания ручных упражнений, не тренировки. '
          'Сопоставимых тестов подтягиваний своим весом: ${s['comparablePullupTests']}'
          '${s.containsKey('firstPullupReps') ? '; первый ${s['firstPullupReps']}, последний ${s['lastPullupReps']} повт.' : '.'}';
    case 'weight':
      return 'Измерений: ${s['measurements']}${s.containsKey('firstKg') ? '; первое ${s['firstKg']} кг, последнее ${s['lastKg']} кг.' : '.'}';
    default:
      return 'Записей: ${s['records']}; до 10 частых названий: ${_names(s['commonNamesUpTo10'])}; разных названий: ${s['uniqueNames']}. '
          'Известный состав добавок по записям: ${_micros(s['knownMicronutrients'])}. '
          'Креатин: известное количество в ${s['knownCreatineRecords']} записях, всего ${s['knownCreatineTotalG']} г. Неполные данные не равны нулю.';
  }
}

class _AiResultCard extends StatelessWidget {
  final JournalAiResult result;
  const _AiResultCard({required this.result});
  @override
  Widget build(BuildContext context) => PremiumCard(
    radius: 24,
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ответ ИИ', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Это ответ модели по выбранной сводке, не диагноз. Сверяй выводы с записями.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 14),
        Text(result.summary),
        for (final section in <(String, List<String>)>[
          ('Что заметил ИИ', result.observations),
          ('Идеи и подсказки', result.suggestions),
          ('Чего не хватает', result.limitations),
        ])
          if (section.$2.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(section.$1, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final item in section.$2)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7, right: 8),
                      child: Icon(
                        Icons.circle,
                        size: 5,
                        color: AppTheme.primary,
                      ),
                    ),
                    Expanded(child: Text(item)),
                  ],
                ),
              ),
          ],
      ],
    ),
  );
}
