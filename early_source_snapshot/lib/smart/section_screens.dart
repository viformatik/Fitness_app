import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../legacy.dart';
import 'gym_models.dart' show GymExercise;
import 'gym_calendar.dart';
import 'gym_exercise_history.dart';
import 'gym_exercise_history_ui.dart';
import 'gym_plan.dart';
import 'gym_ui.dart' show GymSessionScreen;
import 'sleep.dart';
import 'sleep_ui.dart' show SleepDayCard;
import 'home_simple.dart' show showQuickActivityActions;
import 'ui.dart' show AiChatScreen, DaySlider;
import 'workout_ui.dart' show showWorkoutEditor;

/// Exercises from the existing plan plus names already saved in gym sessions.
/// The projection is read-only; it neither creates a parallel data store nor
/// claims to be a separately editable personal exercise library.
class PlanExercisesScreen extends StatefulWidget {
  final VoidCallback openTraining;
  const PlanExercisesScreen({super.key, required this.openTraining});

  @override
  State<PlanExercisesScreen> createState() => _PlanExercisesScreenState();
}

enum _ExerciseFilter { all, plan, sessions }

class _PlanExercisesScreenState extends State<PlanExercisesScreen> {
  final query = TextEditingController();
  late final List<_PlanExercise> items = _planExercises();
  _ExerciseFilter filter = _ExerciseFilter.all;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppDataProvider>();
    final history = readExerciseHistory(provider.storage.local);
    final merged = <String, _ExerciseViewItem>{};
    for (final plan in items) {
      final key = exerciseHistoryKey(plan.exercise.name);
      merged[key] = _ExerciseViewItem(plan, history.byName[key]);
    }
    for (final entry in history.byName.entries) {
      merged.putIfAbsent(entry.key, () => _ExerciseViewItem(null, entry.value));
    }
    final text = _searchName(query.text);
    final visible = merged.values.where((item) {
      if (filter == _ExerciseFilter.plan && item.plan == null) return false;
      if (filter == _ExerciseFilter.sessions && item.history == null)
        return false;
      final haystack = _searchName(
        [
          item.name,
          if (item.history != null) item.history!.name,
          if (item.plan != null) ...item.plan!.alternatives,
        ].join(' '),
      );
      return text.isEmpty || haystack.contains(text);
    }).toList()..sort((a, b) => a.name.compareTo(b.name));

    return CenteredBody(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        itemCount: visible.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Упражнения программы',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Программа и названия из сохранённых занятий. Своё упражнение можно '
                  'добавить внутри тренировки — оно появится здесь. Отдельный '
                  'редактор личной библиотеки пока не создан.',
                ),
                if (history.unreadable > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Не удалось прочитать занятий: ${history.unreadable}. '
                    'Список может быть неполным; записи не изменены.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: query,
                  decoration: const InputDecoration(
                    labelText: 'Найти упражнение',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: widget.openTraining,
                  icon: const Icon(Icons.fitness_center_outlined),
                  label: const Text('Открыть программу тренировок'),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final choice in _ExerciseFilter.values)
                      ChoiceChip(
                        label: Text(switch (choice) {
                          _ExerciseFilter.all => 'Все',
                          _ExerciseFilter.plan => 'Из программы',
                          _ExerciseFilter.sessions => 'Из занятий',
                        }),
                        selected: filter == choice,
                        onSelected: (_) => setState(() => filter = choice),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (visible.isEmpty) const Text('Упражнения не найдены.'),
              ],
            );
          }
          final item = visible[index - 1];
          final plan = item.plan;
          final saved = item.history;
          final subtitle = <String>[
            if (plan != null) 'Дни программы: ${plan.days.join(', ')}',
            if (plan == null) 'Название из занятий',
            if (saved != null && saved.recordedSets > 0)
              'Записано подходов: ${saved.recordedSets}',
            if (saved != null && saved.recordedSets == 0)
              'Подходы пока не записаны',
          ];
          return Card(
            child: ExpansionTile(
              key: PageStorageKey(
                'plan-exercise-${exerciseHistoryKey(item.name)}',
              ),
              title: Text(item.name),
              subtitle: Text(subtitle.join(' · ')),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                if (plan != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      plan.alternatives.isEmpty
                          ? 'Замены в плане не указаны.'
                          : 'Замены: ${plan.alternatives.join(', ')}',
                    ),
                  ),
                if (saved == null)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'В доступных занятиях подходы с этим названием не найдены.',
                    ),
                  )
                else ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      saved.recordedSets == 0
                          ? 'Упражнение есть в занятиях, но подходы ещё не записаны.'
                          : 'Подходы записаны в занятиях: ${saved.sessionsWithSets}.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => GymExerciseHistoryScreen(
                          provider: provider,
                          exerciseKey: saved.key,
                          initialName: item.name,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.history),
                    label: const Text('История подходов'),
                  ),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => AiChatScreen(
                        initialQuestion:
                            'Как безопасно выполнять упражнение «${item.name}»? Объясни технику и типичные ошибки.',
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Спросить ИИ об упражнении'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _searchName(String value) =>
    value.trim().toLowerCase().replaceAll('ё', 'е');

class _ExerciseViewItem {
  final _PlanExercise? plan;
  final ExerciseHistoryItem? history;
  const _ExerciseViewItem(this.plan, this.history);
  String get name => plan?.exercise.name ?? history!.name;
}

class _PlanExercise {
  final GymExercise exercise;
  final Set<String> days;
  final Set<String> alternatives = <String>{};
  _PlanExercise(this.exercise, this.days);
}

List<_PlanExercise> _planExercises() {
  final byName = <String, _PlanExercise>{};
  for (final day in gymPlan()) {
    for (final block in day.blocks) {
      for (final exercise in block.exercises) {
        final key = exerciseHistoryKey(exercise.name);
        if (key.isEmpty) continue;
        final item = byName.putIfAbsent(
          key,
          () => _PlanExercise(exercise, <String>{}),
        );
        item.days.add(day.shortName);
        item.alternatives.addAll(exercise.alternatives);
      }
    }
  }
  final items = byName.values.toList();
  items.sort((a, b) => a.exercise.name.compareTo(b.exercise.name));
  return items;
}

/// Manual activity only. Missing values are labelled as missing, never zero.
class ManualActivityScreen extends StatelessWidget {
  const ManualActivityScreen({super.key});

  @override
  Widget build(BuildContext context) => Consumer<AppDataProvider>(
    builder: (context, provider, _) {
      final key = dayKey(provider.selectedDate);
      final day = provider.dayLogs
          .where((log) => dayKey(log.date) == key)
          .firstOrNull;
      final hasSteps = day?.hasStepsRecord ?? false;
      final hasWater = day?.hasWaterRecord ?? false;
      return CenteredBody(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          children: [
            Text(
              'Активность',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text('Ручной учёт за выбранный день.'),
            const SizedBox(height: 12),
            DiaryErrorBanner(provider: provider),
            DaySlider(provider: provider),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Шаги: ${hasSteps ? formatNumber(provider.todaySteps) : 'не записаны'}',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Вода: ${hasWater ? '${formatNumber(provider.todayWaterIntake)} мл' : 'не записана'}',
                    ),
                    const SizedBox(height: 8),
                    const Text('Подключение Health пока не поддерживается.'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => showQuickActivityActions(context, provider),
              icon: const Icon(Icons.add),
              label: const Text('Добавить шаги или тренировку'),
            ),
            const SizedBox(height: 8),
            SleepDayCard(provider: provider),
            const SizedBox(height: 20),
            WorkoutSection(
              provider: provider,
              onAddWorkout: () => showWorkoutEditor(context, provider),
            ),
          ],
        ),
      );
    },
  );
}

/// Calendar selection shares the existing diary and gym session documents.
/// Manual workouts and gym records are shown separately because they may
/// describe the same activity; no automatic deduplication is assumed.
class JournalCalendarScreen extends StatelessWidget {
  final VoidCallback openDiary;
  final VoidCallback openTraining;
  final VoidCallback? openActivity;
  const JournalCalendarScreen({
    super.key,
    required this.openDiary,
    required this.openTraining,
    this.openActivity,
  });

  @override
  Widget build(BuildContext context) => Consumer<AppDataProvider>(
    builder: (context, provider, _) {
      final selected = provider.selectedDate;
      final key = dayKey(selected);
      final day = provider.dayLogs
          .where((log) => dayKey(log.date) == key)
          .firstOrNull;
      final hasSteps = day?.hasStepsRecord ?? false;
      final hasWater = day?.hasWaterRecord ?? false;
      final gymIndex = readGymCalendar(provider.storage.local);
      final gymDay = gymIndex.forDate(selected);
      final sleep = readSleepDay(provider.storage.local, selected);
      // Do not hide older or future diary records just because their dates
      // fall outside a hard-coded calendar window.
      var firstYear = 1900;
      var lastYear = DateTime.now().year + 3;
      for (final date in [
        selected,
        ...provider.dayLogs.map((log) => log.date),
        ...gymIndex.sessions.map((session) => session.startedAt.toLocal()),
        ...provider.storage.local
            .getKeys()
            .where((key) => key.startsWith(sleepDayPrefix))
            .map((key) => key.substring(sleepDayPrefix.length))
            .where(validSleepDay)
            .map((day) => DateTime.parse('${day}T12:00:00Z')),
      ]) {
        if (date.year < firstYear) firstYear = date.year;
        if (date.year >= lastYear) lastYear = date.year + 1;
      }
      final first = DateTime(firstYear);
      final last = DateTime(lastYear);
      return CenteredBody(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          children: [
            Text('Календарь', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('Выберите дату, чтобы посмотреть записи дневника.'),
            CalendarDatePicker(
              key: ValueKey(key),
              initialDate: selected,
              firstDate: first,
              lastDate: last,
              onDateChanged: provider.setSelectedDate,
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatDateRu(selected),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      provider.todayFoodEntries.isEmpty
                          ? 'Питание: нет записей'
                          : 'Питание: ${provider.todayFoodEntries.length} записей',
                    ),
                    Text(
                      'Вода: ${hasWater ? '${formatNumber(provider.todayWaterIntake)} мл' : 'не записана'}',
                    ),
                    Text(
                      'Шаги: ${hasSteps ? formatNumber(provider.todaySteps) : 'не записаны'}',
                    ),
                    Text(
                      sleep.unreadable
                          ? 'Сон: запись не удалось прочитать'
                          : sleep.value == null
                          ? 'Сон: не записан'
                          : 'Сон: ${formatSleepMinutes(sleep.value!.minutes)} · вручную',
                    ),
                    Text(
                      provider.todayWorkoutEntries.isEmpty
                          ? 'Ручные тренировки: нет записей'
                          : 'Ручные тренировки: ${provider.todayWorkoutEntries.length}',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      gymDay.isNotEmpty
                          ? 'Записи зала и подтягиваний: ${gymDay.length}'
                          : gymIndex.unreadable == 0
                          ? 'Зал и подтягивания: нет записей'
                          : 'За день нет доступных записей зала; часть истории не прочитана.',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (gymIndex.unreadable > 0)
                      Text(
                        'Не удалось прочитать записей зала: ${gymIndex.unreadable}. Сводка за день может быть неполной; исходные данные не изменены.',
                      ),
                    for (final session in gymDay)
                      ListTile(
                        key: ValueKey('calendar-gym-${session.id}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(session.title),
                        subtitle: Text(
                          'Начало ${TimeOfDay.fromDateTime(session.startedAt.toLocal()).format(context)} · '
                          '${session.completed ? 'завершено' : 'не завершено'} · '
                          'подходов: ${session.setCount} · кардио: ${session.cardioCount}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => GymSessionScreen(
                              provider: provider,
                              sessionId: session.id,
                            ),
                          ),
                        ),
                      ),
                    if (gymDay.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      const Text(
                        'Дата — день начала в часовом поясе устройства. '
                        'Ручные записи и записи зала могут относиться к одному занятию и не суммируются.',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: openDiary,
                  icon: const Icon(Icons.restaurant_menu),
                  label: const Text('Дневник питания'),
                ),
                OutlinedButton.icon(
                  onPressed: openTraining,
                  icon: const Icon(Icons.fitness_center),
                  label: const Text('Тренировки'),
                ),
                if (openActivity != null)
                  OutlinedButton.icon(
                    onPressed: openActivity,
                    icon: const Icon(Icons.bedtime_outlined),
                    label: const Text('Активность и сон'),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
