import 'package:flutter/material.dart';
import '../legacy.dart';
import 'ai_actions.dart';
import 'ai_drafts.dart';
import 'ai_preferences.dart';
import 'local_store.dart';
import 'diary_ai.dart';
import 'engine.dart';
import 'remote.dart';
import 'ui.dart' show editAiFoodProposal;

/// Explicit, food-only AI analysis of a user-selected date range. Suggestions
/// are local until the user selects and confirms a single-day atomic write.
class DiaryAiScreen extends StatefulWidget {
  final AppDataProvider provider;
  final DiaryAiSnapshot? initialSnapshot;
  final DiaryAiResult? initialResult;
  final String? initialOwner;
  final String? Function()? ownerReader;
  final bool Function()? authorizationGuard;
  final Listenable? accountChanges;

  const DiaryAiScreen({super.key, required this.provider})
    : initialSnapshot = null,
      initialResult = null,
      initialOwner = null,
      ownerReader = null,
      authorizationGuard = null,
      accountChanges = null;

  /// Reuse the established review/editor/confirmation screen for proposals
  /// returned by another provider. It never submits a second Gemini request.
  const DiaryAiScreen.review({
    super.key,
    required this.provider,
    required DiaryAiSnapshot snapshot,
    required DiaryAiResult result,
    required String owner,
    required this.ownerReader,
    required this.authorizationGuard,
    this.accountChanges,
  }) : initialSnapshot = snapshot,
       initialResult = result,
       initialOwner = owner;

  bool get isReviewOnly => initialSnapshot != null;

  @override
  State<DiaryAiScreen> createState() => _DiaryAiScreenState();
}

class _DiaryAiScreenState extends State<DiaryAiScreen> {
  late DateTime first, last;
  final question = TextEditingController(
    text:
        'Проанализируй записанное питание, укажи неполные данные и что стоит проверить.',
  );
  DiaryAiSnapshot? snapshot;
  DiaryAiResult? result;
  FoodRangeSnapshot? resultRange;
  _UndoDay? undo;
  String? error, resultOwner, boundOwner;
  int? resultPrivacyEpoch;
  bool loading = true, busy = false, replaceKnown = false;
  bool reviewDialogOpen = false;
  int generation = 0;

  String? _currentOwner() => widget.ownerReader != null
      ? widget.ownerReader!()
      : SmartRemote.instance.client?.auth.currentUser?.id;

  bool _sameOwnerAndBinding(String account) =>
      _currentOwner() == account &&
      widget.provider.storage.local.getString('_bound_user') == boundOwner &&
      (boundOwner == null || boundOwner == account);

  bool _authorized(String account) {
    if (!_sameOwnerAndBinding(account)) return false;
    if (widget.isReviewOnly) return widget.authorizationGuard?.call() == true;
    final epoch = resultPrivacyEpoch;
    return epoch != null &&
        AiConsent(widget.provider.storage.local, account).validFor(epoch);
  }

  void _accountChanged() {
    final account = resultOwner;
    if (account == null || _sameOwnerAndBinding(account) || !mounted) return;
    generation++;
    if (reviewDialogOpen) {
      reviewDialogOpen = false;
      // The food editor can itself open a nutrient dialog. Close every dialog
      // above this review route so neither exposes the previous account's data.
      final navigator = Navigator.of(context, rootNavigator: true);
      final reviewRoute = ModalRoute.of(context);
      if (reviewRoute != null && reviewRoute.navigator == navigator) {
        navigator.popUntil((route) => identical(route, reviewRoute));
      } else {
        navigator.pop(false);
      }
    }
    setState(() {
      snapshot = null;
      result = null;
      resultRange = null;
      undo = null;
      resultOwner = null;
      error = 'Аккаунт или привязка дневника изменились. Предложения очищены.';
    });
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSnapshot;
    final d = widget.provider.selectedDate;
    first = initial?.firstDay ?? DateTime(d.year, d.month, d.day);
    last = initial?.lastDay ?? DateTime(d.year, d.month, d.day);
    (widget.accountChanges ?? SmartRemote.instance).addListener(
      _accountChanged,
    );
    if (initial != null) {
      snapshot = initial;
      result = widget.initialResult;
      resultOwner = widget.initialOwner;
      boundOwner = widget.provider.storage.local.getString('_bound_user');
      resultRange = FoodRangeSnapshot(
        firstDay: first,
        lastDay: last,
        entries: initial.byRef.values.toList(),
      );
      loading = false;
      if (resultOwner == null || !_authorized(resultOwner!)) {
        snapshot = null;
        result = null;
        resultRange = null;
        error = 'Аккаунт изменился. Предложения недоступны.';
      }
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    (widget.accountChanges ?? SmartRemote.instance).removeListener(
      _accountChanged,
    );
    question.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final current = ++generation;
    setState(() {
      loading = true;
      error = null;
      snapshot = null;
      result = null;
      resultRange = null;
      resultOwner = null;
      boundOwner = null;
    });
    try {
      final entries = await widget.provider.storage.getFoodEntriesInRange(
        first,
        last,
        maxEntries: DiaryAiSnapshot.maxEntries,
      );
      final fresh = DiaryAiSnapshot(
        firstDay: first,
        lastDay: last,
        entries: entries,
      );
      if (mounted && current == generation) setState(() => snapshot = fresh);
    } catch (e) {
      if (mounted && current == generation)
        setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      initialDateRange: DateTimeRange(start: first, end: last),
      helpText: 'Период для анализа еды',
    );
    if (picked == null || !mounted) return;
    setState(() {
      first = picked.start;
      last = picked.end;
    });
    await _load();
  }

  Future<void> _analyze() async {
    final input = snapshot;
    if (input == null || busy) return;
    final account = SmartRemote.instance.client?.auth.currentUser?.id;
    if (account == null) {
      setState(
        () => error =
            'Для ИИ войдите в аккаунт в разделе «Ещё → Синхронизация». Дневник и ручной ввод работают без входа.',
      );
      return;
    }
    final privacyEpoch = LocalPreferences.privacyEpoch;
    final localOwner = widget.provider.storage.local.getString('_bound_user');
    if (localOwner != null && localOwner != account) {
      setState(
        () => error = 'Дневник связан с другим аккаунтом. Запрос отменён.',
      );
      return;
    }
    final text = question.text.trim();
    if (text.isEmpty || text.length > 2000) {
      setState(
        () => error = 'Введите вопрос или команду длиной до 2000 символов.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
      result = null;
      resultRange = null;
      resultOwner = null;
    });
    try {
      final currentEntries = await widget.provider.storage
          .getFoodEntriesInRange(
            first,
            last,
            maxEntries: DiaryAiSnapshot.maxEntries,
          );
      final fresh = DiaryAiSnapshot(
        firstDay: first,
        lastDay: last,
        entries: currentEntries,
      );
      final before = input.byRef.values.toList();
      final now = fresh.byRef.values.toList();
      if (before.length != now.length ||
          List.generate(
            before.length,
            (i) => i,
          ).any((i) => !sameFoodSnapshot(before[i], now[i]))) {
        if (mounted)
          setState(() {
            snapshot = fresh;
            error =
                'Дневник изменился. Проверьте обновлённый список и отправьте запрос снова.';
          });
        return;
      }
      if (!mounted) return;
      final consent = await ensureAiConsent(
        context,
        widget.provider.storage.local,
        account,
      );
      if (!consent || !mounted) return;
      // Consent belongs to one account. Do not send even a transient request
      // if the user switched accounts or revoked it while the dialog was open.
      if (SmartRemote.instance.client?.auth.currentUser?.id != account ||
          widget.provider.storage.local.getString('_bound_user') !=
              localOwner ||
          !AiConsent(
            widget.provider.storage.local,
            account,
          ).validFor(privacyEpoch)) {
        throw StateError(
          'Аккаунт или привязка изменились либо согласие отозвано. Запрос не отправлен.',
        );
      }
      final received = await SmartRemote.instance.analyzeDiary(
        snapshot: input,
        question: text,
        replaceKnownMicros: replaceKnown,
      );
      if (!mounted) return;
      if (SmartRemote.instance.client?.auth.currentUser?.id != account ||
          widget.provider.storage.local.getString('_bound_user') !=
              localOwner ||
          !AiConsent(
            widget.provider.storage.local,
            account,
          ).validFor(privacyEpoch)) {
        throw StateError(
          'Аккаунт или привязка изменились либо согласие отозвано. Ответ не применён.',
        );
      }
      setState(() {
        result = received;
        resultOwner = account;
        resultPrivacyEpoch = privacyEpoch;
        boundOwner = localOwner;
        resultRange = FoodRangeSnapshot(
          firstDay: input.firstDay,
          lastDay: input.lastDay,
          entries: input.byRef.values.toList(),
        );
      });
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit(DiaryAiSuggestion suggestion) async {
    final proposed = suggestion.proposed;
    final account = resultOwner;
    if (proposed == null) return;
    if (account == null || !_authorized(account)) {
      setState(
        () => error =
            'Аккаунт, возраст или привязка изменились либо согласие отозвано. Повторите анализ.',
      );
      return;
    }
    reviewDialogOpen = true;
    Map<String, dynamic>? changed;
    try {
      changed = await editAiFoodProposal(context, foodAsAiItem(proposed));
    } finally {
      reviewDialogOpen = false;
    }
    final edited = changed;
    if (edited == null || !mounted || !_authorized(account)) return;
    try {
      setState(() => suggestion.edit(edited));
    } catch (e) {
      setState(() => error = friendlyAiError(e));
    }
  }

  Future<void> _changeAddDate(DiaryAiSuggestion suggestion) async {
    final account = resultOwner;
    if (suggestion.kind != 'add' || suggestion.proposed == null) return;
    if (account == null || !_authorized(account)) {
      setState(
        () => error =
            'Аккаунт, возраст или привязка изменились либо согласие отозвано. Повторите анализ.',
      );
      return;
    }
    reviewDialogOpen = true;
    DateTime? picked;
    try {
      picked = await showDatePicker(
        context: context,
        initialDate: suggestion.date,
        firstDate: first,
        lastDate: last,
      );
    } finally {
      reviewDialogOpen = false;
    }
    if (picked == null || !mounted || !_authorized(account)) return;
    setState(
      () => suggestion.edit(foodAsAiItem(suggestion.proposed!), date: picked),
    );
  }

  Future<void> _apply(DateTime date) async {
    final account = resultOwner;
    final plan = result;
    final range = resultRange;
    if (account == null ||
        plan == null ||
        range == null ||
        !_authorized(account)) {
      setState(
        () => error =
            'Аккаунт, возраст или привязка изменились либо согласие отозвано. Повторите анализ.',
      );
      return;
    }
    final picked = plan.suggestions
        .where((s) => s.selected && dayKey(s.date) == dayKey(date))
        .toList();
    if (picked.isEmpty) return;
    final deletions = picked.where((s) => s.kind == 'delete').length;
    reviewDialogOpen = true;
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Применить ${picked.length} изменений?'),
          content: SingleChildScrollView(
            child: Text(
              '${formatDateRu(date)}\n\n${picked.map((s) => '${_kind(s.kind)}${s.reference.isEmpty ? '' : ' · ${s.reference}'}: ${s.original?.name ?? s.proposed!.name}\n${_diff(s.original, s.proposed, s.kind)}').join('\n\n')}'
              '${deletions > 0 ? '\n\nБудут удалены записи: $deletions. Проверьте список.' : ''}'
              '\n\nТолько выбранный день. Перед записью проверим все записи выбранного периода на этом устройстве. При конфликте синхронизации проверьте обе версии: изменения с других устройств могут прийти позже.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (!reviewDialogOpen) return;
                reviewDialogOpen = false;
                Navigator.pop(ctx, false);
              },
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                if (!reviewDialogOpen) return;
                reviewDialogOpen = false;
                Navigator.pop(ctx, true);
              },
              child: const Text('Подтвердить'),
            ),
          ],
        ),
      );
    } finally {
      reviewDialogOpen = false;
    }
    if (confirmed != true || !mounted) return;
    if (!_authorized(account) || !identical(result, plan)) {
      setState(
        () => error =
            'Аккаунт, возраст или привязка изменились либо согласие отозвано. Изменения не применены.',
      );
      return;
    }
    final expected = <String, FoodEntry>{};
    final changes = <String, FoodEntry?>{};
    final additions = <FoodEntry>[];
    final undoExpected = <String, FoodEntry>{};
    final undoChanges = <String, FoodEntry?>{};
    final undoAdditions = <FoodEntry>[];
    for (final s in picked) {
      if (s.kind == 'add') {
        additions.add(s.proposed!);
        undoExpected[s.proposed!.id] = s.proposed!;
        undoChanges[s.proposed!.id] = null;
      } else {
        expected[s.original!.id] = s.original!;
        changes[s.original!.id] = s.kind == 'delete' ? null : s.proposed;
        if (s.kind == 'delete') {
          undoAdditions.add(s.original!);
        } else {
          undoExpected[s.proposed!.id] = s.proposed!;
          undoChanges[s.proposed!.id] = s.original!;
        }
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final nextRange = range.afterReviewedDay(
        date: date,
        changes: changes,
        additions: additions,
      );
      await widget.provider.applyReviewedFoodChanges(
        date: date,
        expected: expected,
        changes: changes,
        additions: additions,
        expectedRange: range,
        authorizationGuard: () =>
            mounted && _authorized(account) && identical(result, plan),
      );
      if (!mounted) return;
      if (!_authorized(account) || !identical(result, plan)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Подтверждённые изменения сохранены до смены аккаунта.',
            ),
          ),
        );
        return;
      }
      setState(() {
        resultRange = nextRange;
        undo = _UndoDay(
          date,
          undoExpected,
          undoChanges,
          undoAdditions,
          account,
        );
        plan.suggestions.removeWhere(picked.contains);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Подтверждённые изменения сохранены.')),
      );
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _undo() async {
    final item = undo;
    final range = resultRange;
    if (item == null || range == null || busy) return;
    if (!_sameOwnerAndBinding(item.owner)) {
      setState(
        () => error =
            'Аккаунт изменился. Отмена для другого аккаунта недоступна.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final nextRange = range.afterReviewedDay(
        date: item.date,
        changes: item.changes,
        additions: item.additions,
      );
      await widget.provider.applyReviewedFoodChanges(
        date: item.date,
        expected: item.expected,
        changes: item.changes,
        additions: item.additions,
        authorizationGuard: () =>
            mounted &&
            _sameOwnerAndBinding(item.owner) &&
            identical(undo, item),
      );
      if (mounted &&
          _sameOwnerAndBinding(item.owner) &&
          identical(undo, item)) {
        setState(() {
          resultRange = nextRange;
          undo = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Последние изменения отменены.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = snapshot, plan = result;
    final dates = <String, DateTime>{};
    if (plan != null) {
      for (final s in plan.suggestions) {
        dates[dayKey(s.date)] = s.date;
      }
    }
    final sortedDays = dates.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isReviewOnly ? 'Предложения ИИ' : 'ИИ-анализ дневника',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Анализ и изменения только по вашему запросу. ИИ может ошибаться; это не медицинская диагностика.',
          ),
          const SizedBox(height: 12),
          if (widget.isReviewOnly)
            Text(
              'Период анализа: ${formatDateRu(first)} — ${formatDateRu(last)}',
            ),
          if (!widget.isReviewOnly) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : _pickRange,
              icon: const Icon(Icons.date_range),
              label: Text(
                'Период: ${formatDateRu(first)} — ${formatDateRu(last)}',
              ),
            ),
            const Text(
              'Можно выбрать любые даты; максимум 60 записей еды за один запрос. Если записей больше, сократите период.',
            ),
            if (loading) const LinearProgressIndicator(),
            if (snap != null) ...[
              const SizedBox(height: 8),
              Text(
                'Выбрано записей еды: ${snap.byRef.length}. Перед отправкой проверьте список.',
              ),
              const Text(
                'В Gemini отправятся вопрос, даты, названия, порции, приём пищи, КБЖУ и известный состав выбранной еды. Профиль, вес, добавки и остальная история автоматически не отправляются. Google не разрешает передавать личные и чувствительные данные в бесплатный API: не отправляйте настоящие личные записи и не вводите личные данные в вопрос.',
              ),
              ExpansionTile(
                title: const Text('Что будет отправлено'),
                children: [
                  if (snap.byRef.isEmpty)
                    const ListTile(title: Text('За период нет записей еды.')),
                  for (final record in snap.byRef.entries)
                    ListTile(
                      dense: true,
                      title: Text('${record.key} · ${record.value.name}'),
                      subtitle: Text(_sentFoodDetails(record.value)),
                    ),
                ],
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: replaceKnown,
              onChanged: busy ? null : (v) => setState(() => replaceKnown = v),
              title: const Text(
                'Предлагать замену известных показателей состава',
              ),
              subtitle: const Text(
                'По умолчанию ИИ заполняет только пустые значения. Все изменения требуют подтверждения.',
              ),
            ),
            TextField(
              controller: question,
              enabled: !busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Что проанализировать или изменить',
                hintText:
                    'Например: добавь недостающие витамины в яблоке; измени вес обеда на 200 г',
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('Проанализировать'),
                  onPressed: busy
                      ? null
                      : () => question.text =
                            'Проанализируй записанное питание, укажи неполные данные и что стоит проверить.',
                ),
                ActionChip(
                  label: const Text('Заполнить неизвестные витамины'),
                  onPressed: busy
                      ? null
                      : () {
                          question.text =
                              'Для записанных продуктов предложи приблизительные значения недостающих витаминов, не меняй известные значения.';
                          setState(() => replaceKnown = false);
                        },
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy || loading || snap == null ? null : _analyze,
              icon: const Icon(Icons.auto_awesome),
              label: Text(busy ? 'Подождите…' : 'Отправить запрос ИИ'),
            ),
          ],
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (plan != null) ...[
            const SizedBox(height: 16),
            Text('Анализ ИИ', style: Theme.of(context).textTheme.titleLarge),
            const Text(
              'Оценка по предоставленным записям, а не измерение или диагноз. Неизвестное не равно нулю.',
            ),
            const SizedBox(height: 8),
            Text(plan.analysis),
            const SizedBox(height: 16),
            Text(
              'Предложения: ${plan.suggestions.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Ничего не изменено. Отметьте нужные предложения, проверьте значения и подтвердите отдельно за каждый день.',
            ),
            if (plan.suggestions.isEmpty)
              const Text('Нет предложений для применения.'),
            for (final suggestion in plan.suggestions)
              _proposalCard(context, suggestion),
            for (final key in sortedDays)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonal(
                  onPressed:
                      busy ||
                          !plan.suggestions.any(
                            (s) => s.selected && dayKey(s.date) == key,
                          )
                      ? null
                      : () => _apply(dates[key]!),
                  child: Text(
                    'Применить отмеченное за ${formatDateRu(dates[key]!)}',
                  ),
                ),
              ),
          ],
          if (undo != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                onPressed: busy ? null : _undo,
                icon: const Icon(Icons.undo),
                label: const Text('Отменить последнее применение'),
              ),
            ),
          if (undo != null)
            const Text(
              'Отмена доступна на этом экране и остановится, если записи успели измениться.',
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _proposalCard(BuildContext context, DiaryAiSuggestion s) {
    final old = s.original, next = s.proposed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: s.selected,
              onChanged: busy
                  ? null
                  : (v) => setState(() => s.selected = v == true),
              title: Text('${_kind(s.kind)} · ${old?.name ?? next!.name}'),
              subtitle: Text(
                '${formatDateRu(s.date)} · ${old?.mealType.label ?? next!.mealType.label}'
                '${old == null ? ' · новая запись' : ' · ${s.reference} · ${_foodTimeLabel(old)}'}',
              ),
            ),
            Text(_diff(old, next, s.kind)),
            if (s.reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  s.reason,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                if (next != null)
                  TextButton.icon(
                    onPressed: busy ? null : () => _edit(s),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Изменить предложение'),
                  ),
                if (s.kind == 'add')
                  TextButton.icon(
                    onPressed: busy ? null : () => _changeAddDate(s),
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: const Text('Изменить дату'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Show the same per-100-g fields and supported micronutrients as the request,
/// without rounding a value to something different from what will be sent.
String _sentFoodDetails(FoodEntry e) {
  final micros = e.micros.entries.where((m) => microLabels.containsKey(m.key));
  return '${formatDateRu(e.date)} · ${e.mealType.label} · порция ${e.amountGrams} г\n'
      'На 100 г: ${e.caloriesPer100g} ккал; Б ${e.proteinPer100g} г; Ж ${e.fatPer100g} г; У ${e.carbsPer100g} г\n'
      'Состав на 100 г: ${micros.isEmpty ? 'нет данных' : micros.map((m) => '${microLabels[m.key]}: ${m.value}').join('; ')}';
}

String _kind(String kind) => switch (kind) {
  'add' => 'Добавить',
  'delete' => 'Удалить',
  _ => 'Изменить',
};

String _exactValue(num n) =>
    n == n.truncateToDouble() ? n.toInt().toString() : n.toString();

String _foodTimeLabel(FoodEntry entry) {
  if (!entry.timeKnown) return 'время не указано';
  return '${entry.loggedAt.hour.toString().padLeft(2, '0')}:${entry.loggedAt.minute.toString().padLeft(2, '0')}';
}

String _foodSummary(FoodEntry entry) =>
    '${entry.name}: ${_exactValue(entry.amountGrams)} г; ${entry.mealType.label}; на 100 г: '
    '${_exactValue(entry.caloriesPer100g)} ккал, Б ${_exactValue(entry.proteinPer100g)}, '
    'Ж ${_exactValue(entry.fatPer100g)}, У ${_exactValue(entry.carbsPer100g)}. '
    'Состав: ${entry.micros.isEmpty ? 'нет данных' : entry.micros.entries.map((e) => '${microLabels[e.key]} ${_exactValue(e.value)}').join(', ')}.';

String _diff(FoodEntry? old, FoodEntry? next, String kind) {
  if (kind == 'delete')
    return 'Будет удалено: ${_foodSummary(old!)} Остальные записи не затрагиваются.';
  if (old == null) return '${_foodSummary(next!)} Это оценка; проверьте.';
  final parts = <String>[];
  void changed(String label, Object a, Object b) {
    if (a != b) parts.add('$label: $a → $b');
  }

  changed('Название', old.name, next!.name);
  changed(
    'Порция, г',
    _exactValue(old.amountGrams),
    _exactValue(next.amountGrams),
  );
  changed(
    'Ккал на 100 г',
    _exactValue(old.caloriesPer100g),
    _exactValue(next.caloriesPer100g),
  );
  changed(
    'Белки на 100 г',
    _exactValue(old.proteinPer100g),
    _exactValue(next.proteinPer100g),
  );
  changed(
    'Жиры на 100 г',
    _exactValue(old.fatPer100g),
    _exactValue(next.fatPer100g),
  );
  changed(
    'Углеводы на 100 г',
    _exactValue(old.carbsPer100g),
    _exactValue(next.carbsPer100g),
  );
  changed('Приём пищи', old.mealType.label, next.mealType.label);
  for (final key in {...old.micros.keys, ...next.micros.keys}) {
    final a = old.micros[key], b = next.micros[key];
    if (a != b)
      parts.add(
        '${microLabels[key]} на 100 г: ${a == null ? 'нет данных' : _exactValue(a)} → ${b == null ? 'нет данных' : _exactValue(b)}',
      );
  }
  return parts.isEmpty ? 'Значения не изменены.' : parts.join('\n');
}

class _UndoDay {
  final DateTime date;
  final Map<String, FoodEntry> expected;
  final Map<String, FoodEntry?> changes;
  final List<FoodEntry> additions;
  final String owner;
  _UndoDay(this.date, this.expected, this.changes, this.additions, this.owner);
}
