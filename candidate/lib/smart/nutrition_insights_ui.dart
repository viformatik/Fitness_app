import 'package:flutter/material.dart';

import '../legacy.dart';
import 'nutrition_insights.dart';

String _n(num value) => value
    .toStringAsFixed(1)
    .replaceFirst(RegExp(r'\.0$'), '')
    .replaceAll('.', ',');

String _change(num value) {
  if (value.abs() < 0.05) return '0';
  return '${value > 0 ? '+' : '−'}${_n(value.abs())}';
}

// Portions are shown to two decimal places; calculations keep the original
// floating-point values. Avoid stripping digits from scientific notation.
String _grams(num value) {
  final raw = value.toStringAsFixed(2);
  final compact = raw.contains('e')
      ? raw
      : raw.replaceFirst(RegExp(r'\.?0+$'), '');
  return compact.replaceAll('.', ',');
}

PortionComparison? _visibleSmallerExample(FoodEntry food) {
  final example = futurePortionExamples(food)
      .where((item) => item.kind == PortionExampleKind.smaller)
      .firstOrNull
      ?.comparison;
  // Do not display two identical-looking quantities as a 25% difference.
  if (example == null ||
      _grams(example.hypotheticalGrams) == _grams(example.originalGrams)) {
    return null;
  }
  return example;
}

/// Dashboard tip is deterministic and stays on the device. It never presents
/// a reduction as necessary and never edits already consumed food.
class DailyNutritionTip extends StatelessWidget {
  final NutritionInsights insight;
  final VoidCallback openDetails;
  const DailyNutritionTip({
    super.key,
    required this.insight,
    required this.openDetails,
  });

  @override
  Widget build(BuildContext context) {
    final food = insight.largestEnergyRecords.firstOrNull;
    final example = food == null ? null : _visibleSmallerExample(food);
    final title = insight.records == 0
        ? (insight.skipped > 0
              ? 'Не удалось проверить часть записей питания.'
              : 'Запиши еду — появится разбор продуктов за выбранный день.')
        : food == null
        ? 'По внесённым значениям энергия за день равна 0 ккал. Если запись неполная, сверь данные продукта.'
        : '«${food.name}»: ${_grams(food.amountGrams)} г и ${_n(food.calories)} ккал — '
              '${(insight.share(food) * 100).round()}% от записанной энергии. '
              '${example == null ? 'Для будущих приёмов пищи можно сравнить варианты порции.' : 'Пример на будущее: ${_grams(example.hypotheticalGrams)} г — ${_change(example.caloriesChange)} ккал и Б ${_change(example.proteinChange)} г относительно записи. Это пример, не норма.'}';
    return PremiumCard(
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline_rounded, color: AppTheme.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Совет дня',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(title),
          const SizedBox(height: 7),
          Text(
            'Блиц-расчёт на устройстве, не ответ ИИ. Учитывает только записанное; не оценивает норму или дефицит.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: openDetails,
            icon: const Icon(Icons.insights_outlined),
            label: const Text('Подробный разбор питания'),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
          ),
        ],
      ),
    );
  }
}

class _FuturePortionExampleLine extends StatelessWidget {
  final FoodEntry entry;
  const _FuturePortionExampleLine({required this.entry});

  @override
  Widget build(BuildContext context) {
    final example = _visibleSmallerExample(entry);
    if (example == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Пример на будущее: ${_grams(example.hypotheticalGrams)} г вместо '
        '${_grams(example.originalGrams)} г: ${_change(example.caloriesChange)} ккал; '
        'Б ${_change(example.proteinChange)} г, Ж ${_change(example.fatChange)} г, '
        'У ${_change(example.carbsChange)} г. Это пример, не норма; '
        'выбор зависит от вашей цели и остального питания.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class RecordedNutritionDetails extends StatelessWidget {
  final NutritionInsights insight;
  final int daysWithRecords;
  const RecordedNutritionDetails({
    super.key,
    required this.insight,
    required this.daysWithRecords,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final protein = insight.largestProteinRecord;
    return PremiumCard(
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Блиц-разбор питания', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Расчёт на устройстве по введённым порциям и КБЖУ, не ответ ИИ.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          if (insight.records == 0)
            Text(
              insight.skipped > 0
                  ? 'Записи не удалось проверить. Проверьте дневник и сохранённые значения.'
                  : 'За выбранный период нет записей еды. Это не означает, что еды не было.',
            )
          else ...[
            Text(
              '${insight.records} записей за $daysWithRecords дн. с едой: '
              '${_n(insight.calories)} ккал, Б ${_n(insight.protein)} г, '
              'Ж ${_n(insight.fat)} г, У ${_n(insight.carbs)} г.',
            ),
            const SizedBox(height: 10),
            if (insight.largestEnergyRecords.isNotEmpty) ...[
              Text(
                'Самые энергозначимые записанные порции',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final entry in insight.largestEnergyRecords)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.name} · ${formatDateRu(entry.date)}, ${entry.mealType.label}: '
                        '${_grams(entry.amountGrams)} г, ${_n(entry.calories)} ккал '
                        '(${(insight.share(entry) * 100).round()}% от записанного).',
                      ),
                      _FuturePortionExampleLine(entry: entry),
                      TextButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              _PortionComparisonDialog(entry: entry),
                        ),
                        icon: const Icon(
                          Icons.compare_arrows_rounded,
                          size: 18,
                        ),
                        label: const Text('Сравнить порцию'),
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      ),
                    ],
                  ),
                ),
            ] else
              const Text('В записанных порциях энергия указана как 0 ккал.'),
            if (protein != null) ...[
              const SizedBox(height: 4),
              Text(
                'Самая белковая из отдельных записанных порций: ${protein.name}, '
                '${_grams(protein.amountGrams)} г — ${_n(protein.protein)} г белка.',
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'В ${insight.recordsWithoutMicros} из ${insight.records} записей нет дополнительных показателей состава; '
              'в ${insight.recordsEstimatedMicros} они оценочные. Даже указанный состав может быть неполным; это не означает нехватку или избыток.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Что можно сделать: сверь порции и этикетки, а для будущего питания сравни варианты. '
              'Самые калорийные продукты не обязательно «плохие»; цели, полнота дневника и состояние здоровья здесь не оцениваются. '
              'Не удаляй фактически съеденное только ради изменения итогов.',
            ),
          ],
          if (insight.skipped > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Не удалось проверить записей: ${insight.skipped}. Разбор неполный.',
            ),
          ],
        ],
      ),
    );
  }
}

class _PortionComparisonDialog extends StatefulWidget {
  final FoodEntry entry;
  const _PortionComparisonDialog({required this.entry});
  @override
  State<_PortionComparisonDialog> createState() =>
      _PortionComparisonDialogState();
}

class _PortionComparisonDialogState extends State<_PortionComparisonDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    // Keep the exact stored portion in the input; round only rendered results.
    controller = TextEditingController(
      text: widget.entry.amountGrams.toString().replaceAll('.', ','),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parsed = double.tryParse(controller.text.trim().replaceAll(',', '.'));
    PortionComparison? comparison;
    if (parsed != null) {
      try {
        comparison = PortionComparison.calculate(widget.entry, parsed);
      } on ArgumentError {
        comparison = null;
      }
    }
    final value = comparison;
    final examples = futurePortionExamples(widget.entry);
    return AlertDialog(
      title: const Text('Сравнить порцию'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.entry.name}: записано ${_grams(widget.entry.amountGrams)} г.',
            ),
            if (examples.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Примеры для будущего приёма, а не норма:'),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final example in examples)
                    OutlinedButton(
                      onPressed: () {
                        final text = example.comparison.hypotheticalGrams
                            .toString()
                            .replaceAll('.', ',');
                        setState(() {
                          controller.value = TextEditingValue(
                            text: text,
                            selection: TextSelection.collapsed(
                              offset: text.length,
                            ),
                          );
                        });
                      },
                      child: Text(switch (example.kind) {
                        PortionExampleKind.smaller => 'На 25% меньше',
                        PortionExampleKind.larger => 'На 25% больше',
                        PortionExampleKind.omit => 'Не добавлять в будущем',
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Вариант порции, г',
                helperText: '0 — не включать продукт в будущий приём пищи',
                errorText: value == null
                    ? 'Укажите число от 0 до 10 000'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            if (value != null)
              Text(
                'Разница относительно записи: ${_change(value.caloriesChange)} ккал; '
                'Б ${_change(value.proteinChange)} г, Ж ${_change(value.fatChange)} г, '
                'У ${_change(value.carbsChange)} г.',
              ),
            const SizedBox(height: 8),
            const Text(
              'Это только расчёт варианта на будущее, а не рекомендация уменьшать порцию. '
              'Основан на данных записи, которые могут быть приблизительными. Дневник не изменится.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
