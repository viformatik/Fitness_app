import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import '../legacy.dart';
import 'engine.dart';
import 'csv_reader.dart';
import 'remote.dart';
import 'ai_drafts.dart';
import 'ai_preferences.dart';
import 'backup_delivery.dart';
import 'local_store.dart';
import 'ai_actions.dart';
import 'supplements.dart';
import 'supplement_ui.dart';
import 'diary_ai_ui.dart';
import 'assistant_hub.dart';
import 'catalog_ui.dart';
import 'food_guard.dart';
import 'lossless_json.dart';
import 'photo.dart';
import 'voice.dart';

/// Single entry point for the full-screen catalog, used by the diary picker
/// and by nutrient suggestions. The local Cyrillic catalog is always offline.
Future<FoodItem?> openFoodCatalog(
  BuildContext context,
  AppDataProvider provider, {
  String? nutrientFocus,
  String? initialQuery,
  String? initialSource,
  bool pickForDiary = false,
}) => Navigator.push<FoodItem>(
  context,
  MaterialPageRoute<FoodItem>(
    builder: (_) => FoodCatalogScreen(
      provider: provider,
      nutrientFocus: nutrientFocus,
      initialQuery: initialQuery,
      initialSource: initialSource,
      pickForDiary: pickForDiary,
    ),
  ),
);

Future<void> notice(BuildContext context, Object error) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(error.toString()),
      duration: const Duration(seconds: 6),
    ),
  );
}

/// Permit a user to retain an otherwise unimportable snapshot for manual
/// recovery, but never present it silently as a verified backup. The dialog
/// contains no actual document keys or values.
Future<bool> confirmUnverifiedBackup(
  BuildContext context,
  BackupReview review,
) async {
  if (review.passesFilePreflight) return true;
  if (!context.mounted) return false;
  final reason = switch (review.issue) {
    BackupReviewIssue.tooLarge =>
      'Файл больше 20 МиБ: загрузка файла в текущей версии его не примет.',
    BackupReviewIssue.changedDocuments =>
      'При проверке чтения содержимое отличается от исходного снимка.',
    BackupReviewIssue.invalid =>
      'Документы не прошли проверку импортёра текущей версии; импорт такой копии может быть отклонён.',
    BackupReviewIssue.none => '',
  };
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Копия не прошла предварительную проверку'),
          content: SingleChildScrollView(
            child: Text(
              '$reason\n\nМожно сохранить её как непроверенный материал для '
              'ручного восстановления. Не удаляйте текущий дневник и не '
              'импортируйте файл поверх единственной копии.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Сохранить непроверенную'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<double?> askPositiveNumber(
  BuildContext context,
  String title,
  double? initial, {
  bool allowZero = false,
  double? maxValue,
}) => showDialog<double>(
  context: context,
  builder: (_) => _NumberInputDialog(
    title: title,
    initial: initial,
    allowZero: allowZero,
    maxValue: maxValue,
  ),
);

// The dialog owns its controller until the route's exit animation completes.
class _NumberInputDialog extends StatefulWidget {
  final String title;
  final double? initial, maxValue;
  final bool allowZero;
  const _NumberInputDialog({
    required this.title,
    required this.initial,
    required this.allowZero,
    this.maxValue,
  });
  @override
  State<_NumberInputDialog> createState() => _NumberInputDialogState();
}

class _NumberInputDialogState extends State<_NumberInputDialog> {
  late final controller = TextEditingController(
    text: widget.initial?.toString() ?? '',
  );
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: form,
      child: TextFormField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: (v) {
          final n = parseNutritionNumber(v ?? '');
          if (n == null || (!widget.allowZero && n <= 0)) {
            return widget.allowZero
                ? 'Введите число не меньше 0'
                : 'Введите число больше 0';
          }
          if (widget.maxValue != null && n > widget.maxValue!) {
            return 'Слишком большое число';
          }
          return null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, parseNutritionNumber(controller.text));
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

Future<void> editPortion(
  BuildContext context,
  AppDataProvider provider,
  FoodEntry entry,
) => showDialog<void>(
  context: context,
  builder: (_) => _FoodPortionDialog(
    provider: provider,
    entry: entry,
    snapshot: provider.captureFoodEdit(entry),
  ),
);

class _FoodPortionDialog extends StatefulWidget {
  final AppDataProvider provider;
  final FoodEntry entry;
  final FoodEditSnapshot snapshot;
  const _FoodPortionDialog({
    required this.provider,
    required this.entry,
    required this.snapshot,
  });
  @override
  State<_FoodPortionDialog> createState() => _FoodPortionDialogState();
}

class _FoodPortionDialogState extends State<_FoodPortionDialog> {
  final form = GlobalKey<FormState>();
  late final controller = TextEditingController(
    text: widget.entry.amountGrams.toString(),
  );
  bool saving = false;
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    final grams = parseNutritionNumber(controller.text)!;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.provider.updateFoodEntry(
        widget.entry.copyWith(amountGrams: grams),
        snapshot: widget.snapshot,
      );
      if (!mounted) return;
      final warning = widget.provider.persistenceError;
      final messenger = ScaffoldMessenger.maybeOf(context);
      setState(() => saving = false);
      Navigator.pop(context);
      if (warning != null)
        messenger?.showSnackBar(SnackBar(content: Text(warning)));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        saving = false;
        error =
            widget.provider.persistenceError ?? 'Не удалось изменить порцию.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Text(
        '${widget.entry.name}: вес, г',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error != null) ...[
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              TextFormField(
                controller: controller,
                enabled: !saving,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) {
                  final number = parseNutritionNumber(value ?? '');
                  return number == null || number <= 0
                      ? 'Введите число больше 0'
                      : null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? 'Сохраняем…' : 'Сохранить'),
        ),
      ],
    ),
  );
}

Future<Map<String, double>?> editMicros(
  BuildContext context,
  Map<String, double> initial,
) => showDialog<Map<String, double>>(
  context: context,
  builder: (_) => _MicroDialog(initial),
);

class _MicroDialog extends StatefulWidget {
  final Map<String, double> initial;
  const _MicroDialog(this.initial);
  @override
  State<_MicroDialog> createState() => _MicroDialogState();
}

class _MicroDialogState extends State<_MicroDialog> {
  final _form = GlobalKey<FormState>();
  late final controllers = {
    for (final k in microLabels.keys)
      k: TextEditingController(text: widget.initial[k]?.toString() ?? ''),
  };
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Микронутриенты на 100 г'),
    content: SizedBox(
      width: 400,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Пусто — нет данных. 0 — известное отсутствие. Натрий/калий/железо в мг, витамин D в мкг.',
              ),
              for (final e in microLabels.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TextFormField(
                    controller: controllers[e.key],
                    decoration: InputDecoration(labelText: e.value),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) =>
                        v == null ||
                            v.trim().isEmpty ||
                            parseNutritionNumber(v) != null
                        ? null
                        : 'Нужно число ≥ 0',
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(context, {
            for (final e in controllers.entries)
              if (e.value.text.trim().isNotEmpty)
                e.key: parseNutritionNumber(e.value.text)!,
          });
        },
        child: const Text('Применить'),
      ),
    ],
  );
}

class DaySlider extends StatelessWidget {
  final AppDataProvider provider;
  const DaySlider({super.key, required this.provider});
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final isToday = dayKey(provider.selectedDate) == dayKey(today);
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 64,
            child: ListView.separated(
              reverse: true,
              scrollDirection: Axis.horizontal,
              itemCount: 30,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final date = DateTime(today.year, today.month, today.day - i);
                final selected = dayKey(date) == dayKey(provider.selectedDate);
                return ChoiceChip(
                  selected: selected,
                  label: Text(
                    '${date.day}.${date.month}\n${const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'][date.weekday - 1]}',
                    textAlign: TextAlign.center,
                  ),
                  onSelected: (_) => provider.setSelectedDate(date),
                );
              },
            ),
          ),
        ),
        if (!isToday)
          IconButton(
            tooltip: 'Вернуться к сегодняшнему дню',
            onPressed: () => provider.setSelectedDate(DateTime.now()),
            icon: const Icon(Icons.today_rounded),
          ),
      ],
    );
  }
}

class SpringProgress extends StatefulWidget {
  final Tween<double> tween;
  final Duration duration;
  final Curve curve;
  final Widget Function(BuildContext, double, Widget?) builder;
  const SpringProgress({
    super.key,
    required this.tween,
    required this.duration,
    required this.curve,
    required this.builder,
  });
  @override
  State<SpringProgress> createState() => _SpringProgressState();
}

class _SpringProgressState extends State<SpringProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: widget.tween.begin ?? 0,
  );
  @override
  void initState() {
    super.initState();
    _animate();
  }

  @override
  void didUpdateWidget(SpringProgress old) {
    super.didUpdateWidget(old);
    if (old.tween.end != widget.tween.end || old.duration != widget.duration)
      _animate();
  }

  int _generation = 0;
  void _animate() {
    final generation = ++_generation;
    final end = widget.tween.end ?? 0;
    if (widget.duration == Duration.zero) {
      _controller.value = end;
      return;
    }
    _controller
        .animateWith(
          SpringSimulation(
            const SpringDescription(mass: 1, stiffness: 180, damping: 28),
            _controller.value,
            end,
            _controller.velocity,
          ),
        )
        .whenCompleteOrCancel(() {
          if (mounted && generation == _generation) _controller.value = end;
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) =>
        widget.builder(context, _controller.value.clamp(0, 1), null),
  );
}

class FluidWaterCard extends StatefulWidget {
  final AppDataProvider provider;
  const FluidWaterCard({super.key, required this.provider});
  @override
  State<FluidWaterCard> createState() => _FluidWaterCardState();
}

class _FluidWaterCardState extends State<FluidWaterCard>
    with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _wave.stop();
    } else {
      _wave.repeat();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final recorded = p.hasRecordedWater;
    final goal = p.confirmedWaterGoal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              height: 100,
              child: Semantics(
                label: recorded
                    ? (goal == null
                          ? 'Вода по записям ${p.todayWaterIntake} миллилитров, цель не подтверждена'
                          : 'Вода ${p.todayWaterIntake} из $goal миллилитров')
                    : 'Вода за день не записана',
                child: !recorded || goal == null
                    ? Icon(
                        Icons.water_drop_outlined,
                        color: Theme.of(context).colorScheme.primary,
                        size: 40,
                      )
                    : SpringProgress(
                        tween: Tween(
                          begin: 0,
                          end: goalProgress(
                            p.todayWaterIntake,
                            goal,
                          ).clamp(0, 1),
                        ),
                        duration: MediaQuery.of(context).disableAnimations
                            ? Duration.zero
                            : const Duration(milliseconds: 500),
                        curve: Curves.linear,
                        builder: (context, fill, _) => AnimatedBuilder(
                          animation: _wave,
                          builder: (_, __) => CustomPaint(
                            painter: _WaterPainter(
                              fill,
                              _wave.value * pi * 2,
                              Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Гидратация',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    recorded
                        ? (goal == null
                              ? '${p.todayWaterIntake} мл · цель не подтверждена'
                              : '${p.todayWaterIntake} / $goal мл')
                        : (goal == null
                              ? 'Не записана · цель не подтверждена'
                              : 'Не записана · цель $goal мл'),
                  ),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: () => p.addWater(250),
                        child: const Text('+250'),
                      ),
                      TextButton(
                        onPressed: () => p.addWater(500),
                        child: const Text('+500'),
                      ),
                      TextButton(
                        onPressed: p.todayWaterIntake > 0
                            ? () => p.setWaterIntake(
                                max(0, p.todayWaterIntake - 250),
                              )
                            : null,
                        child: const Text('−250'),
                      ),
                      IconButton(
                        tooltip: 'Своя порция воды',
                        onPressed: () async {
                          final ml = await askPositiveNumber(
                            context,
                            'Добавить воду, мл',
                            250,
                          );
                          if (ml != null && ml <= 10000)
                            await p.addWater(ml.round());
                        },
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaterPainter extends CustomPainter {
  final double fill, phase;
  final Color color;
  _WaterPainter(this.fill, this.phase, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(
      Rect.fromLTWH(2, 2, size.width - 4, size.height - 4),
      const Radius.circular(16),
    );
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRRect(shape, Paint()..color = color.withValues(alpha: .08));
    for (var layer = 0; layer < 2; layer++) {
      final y = size.height * (1 - fill);
      final amplitude = 4 * sin(pi * fill);
      final path = Path()..moveTo(0, size.height);
      for (var x = 0.0; x <= size.width; x += 2) {
        path.lineTo(
          x,
          y + sin(x / size.width * pi * 2 + phase + layer * 1.5) * amplitude,
        );
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()..color = color.withValues(alpha: layer == 0 ? .28 : .65),
      );
    }
    canvas.restore();
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: .5),
    );
  }

  @override
  bool shouldRepaint(_WaterPainter old) =>
      fill != old.fill || phase != old.phase || color != old.color;
}

class QuickTemplates extends StatelessWidget {
  final AppDataProvider provider;
  const QuickTemplates({super.key, required this.provider});
  @override
  Widget build(BuildContext context) {
    final store = provider.storage.local;
    final templates = List<Map<String, dynamic>>.from(
      (store.decoded('meal_templates') as List? ?? []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            children: [
              for (final template in templates)
                InputChip(
                  label: Text(template['name'] as String),
                  tooltip: 'Добавить набор за выбранный день',
                  onPressed: () async {
                    try {
                      final day = provider.selectedDate;
                      final batch = <FoodEntry>[];
                      for (final raw in template['entries'] as List) {
                        final json = Map<String, dynamic>.from(raw as Map)
                          ..['id'] = newId()
                          ..['date'] = day.toIso8601String()
                          ..['loggedAt'] = foodTime(day).toIso8601String()
                          ..['timeKnown'] = true;
                        batch.add(FoodEntry.fromJson(json));
                      }
                      await provider.addFoodEntriesBatch(batch);
                      if (context.mounted &&
                          provider.persistenceError != null) {
                        await notice(context, provider.persistenceError!);
                      }
                    } catch (_) {
                      if (context.mounted) {
                        await notice(
                          context,
                          provider.persistenceError ??
                              'Не удалось сохранить набор.',
                        );
                      }
                    }
                  },
                  onDeleted: () async {
                    templates.remove(template);
                    await store.setString(
                      'meal_templates',
                      jsonEncode(templates),
                    );
                    await provider.refresh();
                  },
                ),
              ActionChip(
                label: const Text('Сохранить день как набор'),
                avatar: const Icon(Icons.bookmark_add_outlined),
                onPressed: provider.todayFoodEntries.isEmpty
                    ? null
                    : () async {
                        final name = await askText(context, 'Название набора');
                        if (name == null || name.trim().isEmpty) return;
                        if (templates.length >= 20) {
                          if (context.mounted)
                            notice(
                              context,
                              'Сначала удалите один из 20 наборов',
                            );
                          return;
                        }
                        templates.add({
                          'name': name.trim(),
                          'entries': provider.todayFoodEntries
                              .map((e) => e.toJson())
                              .toList(),
                        });
                        await store.setString(
                          'meal_templates',
                          jsonEncode(templates),
                        );
                        await provider.refresh();
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<String?> askText(BuildContext context, String title) async {
  var text = '';
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(autofocus: true, onChanged: (v) => text = v),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, text),
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}

class MacroInsights extends StatefulWidget {
  final AppDataProvider provider;
  final NutrientMetric metric;
  const MacroInsights({
    super.key,
    required this.provider,
    required this.metric,
  });
  @override
  State<MacroInsights> createState() => _MacroInsightsState();
}

class _MacroInsightsState extends State<MacroInsights> {
  late Future<List<List<FoodEntry>>> history;
  String _day = "";
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MacroInsights old) {
    super.didUpdateWidget(old);
    if (_day != dayKey(widget.provider.selectedDate)) _load();
  }

  void _load() {
    final day = widget.provider.selectedDate;
    _day = dayKey(day);
    history = Future.wait(
      List.generate(
        7,
        (i) => widget.provider.storage.getFoodEntries(
          DateTime(day.year, day.month, day.day - i - 1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider, metric = widget.metric;
    final groups = <String, double>{};
    final hours = List.filled(24, 0.0);
    for (final e in p.todayFoodEntries) {
      groups.update(
        e.name,
        (v) => v + metric.value(e),
        ifAbsent: () => metric.value(e),
      );
      if (e.timeKnown) hours[e.loggedAt.hour] += metric.value(e);
    }
    final ordered = groups.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final visible = ordered.take(5).toList();
    final rest = ordered.skip(5).fold(0.0, (v, e) => v + e.value);
    if (rest > 0) visible.add(MapEntry('Остальное', rest));
    final total = groups.values.fold(0.0, (a, b) => a + b);
    const colors = [
      Colors.teal,
      Colors.blue,
      Colors.amber,
      Colors.purple,
      Colors.pink,
      Colors.grey,
    ];
    final maxHour = hours.reduce(max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (visible.isNotEmpty) ...[
          SizedBox(
            height: 160,
            child: PieChart(
              PieChartData(
                centerSpaceRadius: 34,
                sectionsSpace: 3,
                sections: List.generate(
                  visible.length,
                  (i) => PieChartSectionData(
                    value: visible[i].value,
                    title: '${(visible[i].value / total * 100).round()}%',
                    color: colors[i],
                    radius: 40,
                    titleStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: List.generate(
              visible.length,
              (i) => Text(
                '● ${visible[i].key}: ${formatGrams(visible[i].value)}',
                style: TextStyle(color: colors[i]),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Text('По часам · учитываются только записи с известным временем'),
        if (maxHour > 0) ...[
          SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(
                24,
                (i) => Expanded(
                  child: Tooltip(
                    message: '$i:00 · ${formatGrams(hours[i])} ${metric.unit}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        height: max(2, hours[i] / maxHour * 70),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Text('00          06          12          18          23'),
        ] else
          const Text('Нет записей с известным временем.'),
        FutureBuilder<List<List<FoodEntry>>>(
          future: history,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return const Text('История временно недоступна');
            if (!snapshot.hasData) return const LinearProgressIndicator();
            final days = snapshot.data!;
            final y = days.first.fold(0.0, (v, e) => v + metric.value(e));
            final logged = days.where((d) => d.isNotEmpty).toList();
            final average = logged.isEmpty
                ? null
                : logged.fold(
                        0.0,
                        (v, d) =>
                            v + d.fold(0.0, (s, e) => s + metric.value(e)),
                      ) /
                      logged.length;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Вчера: ${days.first.isEmpty ? 'нет записей' : '${formatGrams(y)} ${metric.unit}'}\n'
                'Среднее за предыдущие 7 дней: ${average == null ? 'нет данных' : '${formatGrams(average)} ${metric.unit}'} '
                '(${logged.length} заполненных дней).\n'
                'Цель сегодня: ${metric.target(p) == null ? 'не подтверждена' : '${metric.target(p)} ${metric.unit}'}.',
              ),
            );
          },
        ),
      ],
    );
  }
}

class SmartHub extends StatelessWidget {
  const SmartHub({super.key});
  @override
  Widget build(BuildContext context) => Consumer<AppDataProvider>(
    builder: (context, p, _) => Scaffold(
      appBar: AppBar(title: const Text('Smart • здоровье и данные')),
      body: CenteredBody(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DiaryErrorBanner(provider: p),
            _section(context, 'AI-чат · отдельный блок', [
              const Text(
                'Диалог, фото этикетки, диктовка, черновики, избранное и настройки согласия '
                'теперь на отдельном экране. Сюда не загружается большая база продуктов '
                'и не запускается распознавание речи без вашего действия.',
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const AiChatScreen()),
                ),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Открыть AI-чат'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => DiaryAiScreen(provider: p),
                  ),
                ),
                icon: const Icon(Icons.analytics_outlined),
                label: const Text('ИИ-анализ дневника'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => openFoodCatalog(context, p),
                icon: const Icon(Icons.library_books_outlined),
                label: const Text('Каталог продуктов ПМР и СНГ'),
              ),
            ]),
            _section(context, 'Витамины и добавки', [
              SupplementPanel(provider: p),
            ]),
            DailyBalanceCard(provider: p),
            _section(context, 'Энергия и макроцели', [
              if (p.metabolism.automatic && !p.automaticMetabolismActive)
                const Text(
                  'Автоцель приостановлена: подтвердите рост, вес, возраст и настройки расчёта. '
                  'Пока используется сохранённый ручной ориентир.',
                ),
              Text(
                p.baseCaloriesTarget == null
                    ? 'Цель калорий не подтверждена.'
                    : 'Базовый лимит: ${p.baseCaloriesTarget!.round()} ккал · с тренировками ${p.adjustedCaloriesTarget} ккал',
              ),
              Text(
                'Белки ${p.targetProteinToday == null ? 'не подтверждены' : '${p.targetProteinToday} г'} · '
                'жиры ${p.targetFatToday == null ? 'не подтверждены' : '${p.targetFatToday} г'} · '
                'углеводы ${p.targetCarbsToday == null ? 'не подтверждены' : '${p.targetCarbsToday} г'}',
              ),
              if (p.targetProteinToday != null &&
                  p.targetFatToday != null &&
                  p.targetCarbsToday != null)
                Text(
                  'Коридор ±10%: Б ${(p.targetProteinToday! * .9).round()}–${(p.targetProteinToday! * 1.1).round()}, '
                  'Ж ${(p.targetFatToday! * .9).round()}–${(p.targetFatToday! * 1.1).round()}, '
                  'У ${(p.targetCarbsToday! * .9).round()}–${(p.targetCarbsToday! * 1.1).round()} г',
                ),
              FilledButton.tonal(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _MetabolismDialog(p),
                ),
                child: const Text('BMR, цель и адаптация'),
              ),
              const Text(
                'Расчётные ориентиры для взрослых, не измерение метаболизма. '
                'Коэффициент активности должен исключать отдельно внесённые тренировки, иначе расход будет посчитан дважды.',
              ),
            ]),
            _section(context, 'Микронутриенты и качество', [_MicroSummary(p)]),
            _section(context, 'Недельные и месячные тренды', [
              MacroTrendPanel(provider: p),
            ]),
            _section(context, 'Своя база продуктов', [
              CustomFoodPanel(provider: p),
            ]),
            _section(context, 'Внешний вид', [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final option in const [
                    ('system', 'Системная'),
                    ('dark', 'Тёмная'),
                    ('light', 'Светлая'),
                    ('oled', 'OLED'),
                  ])
                    ChoiceChip(
                      label: Text(option.$2),
                      selected: option.$1 == 'system'
                          ? AppTheme.followsSystem(p.smartSettings)
                          : !AppTheme.followsSystem(p.smartSettings) &&
                                (p.smartSettings['theme'] ?? 'dark') ==
                                    option.$1,
                      onSelected: (_) async {
                        final next = Map<String, dynamic>.of(p.smartSettings);
                        if (option.$1 == 'system') {
                          final fallback = next['theme'] as String? ?? 'dark';
                          next['theme'] = fallback;
                          next['themeFollowSystem'] = true;
                          next['systemThemeFallback'] = fallback;
                        } else {
                          next['theme'] = option.$1;
                          next['themeFollowSystem'] = false;
                          next.remove('systemThemeFallback');
                        }
                        try {
                          await p.updateSmartSettings(next);
                        } catch (e) {
                          if (context.mounted) await notice(context, e);
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                children: [
                  for (final c in [
                    0xFF008577,
                    0xFF1565C0,
                    0xFF7B1FA2,
                    0xFFB53C12,
                  ])
                    IconButton(
                      tooltip: 'Изменить акцент',
                      onPressed: () async {
                        try {
                          await p.updateSmartSettings({
                            ...p.smartSettings,
                            'accent': c,
                          });
                        } catch (e) {
                          if (context.mounted) await notice(context, e);
                        }
                      },
                      icon: Icon(Icons.circle, color: Color(c)),
                    ),
                ],
              ),
            ]),
            _section(context, 'Серии и достижения', [BadgePanel(provider: p)]),
            _section(context, 'Вся история и резервные копии', [
              BackupPanel(provider: p),
            ]),
            _section(context, 'Аккаунт и облачная синхронизация', [
              CloudPanel(provider: p),
            ]),
            const SizedBox(height: 30),
          ],
        ),
      ),
    ),
  );
}

Widget _section(BuildContext context, String title, List<Widget> children) =>
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );

class _MicroSummary extends StatefulWidget {
  final AppDataProvider p;
  const _MicroSummary(this.p);
  @override
  State<_MicroSummary> createState() => _MicroSummaryState();
}

class _MicroSummaryState extends State<_MicroSummary> {
  String _focus = 'vitaminC';

  Widget _row(
    String key,
    Map<String, MicroTotal> totals,
    Map<String, double> fromSupplements,
  ) {
    final total = totals[key]!;
    final reference = microReference[key]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${microLabels[key]}: ${total.coverage == 0 && !fromSupplements.containsKey(key) ? 'нет данных' : formatNutrient(total.value)}'
            '${fromSupplements.containsKey(key) ? ' (из добавок ${formatNutrient(fromSupplements[key]!)})' : ''} · '
            'покрытие ${(total.coverage * 100).round()}% массы еды',
          ),
          LinearProgressIndicator(value: (total.value / reference).clamp(0, 1)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final foodTotals = aggregateMicros(
      widget.p.todayFoodEntries.map((e) => e.toJson()),
    );
    final fromSupplements = supplementMicroTotals(
      widget.p.todaySupplementEntries,
    );
    final totals = <String, MicroTotal>{
      for (final key in microLabels.keys)
        key: MicroTotal(
          foodTotals[key]!.value + (fromSupplements[key] ?? 0),
          foodTotals[key]!.coverage,
        ),
    };
    final score = dietScore(foodTotals);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          score == null
              ? 'Health Score: недостаточно данных'
              : 'Health Score: $score / 100',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text(
          'Экспериментальная оценка, не официальный Nutri-Score. Неизвестные нутриенты не считаются нулями.',
        ),
        if (widget.p.todayFoodEntries.any(
          (e) => e.microsEstimated && e.micros.isNotEmpty,
        ))
          const Text(
            'Часть витаминов и минералов оценена ИИ и может быть неточной. Сверяйте с упаковкой или надёжными источниками.',
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: DropdownButton<String>(
                value: _focus,
                isExpanded: true,
                items: [
                  for (final key in [...vitaminKeys, ...mineralKeys])
                    DropdownMenuItem(
                      value: key,
                      child: Text(
                        microLabels[key]!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _focus = value!),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () =>
                  openFoodCatalog(context, widget.p, nutrientFocus: _focus),
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('Подобрать продукты'),
            ),
          ],
        ),
        const Text(
          'Подбор по каталогу продуктов, не медицинская рекомендация. '
          'Сортировка учитывает количество нутриента на калорию.',
        ),
        ExpansionTile(
          title: Text('Витамины · ${vitaminKeys.length} показателей'),
          children: [
            for (final key in vitaminKeys) _row(key, totals, fromSupplements),
          ],
        ),
        ExpansionTile(
          title: Text('Минералы · ${mineralKeys.length} показателей'),
          children: [
            for (final key in mineralKeys) _row(key, totals, fromSupplements),
          ],
        ),
        ExpansionTile(
          title: const Text('Клетчатка, сахара и жиры'),
          children: [
            for (final key in otherMicroKeys)
              _row(key, totals, fromSupplements),
          ],
        ),
        const Text(
          'Полосы — общие справочные ориентиры для взрослых, не персональная норма. '
          'Для сахаров используется общий сахар, не свободные/добавленные сахара. '
          'Не принимайте добавки по этому экрану. '
          'Значения из подтверждённых добавок прибавлены отдельно; покрытие относится только к еде. Добавить или проверить данные: продукт → редактор → «Витамины и минералы».',
        ),
      ],
    );
  }
}

class _MetabolismDialog extends StatefulWidget {
  final AppDataProvider p;
  const _MetabolismDialog(this.p);
  @override
  State<_MetabolismDialog> createState() => _MetabolismDialogState();
}

class _MetabolismDialogState extends State<_MetabolismDialog> {
  final form = GlobalKey<FormState>();
  late final age = TextEditingController(
    text: widget.p.profile.ageYears?.toString() ?? '',
  );
  late final fat = TextEditingController(
    text: widget.p.smartSettings['bodyFatConfirmed'] == true
        ? '${widget.p.metabolism.bodyFat}'
        : '',
  );
  late final activity = TextEditingController(
    text: '${widget.p.metabolism.activity}',
  );
  late final delta = TextEditingController(
    text: '${widget.p.metabolism.goalDelta}',
  );
  late bool male = widget.p.metabolism.male,
      katch = widget.p.metabolism.useKatch,
      automatic = widget.p.metabolism.automatic,
      adapt = widget.p.metabolism.adaptMacros;
  bool saving = false;
  @override
  void dispose() {
    age.dispose();
    fat.dispose();
    activity.dispose();
    delta.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Метаболизм и цели'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.p.hasConfirmedBodyMetrics
                    ? 'Вес ${widget.p.profile.currentWeight} кг, рост ${widget.p.profile.height} см — подтверждены в профиле.'
                    : 'Для автоматической цели сначала подтвердите рост и вес в настройках профиля.',
              ),
              SwitchListTile(
                title: const Text('Автоцель калорий'),
                value: automatic,
                onChanged: saving ? null : (v) => setState(() => automatic = v),
              ),
              SwitchListTile(
                title: const Text('Адаптировать БЖУ от тренировок'),
                value: adapt,
                onChanged: saving ? null : (v) => setState(() => adapt = v),
              ),
              SwitchListTile(
                title: const Text('Katch–McArdle (нужен % жира)'),
                subtitle: const Text('Иначе Mifflin–St Jeor'),
                value: katch,
                onChanged: saving ? null : (v) => setState(() => katch = v),
              ),
              SwitchListTile(
                title: const Text('Мужской коэффициент Mifflin'),
                value: male,
                onChanged: saving ? null : (v) => setState(() => male = v),
              ),
              _field(
                age,
                automatic ? 'Возраст, 18–100' : 'Возраст, 1–120 (необ.)',
                automatic ? 18 : 1,
                automatic ? 100 : 120,
                optional: !automatic,
              ),
              _field(
                fat,
                'Жир тела, 3–65%',
                3,
                65,
                optional: !automatic || !katch,
              ),
              _field(
                activity,
                'Активность БЕЗ внесённых тренировок: 1.1–2',
                1.1,
                2,
              ),
              _field(
                delta,
                'Цель: −500…+500 ккал (0 = поддержание)',
                -500,
                500,
              ),
              const SizedBox(height: 12),
              const Text(
                'Автоцель: max(1200, BMR × активность + поправка). '
                'Базовые БЖУ автоцели: 30%/25%/45% энергии. Дополнительная энергия силовой: Б40%/У40%/Ж20%; '
                'кардио: Б20%/У60%/Ж20%; смешанная: Б30%/У50%/Ж20%. В граммы переводится через 4/9/4 ккал.',
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                if (!form.currentState!.validate()) return;
                if (automatic && !widget.p.hasConfirmedBodyMetrics) {
                  notice(
                    context,
                    'Сначала подтвердите рост и вес в настройках профиля.',
                  );
                  return;
                }
                final enteredAge = double.tryParse(
                  age.text.replaceAll(',', '.'),
                )?.toInt();
                final enteredFat = double.tryParse(
                  fat.text.replaceAll(',', '.'),
                );
                final stored = MetabolicSettings.fromJson(
                  widget.p.smartSettings,
                );
                final adultAge =
                    enteredAge != null && enteredAge >= 18 && enteredAge <= 100
                    ? enteredAge
                    : null;
                final settings = MetabolicSettings(
                  age: adultAge ?? stored.age,
                  male: male,
                  useKatch: katch,
                  automatic: automatic,
                  adaptMacros: adapt,
                  bodyFat: enteredFat ?? stored.bodyFat,
                  activity: double.parse(activity.text.replaceAll(',', '.')),
                  goalDelta: double.parse(delta.text.replaceAll(',', '.')),
                );
                setState(() => saving = true);
                try {
                  // Both entries are explicit user input; never infer age from a
                  // previous metabolic default. If settings storage fails, the
                  // entered profile age remains saved and the error is shown.
                  if (enteredAge != null &&
                      enteredAge != widget.p.profile.ageYears) {
                    await widget.p.updateProfile(
                      widget.p.profile.copyWith(ageYears: enteredAge),
                    );
                  }
                  final next = <String, dynamic>{
                    ...widget.p.smartSettings,
                    ...settings.toJson(),
                    'metabolismConfirmed': automatic,
                    'bodyFatConfirmed': enteredFat != null,
                  };
                  if (adultAge == null &&
                      !widget.p.smartSettings.containsKey('age')) {
                    next.remove('age');
                  }
                  if (enteredFat == null &&
                      !widget.p.smartSettings.containsKey('bodyFat')) {
                    next.remove('bodyFat');
                  }
                  final bmr = automatic
                      ? settings.bmr(
                          widget.p.profile.currentWeight,
                          widget.p.profile.height,
                        )
                      : null;
                  await widget.p.updateSmartSettings(next);
                  if (context.mounted) {
                    Navigator.pop(context);
                    notice(
                      context,
                      bmr == null
                          ? 'Настройки сохранены. Автоцель выключена.'
                          : 'Расчётный BMR: ${bmr.round()} ккал/сутки',
                    );
                  }
                } catch (e) {
                  if (context.mounted) notice(context, e);
                } finally {
                  if (mounted) setState(() => saving = false);
                }
              },
        child: const Text('Применить'),
      ),
    ],
  );
  Widget _field(
    TextEditingController c,
    String label,
    double min,
    double max, {
    bool optional = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: TextFormField(
      controller: c,
      enabled: !saving,
      decoration: InputDecoration(labelText: label),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      validator: (v) {
        if (optional && (v ?? '').trim().isEmpty) return null;
        final n = double.tryParse((v ?? '').replaceAll(',', '.'));
        return n != null &&
                n.isFinite &&
                n >= min &&
                n <= max &&
                (c != age || n == n.roundToDouble())
            ? null
            : 'Допустимо $min…$max';
      },
    ),
  );
}

class BackupPanel extends StatelessWidget {
  final AppDataProvider provider;
  const BackupPanel({super.key, required this.provider});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: provider,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Копия содержит личные записи — храните её в защищённом месте. '
          'В неё не входят локальные черновики, избранное и согласие ИИ, '
          'данные входа и само облако. Структура и размер файла проверяются '
          'перед экспортом, но это не восстановление. Проверьте копию в '
          'отдельном профиле: старые или повреждённые записи могут не импортироваться.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: [
            OutlinedButton(
              onPressed: () => _export(context, false),
              child: const Text('Экспорт JSON'),
            ),
            OutlinedButton(
              onPressed: () => _export(context, true),
              child: const Text('Экспорт CSV'),
            ),
            OutlinedButton(
              onPressed: () => _import(context),
              child: const Text('Импорт JSON / CSV'),
            ),
          ],
        ),
        if (provider.storage.local.hasImportBackup) ...[
          const SizedBox(height: 12),
          const Text(
            'Копия до последнего импорта хранится только на этом устройстве и содержит личные записи.',
          ),
          Wrap(
            spacing: 6,
            children: [
              OutlinedButton(
                onPressed: () => _copyPrevious(context),
                child: const Text('Скопировать копию до импорта'),
              ),
              TextButton(
                onPressed: () => _discardPrevious(context),
                child: const Text('Удалить эту копию'),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  Future<void> _copyPrevious(BuildContext context) async {
    try {
      final backup = provider.storage.importBackupJson();
      if (backup == null) throw StateError('Не удалось прочитать копию.');
      final review = reviewBackupFile(backup);
      if (!await confirmUnverifiedBackup(context, review)) return;
      await Clipboard.setData(ClipboardData(text: backup));
      if (context.mounted)
        await notice(
          context,
          'Копия в буфере обмена. Сохраните её в надёжном месте.',
        );
    } catch (e) {
      if (context.mounted) await notice(context, e);
    }
  }

  Future<void> _discardPrevious(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить копию до импорта?'),
        content: const Text(
          'Удалится только локальная копия. Текущий дневник останется без изменений.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить копию'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await provider.discardImportBackup();
      if (context.mounted) await notice(context, 'Локальная копия удалена.');
    } catch (e) {
      if (context.mounted) await notice(context, e);
    }
  }

  Future<void> _export(BuildContext context, bool csv) async {
    try {
      await provider.storage.pendingMutations;
      final payload = await provider.storage.exportData();
      final documents = Map<String, dynamic>.from(payload['data'] as Map);
      final text = csv
          ? exportCsv(documents)
          : const JsonEncoder.withIndent('  ').convert(payload);
      if (!context.mounted) return;
      final review = reviewBackupFile(
        text,
        csv: csv,
        expectedDocuments: documents,
      );
      if (!await confirmUnverifiedBackup(context, review)) return;
      if (!context.mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final delivered = await deliverBackupFile(
        Uint8List.fromList(utf8.encode(text)),
        fileName:
            'fitness_all_${dayKey(DateTime.now())}.${csv ? 'csv' : 'json'}',
        mimeType: csv ? 'text/csv' : 'application/json',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      );
      if (!context.mounted) return;
      await notice(
        context,
        switch (delivered) {
          BackupDelivery.shared => 'Файл передан в систему обмена. '
              'Проверьте, что он сохранён в надёжном месте.',
          BackupDelivery.downloaded => 'Файл сохранён как загрузка браузера. '
              'Проверьте папку загрузок.',
          BackupDelivery.failed => 'Не удалось передать файл. '
              'Скопируйте копию вручную из окна экспорта.',
        },
      );
    } catch (e) {
      if (context.mounted) notice(context, e);
    }
  }

  Future<void> _import(BuildContext context) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'csv'],
        withData: true,
      );
      if (picked == null || !context.mounted) return;
      final file = picked.files.single;
      if (file.bytes == null ||
          file.size > backupFileLimitBytes ||
          file.bytes!.lengthInBytes > backupFileLimitBytes) {
        throw const FormatException('Размер файла не должен превышать 20 МиБ');
      }
      final text = utf8.decode(file.bytes!);
      final csv = file.name.toLowerCase().endsWith('.csv');
      final review = reviewBackupFile(text, csv: csv);
      if (!review.passesFilePreflight) {
        if (context.mounted) {
          await notice(
            context,
            'Копия не прошла проверку импортёра. Дневник не изменён. '
            'Сохраните исходный файл для возможного восстановления.',
          );
        }
        return;
      }
      final raw = csv
          ? jsonEncode({'app': 'fitness_tracker', 'data': importCsv(text)})
          : text;
      final incoming = parseBackupDocuments(text, csv: csv);
      if (incoming == null) {
        if (context.mounted) {
          await notice(
            context,
            'Копия не прошла проверку импортёра. Дневник не изменён.',
          );
        }
        return;
      }
      if (!context.mounted) return;
      final current = provider.storage.local.snapshot();
      final preview = previewImportDocuments(incoming, current);
      final guard = ImportReviewGuard(
        documents: documentsFingerprint(incoming),
        diary: documentsFingerprint(current),
        account: currentImportAccount(provider),
      );
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Заменить всю локальную историю?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(preview.summary),
              const SizedBox(height: 10),
              const Text(
                'Сделайте экспорт перед импортом. После синхронизации изменения попадут и в облако. '
                'Локальные черновики и избранное ИИ, а также согласие не входят в файл '
                'и останутся на этом устройстве.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Заменить'),
            ),
          ],
        ),
      );
      if (yes != true) return;
      if (!context.mounted) return;
      if (!await confirmImportRemovals(context, preview)) return;
      if (!context.mounted) return;
      final stale = guard.staleReason(
        documents: documentsFingerprint(
          parseBackupDocuments(text, csv: csv) ?? const {},
        ),
        diary: await currentDiaryFingerprint(provider),
        account: currentImportAccount(provider),
      );
      if (stale != null) {
        if (context.mounted) await notice(context, '$stale Импорт отменён.');
        return;
      }
      final error = await provider.importDataJson(raw);
      if (context.mounted) notice(context, error ?? 'История импортирована');
    } catch (e) {
      if (context.mounted) notice(context, e);
    }
  }
}

class CloudPanel extends StatefulWidget {
  final AppDataProvider provider;
  const CloudPanel({super.key, required this.provider});
  @override
  State<CloudPanel> createState() => _CloudPanelState();
}

class _CloudPanelState extends State<CloudPanel> {
  final email = TextEditingController(), password = TextEditingController();
  bool pending = false;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> act(Future<void> Function() action) async {
    if (pending) return;
    setState(() => pending = true);
    try {
      await action();
    } catch (e) {
      if (mounted) notice(context, e);
    } finally {
      if (mounted) setState(() => pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: SmartRemote.instance,
    builder: (context, _) {
      final remote = SmartRemote.instance;
      final local = widget.provider.storage.local;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(remote.status),
          if (local.importSyncPaused)
            const Text(
              'Автосинхронизация приостановлена после импорта. Проверьте данные и подтвердите синхронизацию вручную.',
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Автосинхронизация в открытом приложении'),
            subtitle: const Text(
              'После изменений и раз в минуту при входе. Конфликты не перезаписываются.',
            ),
            value: widget.provider.smartSettings['autoSync'] == true,
            onChanged: pending
                ? null
                : (value) => act(
                    () => widget.provider.updateSmartSettings({
                      ...widget.provider.smartSettings,
                      'autoSync': value,
                    }),
                  ),
          ),
          if (remote.client == null)
            const Text(
              'Нужны ваш бесплатный проект Supabase и серверная функция. '
              'Инструкция и SQL приложены. Без настройки AI и облако не работают; локальные функции доступны.',
            ),
          if (remote.client != null && !remote.signedIn) ...[
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Пароль (от 8 символов)',
              ),
            ),
            Wrap(
              children: [
                TextButton(
                  onPressed: pending
                      ? null
                      : () => act(
                          () => remote.login(email.text.trim(), password.text),
                        ),
                  child: const Text('Войти'),
                ),
                TextButton(
                  onPressed: pending
                      ? null
                      : () => act(
                          () => remote.login(
                            email.text.trim(),
                            password.text,
                            signup: true,
                          ),
                        ),
                  child: const Text('Создать аккаунт'),
                ),
              ],
            ),
          ],
          if (remote.signedIn) ...[
            Text(remote.client!.auth.currentUser!.email ?? 'Аккаунт'),
            FilledButton(
              onPressed: pending || remote.busy
                  ? null
                  : () => act(() async {
                      await widget.provider.storage.pendingMutations;
                      String? confirmedGeneration;
                      if (local.importSyncPaused) {
                        final generation = local.diaryGeneration;
                        if (!context.mounted) return;
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text(
                              'Синхронизировать после импорта?',
                            ),
                            content: const Text(
                              'Импортированные изменения, включая удаления, могут попасть в облако. '
                              'Проверьте дневник и резервную копию. Конфликты потребуется разрешить отдельно. '
                              'После успешной синхронизации автоматический режим возобновится, если он включён.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('Отмена'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('Синхронизировать'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        confirmedGeneration = generation;
                        await widget.provider.storage.pendingMutations;
                      }
                      await remote.sync(
                        local,
                        validate: validateAppDocument,
                        confirmedImportGeneration: confirmedGeneration,
                      );
                      await widget.provider.reloadAll();
                    }),
              child: const Text('Синхронизировать сейчас'),
            ),
            TextButton(
              onPressed: pending ? null : () => act(remote.logout),
              child: const Text('Выйти'),
            ),
          ],
          for (final conflict in remote.conflicts)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Text('Конфликт: ${conflict.key}'),
                    if (conflict.matchingCounterNeedsReview)
                      Text(
                        'Итоги совпадают, но действия на устройствах могли быть разными. '
                        'Последнее общее значение: ${conflict.counterBaseline ?? 'неизвестно'}. '
                        'Приложение не складывает их автоматически. '
                        'Проверьте оба устройства и при необходимости исправьте итог в дневнике, '
                        'затем повторите синхронизацию.',
                      ),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Сравнение версий'),
                          content: SingleChildScrollView(
                            child: Text(
                              'Устройство:\n${conflict.local}\n\nОблако:\n${conflict.remote}',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Закрыть'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Посмотреть версии'),
                    ),
                    Wrap(
                      children: [
                        if (conflict.matchingCounterNeedsReview)
                          TextButton(
                            onPressed: pending || remote.busy
                                ? null
                                : () => act(() async {
                                    final isWater = conflict.key.startsWith(
                                      'water_intake_',
                                    );
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Подтвердить итог?'),
                                        content: Text(
                                          'На обоих устройствах сейчас '
                                          '${conflict.local} ${isWater ? 'мл' : 'шагов'}. '
                                          'Это могут быть как одна запись, так и разные действия. '
                                          'Мы не знаем, нужно ли их суммировать. '
                                          'Подтверждайте только после проверки: этот итог будет принят без автоматического сложения.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: const Text(
                                              'Проверить позже',
                                            ),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text('Подтвердить'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed != true || !mounted) return;
                                    await widget
                                        .provider
                                        .storage
                                        .pendingMutations;
                                    if (!mounted) return;
                                    await remote.resolve(
                                      widget.provider.storage.local,
                                      conflict,
                                      true,
                                      validate: validateAppDocument,
                                      confirmedMatchingCounter: true,
                                    );
                                    if (!mounted) return;
                                    await widget.provider.reloadAll();
                                  }),
                            child: const Text('Подтвердить этот итог'),
                          )
                        else
                          for (final local in [true, false])
                            TextButton(
                              onPressed: pending || remote.busy
                                  ? null
                                  : () => act(() async {
                                      await widget
                                          .provider
                                          .storage
                                          .pendingMutations;
                                      await remote.resolve(
                                        widget.provider.storage.local,
                                        conflict,
                                        local,
                                        validate: validateAppDocument,
                                      );
                                      await widget.provider.reloadAll();
                                    }),
                              child: Text(
                                local ? 'Оставить устройство' : 'Взять облако',
                              ),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (pending || remote.busy) const LinearProgressIndicator(),
          const Text(
            'По умолчанию синхронизация по кнопке. Автоматический режим работает только в открытом приложении. При конфликте нет скрытого перезаписывания. '
            'На общем устройстве не смешивайте аккаунты: локальная база привязывается к первому аккаунту.',
          ),
        ],
      );
    },
  );
}

class BadgePanel extends StatelessWidget {
  final AppDataProvider provider;
  const BadgePanel({super.key, required this.provider});
  @override
  Widget build(BuildContext context) {
    final data = provider.storage.local;
    final waterDates = <DateTime>[];
    final waterGoal = provider.confirmedWaterGoal;
    var workout1000 = false;
    for (final key in data.getKeys()) {
      if (waterGoal != null &&
          key.startsWith('water_intake_') &&
          (data.getInt(key) ?? 0) >= waterGoal) {
        final date = DateTime.tryParse(key.substring(13));
        if (date != null) waterDates.add(date);
      }
      if (key.startsWith('workout_entries_')) {
        final list = data.decoded(key) as List? ?? [];
        workout1000 |= list.any(
          (e) => number((e as Map)['caloriesBurned']) >= 1000,
        );
      }
    }
    waterDates.sort();
    var run = 0, best = 0;
    DateTime? prev;
    for (final day in waterDates) {
      run =
          prev != null &&
              DateTime.utc(day.year, day.month, day.day)
                      .difference(DateTime.utc(prev.year, prev.month, prev.day))
                      .inDays ==
                  1
          ? run + 1
          : 1;
      best = max(best, run);
      prev = day;
    }
    final proteinGoal = provider.targetProteinToday;
    final protein =
        proteinGoal != null &&
        proteinGoal > 0 &&
        provider.todayProteinConsumed >= proteinGoal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '🔥 Дневник без пропусков: ${provider.currentStreak} дн. · рекорд ${provider.bestStreak}',
        ),
        for (final badge in [
          (best >= 7, 'Водный баланс: 7 дней подряд'),
          (protein, 'Цель по белку за выбранный день'),
          (workout1000, 'Тренировка на 1000 ккал'),
        ])
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              badge.$1 ? Icons.verified : Icons.lock_outline,
              color: badge.$1 ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(badge.$2),
          ),
        const Text(
          'Достижения рассчитываются из истории, не требуют сервера. Водная серия сравнивается с текущей целью воды.',
        ),
      ],
    );
  }
}

class CustomFoodPanel extends StatelessWidget {
  final AppDataProvider provider;
  const CustomFoodPanel({super.key, required this.provider});
  @override
  Widget build(BuildContext context) {
    final store = provider.storage.local;
    final expected = store.get('custom_foods');
    final generation = store.diaryGeneration;
    late final List<String> rawRows;
    late final List<Json> foods;
    try {
      if (expected != null && expected is! String)
        throw const FormatException();
      if (expected != null) validateAppDocument('custom_foods', expected);
      rawRows = rawJsonArrayElements((expected as String?) ?? '[]');
      foods = rawRows.map(uniqueJsonObject).toList();
    } catch (_) {
      return const Text(
        'Свою базу не удалось безопасно прочитать. Данные не изменены; сохраните резервную копию и откройте её в совместимой версии.',
      );
    }
    bool nameExists(String name, {int? except}) => foods.indexed.any(
      (item) =>
          item.$1 != except &&
          (item.$2['name'] as String).trim().toLowerCase() ==
              name.trim().toLowerCase(),
    );

    Future<void> save(List<String> nextRows) async {
      var committed = false;
      try {
        if (store.diaryGeneration != generation) {
          throw StateError('Дневник заменён. Обновите экран и повторите.');
        }
        final next = '[${nextRows.join(',')}]';
        if (expected != null) validateAppDocument('custom_foods', expected);
        validateAppDocument('custom_foods', next);
        final saved = await store.compareAndPut(
          'custom_foods',
          expected,
          next,
          authorizationGuard: () => store.diaryGeneration == generation,
        );
        if (!saved) {
          throw StateError('Своя база изменилась. Обновите экран и повторите.');
        }
        committed = true;
        await provider.refresh();
      } catch (e) {
        if (context.mounted) {
          await notice(
            context,
            committed
                ? 'Изменение сохранено, но экран не обновился. Обновите приложение.'
                : store.diaryGeneration != generation
                ? 'Дневник заменён. Обновите экран и повторите.'
                : e,
          );
        }
      }
    }

    return Column(
      children: [
        for (final (index, f) in foods.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(f['name'] as String),
            subtitle: Text('${f['caloriesPer100g']} ккал / 100 г'),
            onTap: () async {
              final edited = await showDialog<Json>(
                context: context,
                builder: (_) => _FoodDraftDialog(f),
              );
              if (edited != null) {
                if (nameExists(edited['name'] as String, except: index)) {
                  if (context.mounted) {
                    await notice(
                      context,
                      'Такой продукт уже есть в своей базе.',
                    );
                  }
                  return;
                }
                try {
                  final before = Map<String, dynamic>.of(f);
                  if (before['micros'] != null && before['micros'] is! Map) {
                    throw const FormatException();
                  }
                  // Treat absent micros as empty only for comparison; the raw
                  // field is retained unchanged unless the user edits it.
                  before['micros'] ??= <String, dynamic>{};
                  final nextRows = List<String>.of(rawRows);
                  nextRows[index] = patchFoodRow(
                    rawRows[index],
                    before,
                    edited,
                  );
                  await save(nextRows);
                } catch (_) {
                  if (context.mounted) {
                    await notice(
                      context,
                      'Не удалось безопасно изменить продукт. Данные не изменены.',
                    );
                  }
                }
              }
            },
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Добавить порцию в дневник',
                  onPressed: () async {
                    final grams = await askPositiveNumber(
                      context,
                      'Вес порции, г',
                      100,
                    );
                    if (grams == null) return;
                    final raw = Map<String, dynamic>.of(f)
                      ..['id'] = newId()
                      ..['date'] = provider.selectedDate.toIso8601String()
                      ..['amountGrams'] = grams
                      ..['mealType'] = MealType.snack.index
                      ..['timeKnown'] = true
                      ..['loggedAt'] = foodTime(
                        provider.selectedDate,
                      ).toIso8601String();
                    try {
                      await provider.addFoodEntry(FoodEntry.fromJson(raw));
                      if (context.mounted &&
                          provider.persistenceError != null) {
                        await notice(context, provider.persistenceError!);
                      }
                    } catch (_) {
                      if (context.mounted) {
                        await notice(
                          context,
                          provider.persistenceError ??
                              'Не удалось сохранить продукт.',
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.add_circle_outline),
                ),
                IconButton(
                  tooltip: 'Удалить из своей базы',
                  onPressed: () async {
                    final nextRows = List<String>.of(rawRows)..removeAt(index);
                    await save(nextRows);
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        OutlinedButton.icon(
          onPressed: () async {
            final draft = await showDialog<Json>(
              context: context,
              builder: (_) => const _FoodDraftDialog({}),
            );
            if (draft != null) {
              if (nameExists(draft['name'] as String)) {
                if (context.mounted) {
                  await notice(context, 'Такой продукт уже есть в своей базе.');
                }
                return;
              }
              await save([...rawRows, jsonEncode(draft)]);
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('Создать продукт с микронутриентами'),
        ),
      ],
    );
  }
}

class _FoodDraftDialog extends StatefulWidget {
  final Json initial;
  const _FoodDraftDialog(this.initial);
  @override
  State<_FoodDraftDialog> createState() => _FoodDraftDialogState();
}

class _FoodDraftDialogState extends State<_FoodDraftDialog> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(
    text: widget.initial['name'] as String? ?? '',
  );
  late final fields = {
    for (final k in [
      'caloriesPer100g',
      'proteinPer100g',
      'fatPer100g',
      'carbsPer100g',
    ])
      k: TextEditingController(text: widget.initial[k]?.toString() ?? ''),
  };
  late Map<String, double> micros = readMicros(widget.initial['micros']);
  @override
  void dispose() {
    name.dispose();
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Своя база · на 100 г'),
    content: SizedBox(
      width: 400,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Название'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Укажите название' : null,
              ),
              for (final e in fields.entries)
                TextFormField(
                  controller: e.value,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: const {
                      'caloriesPer100g': 'Калории',
                      'proteinPer100g': 'Белки, г',
                      'fatPer100g': 'Жиры, г',
                      'carbsPer100g': 'Углеводы, г',
                    }[e.key],
                  ),
                  validator: (v) => parseNutritionNumber(v ?? '') == null
                      ? 'Укажите число ≥ 0'
                      : null,
                ),
              TextButton(
                onPressed: () async {
                  final value = await editMicros(context, micros);
                  if (value != null) setState(() => micros = value);
                },
                child: Text(
                  'Микронутриенты: ${micros.length} из ${microLabels.length}',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate())
            Navigator.pop(context, {
              ...widget.initial,
              'name': name.text.trim(),
              // This client cannot edit newer micronutrient keys. Keep their
              // raw values rather than silently deleting them on a rename.
              'micros': {
                if (widget.initial['micros'] is Map)
                  for (final entry in (widget.initial['micros'] as Map).entries)
                    if (entry.key is String &&
                        !microLabels.containsKey(entry.key))
                      entry.key as String: entry.value,
                ...micros,
              },
              for (final e in fields.entries)
                e.key: parseNutritionNumber(e.value.text)!,
            });
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

typedef AiFoodRequester =
    Future<List<Json>> Function({
      required String text,
      Uint8List? image,
      required String mime,
      required String mode,
    });

class AiChatScreen extends StatelessWidget {
  final String? initialQuestion;
  final DateTimeRange? initialNutritionRange;
  const AiChatScreen({
    super.key,
    this.initialQuestion,
    this.initialNutritionRange,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ИИ-помощник')),
    body: CenteredBody(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AssistantHubPanel(
            initialQuestion: initialQuestion,
            initialNutritionRange: initialNutritionRange,
          ),
          const SizedBox(height: 16),
          const AiFoodPanel(chatMode: true),
          const SizedBox(height: 30),
        ],
      ),
    ),
  );
}

class AiFoodPanel extends StatefulWidget {
  final bool chatMode;
  final AiFoodRequester? requestOverride;
  const AiFoodPanel({super.key, this.chatMode = false, this.requestOverride});
  @override
  State<AiFoodPanel> createState() => _AiFoodPanelState();
}

// Screen-local only: switching accounts parks the previous account's draft in
// memory rather than showing it to the next account or silently discarding it.
class _AiFoodSession {
  final TextEditingController input;
  final List<_ChatMessage> messages;
  final Uint8List? image;
  final String mime, mode;
  final String? error, cacheWarning, photoInfo;
  const _AiFoodSession({
    required this.input,
    required this.messages,
    required this.image,
    required this.mime,
    required this.mode,
    required this.error,
    required this.cacheWarning,
    required this.photoInfo,
  });
}

class _AiFoodPanelState extends State<AiFoodPanel> {
  // SpeechToText is a process-wide singleton and platform results have no
  // account/session ID. Do not start it under a different account until a
  // full app restart has recreated the plugin and its callback state.
  static bool speechOwnerKnown = false, speechRestartRequired = false;
  static String? speechOwner;
  TextEditingController text = TextEditingController();
  final speech = SpeechToText();
  final List<_ChatMessage> messages = <_ChatMessage>[];
  Uint8List? image;
  String mime = 'image/jpeg';
  String mode = 'food';
  bool busy = false;
  bool photoBusy = false, reviewOpen = false;
  bool voiceListening = false, voicePreparing = false;
  bool voiceUsed = false, voiceDisabledAfterSwitch = false;
  int voiceSession = 0;
  String? error, cacheWarning, photoInfo;
  String? get owner => SmartRemote.instance.client?.auth.currentUser?.id;
  late String? displayedOwner;
  int accountGeneration = 0;
  final Map<String?, _AiFoodSession> parked = {};

  bool currentGeneration(int generation) =>
      mounted && generation == accountGeneration && owner == displayedOwner;

  @override
  void initState() {
    super.initState();
    displayedOwner = owner;
    if (speechOwnerKnown && speechOwner != displayedOwner) {
      speechRestartRequired = true;
    }
    voiceDisabledAfterSwitch = speechRestartRequired;
    SmartRemote.instance.addListener(accountChanged);
    LocalPreferences.privacyChanges.addListener(privacyChanged);
  }

  void privacyChanged() {
    if (!mounted ||
        (!voicePreparing && !voiceListening && !speech.isListening)) {
      return;
    }
    // Stop active recognition and ignore callbacks from the old epoch. Audio
    // already processed by the platform/browser cannot be recalled.
    voiceSession++;
    voiceListening = false;
    unawaited(speech.cancel().catchError((_) {}));
    setState(
      () => error =
          'Настройки конфиденциальности изменились. Диктовка остановлена.',
    );
  }

  void accountChanged() {
    final next = owner;
    if (!mounted || next == displayedOwner) return;
    parked[displayedOwner] = _AiFoodSession(
      input: text,
      messages: List<_ChatMessage>.of(messages),
      image: image,
      mime: mime,
      mode: mode,
      error: error,
      cacheWarning: cacheWarning,
      photoInfo: photoInfo,
    );
    displayedOwner = next;
    accountGeneration++;
    final restored = parked.remove(next);
    final interruptedReview = reviewOpen;
    final interruptedPhoto = photoBusy;
    reviewOpen = false;
    voiceListening = false;
    voiceSession++;
    if (voiceUsed || (speechOwnerKnown && speechOwner != next)) {
      speechRestartRequired = true;
      voiceDisabledAfterSwitch = true;
    }
    // Do not allow callbacks from an earlier account's dictation to populate
    // the next account's input. Cancellation cannot recall audio already sent
    // to the device/browser's speech service.
    unawaited(speech.cancel().catchError((_) {}));
    setState(() {
      text = restored?.input ?? TextEditingController();
      messages
        ..clear()
        ..addAll(restored?.messages ?? const <_ChatMessage>[]);
      image = restored?.image;
      mime = restored?.mime ?? 'image/jpeg';
      mode = restored?.mode ?? 'food';
      photoInfo = restored?.photoInfo;
      cacheWarning = restored?.cacheWarning;
      error = interruptedReview
          ? 'Аккаунт изменился. Окно проверки закрыто; незавершённые правки в нём '
                'не восстанавливаются автоматически. Проверьте дневник перед повтором.'
          : interruptedPhoto
          ? 'Аккаунт изменился. Результат незавершённого выбора фото не будет применён; при необходимости выберите фото заново.'
          : restored?.error ??
                'Аккаунт изменился. Чат и ввод другого аккаунта скрыты до возврата '
                    'и только пока открыт этот экран. Отправленный запрос нельзя отозвать, '
                    'но его результат не будет применён.';
      busy = false;
      photoBusy = false;
      voicePreparing = false;
    });
  }

  @override
  void dispose() {
    SmartRemote.instance.removeListener(accountChanged);
    LocalPreferences.privacyChanges.removeListener(privacyChanged);
    speech.cancel();
    text.dispose();
    for (final session in parked.values) {
      session.input.dispose();
    }
    parked.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on auth changes: another account must never see cached drafts.
    return ListenableBuilder(
      listenable: SmartRemote.instance,
      builder: (context, _) {
        final account = displayedOwner;
        final generation = accountGeneration;
        final accountCache = account == null
            ? null
            : AiDraftCache(
                context.read<AppDataProvider>().storage.local,
                account,
              );
        final recent = accountCache?.read() ?? <Json>[];
        return _section(
          context,
          widget.chatMode
              ? 'AI-чат · текст / фото / голос'
              : 'AI-дневник · текст / фото / голос',
          [
            if (widget.chatMode) ...[
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Диалог · только на этом экране',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Очистить историю чата',
                    onPressed: messages.isEmpty || busy
                        ? null
                        : () {
                            if (currentGeneration(generation)) {
                              setState(() => messages.clear());
                            }
                          },
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ),
              if (messages.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'История и незаконченный ввод хранятся только пока открыт этот экран; '
                    'при смене аккаунта они скрыты. Недавние черновики и избранное доступны ниже отдельно.',
                  ),
                ),
              for (final message in messages)
                Align(
                  alignment: message.fromUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 330),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: message.fromUser
                          ? AppTheme.primary.withValues(alpha: 0.18)
                          : AppTheme.surfaceHigh,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(message.text),
                        if (message.hadPhoto)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text(
                              'Фото обработано и удалено из поля ввода.',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        if (message.draft.isNotEmpty)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => review(
                                      message.draft,
                                      message.date ??
                                          context
                                              .read<AppDataProvider>()
                                              .selectedDate,
                                      account,
                                    ),
                              icon: const Icon(
                                Icons.fact_check_outlined,
                                size: 17,
                              ),
                              label: const Text('Открыть черновик'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const Divider(height: 26),
            ],
            const Text(
              'Опишите еду обычными словами. AI оценит КБЖУ и доступные витамины; в дневник попадёт только подтверждённый черновик.',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => showSupplementAiInput(
                      context,
                      context.read<AppDataProvider>(),
                    ),
              icon: const Icon(Icons.medication_outlined),
              label: const Text('Витамины и добавки через ИИ'),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'food',
                  icon: Icon(Icons.restaurant_outlined),
                  label: Text('Еда'),
                ),
                ButtonSegment(
                  value: 'label',
                  icon: Icon(Icons.document_scanner_outlined),
                  label: Text('Этикетка'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: busy
                  ? null
                  : (selected) {
                      if (currentGeneration(generation)) {
                        setState(() {
                          mode = selected.first;
                          error = null;
                        });
                      }
                    },
            ),
            if (mode == 'label')
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Сфотографируйте таблицу КБЖУ. Если цифры не читаются, AI не должен их угадывать. Проверьте единицы: на 100 г или на порцию.',
                ),
              ),
            const SizedBox(height: 10),
            TextField(
              key: ValueKey(('ai-food-input', account)),
              controller: text,
              enabled: !busy,
              maxLines: 3,
              maxLength: 4000,
              decoration: InputDecoration(
                hintText: mode == 'label'
                    ? 'Упаковка 200 г, съел половину. Название продукта…'
                    : 'На обед 2 булочки с фото, на ужин ещё 1. Одна примерно 80 г.',
                helperText: 'Количество · вес · приём пищи — если известны',
                helperMaxLines: 2,
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Tooltip(
                  message: 'Фото из галереи',
                  child: OutlinedButton.icon(
                    onPressed: busy || photoBusy
                        ? null
                        : () => photo(ImageSource.gallery),
                    icon: const Icon(Icons.photo_outlined, size: 18),
                    label: const Text('Галерея'),
                  ),
                ),
                Tooltip(
                  message: 'Камера',
                  child: OutlinedButton.icon(
                    onPressed: busy || photoBusy
                        ? null
                        : () => photo(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text('Камера'),
                  ),
                ),
                Tooltip(
                  message: speech.isListening
                      ? 'Остановить диктовку'
                      : 'Голосовой ввод (системное распознавание)',
                  child: OutlinedButton.icon(
                    onPressed:
                        busy ||
                            photoBusy ||
                            voicePreparing ||
                            voiceDisabledAfterSwitch
                        ? null
                        : voice,
                    icon: Icon(
                      speech.isListening
                          ? Icons.stop_circle_outlined
                          : Icons.mic_none,
                      size: 18,
                    ),
                    label: Text(speech.isListening ? 'Стоп' : 'Диктовка'),
                  ),
                ),
                if (image != null)
                  TextButton.icon(
                    onPressed: busy || photoBusy
                        ? null
                        : () {
                            if (currentGeneration(generation)) {
                              setState(() {
                                image = null;
                                photoInfo = null;
                              });
                            }
                          },
                    icon: const Icon(Icons.close, size: 17),
                    label: const Text('Убрать фото'),
                  ),
                if (photoBusy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (voiceDisabledAfterSwitch)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Диктовка отключена после смены аккаунта. Чтобы включить её, '
                  'сохраните нужный текст и перезапустите приложение или обновите страницу. '
                  'Несохранённый чат при этом очистится.',
                ),
              ),
            if (photoInfo != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  photoInfo!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            if (image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 140,
                  child: Image.memory(
                    image!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Text('Не удалось показать предпросмотр'),
                    ),
                  ),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (cacheWarning != null) Text(cacheWarning!),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy || voicePreparing || photoBusy ? null : parse,
                icon: const Icon(Icons.auto_awesome),
                label: Text(
                  busy ? 'Готовим черновик…' : 'Разобрать и проверить',
                ),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text(
              'Оценка, не точное измерение. Фото и описание отправляются только после согласия. '
              'Нужны интернет и вход в аккаунт. После успешного ответа поле и фото очищаются. '
              'Диктовку выполняет сервис браузера или устройства; сырое аудио приложение не сохраняет.',
            ),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  voiceFallbackHint,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            AiPrivacyControls(
              key: ValueKey(('food-privacy', account)),
              store: context.read<AppDataProvider>().storage.local,
              owner: account,
              busy: busy,
            ),
            AiPersonalShortcuts(
              key: ValueKey(('food-shortcuts', account)),
              provider: context.read<AppDataProvider>(),
              owner: account,
              busy: busy,
              onReview: (rows) => review(
                rows,
                context.read<AppDataProvider>().selectedDate,
                account,
              ),
            ),
            if (recent.isNotEmpty) ...[
              const Divider(height: 28),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Недавние черновики',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Очистить недавние черновики',
                    onPressed: busy
                        ? null
                        : () async {
                            if (!currentGeneration(generation)) return;
                            try {
                              await accountCache?.clear();
                              if (currentGeneration(generation))
                                setState(() {});
                            } catch (_) {
                              if (currentGeneration(generation)) {
                                setState(
                                  () => cacheWarning =
                                      'Не удалось очистить историю. Попробуйте ещё раз.',
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              const Text(
                'Без нового AI-запроса · только на этом устройстве · фото не сохраняются',
              ),
              for (final record in recent)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text(
                    (record['items'] as List)
                        .map((e) => e['name'])
                        .take(3)
                        .join(', '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${(record['items'] as List).length} поз. · ${AiPortionTotals.fromItems((record['items'] as List).cast<Json>()).calories.round()} ккал · проверить и повторить',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy
                      ? null
                      : () => review(
                          (record['items'] as List).cast<Json>(),
                          context.read<AppDataProvider>().selectedDate,
                          account,
                        ),
                ),
            ],
          ],
        );
      },
    );
  }

  Future<void> photo(ImageSource source) async {
    if (busy || photoBusy) return;
    final generation = accountGeneration;
    if (!currentGeneration(generation)) return;
    setState(() {
      photoBusy = true;
      error = null;
    });
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 75,
        requestFullMetadata: false,
      );
      if (file == null || !currentGeneration(generation)) return;
      final originalLength = await file.length();
      if (!currentGeneration(generation)) return;
      if (originalLength > 12 * 1024 * 1024) {
        throw ArgumentError(
          'Фото больше 12 МБ до сжатия. Выберите изображение поменьше.',
        );
      }
      final bytes = await file.readAsBytes();
      if (!currentGeneration(generation)) return;
      final compressed = await compressPhoto(bytes);
      if (!currentGeneration(generation)) return;
      setState(() {
        image = compressed.bytes;
        mime = compressed.mime;
        photoInfo =
            'Сжато: ${compressed.width}×${compressed.height}, ${compressed.sizeLabel} '
            'вместо ${(originalLength / 1024).round()} КБ';
        error = null;
      });
    } catch (e) {
      if (currentGeneration(generation)) {
        setState(() => error = friendlyAiError(e));
      }
    } finally {
      if (currentGeneration(generation)) setState(() => photoBusy = false);
    }
  }

  Future<void> voice() async {
    final generation = accountGeneration;
    final privacyEpoch = LocalPreferences.privacyEpoch;
    bool current() =>
        currentGeneration(generation) &&
        LocalPreferences.privacyEpochIsCurrent(privacyEpoch);
    if (!current() || voicePreparing) return;
    if (speechRestartRequired ||
        voiceDisabledAfterSwitch ||
        (speechOwnerKnown && speechOwner != displayedOwner)) {
      setState(() {
        speechRestartRequired = true;
        voiceDisabledAfterSwitch = true;
      });
      return;
    }
    setState(() => voicePreparing = true);
    try {
      if (speech.isListening || voiceListening) {
        voiceListening = false;
        voiceSession++;
        if (speech.isListening) unawaited(speech.stop());
        if (currentGeneration(generation)) setState(() {});
        return;
      }
      if (kIsWeb) {
        final accepted = await ensureVoiceNotice(
          context,
          context.read<AppDataProvider>().storage.local,
        );
        if (!current()) return;
        if (!accepted) {
          setState(() => error = voiceFallbackHint);
          return;
        }
      }
      speechOwnerKnown = true;
      speechOwner = displayedOwner;
      voiceUsed = true;
      void onError(SpeechRecognitionError e) {
        if (current()) {
          setState(() => error = friendlyVoiceError(e));
        }
      }

      void onStatus(String status) {
        if (!current()) return;
        if (status == 'notListening' || status.contains('done')) {
          voiceListening = false;
        }
        setState(() {});
      }

      final available = await speech.initialize(
        onError: onError,
        onStatus: onStatus,
      );
      if (!current()) return;
      // initialize() returns early once the singleton is initialized. Refresh
      // its callbacks when this screen is recreated for the same account.
      speech.errorListener = onError;
      speech.statusListener = onStatus;
      if (!available) {
        throw StateError(
          'Браузер не поддерживает встроенную диктовку. $voiceFallbackHint',
        );
      }
      final locales = await speech.locales();
      if (!current()) return;
      if (kIsWeb &&
          context.read<AppDataProvider>().storage.local.getString(
                '_voice_notice_v1',
              ) !=
              'accepted') {
        return;
      }
      final localeId = resolveSpeechLocale(
        web: kIsWeb,
        locales: locales.map((e) => e.localeId).toList(),
      );
      // The plugin does not tag late platform events by account. After a
      // switch we cancel dictation and require an app restart before reuse.
      final session = ++voiceSession;
      voiceListening = true;
      await speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          listenFor: const Duration(seconds: 25),
          pauseFor: const Duration(seconds: 3),
          cancelOnError: true,
        ),
        onResult: (result) {
          if (current() &&
              acceptVoiceResult(
                listening: voiceListening,
                session: session,
                currentSession: voiceSession,
              )) {
            setState(() => text.text = result.recognizedWords);
          }
        },
      );
      if (current()) setState(() => error = null);
    } catch (e) {
      if (current()) {
        setState(
          () => error = e is StateError ? e.message : friendlyAiError(e),
        );
      }
    } finally {
      if (currentGeneration(generation)) {
        setState(() => voicePreparing = false);
      }
    }
  }

  Future<void> review(List<Json> items, DateTime date, String? account) async {
    final generation = accountGeneration;
    if (!currentGeneration(generation) || account != displayedOwner) return;
    if (items.isEmpty) {
      setState(
        () => error = mode == 'label'
            ? 'Не удалось прочитать КБЖУ с этикетки. Нужна чёткая таблица на 100 г или на порцию с известным весом. Значения не угаданы — ничего не добавлено.'
            : 'Еда не найдена. Уточните название, количество или приложите более чёткое фото. Ничего не добавлено.',
      );
      return;
    }
    reviewOpen = true;
    int? saved;
    try {
      saved = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AiReviewDialog(
          items: items,
          provider: context.read<AppDataProvider>(),
          date: date,
          owner: account,
        ),
      );
    } finally {
      if (currentGeneration(generation)) reviewOpen = false;
    }
    if (currentGeneration(generation)) {
      setState(() {});
      if (saved != null) {
        final p = context.read<AppDataProvider>();
        final snapshot = account == null
            ? <Json>[]
            : AiUndoStore(p.storage.local, account).read();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Добавлено продуктов: $saved. Записи в разделе «Питание».',
            ),
            duration: const Duration(seconds: 8),
            action: account == null || snapshot.isEmpty
                ? null
                : SnackBarAction(
                    label: 'Отменить',
                    onPressed: () async {
                      try {
                        await undoAiAddition(p, account, original: snapshot);
                        if (mounted) setState(() {});
                      } catch (e) {
                        if (mounted) notice(context, friendlyAiError(e));
                      }
                    },
                  ),
          ),
        );
      }
    }
  }

  Future<void> parse() async {
    if (busy || voicePreparing || photoBusy) return;
    final generation = accountGeneration;
    if (!currentGeneration(generation)) return;
    if (!SmartRemote.instance.signedIn) {
      setState(
        () => error =
            'Для AI войдите в разделе «Аккаунт» ниже. Дневник и ручной ввод работают без входа.',
      );
      return;
    }
    if (mode == 'label' && image == null) {
      setState(() => error = 'Добавьте фото таблицы пищевой ценности.');
      return;
    }
    if (text.text.trim().isEmpty && image == null) {
      setState(() => error = 'Напишите, что вы съели, или добавьте фото.');
      return;
    }
    if (speech.isListening || voiceListening) {
      voiceListening = false;
      voiceSession++;
      // Some web implementations leave stop() pending until the next status
      // event. Invalidate the session first and never block the AI request.
      if (speech.isListening) unawaited(speech.stop());
    }
    if (!mounted) return;
    // Snapshot the whole request. Nothing mutable is read after the await, and
    // the input is cleared only after a valid response arrives.
    final date = context.read<AppDataProvider>().selectedDate;
    final account = owner;
    if (account == null) return;
    final privacyEpoch = LocalPreferences.privacyEpoch;
    final prompt = text.text.trim();
    final requestMode = mode;
    final photoBytes = image;
    final photoMime = mime;
    final hadPhoto = photoBytes != null;
    setState(() => busy = true);
    final consent = await ensureAiConsent(
      context,
      context.read<AppDataProvider>().storage.local,
      account,
      authorizationGuard: () => currentGeneration(generation),
    );
    if (!currentGeneration(generation)) return;
    if (!consent) {
      setState(() => busy = false);
      return;
    }
    setState(() {
      busy = true;
      error = null;
      cacheWarning = null;
    });
    try {
      if (account != owner ||
          !AiConsent(
            context.read<AppDataProvider>().storage.local,
            account,
          ).validFor(privacyEpoch)) {
        throw StateError(
          'Аккаунт или согласие изменились. Запрос не отправлен.',
        );
      }
      final items = widget.requestOverride != null
          ? await widget.requestOverride!(
              text: prompt,
              image: photoBytes,
              mime: photoMime,
              mode: requestMode,
            )
          : await SmartRemote.instance.parseFood(
              text: prompt,
              image: photoBytes,
              mime: photoMime,
              mode: requestMode,
            );
      if (!currentGeneration(generation)) return;
      if (account != owner)
        throw StateError(
          'Аккаунт изменился. Повторите запрос из своего аккаунта.',
        );
      if (!AiConsent(
        context.read<AppDataProvider>().storage.local,
        account,
      ).validFor(privacyEpoch)) {
        throw StateError(
          'Согласие отозвано или изменилось. Результат не применён.',
        );
      }
      try {
        // An optional cache failure must not make an invalidated answer usable.
        await AiDraftCache(
          context.read<AppDataProvider>().storage.local,
          account,
        ).remember(items);
      } catch (_) {
        if (currentGeneration(generation)) {
          setState(
            () => cacheWarning =
                'Черновик готов, но не удалось сохранить его в недавние.',
          );
        }
      }
      if (!currentGeneration(generation)) return;
      if (!AiConsent(
        context.read<AppDataProvider>().storage.local,
        account,
      ).validFor(privacyEpoch)) {
        throw StateError(
          'Согласие отозвано или изменилось. Результат не применён.',
        );
      }
      final draft = List<Json>.from(items);
      if (widget.chatMode) {
        messages.add(
          _ChatMessage(
            text: prompt.isEmpty
                ? (requestMode == 'label' ? 'Фото этикетки' : 'Фото еды')
                : prompt,
            fromUser: true,
            hadPhoto: hadPhoto,
          ),
        );
        messages.add(
          _ChatMessage(
            text: draft.isEmpty
                ? 'Продукты не выделены. Уточните запрос; ничего не добавлено в дневник.'
                : 'Подготовлен черновик: ${draft.length} поз. Проверьте КБЖУ и порции перед сохранением.',
            fromUser: false,
            draft: draft,
            date: date,
          ),
        );
      }
      // Successful processing: clear both text and photo. Errors preserve input.
      setState(() {
        text.clear();
        image = null;
        photoInfo = null;
      });
      // The review dialog is a separate route; do not keep an indeterminate
      // progress animation running behind it for the whole review.
      setState(() => busy = false);
      await review(items, date, account);
    } catch (e) {
      if (currentGeneration(generation)) {
        setState(() => error = friendlyAiError(e));
      }
    } finally {
      if (currentGeneration(generation) && busy) {
        setState(() => busy = false);
      }
    }
  }
}

class _ChatMessage {
  final String text;
  final bool fromUser;
  final bool hadPhoto;
  final List<Json> draft;
  final DateTime? date;
  const _ChatMessage({
    required this.text,
    required this.fromUser,
    this.hadPhoto = false,
    this.draft = const <Json>[],
    this.date,
  });
}

/// Confirm a draft before saving; optional refinement makes a separate AI call.
class AiReviewDialog extends StatefulWidget {
  final List<Json> items;
  final AppDataProvider provider;
  final DateTime date;
  final String? owner;
  const AiReviewDialog({
    super.key,
    required this.items,
    required this.provider,
    required this.date,
    this.owner,
  });
  @override
  State<AiReviewDialog> createState() => _AiReviewDialogState();
}

class _AiReviewDialogState extends State<AiReviewDialog> {
  late final List<Json> items = validateAiItems(
    widget.items,
  ).map((e) => {...e, '_entryId': newId()}).toList();
  late DateTime date = widget.date;
  late final AppDataProvider reviewProvider;
  late final String? reviewOwner, originalBinding;
  late final String reviewGeneration;
  late final int reviewPrivacyEpoch;
  bool saving = false, locked = false, refining = false, invalidated = false;
  bool get blocked => locked || refining;
  final refinement = TextEditingController();

  bool get sameOwnerAndBinding {
    final account = reviewOwner;
    if (account == null) return true; // Ownerless deterministic/manual review.
    final binding = reviewProvider.storage.local.getString('_bound_user');
    return !invalidated &&
        account == SmartRemote.instance.client?.auth.currentUser?.id &&
        binding == originalBinding &&
        (binding == null || binding == account);
  }

  bool get authorized =>
      reviewProvider.storage.local.diaryGeneration == reviewGeneration &&
      sameOwnerAndBinding &&
      (reviewOwner == null ||
          AiConsent(
            reviewProvider.storage.local,
            reviewOwner!,
          ).validFor(reviewPrivacyEpoch));

  @override
  void initState() {
    super.initState();
    // Capture before any asynchronous write or account transition.
    reviewProvider = widget.provider;
    reviewOwner = widget.owner;
    originalBinding = reviewProvider.storage.local.getString('_bound_user');
    reviewGeneration = reviewProvider.storage.local.diaryGeneration;
    reviewPrivacyEpoch = LocalPreferences.privacyEpoch;
    if (reviewOwner != null) {
      SmartRemote.instance.addListener(accountChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => accountChanged());
    }
  }

  void accountChanged() {
    if (!mounted ||
        invalidated ||
        reviewOwner == null ||
        reviewOwner == SmartRemote.instance.client?.auth.currentUser?.id) {
      return;
    }
    setState(() => invalidated = true);
    // A review can have a product editor, nutrient editor, date picker or
    // confirmation above it. Close those first, then remove this exact route;
    // removing it also works when a durable save has temporarily locked pop.
    final route = ModalRoute.of(context);
    final navigator = route?.navigator;
    if (route != null && navigator != null && route.isActive) {
      navigator.popUntil((candidate) => identical(candidate, route));
      if (route is DialogRoute && route.isActive) navigator.removeRoute(route);
    }
  }

  @override
  void dispose() {
    if (reviewOwner != null) {
      SmartRemote.instance.removeListener(accountChanged);
    }
    refinement.dispose();
    super.dispose();
  }

  String? error;

  Future<void> save() async {
    if (saving || refining || items.isEmpty) return;
    setState(() {
      saving = true;
      locked = true;
      error = null;
    });
    try {
      if (!authorized) {
        throw const AiRequestFailure(
          'Аккаунт или согласие изменились, дневник заменён либо дневник связан с другим аккаунтом. Продукты не добавлены.',
        );
      }
      final entries = items
          .map(
            (item) => FoodEntry(
              id: item['_entryId'] as String,
              name: item['name'] as String,
              caloriesPer100g: number(item['calories']),
              proteinPer100g: number(item['protein']),
              fatPer100g: number(item['fat']),
              carbsPer100g: number(item['carbs']),
              micros: readMicros(item['micros']),
              microsEstimated: readMicros(item['micros']).isNotEmpty,
              amountGrams: number(item['grams']),
              mealType: MealType.values.firstWhere(
                (m) => m.name == item['meal'],
                orElse: () => MealType.snack,
              ),
              date: date,
              loggedAt:
                  date, // Stable across retry; actual meal time remains unknown.
              timeKnown: false,
            ),
          )
          .toList();
      await reviewProvider.addFoodEntriesBatch(
        entries,
        authorizationGuard: () => authorized,
      );
      final account = reviewOwner;
      if (account != null) {
        try {
          await AiUndoStore(reviewProvider.storage.local, account).remember(
            entries.map((e) => e.toJson()).toList(),
            generation: reviewGeneration,
          );
        } catch (_) {
          /* Diary already committed; no unsafe undo will be offered. */
        }
        try {
          await AiDraftCache(
            reviewProvider.storage.local,
            account,
          ).remember(items);
        } catch (_) {
          /* Diary already saved. */
        }
      }
      if (mounted && !invalidated) {
        // Unlock the route first so PopScope does not veto the successful close.
        setState(() => saving = false);
        Navigator.pop(context, entries.length);
      }
    } catch (e) {
      if (mounted && !invalidated)
        setState(() {
          saving = false;
          error = !authorized
              ? 'Аккаунт или согласие изменились, дневник заменён либо дневник связан с другим аккаунтом. Продукты не добавлены.'
              : e is AiRequestFailure
              ? e.message
              : 'Не удалось завершить сохранение. Повторите без изменения набора — одинаковые записи не добавятся дважды. Если проблема остаётся, закройте окно и обновите дневник.';
        });
    }
  }

  Future<void> askRefinement() async {
    if (blocked || items.isEmpty) return;
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Что исправить?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: refinement,
                  autofocus: true,
                  maxLines: 3,
                  maxLength: 1000,
                  onChanged: (_) => update(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Уточнение к этому черновику',
                    hintText: 'Булочки с творогом, по 90 г. Кофе без сахара.',
                  ),
                ),
                const Text(
                  'Отправим только этот черновик и уточнение, без исходного фото и остального дневника. Это новый AI-запрос с тем же лимитом.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: refinement.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('Уточнить с AI'),
            ),
          ],
        ),
      ),
    );
    if (send == true && mounted && sameOwnerAndBinding) await refine();
  }

  Future<void> refine() async {
    if (blocked || refinement.text.trim().isEmpty || items.isEmpty) return;
    final account = widget.owner;
    if (account == null) {
      setState(() => error = 'Для уточнения нужен вход в аккаунт.');
      return;
    }
    if (!sameOwnerAndBinding) {
      setState(() => error = 'Аккаунт или привязка дневника изменились.');
      return;
    }
    setState(() {
      refining = true;
      error = null;
    });
    try {
      final consent = await ensureAiConsent(
        context,
        widget.provider.storage.local,
        account,
        authorizationGuard: () => mounted && sameOwnerAndBinding,
      );
      if (!consent || !mounted || !sameOwnerAndBinding) return;
      if (!authorized) {
        throw const AiRequestFailure(
          'Аккаунт или согласие изменились. Запрос не отправлен.',
        );
      }
      final updated = await SmartRemote.instance.parseFood(
        text: refinement.text,
        mode: 'refine',
        previousItems: validateAiItems(items),
      );
      if (!mounted || !sameOwnerAndBinding) return;
      if (!authorized) {
        throw const AiRequestFailure(
          'Согласие или дневник изменились. Уточнение не применено.',
        );
      }
      if (updated.isEmpty)
        throw const AiRequestFailure(
          'Не удалось уточнить набор. Прежний черновик оставлен без изменений.',
        );
      setState(() {
        items.clear();
        items.addAll(updated.map((e) => {...e, '_entryId': newId()}));
        refinement.clear();
      });
      try {
        await AiDraftCache(
          widget.provider.storage.local,
          account,
        ).remember(updated);
      } catch (_) {
        /* Optional cache. */
      }
    } catch (e) {
      if (mounted && !invalidated) {
        setState(() => error = friendlyAiError(e));
      }
    } finally {
      if (mounted && !invalidated) setState(() => refining = false);
    }
  }

  Future<void> pin() async {
    if (blocked || widget.owner == null) return;
    if (!authorized) {
      setState(
        () => error = 'Согласие или дневник изменились. Повторите запрос.',
      );
      return;
    }
    try {
      await pinAiFavorite(
        context,
        widget.provider,
        widget.owner!,
        validateAiItems(items),
      );
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    }
  }

  Future<void> edit(int index) async {
    final changed = await showDialog<Json>(
      context: context,
      builder: (_) => _AiItemDialog(items[index]),
    );
    if (changed != null && mounted && sameOwnerAndBinding) {
      setState(() => items[index] = changed);
    }
  }

  void scale(double factor) {
    if (items.any(
      (e) =>
          number(e['grams']) * factor > 20000 ||
          number(e['grams']) * factor < .1,
    )) {
      setState(
        () => error =
            'Вес порции должен быть от 0,1 до 20 000 г. Измените его вручную.',
      );
      return;
    }
    setState(() {
      for (final item in items) {
        item['grams'] = number(item['grams']) * factor;
      }
      error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.owner != null &&
        (invalidated ||
            widget.owner !=
                SmartRemote.instance.client?.auth.currentUser?.id)) {
      return AlertDialog(
        title: const Text('Аккаунт изменился'),
        content: const Text('Черновик предыдущего аккаунта скрыт.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('Закрыть'),
          ),
        ],
      );
    }
    final totals = AiPortionTotals.fromItems(items);
    return PopScope(
      canPop: !saving && !refining,
      child: AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('Черновик AI')),
            IconButton(
              tooltip: 'В избранное',
              onPressed: blocked || widget.owner == null || items.isEmpty
                  ? null
                  : pin,
              icon: const Icon(Icons.star_outline),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today_outlined, size: 18),
                  label: Text('В дневник за ${formatDateRu(date)}'),
                  onPressed: blocked
                      ? null
                      : () async {
                          final chosen = await showDatePicker(
                            context: context,
                            initialDate: date,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (chosen != null &&
                              mounted &&
                              sameOwnerAndBinding) {
                            setState(() => date = chosen);
                          }
                        },
                ),
                const SizedBox(height: 8),
                Text(
                  '${totals.calories.round()} ккал · ${totals.grams.toStringAsFixed(0)} г',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  'За весь набор: Б ${totals.protein.toStringAsFixed(1)} · Ж ${totals.fat.toStringAsFixed(1)} · У ${totals.carbs.toStringAsFixed(1)} г',
                ),
                const SizedBox(height: 10),
                const Text(
                  'Это оценка, включая витамины и минералы. Проверьте вес, состав и упаковку; неизвестное не считается нулём. Значения ниже — на порцию, в редакторе — на 100 г. Время еды не угадывается.',
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    ActionChip(
                      label: const Text('Всё ×½'),
                      onPressed: blocked ? null : () => scale(.5),
                    ),
                    ActionChip(
                      label: const Text('Всё ×2'),
                      onPressed: blocked ? null : () => scale(2),
                    ),
                  ],
                ),
                DropdownButtonFormField<MealType>(
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Назначить всем приём пищи',
                  ),
                  items: [
                    for (final meal in MealType.values)
                      DropdownMenuItem(value: meal, child: Text(meal.label)),
                  ],
                  onChanged: blocked
                      ? null
                      : (meal) {
                          if (meal != null)
                            setState(() {
                              for (final item in items) {
                                item['meal'] = meal.name;
                              }
                            });
                        },
                ),
                for (final meal in MealType.values)
                  if (items.any((e) => e['meal'] == meal.name)) ...[
                    const SizedBox(height: 18),
                    Text(
                      '${meal.label} · ${AiPortionTotals.fromItems(items.where((e) => e['meal'] == meal.name)).calories.round()} ккал',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    for (final item in items.where(
                      (e) => e['meal'] == meal.name,
                    ))
                      Card(
                        margin: const EdgeInsets.only(top: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      item['name'] as String,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Убрать из результата',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: blocked
                                        ? null
                                        : () => setState(
                                            () => items.remove(item),
                                          ),
                                    icon: const Icon(Icons.close, size: 20),
                                  ),
                                ],
                              ),
                              Text(
                                '${number(item['grams']).toStringAsFixed(1)} г · ${AiPortionTotals.fromItems([item]).calories.round()} ккал',
                              ),
                              Text(
                                'Б ${AiPortionTotals.fromItems([item]).protein.toStringAsFixed(1)} · Ж ${AiPortionTotals.fromItems([item]).fat.toStringAsFixed(1)} · У ${AiPortionTotals.fromItems([item]).carbs.toStringAsFixed(1)} г',
                              ),
                              Text(
                                '${item['assumptions']}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (readMicros(item['micros']).isEmpty)
                                const Text('Витамины и минералы: нет данных')
                              else
                                ExpansionTile(
                                  tilePadding: EdgeInsets.zero,
                                  title: Text(
                                    'Витамины и минералы · оценка ИИ (${readMicros(item['micros']).length})',
                                  ),
                                  subtitle: const Text(
                                    'На указанную порцию; проверьте значения',
                                  ),
                                  children: [
                                    for (final e in readMicros(
                                      item['micros'],
                                    ).entries)
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          '${microLabels[e.key]}: ${formatNutrient(e.value * number(item['grams']) / 100)}',
                                        ),
                                      ),
                                  ],
                                ),
                              Wrap(
                                spacing: 4,
                                children: [
                                  TextButton.icon(
                                    onPressed: blocked
                                        ? null
                                        : () => edit(items.indexOf(item)),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 16,
                                    ),
                                    label: const Text('Изменить'),
                                  ),
                                  TextButton(
                                    onPressed: blocked
                                        ? null
                                        : () async {
                                            final grams =
                                                await askPositiveNumber(
                                                  context,
                                                  'Вес порции, г',
                                                  number(item['grams']),
                                                );
                                            if (grams != null &&
                                                mounted &&
                                                sameOwnerAndBinding) {
                                              if (grams > 20000) {
                                                setState(
                                                  () => error =
                                                      'Максимальный вес одной позиции — 20 000 г.',
                                                );
                                              } else {
                                                setState(
                                                  () => item['grams'] = grams,
                                                );
                                              }
                                            }
                                          },
                                    child: const Text('Вес порции'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Все продукты убраны. Закройте окно и уточните описание.',
                    ),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (saving || refining) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: blocked || items.isEmpty ? null : askRefinement,
            child: const Text('Уточнить словами'),
          ),
          TextButton(
            onPressed: saving || refining ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: saving || refining || items.isEmpty ? null : save,
            child: Text(
              saving
                  ? 'Сохраняем…'
                  : 'Добавить ${items.length} · ${totals.calories.round()} ккал',
            ),
          ),
        ],
      ),
    );
  }
}

class DailyBalanceCard extends StatelessWidget {
  final AppDataProvider provider;
  const DailyBalanceCard({super.key, required this.provider});
  @override
  Widget build(BuildContext context) {
    final p = provider;
    final protein = p.targetProteinToday == null
        ? null
        : max(0.0, p.targetProteinToday! - p.todayProteinConsumed);
    final fat = p.targetFatToday == null
        ? null
        : max(0.0, p.targetFatToday! - p.todayFatConsumed);
    final carbs = p.targetCarbsToday == null
        ? null
        : max(0.0, p.targetCarbsToday! - p.todayCarbsConsumed);
    final remaining = p.caloriesRemaining;
    final hasFood = p.todayFoodEntries.isNotEmpty;
    final waterGoal = p.confirmedWaterGoal;
    return _section(context, 'Ваш баланс · ${formatDateRu(p.selectedDate)}', [
      Text(
        !hasFood
            ? 'Питание за этот день не записано'
            : remaining == null
            ? 'По записям: ${p.todayCaloriesConsumed} ккал. Подтвердите цели в настройках.'
            : remaining >= 0
            ? 'До ориентира по записанному: $remaining ккал'
            : 'По записанному выше ориентира на ${-remaining} ккал',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      if (hasFood && (protein != null || fat != null || carbs != null)) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (protein != null)
              Chip(label: Text('Белки ещё ${protein.round()} г')),
            if (fat != null) Chip(label: Text('Жиры ещё ${fat.round()} г')),
            if (carbs != null)
              Chip(label: Text('Углеводы ещё ${carbs.round()} г')),
          ],
        ),
      ],
      Text(
        !hasFood
            ? 'Пока нет записей за этот день. Сначала внесите еду — баланс отражает только записанное.'
            : remaining == null
            ? 'Цели можно проверить в настройках. Записанное питание видно независимо от цели.'
            : remaining < 0
            ? 'Это ориентир, не оценка вас. Не нужно компенсировать превышение голоданием или дополнительной тренировкой.'
            : protein != null && protein >= 20 && remaining >= 150
            ? 'Для следующего приёма можно рассмотреть источник белка: творог, рыбу, бобовые или тофу. Выбирайте с учётом предпочтений и аллергий.'
            : 'Ориентируйтесь также на голод и самочувствие. Не обязательно добирать каждую цифру до точного совпадения.',
      ),
      const SizedBox(height: 8),
      Text(
        p.hasRecordedWater
            ? (waterGoal == null
                  ? 'Вода по записям: ${p.todayWaterIntake} мл · цель не подтверждена.'
                  : 'Вода: ${p.todayWaterIntake} / $waterGoal мл. Потребности индивидуальны; медицинские ограничения важнее цели приложения.')
            : (waterGoal == null
                  ? 'Вода за день не записана. Цель не подтверждена.'
                  : 'Вода за день не записана. Ориентир в настройках: $waterGoal мл; потребности индивидуальны.'),
      ),
      const SizedBox(height: 6),
      const Text(
        'Рассчитано на устройстве по вашим целям и записям. Профиль и история не отправляются в AI.',
        style: TextStyle(fontSize: 12),
      ),
    ]);
  }
}

/// Shared review editor for food drafts and explicit diary-change proposals.
Future<Json?> editAiFoodProposal(BuildContext context, Json item) =>
    showDialog<Json>(context: context, builder: (_) => _AiItemDialog(item));

class _AiItemDialog extends StatefulWidget {
  final Json item;
  const _AiItemDialog(this.item);
  @override
  State<_AiItemDialog> createState() => _AiItemDialogState();
}

class _AiItemDialogState extends State<_AiItemDialog> {
  final form = GlobalKey<FormState>();
  late final fields = {
    for (final k in ['name', 'grams', 'calories', 'protein', 'fat', 'carbs'])
      k: TextEditingController(text: '${widget.item[k]}'),
  };
  late Map<String, double> micros = readMicros(widget.item['micros']);
  late String meal =
      MealType.values
          .where((m) => m.name == widget.item['meal'])
          .firstOrNull
          ?.name ??
      'snack';
  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Уточнить продукт'),
    content: Form(
      key: form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in fields.entries)
              TextFormField(
                controller: e.value,
                decoration: InputDecoration(
                  labelText: const {
                    'name': 'Название',
                    'grams': 'Вес порции, г',
                    'calories': 'Ккал на 100 г',
                    'protein': 'Белки на 100 г',
                    'fat': 'Жиры на 100 г',
                    'carbs': 'Углеводы на 100 г',
                  }[e.key],
                ),
                keyboardType: e.key == 'name'
                    ? TextInputType.text
                    : const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  if (e.key == 'name')
                    return v == null || v.trim().isEmpty
                        ? 'Укажите название'
                        : null;
                  final n = parseNutritionNumber(v ?? '');
                  return n == null ||
                          (e.key == 'grams' ? n <= 0 || n > 20000 : n > 1000)
                      ? 'Проверьте число и размер порции'
                      : null;
                },
              ),
            TextButton.icon(
              onPressed: () async {
                final changed = await editMicros(context, micros);
                if (changed != null && mounted)
                  setState(() => micros = changed);
              },
              icon: const Icon(Icons.science_outlined),
              label: Text('Витамины и минералы на 100 г · ${micros.length}'),
            ),
            DropdownButtonFormField<String>(
              initialValue: meal,
              isExpanded: true,
              items: [
                for (final m in MealType.values)
                  DropdownMenuItem(
                    value: m.name,
                    child: Text(m.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => meal = v!,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate())
            Navigator.pop(context, {
              ...widget.item,
              'meal': meal,
              'micros': micros,
              for (final e in fields.entries)
                e.key: e.key == 'name'
                    ? e.value.text.trim()
                    : parseNutritionNumber(e.value.text)!,
            });
        },
        child: const Text('Применить'),
      ),
    ],
  );
}

class MacroTrendPanel extends StatefulWidget {
  final AppDataProvider provider;
  const MacroTrendPanel({super.key, required this.provider});
  @override
  State<MacroTrendPanel> createState() => _MacroTrendPanelState();
}

class _MacroTrendPanelState extends State<MacroTrendPanel> {
  int length = 7;
  @override
  Widget build(BuildContext context) {
    final p = widget.provider, store = p.storage.local;
    final end = p.selectedDate;
    final days = List.generate(length, (i) {
      final day = DateTime(end.year, end.month, end.day - length + i + 1);
      final entries =
          (store.decoded('food_entries_${dayKey(day)}') as List? ?? [])
              .map(
                (e) => FoodEntry.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList();
      double sum(double Function(FoodEntry) fn) =>
          entries.fold(0.0, (v, e) => v + fn(e));
      final targets = p.macroTargets;
      final macros = [
        sum((e) => e.protein),
        sum((e) => e.fat),
        sum((e) => e.carbs),
      ];
      final goals = [targets.protein, targets.fat, targets.carbs];
      final available = goals.where((goal) => goal != null && goal > 0).length;
      final inRange = List.generate(3, (j) {
        final goal = goals[j];
        return goal != null &&
            goal > 0 &&
            macros[j] >= goal * .9 &&
            macros[j] <= goal * 1.1;
      }).where((v) => v).length;
      return (
        day: day,
        filled: entries.isNotEmpty,
        calories: sum((e) => e.calories),
        inRange: inRange,
        available: available,
      );
    });
    final logged = days.where((e) => e.filled).toList();
    final average = logged.isEmpty
        ? 0.0
        : logged.fold(0.0, (v, e) => v + e.calories) / logged.length;
    final maxValue = days.fold(1.0, (v, e) => max(v, e.calories));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 7, label: Text('7 дней')),
            ButtonSegment(value: 30, label: Text('30 дней')),
          ],
          selected: {length},
          onSelectionChanged: (v) => setState(() => length = v.first),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 110,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final day in days)
                Expanded(
                  child: Tooltip(
                    message:
                        '${dayKey(day.day)}: ${day.filled ? '${day.calories.round()} ккал, ${day.available == 0 ? 'нет доступных целей БЖУ' : 'в коридоре ${day.inRange}/${day.available} доступных целей БЖУ'}' : 'нет записей'}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        height: day.filled
                            ? max(3, day.calories / maxValue * 100)
                            : 2,
                        color: day.available > 0 && day.inRange == day.available
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.secondary.withValues(alpha: .65),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Средний калораж: ${logged.isEmpty ? 'нет данных' : '${average.round()} ккал'}; заполнено ${logged.length}/$length дней.',
        ),
        Text(
          'Для выбранного дня положительных подтверждённых целей ${days.first.available} из 3. '
          'Все доступные цели в коридоре ±10%: ${logged.where((e) => e.available > 0 && e.inRange == e.available).length}/${logged.length} заполненных дней.',
        ),
        const Text(
          'Сравнение с текущими целями выбранного дня, а не с историческими целями. Пропуски не считаются нулевым питанием. Графики веса — на вкладке «Вес».',
        ),
      ],
    );
  }
}
