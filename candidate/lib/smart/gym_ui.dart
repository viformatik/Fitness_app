import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../legacy.dart';
import 'gym_models.dart';
import 'gym_plan.dart';
import 'gym_guided.dart';

Future<void> showGym(BuildContext context, AppDataProvider provider) =>
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => GymHomeScreen(provider: provider),
      ),
    );

// Display the saved value without rounding it on edit (e.g. 1.25 kg plates).
String gymNumber(num n) => n.toString().replaceFirst(RegExp(r'\.0$'), '');
String gymClock(int seconds) {
  final s = math.max(0, seconds);
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}'
      : '$m:${r.toString().padLeft(2, '0')}';
}

String gymDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';
String _setResult(GymSet set) {
  final parts = <String>[];
  if (set.reps != null) parts.add('${set.reps} повт.');
  if (set.seconds != null) parts.add('${set.seconds} с');
  if (set.isPullup) {
    if (set.pullupMode == 'bodyweight') parts.add('свой вес');
    if (set.pullupMode == 'weighted')
      parts.add(
        set.weightKg == null
            ? '+ вес не указан'
            : '+${gymNumber(set.weightKg!)} кг',
      );
    if (set.pullupMode == 'assisted')
      parts.add(
        set.weightKg == null
            ? 'с помощью'
            : 'помощь ${gymNumber(set.weightKg!)} кг',
      );
    if (set.pullupMode == 'unknown' && set.weightKg != null)
      parts.add('${gymNumber(set.weightKg!)} кг · вид не указан');
  } else if (set.weightKg != null) {
    parts.add('${gymNumber(set.weightKg!)} кг');
  }
  if (set.rir != null) parts.add('запас ${set.rir}');
  return parts.join(' · ');
}

List<GymSession> _readSessions(StorageService store) {
  final items = <GymSession>[];
  for (final key in store.local.getKeys().where(
    (k) => k.startsWith(gymSessionPrefix),
  )) {
    final raw = store.local.getString(key);
    if (raw == null) continue;
    validateGymDocument(key, raw);
    items.add(
      GymSession.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)),
    );
  }
  items.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return items;
}

class GymHomeScreen extends StatefulWidget {
  final AppDataProvider provider;
  const GymHomeScreen({super.key, required this.provider});
  @override
  State<GymHomeScreen> createState() => _GymHomeScreenState();
}

class _GymHomeScreenState extends State<GymHomeScreen> {
  late String dayId;
  List<GymSession> sessions = [];
  DateTime? cycleStart;
  String? loadError, settingsRaw;
  bool loading = true, savingChecks = false;
  StorageService get store => widget.provider.storage;

  @override
  void initState() {
    super.initState();
    dayId = gymPlan().firstWhere((d) => d.weekday == DateTime.now().weekday).id;
    widget.provider.addListener(_providerChanged);
    unawaited(_reload());
  }

  void _providerChanged() {
    if (mounted) unawaited(_reload());
  }

  @override
  void dispose() {
    widget.provider.removeListener(_providerChanged);
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      await store.pendingMutations;
      final list = _readSessions(store);
      final raw = store.local.getString(gymSettingsKey);
      DateTime? start;
      if (raw != null) {
        validateGymDocument(gymSettingsKey, raw);
        final j = jsonDecode(raw) as Map;
        if (j['cycleStart'] is String)
          start = DateTime.parse(j['cycleStart'] as String).toLocal();
      }
      if (mounted)
        setState(() {
          sessions = list;
          cycleStart = start;
          settingsRaw = raw;
          loadError = null;
          loading = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          loadError =
              'Не удалось прочитать историю зала. Данные не изменены; проверьте резервную копию.';
          loading = false;
        });
    }
  }

  Future<void> _open(String id) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            GymSessionScreen(provider: widget.provider, sessionId: id),
      ),
    );
    await _reload();
  }

  Future<void> _start(GymDayPlan day) async {
    if (loadError != null) return;
    final active = sessions.where((s) => !s.completed).toList();
    if (active.isNotEmpty) {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Есть незавершённая тренировка'),
          content: Text(
            '«${active.first.title}» сохранена. Продолжить её или начать ещё одно занятие?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'new'),
              child: const Text('Начать другое'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'resume'),
              child: const Text('Продолжить'),
            ),
          ],
        ),
      );
      if (!mounted || result == null || result == 'cancel') return;
      if (result == 'resume') {
        await _open(active.first.id);
        return;
      }
    }
    final s = day.start(newId(), DateTime.now());
    try {
      await store.writeGymDocument(
        '$gymSessionPrefix${s.id}',
        null,
        jsonEncode(s.toJson()),
      );
      if (mounted) await _open(s.id);
    } catch (_) {
      if (mounted) _message('Не удалось начать занятие. Ничего не удалено.');
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _setCycle() async {
    final expected = store.local.getString(gymSettingsKey);
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: cycleStart ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 2, 12, 31),
      helpText: 'Выберите начало цикла',
    );
    if (selected == null || !mounted) return;
    try {
      // Preserve the per-week checks (and other settings) when changing the cycle.
      if (expected != null) validateGymDocument(gymSettingsKey, expected);
      final data = expected == null
          ? <String, dynamic>{'version': 1}
          : Map<String, dynamic>.from(jsonDecode(expected) as Map);
      // Date-only: the chosen cycle week must not shift across time zones.
      data['cycleStart'] = dayKey(selected);
      final json = jsonEncode(data);
      await store.writeGymDocument(gymSettingsKey, expected, json);
      await _reload();
    } catch (_) {
      if (mounted) _message('Не удалось сохранить начало цикла. Повторите.');
    }
  }

  Future<void> _setWeekCheck(DateTime week, String id, bool value) async {
    if (savingChecks) return;
    setState(() => savingChecks = true);
    final expected = store.local.getString(gymSettingsKey);
    try {
      final json = gymSetWeekCheck(expected, week, id, value);
      await store.writeGymDocument(gymSettingsKey, expected, json);
      await _reload();
    } catch (_) {
      if (mounted)
        _message('Не удалось сохранить отметку. Обнови экран и повтори.');
    } finally {
      if (mounted) setState(() => savingChecks = false);
    }
  }

  Future<void> _quickPullup() async {
    final exercise = GymExercise(
      id: 'P1',
      name: 'Подтягивания',
      plannedSets: 1,
      target: '',
    );
    final result = await showDialog<_SetDialogResult>(
      context: context,
      builder: (_) => _SetDialog(exercise: exercise, index: 1, allowDate: true),
    );
    if (result?.set == null || !mounted) return;
    final set = result!.set!;
    final now = set.recordedAt;
    exercise.sets.add(set);
    final s = GymSession(
      id: newId(),
      planDay: 'manual',
      title: 'Подтягивания · свободная запись',
      startedAt: now,
      warmup: '',
      cardioPlan: '',
      endedAt: now,
      blocks: [
        GymBlock(
          id: 'P',
          title: 'Подтягивания',
          restMinSeconds: 0,
          restMaxSeconds: 0,
          exercises: [exercise],
        ),
      ],
    );
    try {
      await store.writeGymDocument(
        '$gymSessionPrefix${s.id}',
        null,
        jsonEncode(s.toJson()),
      );
      await _reload();
      if (mounted) _message('Подход сохранён.');
    } catch (_) {
      if (mounted) _message('Не удалось сохранить подход.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = gymDay(dayId);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Зал и подтягивания'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'План'),
              Tab(text: 'Подтягивания'),
              Tab(text: 'История'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Обновить',
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(loadError!),
                ),
              )
            : TabBarView(
                children: [_planPage(day), _pullupPage(), _historyPage()],
              ),
      ),
    );
  }

  Widget _planPage(GymDayPlan day) {
    final active = sessions.where((s) => !s.completed).toList();
    final now = DateTime.now();
    final week = cycleStart == null ? null : cycleWeek(cycleStart!, now);
    final startWeek = mondayOf(now);
    final completedThisWeek = sessions
        .where(
          (s) =>
              s.completed &&
              s.setCount > 0 &&
              mondayOf(s.startedAt) == startWeek,
        )
        .map((s) => s.planDay)
        .toSet();
    final pullupDays = sessions
        .expand((s) => s.allSets)
        .where(
          (set) =>
              set.isPullup &&
              set.reps != null &&
              mondayOf(set.recordedAt) == startWeek,
        )
        .map((set) => dayKey(set.recordedAt))
        .toSet()
        .length;
    final cardioEntries = sessions
        .expand((s) => s.cardio)
        .where((entry) => mondayOf(entry.recordedAt) == startWeek)
        .length;
    final checks = gymWeekChecks(settingsRaw, now);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Твой план на неделю',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  '4 силовые: Вт / Чт / Пт / Вс. Подтягивания есть Пн, Вт, Ср, Чт и Пт; воскресный тест — по желанию.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Основная тренировка по плану — 45–60 минут плюс кардио. Сохраняй реальные подходы и отдыхай после пары. Тренировка не добавляет калории и не меняет питание автоматически.',
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Если тебе меньше 18 лет: согласуй нагрузку и питание со специалистом, не работай через боль. Взрослые формулы и ИИ 18+ могут быть недоступны или неподходящими.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final s in active)
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('Незавершённое занятие'),
              subtitle: Text('${s.title} · подходов: ${s.setCount}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(s.id),
            ),
          ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final d in gymPlan())
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(d.shortName),
                    selected: d.id == dayId,
                    onSelected: (_) => setState(() => dayId = d.id),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(day.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(day.description),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _start(day),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Начать занятие'),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Разминка: ${day.warmup}'),
                const SizedBox(height: 8),
                Text('Кардио: ${day.cardioPlan}'),
              ],
            ),
          ),
        ),
        for (final block in day.blocks)
          Card(
            child: ExpansionTile(
              title: Text(block.title),
              subtitle: Text(
                '${block.exercises.length > 1 ? 'После пары' : 'После подхода'}: ${_restRange(block)}${block.optional ? ' · по желанию' : ''}',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (block.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(block.note),
                  ),
                for (final exercise in block.exercises)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${exercise.id}. ${exercise.name} · ${exercise.plannedSets} × ${exercise.targets.isNotEmpty ? exercise.targets.join(' / ') : exercise.target}'
                      '${exercise.alternatives.isEmpty ? '' : '\nЗамены: ${exercise.alternatives.join(', ')}'}',
                    ),
                  ),
              ],
            ),
          ),
        Card(
          child: ExpansionTile(
            title: const Text('Правила суперсетов и восстановление'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: const [
              Text(gymPairGuidance),
              SizedBox(height: 12),
              Text(gymSafetyGuidance),
            ],
          ),
        ),
        Card(
          child: ExpansionTile(
            title: const Text('Прогрессия и разгрузка'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                cycleStart == null
                    ? 'Дата начала цикла не задана.'
                    : week == null
                    ? 'Цикл начинается ${gymDate(cycleStart!)}.'
                    : 'Начало: ${gymDate(cycleStart!)} · неделя $week${week % 6 == 0 ? ' · по плану разгрузочная' : ''}.',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _setCycle,
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: const Text('Указать начало цикла'),
                ),
              ),
              const Text(gymProgressionGuidance),
            ],
          ),
        ),
        Card(
          child: ExpansionTile(
            title: const Text('Питание и сон'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: const [Text(gymNutritionGuidance)],
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Чек-лист на эту неделю',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final id in ['tue', 'thu', 'fri', 'sun'])
                      Chip(
                        avatar: Icon(
                          completedThisWeek.contains(id)
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 18,
                        ),
                        label: Text(gymDay(id).shortName),
                      ),
                  ],
                ),
                const Text(
                  'Силовые отмечаются по завершённым занятиям с подходами; перенос дня допустим.',
                ),
                const SizedBox(height: 10),
                Text('Подтягивания: $pullupDays дн. с записанными подходами.'),
                Text(
                  'Кардио: $cardioEntries записей; интенсивность проверь самостоятельно.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Остальные пункты отмечай вручную по факту. План пяти дней подтягиваний и 3–4 спокойных кардио — не обязательная норма: согласуй объём и восстановление с тренером.',
                ),
                for (final entry in gymChecklistLabels.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(entry.value),
                    value: checks[entry.key] ?? false,
                    onChanged: savingChecks
                        ? null
                        : (value) =>
                              _setWeekCheck(now, entry.key, value ?? false),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _historyPage() => sessions.isEmpty
      ? const Center(
          child: Text('Пока нет записей. Начни занятие на вкладке «План».'),
        )
      : ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          itemCount: sessions.length,
          itemBuilder: (ctx, i) {
            final s = sessions[i];
            return Card(
              child: ListTile(
                onTap: () => _open(s.id),
                leading: Icon(
                  s.completed
                      ? Icons.check_circle_outline
                      : Icons.play_circle_outline,
                ),
                title: Text(s.title),
                subtitle: Text(
                  '${gymDate(s.startedAt)} · ${s.completed ? 'завершено' : 'в процессе'} · подходов: ${s.setCount} · кардио: ${s.cardio.length}',
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
            );
          },
        );

  Widget _pullupPage() {
    final all = <({GymSession session, GymSet set})>[];
    for (final session in sessions) {
      for (final set in session.allSets.where(
        (s) => s.isPullup && s.reps != null,
      )) {
        all.add((session: session, set: set));
      }
    }
    all.sort((a, b) => b.set.recordedAt.compareTo(a.set.recordedAt));
    final tests = all.where((r) => r.set.isComparableTest).toList();
    final reps = all.fold<int>(0, (n, r) => n + r.set.reps!);
    final weekRows = all
        .where((r) => mondayOf(r.set.recordedAt) == mondayOf(DateTime.now()))
        .toList();
    final weekReps = weekRows.fold<int>(0, (n, r) => n + r.set.reps!);
    final weekDays = weekRows
        .map((r) => dayKey(r.set.recordedAt))
        .toSet()
        .length;
    final best = tests.isEmpty
        ? null
        : tests.map((r) => r.set.reps!).reduce(math.max);
    final daysSince = tests.isEmpty
        ? null
        : DateTime.now().difference(tests.first.set.recordedAt).inDays;
    final maxForBars = tests.isEmpty
        ? 1
        : math.max(1, tests.take(8).map((e) => e.set.reps!).reduce(math.max));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Подтягивания',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Все записанные подходы, включая разминку; тяга верхнего блока в подсчёт не входит.',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _quickPullup,
                    icon: const Icon(Icons.add),
                    label: const Text('Записать подход подтягиваний'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Подходов: ${all.length} · повторений: $reps',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'За эту неделю: подходов ${weekRows.length} · повторений $weekReps · дней $weekDays.',
                ),
                const SizedBox(height: 4),
                Text(
                  best == null
                      ? 'Технических тестов без дополнительного веса пока нет.'
                      : 'Лучший технический тест без веса: $best',
                ),
                if (tests.length >= 2)
                  Text(
                    'Последний: ${tests[0].set.reps}; предыдущий: ${tests[1].set.reps}; разница: ${tests[0].set.reps! - tests[1].set.reps! >= 0 ? '+' : ''}${tests[0].set.reps! - tests[1].set.reps!}.',
                  ),
                if (daysSince != null)
                  Text(
                    'Последний тест: ${gymDate(tests.first.set.recordedAt)}${daysSince >= 14 ? ' · по желанию можно обсудить следующий с тренером' : ''}.',
                  ),
                const SizedBox(height: 6),
                const Text(
                  'Тесты с помощью или дополнительным весом показаны в истории, но не смешиваются с тестами собственного веса.',
                ),
              ],
            ),
          ),
        ),
        if (tests.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'История технических тестов',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final row in tests.take(8).toList().reversed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 82,
                            child: Text(
                              gymDate(row.set.recordedAt),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: row.set.reps! / maxForBars,
                              minHeight: 8,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${row.set.reps}'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'История подходов',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (all.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Запиши первый подход, чтобы увидеть прогресс.'),
          ),
        for (final row in all.take(100))
          Card(
            child: ListTile(
              onTap: () => _open(row.session.id),
              title: Text(_setResult(row.set)),
              subtitle: Text(
                '${gymDate(row.set.recordedAt)} · ${row.set.isTest ? 'технический тест · ' : ''}${row.set.exerciseName}${row.session.completed ? '' : ' · занятие в процессе'}',
              ),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
        if (all.length > 100)
          const Text(
            'Показаны последние 100 подходов; все записи доступны в истории занятий.',
          ),
      ],
    );
  }
}

String _restRange(GymBlock b) => b.restMinSeconds == b.restMaxSeconds
    ? gymClock(b.restMaxSeconds)
    : '${gymClock(b.restMinSeconds)}–${gymClock(b.restMaxSeconds)}';

class GymSessionScreen extends StatefulWidget {
  final AppDataProvider provider;
  final String sessionId;
  const GymSessionScreen({
    super.key,
    required this.provider,
    required this.sessionId,
  });
  @override
  State<GymSessionScreen> createState() => _GymSessionScreenState();
}

class _GymSessionScreenState extends State<GymSessionScreen>
    with WidgetsBindingObserver {
  GymSession? session;
  String? raw, error;
  bool busy = false;
  // Active sessions default to the focused one-set flow; the full editor is
  // still available for history, optional test blocks, cardio and changes.
  bool showOverview = false;
  String? focusedBlockId, focusedExerciseId;
  int? focusedSetIndex;
  DateTime now = DateTime.now();
  Timer? tick;
  bool notified = false;
  int? intervalPhase;
  StorageService get store => widget.provider.storage;
  String get key => '$gymSessionPrefix${widget.sessionId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final t = DateTime.now();
      final s = session;
      if (s?.restDeadline != null && s!.restRemainingAt(t) == 0 && !notified) {
        notified = true;
        // Best effort only while the page is active; browsers may suppress it.
        _alert();
      }
      final elapsed = s?.intervalElapsedAt(t);
      if (elapsed != null && s?.intervalResumedAt != null) {
        final phase = elapsed >= 1440
            ? 16
            : (elapsed ~/ 180) * 2 + (elapsed % 180 >= 60 ? 1 : 0);
        if (intervalPhase != null && phase != intervalPhase) {
          _alert();
        }
        intervalPhase = phase;
      } else {
        intervalPhase = null;
      }
      setState(() => now = t);
    });
  }

  void _alert() {
    unawaited(
      SystemSound.play(SystemSoundType.alert).catchError((Object _) {}),
    );
    unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted)
      setState(() => now = DateTime.now());
  }

  @override
  void dispose() {
    tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await store.pendingMutations;
      final value = store.local.getString(key);
      if (value == null) throw StateError('Запись не найдена');
      validateGymDocument(key, value);
      final s = GymSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
      if (mounted)
        setState(() {
          raw = value;
          session = s;
          error = null;
          now = DateTime.now();
        });
    } catch (_) {
      if (mounted)
        setState(
          () => error = 'Не удалось открыть занятие. Данные не изменены.',
        );
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<bool> _mutate(void Function(GymSession) change) async {
    final original = session, expected = raw;
    if (busy || original == null || expected == null) return false;
    setState(() => busy = true);
    try {
      final next = original.clone();
      change(next);
      final json = jsonEncode(next.toJson());
      await store.writeGymDocument(key, expected, json);
      if (mounted)
        setState(() {
          session = next;
          raw = json;
          now = DateTime.now();
        });
      return true;
    } catch (e) {
      if (mounted) {
        _message(
          e is StateError && e.message.toString().contains('другом устройстве')
              ? 'Запись изменилась. Экран обновлён; повторите действие.'
              : 'Не удалось сохранить изменение. Проверьте свободное место и повторите.',
        );
        await _load();
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  GymGuidedStep? _focusedStep(GymSession s) {
    final blockId = focusedBlockId,
        exerciseId = focusedExerciseId,
        index = focusedSetIndex;
    if (blockId != null &&
        exerciseId != null &&
        index != null &&
        index >= 1 &&
        index <= 100) {
      for (final block in s.blocks) {
        if (block.id != blockId) continue;
        for (final exercise in block.exercises) {
          if (exercise.id == exerciseId && exercise.setAt(index) == null) {
            return GymGuidedStep(block, exercise, index);
          }
        }
      }
    }
    return gymResumeStartedOptional(s) ?? gymNextGuidedStep(s);
  }

  void _selectGuided(GymBlock block, GymExercise exercise, int index) {
    setState(() {
      focusedBlockId = block.id;
      focusedExerciseId = exercise.id;
      focusedSetIndex = index;
      showOverview = false;
    });
  }

  GymSet? _latestFor(String name) {
    try {
      final candidates =
          _readSessions(store)
              .expand((s) => s.allSets)
              .where((set) => set.exerciseName == name)
              .toList()
            ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
      return candidates.isEmpty ? null : candidates.first;
    } catch (_) {
      return null; // A history hint must never block saving the next set.
    }
  }

  Future<bool> _saveGuided(GymGuidedStep step, GymSet recorded) async {
    final at = DateTime.now();
    notified = false;
    final ok = await _mutate((s) {
      final block = s.block(step.block.id);
      final exercise = s.exercise(step.block.id, step.exercise.id);
      if (exercise.name != recorded.exerciseName ||
          exercise.setAt(step.index) != null) {
        throw StateError('Подход уже изменён.');
      }
      exercise.sets.add(recorded);
      exercise.sets.sort((a, b) => a.index.compareTo(b.index));
      if (!s.running) s.resumeSession(at);
      final transition = gymHasNextInRound(block, exercise.id, step.index);
      // Saving the set and its timer is one local CAS mutation, so reopening
      // after suspension cannot produce an unrecorded or duplicated set.
      s.startRest(
        at,
        transition ? 15 : block.restMaxSeconds,
        block.title,
        isTransition: transition,
        blockId: block.id,
      );
    });
    if (ok && mounted) {
      // An optional test is never started automatically, but after the user
      // explicitly starts it, continue through its adjacent optional steps.
      final nextOptional = step.block.optional && session != null
          ? gymNextOptionalStep(session!, step.block.id)
          : null;
      setState(() {
        focusedBlockId = nextOptional?.block.id;
        focusedExerciseId = nextOptional?.exercise.id;
        focusedSetIndex = nextOptional?.index;
      });
    }
    return ok;
  }

  Future<void> _editGuidedRest() async {
    final current = session;
    if (current == null) return;
    final controller = TextEditingController(
      text: '${current.restRemainingAt(DateTime.now())}',
    );
    String? validation;
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Время отдыха'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Секунды',
                  errorText: validation,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 5,
                runSpacing: 2,
                children: [
                  for (final seconds in [15, 60, 90, 120, 180])
                    ActionChip(
                      label: Text(gymClock(seconds)),
                      onPressed: () => controller.text = '$seconds',
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text('От 0 до 7200 секунд.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final seconds = int.tryParse(controller.text.trim());
                if (seconds == null || seconds < 0 || seconds > 7200) {
                  update(() => validation = 'Укажи число от 0 до 7200');
                } else {
                  Navigator.pop(ctx, seconds);
                }
              },
              child: const Text('Применить'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    notified = false;
    await _mutate((s) {
      final at = DateTime.now();
      final paused = s.restPausedSeconds != null;
      s.startRest(
        at,
        value,
        s.restLabel,
        isTransition: s.restIsTransition,
        blockId: s.restBlockId,
      );
      if (paused) s.pauseRest(at);
    });
  }

  Future<void> _set(GymBlock block, GymExercise exercise, int index) async {
    final old = exercise.setAt(index);
    GymSet? latest;
    try {
      final candidates =
          _readSessions(store)
              .expand((s) => s.allSets)
              .where(
                (set) =>
                    set.exerciseName == (old?.exerciseName ?? exercise.name),
              )
              .toList()
            ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
      if (candidates.isNotEmpty) latest = candidates.first;
    } catch (_) {
      /* A missing history hint must never block recording. */
    }
    final result = await showDialog<_SetDialogResult>(
      context: context,
      builder: (_) => _SetDialog(
        exercise: exercise,
        index: index,
        previous: old,
        latest: latest,
      ),
    );
    if (result == null || !mounted) return;
    await _mutate((s) {
      final e = s.exercise(block.id, exercise.id);
      e.sets.removeWhere((v) => v.index == index);
      if (result.set != null) e.sets.add(result.set!);
      e.sets.sort((a, b) => a.index.compareTo(b.index));
    });
  }

  Future<void> _replace(GymBlock block, GymExercise exercise) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _ReplaceDialog(exercise: exercise),
    );
    if (name == null || !mounted || name == exercise.name) return;
    await _mutate((s) => s.exercise(block.id, exercise.id).name = name);
  }

  Future<void> _configure(GymBlock block, GymExercise exercise) async {
    final result = await showDialog<_ExerciseEdit>(
      context: context,
      builder: (_) => _ExerciseDialog(existing: exercise),
    );
    if (result == null || !mounted) return;
    await _mutate((s) {
      final e = s.exercise(block.id, exercise.id);
      e.plannedSets = result.sets;
      e.target = result.target;
      e.targets = [];
      e.timed = result.timed;
    });
  }

  Future<void> _addExercise(GymBlock? block) async {
    final result = await showDialog<_ExerciseEdit>(
      context: context,
      builder: (_) => const _ExerciseDialog(),
    );
    if (result == null || !mounted) return;
    final exercise = GymExercise(
      id: newId(),
      name: result.name,
      plannedSets: result.sets,
      target: result.target,
      timed: result.timed,
    );
    await _mutate((s) {
      if (block == null) {
        s.blocks.add(
          GymBlock(
            id: newId(),
            title: 'Дополнительный блок',
            restMinSeconds: 90,
            restMaxSeconds: 90,
            exercises: [exercise],
          ),
        );
      } else {
        s.block(block.id).exercises.add(exercise);
      }
    });
  }

  Future<void> _removeExercise(GymBlock block, GymExercise exercise) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить упражнение?'),
        content: Text(
          '«${exercise.name}» будет удалено только из этого занятия.${exercise.sets.isEmpty ? '' : ' Записанных подходов: ${exercise.sets.length} — они тоже удалятся.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _mutate((s) {
      final b = s.block(block.id);
      b.exercises.removeWhere((e) => e.id == exercise.id);
      if (b.exercises.isEmpty) s.blocks.removeWhere((b) => b.id == block.id);
    });
  }

  Future<void> _rest(GymBlock block) async {
    if (session == null || session!.completed) return;
    if ((session!.restDeadline != null || session!.restPausedSeconds != null) &&
        session!.restRemainingAt(DateTime.now()) > 0) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Заменить работающий таймер?'),
          content: const Text('Текущий отдых будет остановлен.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Нет'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Запустить новый'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    notified = false;
    final ok = await _mutate(
      (s) => s.startRest(
        DateTime.now(),
        block.restMaxSeconds,
        block.title,
        blockId: block.id,
      ),
    );
    if (ok && mounted) setState(() => showOverview = false);
  }

  Future<void> _restSettings(GymBlock block) async {
    final controller = TextEditingController(text: '${block.restMaxSeconds}');
    final seconds = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отдых после блока'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Секунды, от 0 до 7200'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text.trim());
              if (n != null && n >= 0 && n <= 7200) Navigator.pop(ctx, n);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (seconds == null || !mounted) return;
    await _mutate((s) {
      final b = s.block(block.id);
      b.restMinSeconds = seconds;
      b.restMaxSeconds = seconds;
    });
  }

  Future<void> _startIntervals() async {
    if (session?.intervalBaseSeconds != null) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Запустить интервалы заново?'),
          content: const Text(
            'Текущий интервальный таймер сбросится; записанные результаты останутся.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Запустить'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    intervalPhase = null;
    await _mutate((s) {
      final t = DateTime.now();
      if (!s.running) s.resumeSession(t);
      s.startIntervals(t);
    });
  }

  Future<void> _cardio([GymCardio? existing]) async {
    final c = await showDialog<_CardioResult>(
      context: context,
      builder: (_) => _CardioDialog(previous: existing),
    );
    if (c == null || !mounted) return;
    await _mutate((s) {
      if (existing != null) s.cardio.removeWhere((v) => v.id == existing.id);
      if (c.cardio != null) s.cardio.add(c.cardio!);
    });
  }

  Future<void> _finish() async {
    final s = session;
    if (s == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Завершить занятие?'),
        content: Text(
          'Подходов: ${s.setCount}; кардио: ${s.cardio.length}. Время: ${gymClock(s.elapsedAt(DateTime.now()))}. '
          'Запись останется доступной для исправлений. Калории и цели питания не изменятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Продолжить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await _mutate((s) => s.finish(DateTime.now()));
    if (ok && mounted) _message('Занятие сохранено в истории.');
  }

  Future<void> _deleteSession() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить это занятие?'),
        content: const Text(
          'Будут удалены все подходы и кардио этого занятия. Остальные записи дневника не изменятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted || busy) return;
    setState(() => busy = true);
    try {
      await store.writeGymDocument(key, raw, null);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        _message('Запись изменилась или не удалена. Обновите экран.');
        await _load();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _note() async {
    final controller = TextEditingController(text: session?.note ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Заметка к занятию'),
        content: TextField(
          controller: controller,
          maxLength: 1000,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Самочувствие, техника, условия…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && mounted) await _mutate((s) => s.note = value);
  }

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s != null && error == null && !s.completed && !showOverview) {
      final hasRest = s.restDeadline != null || s.restPausedSeconds != null;
      final next = _focusedStep(s);
      if (hasRest) {
        GymBlock? source;
        for (final block in s.blocks) {
          if (block.id == s.restBlockId ||
              (s.restBlockId == null && block.title == s.restLabel)) {
            source = block;
            break;
          }
        }
        final restBlock = source;
        return GymRestScreen(
          session: s,
          next: next,
          now: now,
          busy: busy,
          onOverview: () => setState(() => showOverview = true),
          onAdjustDown: () => _mutate((x) => x.adjustRest(DateTime.now(), -15)),
          onAdjustUp: () {
            notified = false;
            _mutate((x) => x.adjustRest(DateTime.now(), 15));
          },
          onPauseResume: () => _mutate((x) {
            if (x.restDeadline != null) {
              x.pauseRest(DateTime.now());
            } else {
              x.resumeRest(DateTime.now());
            }
          }),
          onEditTime: _editGuidedRest,
          onSkip: () => _mutate((x) => x.clearRest()),
          onFullRest: restBlock == null
              ? null
              : () {
                  notified = false;
                  _mutate(
                    (x) => x.startRest(
                      DateTime.now(),
                      restBlock.restMaxSeconds,
                      restBlock.title,
                      blockId: restBlock.id,
                    ),
                  );
                },
        );
      }
      if (next != null) {
        return GymGuidedExerciseScreen(
          key: ValueKey(
            '${s.id}:${next.block.id}:${next.exercise.id}:${next.index}:${next.exercise.name}',
          ),
          session: s,
          step: next,
          latest: _latestFor(next.exercise.name),
          now: now,
          busy: busy,
          onSave: (set) => _saveGuided(next, set),
          onOverview: () => setState(() => showOverview = true),
          onReplace: () => _replace(next.block, next.exercise),
        );
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          s?.title ?? 'Занятие',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (s != null &&
              !s.completed &&
              (_focusedStep(s) != null ||
                  s.restDeadline != null ||
                  s.restPausedSeconds != null))
            IconButton(
              tooltip: 'Вернуться к тренировке',
              onPressed: busy
                  ? null
                  : () => setState(() => showOverview = false),
              icon: const Icon(Icons.play_circle_outline_rounded),
            ),
          IconButton(
            tooltip: 'Обновить запись',
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') _deleteSession();
              if (v == 'note') _note();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'note', child: Text('Заметка')),
              PopupMenuItem(value: 'delete', child: Text('Удалить занятие')),
            ],
          ),
        ],
      ),
      body: error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(error!),
              ),
            )
          : s == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _sessionHeader(s),
                if (showOverview &&
                    !s.completed &&
                    (_focusedStep(s) != null ||
                        s.restDeadline != null ||
                        s.restPausedSeconds != null))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: busy
                            ? null
                            : () => setState(() => showOverview = false),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          s.restDeadline != null || s.restPausedSeconds != null
                              ? 'Вернуться к таймеру'
                              : 'Продолжить по шагам',
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    children: [
                      Card(
                        child: ExpansionTile(
                          title: const Text('Разминка и правила'),
                          subtitle: Text(
                            s.warmup,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          childrenPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            16,
                          ),
                          children: [
                            Text(s.warmup),
                            const SizedBox(height: 8),
                            const Text(gymPairGuidance),
                            const SizedBox(height: 8),
                            const Text(gymSafetyGuidance),
                          ],
                        ),
                      ),
                      for (final block in s.blocks) _blockCard(s, block),
                      OutlinedButton.icon(
                        onPressed: busy ? null : () => _addExercise(null),
                        icon: const Icon(Icons.add),
                        label: const Text('Добавить свой блок'),
                      ),
                      const SizedBox(height: 12),
                      _cardioCard(s),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Итоги занятия',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                'Подходов: ${s.setCount} · известных повторений: ${s.knownReps}.',
                              ),
                              Text(
                                'Известный объём внешнего веса: ${gymNumber(s.externalVolumeKg)} кг по ${s.volumeRows.length} подходам. Не включает вес тела и помощь; пустой вес не считается нулём.',
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (s.note.isNotEmpty)
                        Card(
                          child: ListTile(
                            title: const Text('Заметка'),
                            subtitle: Text(s.note),
                            onTap: _note,
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        'Результаты и таймер сохраняются на устройстве. Продолжительность и результаты не превращаются в калории автоматически.',
                      ),
                    ],
                  ),
                ),
                _sessionActions(s),
              ],
            ),
    );
  }

  Widget _sessionHeader(GymSession s) {
    final hasRest = s.restDeadline != null || s.restPausedSeconds != null;
    final remaining = s.restRemainingAt(now);
    final interval = s.intervalElapsedAt(now);
    final phaseSeconds = interval == null ? 0 : interval % 180;
    final faster = phaseSeconds < 60;
    final intervalRemaining = interval == null || interval >= 1440
        ? 0
        : (faster ? 60 - phaseSeconds : 180 - phaseSeconds);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${s.completed
                        ? 'Завершено'
                        : s.running
                        ? 'Занятие идёт'
                        : 'Занятие на паузе'} · ${gymClock(s.elapsedAt(now))}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('${s.setCount} подх.'),
              ],
            ),
            if (hasRest) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.timer_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      remaining == 0
                          ? 'Отдых завершён · ${s.restLabel}'
                          : 'Отдых ${gymClock(remaining)} · ${s.restLabel}${s.restPausedSeconds != null ? ' · пауза' : ''}',
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : () =>
                              _mutate((x) => x.adjustRest(DateTime.now(), -15)),
                    child: const Text('−15 с'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            notified = false;
                            _mutate((x) => x.adjustRest(DateTime.now(), 15));
                          },
                    child: const Text('+15 с'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _mutate((x) {
                            if (x.restDeadline != null) {
                              x.pauseRest(DateTime.now());
                            } else {
                              x.resumeRest(DateTime.now());
                            }
                          }),
                    child: Text(
                      s.restDeadline != null ? 'Пауза' : 'Продолжить',
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _mutate((x) => x.clearRest()),
                    child: const Text('Стоп'),
                  ),
                ],
              ),
              const Text(
                'При блокировке телефона звук может не прозвучать; время обновится при возвращении.',
                style: TextStyle(fontSize: 11),
              ),
            ],
            if (interval != null) ...[
              const SizedBox(height: 6),
              Text(
                interval >= 1440
                    ? 'Интервалы завершены'
                    : 'Интервал ${interval ~/ 180 + 1}/8 · ${faster ? 'быстрее' : 'медленнее'} · ${gymClock(intervalRemaining)}${s.intervalResumedAt == null ? ' · пауза' : ''}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Wrap(
                spacing: 4,
                children: [
                  if (interval < 1440 && !s.completed)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _mutate((x) {
                              final t = DateTime.now();
                              if (x.intervalResumedAt != null) {
                                x.pauseIntervals(t);
                              } else {
                                if (!x.running) x.resumeSession(t);
                                x.resumeIntervals(t);
                              }
                            }),
                      child: Text(
                        s.intervalResumedAt == null
                            ? 'Продолжить интервалы'
                            : 'Пауза интервалов',
                      ),
                    ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _mutate((x) => x.clearIntervals()),
                    child: const Text('Закрыть интервалы'),
                  ),
                ],
              ),
              if (!hasRest)
                const Text(
                  'На заблокированном телефоне звук может не прозвучать.',
                  style: TextStyle(fontSize: 11),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sessionActions(GymSession s) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          if (!s.completed) ...[
            Expanded(
              child: OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _mutate((x) {
                        if (x.running) {
                          x.pauseSession(DateTime.now());
                        } else {
                          x.resumeSession(DateTime.now());
                        }
                      }),
                child: Text(s.running ? 'Пауза занятия' : 'Продолжить'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: busy ? null : _finish,
                child: const Text('Завершить'),
              ),
            ),
          ] else
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => _mutate((x) => x.reopen(DateTime.now())),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Вернуть в работу'),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _blockCard(GymSession s, GymBlock block) {
    final next = block.nextExercise(), round = block.nextRound();
    return Card(
      child: ExpansionTile(
        key: PageStorageKey('gym-${s.id}-${block.id}'),
        initiallyExpanded: s.blocks.first == block && !block.optional,
        title: Text(block.title),
        subtitle: Text(
          next == null
              ? 'Плановые подходы записаны${block.optional ? ' · необязательно' : ''}'
              : 'Далее: круг $round · ${next.id} ${next.name}${block.optional ? ' · по желанию' : ''}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (block.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(block.note),
            ),
          for (final e in block.exercises) _exerciseCard(block, e),
          Wrap(
            spacing: 6,
            children: [
              if (!s.completed)
                FilledButton.tonalIcon(
                  onPressed: busy ? null : () => _rest(block),
                  icon: const Icon(Icons.timer_outlined),
                  label: Text('Отдых ${gymClock(block.restMaxSeconds)}'),
                ),
              TextButton(
                onPressed: busy ? null : () => _restSettings(block),
                child: const Text('Время отдыха'),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => _addExercise(block),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Упражнение'),
              ),
            ],
          ),
          Text(
            '${block.exercises.length > 1 ? 'Отдых после пары' : 'Отдых между подходами'}: ${_restRange(block)}. Переход к следующему блоку входит в этот отдых.',
          ),
        ],
      ),
    );
  }

  Widget _exerciseCard(GymBlock block, GymExercise e) {
    final maxIndex = e.sets.fold<int>(
      e.plannedSets,
      (n, row) => math.max(n, row.index),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${e.id} · ${e.name}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Настроить упражнение',
                onSelected: (v) {
                  if (v == 'replace') _replace(block, e);
                  if (v == 'configure') _configure(block, e);
                  if (v == 'delete') _removeExercise(block, e);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'replace',
                    child: Text('Заменить упражнение'),
                  ),
                  PopupMenuItem(
                    value: 'configure',
                    child: Text('Изменить план подходов'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Удалить из занятия'),
                  ),
                ],
              ),
            ],
          ),
          Text(
            'План: ${e.plannedSets} × ${e.targets.isNotEmpty
                ? e.targets.join(' / ')
                : e.target.isEmpty
                ? 'по самочувствию'
                : e.target}',
          ),
          if (e.sets.any((v) => v.exerciseName != e.name))
            const Text(
              'Ранее записанные подходы сохраняют прежнее название.',
              style: TextStyle(fontSize: 12),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 1; i <= maxIndex; i++)
                (() {
                  final row = e.setAt(i);
                  return OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () {
                            if (row == null && !session!.completed) {
                              _selectGuided(block, e, i);
                            } else {
                              _set(block, e, i);
                            }
                          },
                    icon: Icon(row == null ? Icons.add : Icons.check, size: 17),
                    label: Text(
                      row == null
                          ? 'Подход $i${e.targetFor(i).isNotEmpty ? ' · ${e.targetFor(i)}' : ''}'
                          : '$i · ${_setResult(row)}',
                    ),
                  );
                })(),
              if (maxIndex < 100)
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () {
                          if (session!.completed) {
                            _set(block, e, maxIndex + 1);
                          } else {
                            _selectGuided(block, e, maxIndex + 1);
                          }
                        },
                  icon: const Icon(Icons.add, size: 17),
                  label: const Text('Ещё подход'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cardioCard(GymSession s) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Кардио', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            s.cardioPlan.isEmpty
                ? 'При желании запиши фактически выполненное кардио.'
                : s.cardioPlan,
          ),
          const SizedBox(height: 8),
          if (s.planDay == 'sat' && !s.completed) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : _startIntervals,
              icon: const Icon(Icons.timer_outlined),
              label: const Text('Интервалы: 8 × 1/2 мин'),
            ),
            const Text(
              'Таймер не записывает кардио сам: внеси фактическое время ниже.',
            ),
          ],
          for (final c in s.cardio)
            ListTile(
              contentPadding: EdgeInsets.zero,
              onTap: () => _cardio(c),
              title: Text('${c.type} · ${gymNumber(c.minutes)} мин'),
              subtitle: Text(
                [
                  if (c.distanceKm != null) '${gymNumber(c.distanceKm!)} км',
                  if (c.speed != null) 'скорость ${gymNumber(c.speed!)}',
                  if (c.incline != null) 'наклон ${gymNumber(c.incline!)}',
                  if (c.note.isNotEmpty) c.note,
                ].join(' · '),
              ),
              trailing: const Icon(Icons.edit_outlined),
            ),
          OutlinedButton.icon(
            onPressed: busy ? null : () => _cardio(),
            icon: const Icon(Icons.add),
            label: const Text('Записать кардио'),
          ),
        ],
      ),
    ),
  );
}

class _SetDialogResult {
  final GymSet? set;
  const _SetDialogResult(this.set);
}

class _SetDialog extends StatefulWidget {
  final GymExercise exercise;
  final int index;
  final GymSet? previous, latest;
  final bool allowDate;
  const _SetDialog({
    required this.exercise,
    required this.index,
    this.previous,
    this.latest,
    this.allowDate = false,
  });
  @override
  State<_SetDialog> createState() => _SetDialogState();
}

class _SetDialogState extends State<_SetDialog> {
  late final TextEditingController reps, seconds, weight, rir, note;
  late String mode;
  late bool isTest;
  late DateTime recorded;
  String? error;
  String get actualName =>
      widget.previous?.exerciseName ?? widget.exercise.name;
  bool get pullup => isPullupName(actualName);
  @override
  void initState() {
    super.initState();
    final s = widget.previous;
    reps = TextEditingController(text: s?.reps?.toString() ?? '');
    seconds = TextEditingController(text: s?.seconds?.toString() ?? '');
    weight = TextEditingController(
      text: s?.weightKg == null ? '' : gymNumber(s!.weightKg!),
    );
    rir = TextEditingController(text: s?.rir?.toString() ?? '');
    note = TextEditingController(text: s?.note ?? '');
    mode = s?.pullupMode ?? 'unknown';
    isTest = s?.isTest ?? widget.exercise.isTest;
    recorded = s?.recordedAt ?? DateTime.now();
  }

  @override
  void dispose() {
    reps.dispose();
    seconds.dispose();
    weight.dispose();
    rir.dispose();
    note.dispose();
    super.dispose();
  }

  int? _integerField(String value) {
    if (value.trim().isEmpty) return null;
    final n = int.tryParse(value.trim());
    if (n == null) throw const FormatException('Укажите целое число.');
    return n;
  }

  double? _weight() {
    if (pullup && mode == 'bodyweight') return 0;
    if (weight.text.trim().isEmpty) return null;
    final n = double.tryParse(weight.text.trim().replaceAll(',', '.'));
    if (n == null || !n.isFinite) throw const FormatException('Проверьте вес.');
    return n;
  }

  Future<void> _datePicker() async {
    final d = await showDatePicker(
      context: context,
      initialDate: recorded,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'Когда выполнен подход?',
    );
    if (d != null && mounted)
      setState(() {
        final now = DateTime.now();
        recorded =
            d.year == now.year && d.month == now.month && d.day == now.day
            ? now
            : DateTime(d.year, d.month, d.day, 12);
      });
  }

  void _save() {
    try {
      final data = {
        'index': widget.index,
        'recordedAt': recorded.toUtc().toIso8601String(),
        'exerciseName': actualName,
        'reps': _integerField(reps.text),
        'seconds': _integerField(seconds.text),
        'weightKg': _weight(),
        'rir': _integerField(rir.text),
        'pullupMode': pullup ? mode : 'unknown',
        'isTest': pullup && isTest,
        'note': note.text.trim(),
      };
      final set = GymSet.fromJson(data);
      Navigator.pop(context, _SetDialogResult(set));
    } catch (e) {
      setState(
        () => error = e is FormatException
            ? e.message
            : 'Проверьте значения подхода.',
      );
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить подход?'),
        content: const Text(
          'Данные этого подхода будут удалены; остальные результаты останутся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (yes == true && mounted)
      Navigator.pop(context, const _SetDialogResult(null));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.index} · $actualName'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.exercise.targetFor(widget.index).isNotEmpty)
            Text(
              'План: ${widget.exercise.targetFor(widget.index)}. Запиши фактическое значение.',
            ),
          if (widget.latest != null)
            Text(
              'Последняя запись: ${_setResult(widget.latest!)} · ${gymDate(widget.latest!.recordedAt)}. Значения не подставляются автоматически.',
            ),
          if (widget.allowDate)
            TextButton.icon(
              onPressed: _datePicker,
              icon: const Icon(Icons.calendar_today),
              label: Text('Дата: ${gymDate(recorded)}'),
            ),
          TextField(
            controller: reps,
            autofocus: !widget.exercise.timed,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Повторения',
              hintText: 'Неизвестно — оставь пустым',
            ),
          ),
          TextField(
            controller: seconds,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Время подхода, сек (необ.)',
            ),
          ),
          if (pullup)
            DropdownButtonFormField<String>(
              initialValue: mode,
              decoration: const InputDecoration(
                labelText: 'Вариант подтягиваний',
              ),
              items: const [
                DropdownMenuItem(value: 'unknown', child: Text('Не указан')),
                DropdownMenuItem(
                  value: 'bodyweight',
                  child: Text('Собственный вес'),
                ),
                DropdownMenuItem(
                  value: 'weighted',
                  child: Text('Дополнительный вес'),
                ),
                DropdownMenuItem(
                  value: 'assisted',
                  child: Text('С помощью / гравитрон'),
                ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => mode = v);
              },
            ),
          if (!pullup || mode != 'bodyweight')
            TextField(
              controller: weight,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: false,
              ),
              decoration: InputDecoration(
                labelText: pullup && mode == 'assisted'
                    ? 'Помощь, кг (необ.)'
                    : 'Внешний вес, кг (необ.)',
                hintText: 'Пусто — неизвестно; 0 — без веса',
              ),
            ),
          if (pullup && mode == 'bodyweight')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Без дополнительного веса.'),
            ),
          TextField(
            controller: rir,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Запас повторений (необ.)',
            ),
          ),
          TextField(
            controller: note,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Заметка (необ.)'),
          ),
          if (pullup)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: isTest,
              title: const Text('Технический тест'),
              subtitle: const Text(
                'Только чистые повторения; остановись при боли.',
              ),
              onChanged: (v) => setState(() => isTest = v),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      if (widget.previous != null)
        TextButton(onPressed: _delete, child: const Text('Удалить')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _save, child: const Text('Сохранить подход')),
    ],
  );
}

class _ExerciseEdit {
  final String name, target;
  final int sets;
  final bool timed;
  const _ExerciseEdit(this.name, this.target, this.sets, this.timed);
}

class _ExerciseDialog extends StatefulWidget {
  final GymExercise? existing;
  const _ExerciseDialog({this.existing});
  @override
  State<_ExerciseDialog> createState() => _ExerciseDialogState();
}

class _ExerciseDialogState extends State<_ExerciseDialog> {
  late final TextEditingController name, count, target;
  late bool timed;
  String? error;
  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    name = TextEditingController(text: e?.name ?? '');
    count = TextEditingController(text: '${e?.plannedSets ?? 3}');
    target = TextEditingController(text: e?.target ?? '');
    timed = e?.timed ?? false;
  }

  @override
  void dispose() {
    name.dispose();
    count.dispose();
    target.dispose();
    super.dispose();
  }

  void _save() {
    final n = int.tryParse(count.text.trim());
    if (name.text.trim().isEmpty ||
        name.text.trim().length > 120 ||
        n == null ||
        n < 1 ||
        n > 50 ||
        target.text.length > 120) {
      setState(() => error = 'Укажи название и от 1 до 50 подходов.');
      return;
    }
    Navigator.pop(
      context,
      _ExerciseEdit(name.text.trim(), target.text.trim(), n, timed),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'Новое упражнение' : 'План подходов'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.existing == null)
            TextField(
              controller: name,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
          TextField(
            controller: count,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Планируемых подходов',
            ),
          ),
          TextField(
            controller: target,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Цель / повторения (необ.)',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: timed,
            onChanged: (v) => setState(() => timed = v),
            title: const Text('Упражнение на время'),
          ),
          if (widget.existing != null)
            const Text(
              'Изменение только для этого занятия. Уже записанные подходы останутся.',
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _save, child: const Text('Сохранить')),
    ],
  );
}

class _ReplaceDialog extends StatefulWidget {
  final GymExercise exercise;
  const _ReplaceDialog({required this.exercise});
  @override
  State<_ReplaceDialog> createState() => _ReplaceDialogState();
}

class _ReplaceDialogState extends State<_ReplaceDialog> {
  final custom = TextEditingController();
  String? error;
  @override
  void dispose() {
    custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.exercise;
    final names = <String>{e.originalName, ...e.alternatives};
    return AlertDialog(
      title: const Text('Замена упражнения'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Записанные ранее подходы сохранят своё название. Замена действует только в этом занятии.',
            ),
            for (final name in names)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(name),
                trailing: name == e.name ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, name),
              ),
            TextField(
              controller: custom,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Или своё название'),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final value = custom.text.trim();
            if (value.isEmpty) {
              setState(() => error = 'Укажите название.');
              return;
            }
            Navigator.pop(context, value);
          },
          child: const Text('Выбрать своё'),
        ),
      ],
    );
  }
}

class _CardioResult {
  final GymCardio? cardio;
  const _CardioResult(this.cardio);
}

class _CardioDialog extends StatefulWidget {
  final GymCardio? previous;
  const _CardioDialog({this.previous});
  @override
  State<_CardioDialog> createState() => _CardioDialogState();
}

class _CardioDialogState extends State<_CardioDialog> {
  late final TextEditingController type,
      minutes,
      distance,
      speed,
      incline,
      note;
  String? error;
  @override
  void initState() {
    super.initState();
    final c = widget.previous;
    type = TextEditingController(text: c?.type ?? '');
    minutes = TextEditingController(
      text: c == null ? '' : gymNumber(c.minutes),
    );
    distance = TextEditingController(
      text: c?.distanceKm == null ? '' : gymNumber(c!.distanceKm!),
    );
    speed = TextEditingController(
      text: c?.speed == null ? '' : gymNumber(c!.speed!),
    );
    incline = TextEditingController(
      text: c?.incline == null ? '' : gymNumber(c!.incline!),
    );
    note = TextEditingController(text: c?.note ?? '');
  }

  @override
  void dispose() {
    type.dispose();
    minutes.dispose();
    distance.dispose();
    speed.dispose();
    incline.dispose();
    note.dispose();
    super.dispose();
  }

  double? _number(String value) {
    if (value.trim().isEmpty) return null;
    final n = double.tryParse(value.trim().replaceAll(',', '.'));
    if (n == null || !n.isFinite)
      throw const FormatException('Проверьте числа кардио.');
    return n;
  }

  void _save() {
    try {
      final c = GymCardio.fromJson({
        'id': widget.previous?.id ?? newId(),
        'type': type.text.trim(),
        'recordedAt': (widget.previous?.recordedAt ?? DateTime.now())
            .toUtc()
            .toIso8601String(),
        'minutes': _number(minutes.text),
        'distanceKm': _number(distance.text),
        'speed': _number(speed.text),
        'incline': _number(incline.text),
        'note': note.text.trim(),
      });
      Navigator.pop(context, _CardioResult(c));
    } catch (e) {
      setState(
        () => error = e is FormatException ? e.message : 'Проверьте кардио.',
      );
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить кардио?'),
        content: const Text('Остальные результаты занятия останутся.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (yes == true && mounted)
      Navigator.pop(context, const _CardioResult(null));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.previous == null ? 'Записать кардио' : 'Изменить кардио',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: type,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Вид кардио',
              hintText: 'Ходьба, интервалы, велосипед…',
            ),
          ),
          TextField(
            controller: minutes,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Минуты'),
          ),
          TextField(
            controller: distance,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Дистанция, км (необ.)',
            ),
          ),
          TextField(
            controller: speed,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Скорость на тренажёре (необ.)',
            ),
          ),
          TextField(
            controller: incline,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              labelText: 'Наклон на тренажёре (необ.)',
            ),
          ),
          TextField(
            controller: note,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Заметка (необ.)'),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      if (widget.previous != null)
        TextButton(onPressed: _delete, child: const Text('Удалить')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _save, child: const Text('Сохранить')),
    ],
  );
}
