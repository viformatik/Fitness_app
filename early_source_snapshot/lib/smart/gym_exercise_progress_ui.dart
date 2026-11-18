import 'package:flutter/material.dart';

import '../legacy.dart';
import 'gym_exercise_history.dart';
import 'gym_exercise_progress.dart';
import 'gym_ui.dart' show gymDate;

String _inputWeight(double value) =>
    value.toString().replaceFirst(RegExp(r'\.0$'), '').replaceAll('.', ',');
String _estimate(double value) => value.toStringAsFixed(1).replaceAll('.', ',');

String _relativeDifference(double value) {
  if (value == 0) return '0,0%';
  if (value.abs() < 0.05) return 'меньше 0,1% по модулю';
  final sign = value > 0 ? '+' : '−';
  return '$sign${value.abs().toStringAsFixed(1).replaceAll('.', ',')}%';
}

String _dateTime(DateTime date) {
  final local = date.toLocal();
  return '${gymDate(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Confirmation and results are local and read-only. No workout, target, AI
/// context or estimate is persisted; reread the current documents after the
/// user accepts rather than calculating from a stale route snapshot.
Future<void> showExerciseProgressEstimate(
  BuildContext context,
  AppDataProvider provider,
  String exerciseKey,
) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: const Text('Условная оценка 1ПМ'),
      content: const Text(
        'Формула Эпли приблизительно оценивает вес на одно повторение по '
        'записанному весу и 2–10 повторениям. В каждом из двух последних '
        'подходящих занятий выбирается подход с наибольшей оценкой.\n\n'
        'Исключаются подтягивания, подходы на время, технические тесты и '
        'записи без положительного веса. Продолжайте только если указанный '
        'вес отражает всю поднимаемую нагрузку, а техника, оборудование, '
        'амплитуда и усилие были сопоставимы. Одинаковое название этого '
        'не гарантирует.\n\n'
        'Запас повторений формула не учитывает: лёгкий подход может дать '
        'заниженную оценку. Не доводите подход до отказа ради расчёта.\n\n'
        'Оценка может ошибаться, не является измеренным максимумом или '
        'рекомендацией к нагрузке. Не пробуйте максимальный вес из-за неё.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Показать оценку'),
        ),
      ],
    ),
  );
  if (!context.mounted || agreed != true) return;

  final index = readExerciseHistory(provider.storage.local);
  final item = index.byName[exerciseKey];
  final result = estimateExerciseProgress(item);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: const Text('Приблизительная оценка 1ПМ'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item == null)
            const Text('Это название больше не найдено в доступных занятиях.')
          else if (result.latestOrderUnclear)
            const Text(
              'У нескольких последних подходящих занятий одинаковое время начала. '
              'Их последовательность неизвестна, поэтому сравнение не рассчитано.',
            )
          else if (result.latest == null)
            const Text(
              'Нет подходящих записей. Нужны положительный вес и от 2 до 10 '
              'повторений в одном весовом подходе; отсутствие данных не '
              'означает нулевой результат.',
            )
          else ...[
            _EstimateRow(
              label: 'Последнее подходящее занятие',
              set: result.latest!,
            ),
            const SizedBox(height: 12),
            if (result.previousOrderUnclear)
              const Text(
                'Несколько предыдущих подходящих занятий имеют одинаковое время начала. '
                'Какое было последним, неизвестно; разница не рассчитана.',
              )
            else if (result.previous == null)
              const Text(
                'Предыдущего подходящего занятия в доступной истории нет.',
              )
            else ...[
              _EstimateRow(
                label: 'Предыдущее подходящее занятие',
                set: result.previous!,
              ),
              const SizedBox(height: 12),
              Text(
                'Условная разница оценок: ${_relativeDifference(result.percentageChange!)}.',
                style: Theme.of(dialogContext).textTheme.titleSmall,
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Учтено подходов: ${result.qualifyingSets}; исключено: ${result.excludedSets}. '
              'Подходящих занятий: ${result.qualifyingSessions}.',
            ),
          ],
          if (index.unreadable > 0) ...[
            const SizedBox(height: 12),
            Text(
              'Не удалось прочитать занятий: ${index.unreadable}. '
              'Сравнение может быть неполным; исходные документы не изменены.',
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Оценка по Эпли: вес × (1 + повторения / 30). Это не измеренный '
            'максимум и не инструкция к увеличению нагрузки. Сопоставимость '
            'оборудования и техники автоматически не проверяется. Запас '
            'повторений не учитывается; лёгкий подход может дать заниженную '
            'оценку. Не доводите подход до отказа ради расчёта.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

class _EstimateRow extends StatelessWidget {
  final String label;
  final ExerciseEstimateSet set;
  const _EstimateRow({required this.label, required this.set});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 3),
      Text(
        '${gymDate(set.sessionStartedAt.toLocal())} · ${set.sessionTitle}\n'
        '${set.sessionCompleted ? 'Занятие завершено' : 'Занятие в процессе'}',
      ),
      const SizedBox(height: 3),
      Text(
        'Подход ${set.setIndex} · ${_dateTime(set.recordedAt)}\n'
        '${set.reps} повт. × ${_inputWeight(set.weightKg)} кг → '
        'оценка ${_estimate(set.estimatedOneRepMaxKg)} кг',
      ),
    ],
  );
}
