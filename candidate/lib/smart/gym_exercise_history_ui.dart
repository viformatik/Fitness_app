import 'package:flutter/material.dart';

import '../legacy.dart';
import 'gym_exercise_history.dart';
import 'gym_exercise_progress_ui.dart';
import 'gym_ui.dart' show GymSessionScreen, gymDate;

String _number(num value) =>
    value.toString().replaceFirst(RegExp(r'\.0$'), '').replaceAll('.', ',');

/// Describe only values actually present in the stored set. In particular,
/// assistance is not treated as added weight and an absent weight is not zero.
String describeRecordedExerciseSet(ExerciseHistorySet set) {
  final values = <String>[];
  if (set.reps != null) values.add('${set.reps} повт.');
  if (set.seconds != null) values.add('${set.seconds} с');
  if (set.isPullup) {
    switch (set.pullupMode) {
      case 'bodyweight':
        values.add('свой вес');
      case 'weighted':
        values.add(
          set.weightKg == null
              ? 'дополнительный вес не указан'
              : 'доп. вес ${_number(set.weightKg!)} кг',
        );
      case 'assisted':
        values.add(
          set.weightKg == null
              ? 'помощь, величина не указана'
              : 'помощь ${_number(set.weightKg!)} кг',
        );
      default:
        values.add(
          set.weightKg == null
              ? 'вид и вес не указаны'
              : '${_number(set.weightKg!)} кг, вид не указан',
        );
    }
  } else {
    values.add(
      set.weightKg == null ? 'вес не указан' : '${_number(set.weightKg!)} кг',
    );
  }
  if (set.rir != null) values.add('запас ${set.rir}');
  if (set.isTest) values.add('технический тест');
  return values.join(' · ');
}

String _setDate(DateTime value) {
  final time = value.toLocal();
  return '${gymDate(time)} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

/// Reads the existing local workout documents on each notified change. It does
/// not send history to the AI screen or write a second exercise database.
class GymExerciseHistoryScreen extends StatelessWidget {
  final AppDataProvider provider;
  final String exerciseKey, initialName;
  const GymExerciseHistoryScreen({
    super.key,
    required this.provider,
    required this.exerciseKey,
    required this.initialName,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: provider,
    builder: (context, _) {
      final index = readExerciseHistory(provider.storage.local);
      final exercise = index.byName[exerciseKey];
      final name = exercise?.name ?? initialName;
      final sessions = exercise?.sessions ?? const <ExerciseHistorySession>[];
      return Scaffold(
        appBar: AppBar(
          title: Text(
            'История: $name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: CenteredBody(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: sessions.length + 1,
            itemBuilder: (context, indexInList) {
              if (indexInList == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      exercise == null
                          ? 'Это название больше не найдено в доступных занятиях.'
                          : 'Записано подходов: ${exercise.recordedSets}; занятий с подходами: ${exercise.sessionsWithSets}.',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Показаны сохранённые занятия и подходы этого названия. '
                      'Регистр и лишние пробелы не учитываются; одинаковое название '
                      'не гарантирует одинаковую технику или оборудование. '
                      'Время показано в часовом поясе устройства.',
                    ),
                    if (index.unreadable > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Не удалось прочитать занятий: ${index.unreadable}. '
                        'История может быть неполной; записи не изменены.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (exercise != null) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => showExerciseProgressEstimate(
                          context,
                          provider,
                          exerciseKey,
                        ),
                        icon: const Icon(Icons.query_stats),
                        label: const Text('Оценка прогресса и 1ПМ'),
                      ),
                    ],
                    const SizedBox(height: 10),
                  ],
                );
              }
              final session = sessions[indexInList - 1];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${gymDate(session.startedAt.toLocal())} · ${session.title}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.completed
                            ? 'Занятие завершено'
                            : 'Занятие в процессе',
                      ),
                      if (!session.listedInSession && session.sets.isNotEmpty)
                        const Text(
                          'Подходы записаны под этим названием; текущее название в занятии отличается.',
                        ),
                      if (session.sets.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Упражнение указано в занятии, но подходы с этим названием не записаны.',
                          ),
                        )
                      else
                        for (final set in session.sets)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Подход ${set.index} · ${_setDate(set.recordedAt)}\n'
                              '${describeRecordedExerciseSet(set)}',
                            ),
                          ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => GymSessionScreen(
                              provider: provider,
                              sessionId: session.id,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Открыть занятие'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}
