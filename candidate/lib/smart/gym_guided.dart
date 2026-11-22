import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'gym_models.dart';

/// A planned slot, not an extra or automatically recorded set.
class GymGuidedStep {
  final GymBlock block;
  final GymExercise exercise;
  final int index;
  const GymGuidedStep(this.block, this.exercise, this.index);
}

/// Optional blocks (for example, the Sunday test) never start themselves.
GymGuidedStep? gymNextGuidedStep(GymSession session) {
  for (final block in session.blocks) {
    if (block.optional) continue;
    for (var round = 1; round <= block.plannedRounds; round++) {
      for (final exercise in block.exercises) {
        if (round <= exercise.plannedSets && exercise.setAt(round) == null) {
          return GymGuidedStep(block, exercise, round);
        }
      }
    }
  }
  return null;
}

/// Once the user explicitly starts an optional block, continue through the
/// adjacent optional blocks; never start them without that explicit choice.
GymGuidedStep? gymNextOptionalStep(GymSession session, String startBlockId) {
  final start = session.blocks.indexWhere((block) => block.id == startBlockId);
  if (start < 0 || !session.blocks[start].optional) return null;
  for (var i = start; i < session.blocks.length; i++) {
    final block = session.blocks[i];
    if (!block.optional) break;
    for (var round = 1; round <= block.plannedRounds; round++) {
      for (final exercise in block.exercises) {
        if (round <= exercise.plannedSets && exercise.setAt(round) == null) {
          return GymGuidedStep(block, exercise, round);
        }
      }
    }
  }
  return null;
}

/// Recover an explicitly started optional warm-up/test after a restart.
/// A later mandatory set means the user has moved on from the optional test.
GymGuidedStep? gymResumeStartedOptional(GymSession session) {
  GymBlock? latestBlock;
  DateTime? latestOptional, latestMandatory;
  for (final block in session.blocks) {
    for (final exercise in block.exercises) {
      for (final set in exercise.sets) {
        final date = set.recordedAt;
        if (block.optional &&
            (latestOptional == null || !date.isBefore(latestOptional))) {
          latestOptional = date;
          latestBlock = block;
        } else if (!block.optional &&
            (latestMandatory == null || date.isAfter(latestMandatory))) {
          latestMandatory = date;
        }
      }
    }
  }
  if (latestBlock == null ||
      (latestMandatory != null && latestMandatory.isAfter(latestOptional!))) {
    return null;
  }
  return gymNextOptionalStep(session, latestBlock.id);
}

/// Transition only when another exercise remains in the *same* pair/round.
/// Unequal pairs therefore do not create a phantom set or a second full rest.
bool gymHasNextInRound(GymBlock block, String exerciseId, int index) {
  final position = block.exercises.indexWhere((e) => e.id == exerciseId);
  if (position < 0) return false;
  return block.exercises
      .skip(position + 1)
      .any((e) => index <= e.plannedSets && e.setAt(index) == null);
}

({int done, int total}) gymGuidedProgress(GymSession session) {
  var done = 0, total = 0;
  for (final block in session.blocks.where((b) => !b.optional)) {
    for (final exercise in block.exercises) {
      total += exercise.plannedSets;
      for (var i = 1; i <= exercise.plannedSets; i++) {
        if (exercise.setAt(i) != null) done++;
      }
    }
  }
  return (done: done, total: total);
}

String _number(num n) => n.toString().replaceFirst(RegExp(r'\.0$'), '');
String _clock(int seconds) {
  final value = math.max(0, seconds);
  final hours = value ~/ 3600, minutes = (value % 3600) ~/ 60;
  final secs = (value % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$secs'
      : '$minutes:$secs';
}

class _GymColors {
  final bool dark;
  _GymColors(BuildContext context)
    : dark = Theme.of(context).brightness == Brightness.dark;
  Color get background =>
      dark ? const Color(0xFF0D1514) : const Color(0xFFF4F7F5);
  Color get panel => dark ? const Color(0xFF182521) : Colors.white;
  Color get panelHigh =>
      dark ? const Color(0xFF22332D) : const Color(0xFFE8F1EB);
  Color get stroke => dark ? const Color(0xFF30443B) : const Color(0xFFD6E5DA);
  Color get text => dark ? const Color(0xFFF4FAF6) : const Color(0xFF17261F);
  Color get muted => dark ? const Color(0xFFADC1B4) : const Color(0xFF586E60);
  Color get accent => dark ? const Color(0xFF59EDAB) : const Color(0xFF007E4C);
  Color get button => dark ? const Color(0xFF56E9A8) : const Color(0xFF007E4C);
  Color get onButton => dark ? const Color(0xFF092015) : Colors.white;
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData? icon;
  const _Pill(this.text, {this.icon});
  @override
  Widget build(BuildContext context) {
    final c = _GymColors(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: c.panelHigh,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: c.accent),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: c.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GymGuidedExerciseScreen extends StatefulWidget {
  final GymSession session;
  final GymGuidedStep step;
  final GymSet? latest;
  final DateTime now;
  final bool busy;
  final Future<bool> Function(GymSet set) onSave;
  final VoidCallback onOverview;
  final VoidCallback onReplace;
  const GymGuidedExerciseScreen({
    super.key,
    required this.session,
    required this.step,
    required this.latest,
    required this.now,
    required this.busy,
    required this.onSave,
    required this.onOverview,
    required this.onReplace,
  });
  @override
  State<GymGuidedExerciseScreen> createState() =>
      _GymGuidedExerciseScreenState();
}

class _GymGuidedExerciseScreenState extends State<GymGuidedExerciseScreen> {
  late final TextEditingController reps, seconds, weight, rir, note;
  String mode = 'unknown';
  bool test = false, expanded = false, submitting = false, allowPop = false;
  String? error;
  GymExercise get exercise => widget.step.exercise;
  bool get isPullup => isPullupName(exercise.name);
  bool get dirty =>
      reps.text.trim().isNotEmpty ||
      seconds.text.trim().isNotEmpty ||
      weight.text.trim().isNotEmpty ||
      rir.text.trim().isNotEmpty ||
      note.text.trim().isNotEmpty ||
      mode != 'unknown' ||
      test != exercise.isTest;

  @override
  void initState() {
    super.initState();
    reps = TextEditingController();
    seconds = TextEditingController();
    weight = TextEditingController();
    rir = TextEditingController();
    note = TextEditingController();
    test = exercise.isTest;
    for (final controller in [reps, seconds, weight, rir, note]) {
      controller.addListener(_fieldChanged);
    }
  }

  void _fieldChanged() {
    if (mounted)
      setState(() {
        error = null;
      });
  }

  @override
  void dispose() {
    for (final controller in [reps, seconds, weight, rir, note]) {
      controller.removeListener(_fieldChanged);
      controller.dispose();
    }
    super.dispose();
  }

  Future<bool> _discardIfNeeded() async {
    if (!dirty) return true;
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Подход ещё не записан'),
        content: const Text(
          'Введённые значения не сохранятся, если выйти с этого экрана.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Остаться'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти без записи'),
          ),
        ],
      ),
    );
    return answer == true;
  }

  Future<void> _exit() async {
    if (!await _discardIfNeeded() || !mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _overview() async {
    if (!await _discardIfNeeded() || !mounted) return;
    widget.onOverview();
  }

  Future<void> _replace() async {
    if (!await _discardIfNeeded() || !mounted) return;
    widget.onReplace();
  }

  int? _integer(String value) {
    if (value.trim().isEmpty) return null;
    final n = int.tryParse(value.trim());
    if (n == null)
      throw const FormatException('Укажи целое число повторений или секунд.');
    return n;
  }

  double? _weight() {
    if (isPullup && mode == 'bodyweight') return 0;
    if (weight.text.trim().isEmpty) return null;
    final n = double.tryParse(weight.text.trim().replaceAll(',', '.'));
    if (n == null || !n.isFinite)
      throw const FormatException('Проверь вес: например, 27,5.');
    return n;
  }

  Future<void> _save() async {
    if (submitting || widget.busy) return;
    try {
      final set = GymSet.fromJson({
        'index': widget.step.index,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'exerciseName': exercise.name,
        'reps': _integer(reps.text),
        'seconds': _integer(seconds.text),
        'weightKg': _weight(),
        'rir': _integer(rir.text),
        'pullupMode': isPullup ? mode : 'unknown',
        'isTest': isPullup && test,
        'note': note.text.trim(),
      });
      setState(() {
        submitting = true;
        error = null;
      });
      await widget.onSave(set);
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is FormatException
              ? e.message
              : 'Проверь значения подхода.',
        );
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  void _usePrevious() {
    final s = widget.latest;
    if (s == null) return;
    // Only copy the visible primary values by explicit tap. A previous RIR,
    // note, test or hidden secondary value must never be silently repeated.
    reps.text = exercise.timed ? '' : (s.reps?.toString() ?? '');
    seconds.text = exercise.timed ? (s.seconds?.toString() ?? '') : '';
    weight.text = s.weightKg == null ? '' : _number(s.weightKg!);
    setState(() => mode = isPullup ? s.pullupMode : 'unknown');
  }

  @override
  Widget build(BuildContext context) {
    final c = _GymColors(context), step = widget.step;
    final progress = gymGuidedProgress(widget.session);
    final target = exercise.targetFor(step.index);
    final disabled = submitting || widget.busy;
    final latest = widget.latest;
    final latestParts = <String>[
      if (latest?.reps != null) '${latest!.reps} повт.',
      if (latest?.seconds != null) '${latest!.seconds} с',
      if (latest?.isPullup == true && latest?.pullupMode == 'bodyweight')
        'свой вес',
      if (latest?.weightKg != null && latest?.pullupMode != 'bodyweight')
        '${latest?.pullupMode == 'assisted' ? 'помощь ' : ''}${_number(latest!.weightKg!)} кг',
    ];
    return PopScope(
      canPop: allowPop || !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _exit();
      },
      child: Scaffold(
        backgroundColor: c.background,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 12, 3),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Назад',
                      onPressed: disabled ? null : _exit,
                      icon: Icon(Icons.arrow_back_rounded, color: c.text),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ТРЕНИРОВКА',
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.3,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: disabled ? null : _overview,
                      style: TextButton.styleFrom(foregroundColor: c.text),
                      icon: const Icon(
                        Icons.format_list_bulleted_rounded,
                        size: 19,
                      ),
                      label: const Text('Список'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'ТВОЙ СЛЕДУЮЩИЙ ПОДХОД',
                                  style: TextStyle(
                                    color: c.accent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ),
                              Text(
                                '${progress.done}/${progress.total}',
                                style: TextStyle(
                                  color: c.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: LinearProgressIndicator(
                              minHeight: 5,
                              value: progress.total == 0
                                  ? 0
                                  : progress.done / progress.total,
                              backgroundColor: c.stroke,
                              valueColor: AlwaysStoppedAnimation(c.accent),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(20, 19, 20, 18),
                            decoration: BoxDecoration(
                              color: c.panel,
                              border: Border.all(color: c.stroke),
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 7,
                                  runSpacing: 7,
                                  children: [
                                    _Pill(
                                      '${step.block.exercises.length > 1 ? 'Суперсет' : 'Упражнение'}${RegExp(r'^[A-Z][0-9]+$').hasMatch(exercise.id) ? ' · ${exercise.id}' : ''}',
                                      icon: Icons.fitness_center_rounded,
                                    ),
                                    _Pill(
                                      step.index > exercise.plannedSets
                                          ? 'Доп. подход ${step.index}'
                                          : 'Подход ${step.index} из ${exercise.plannedSets}',
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 15),
                                Text(
                                  exercise.name,
                                  style: TextStyle(
                                    color: c.text,
                                    fontSize: 27,
                                    height: 1.12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  target.isEmpty
                                      ? 'Выполняй с хорошей техникой'
                                      : 'Цель: $target',
                                  style: TextStyle(
                                    color: c.muted,
                                    fontSize: 14,
                                    height: 1.35,
                                  ),
                                ),
                                if (exercise.isTest) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Только с тренером и без боли. Остановись, когда техника ухудшается.',
                                    style: TextStyle(
                                      color: c.muted,
                                      fontSize: 12,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 15),
                                if (exercise.plannedSets <= 8)
                                  Row(
                                    children: [
                                      for (
                                        var i = 1;
                                        i <= exercise.plannedSets;
                                        i++
                                      )
                                        Expanded(
                                          child: Container(
                                            height: 4,
                                            margin: EdgeInsets.only(
                                              right: i == exercise.plannedSets
                                                  ? 0
                                                  : 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: exercise.setAt(i) != null
                                                  ? c.accent
                                                  : (i == step.index
                                                        ? c.accent.withValues(
                                                            alpha: .5,
                                                          )
                                                        : c.stroke),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                          ),
                                        ),
                                    ],
                                  )
                                else
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      minHeight: 4,
                                      value:
                                          exercise.sets
                                              .where(
                                                (s) =>
                                                    s.index <=
                                                    exercise.plannedSets,
                                              )
                                              .length /
                                          exercise.plannedSets,
                                      backgroundColor: c.stroke,
                                      valueColor: AlwaysStoppedAnimation(
                                        c.accent,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      foregroundColor: c.accent,
                                    ),
                                    onPressed: disabled ? null : _replace,
                                    icon: const Icon(
                                      Icons.swap_horiz_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Заменить упражнение'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 23),
                          Text(
                            'Как выполнил?',
                            style: TextStyle(
                              color: c.text,
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Введи фактические значения подхода',
                            style: TextStyle(color: c.muted, fontSize: 13),
                          ),
                          if (isPullup) ...[
                            const SizedBox(height: 15),
                            Text(
                              'ВАРИАНТ ПОДТЯГИВАНИЙ',
                              style: TextStyle(
                                color: c.muted,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: .7,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 7,
                              runSpacing: 7,
                              children: [
                                for (final option in [
                                  ('bodyweight', 'Свой вес'),
                                  ('weighted', '+ вес'),
                                  ('assisted', 'С помощью'),
                                ])
                                  ChoiceChip(
                                    label: Text(option.$2),
                                    selected: mode == option.$1,
                                    onSelected: disabled
                                        ? null
                                        : (_) {
                                            // A previous added weight must not silently
                                            // become an assistance value (or vice versa).
                                            if (mode != option.$1)
                                              weight.clear();
                                            setState(() => mode = option.$1);
                                          },
                                    selectedColor: c.accent.withValues(
                                      alpha: .22,
                                    ),
                                    backgroundColor: c.panel,
                                    labelStyle: TextStyle(
                                      color: mode == option.$1
                                          ? c.accent
                                          : c.text,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    side: BorderSide(
                                      color: mode == option.$1
                                          ? c.accent
                                          : c.stroke,
                                    ),
                                  ),
                              ],
                            ),
                            if (mode == 'unknown')
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  'Выбери вариант, если знаешь',
                                  style: TextStyle(
                                    color: c.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                          const SizedBox(height: 14),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: _InputTile(
                                  controller: exercise.timed ? seconds : reps,
                                  label: exercise.timed
                                      ? 'ВРЕМЯ'
                                      : 'ПОВТОРЕНИЯ',
                                  semanticLabel: exercise.timed
                                      ? 'Время подхода, секунд'
                                      : 'Повторения',
                                  suffix: exercise.timed ? 'сек' : 'раз',
                                  enabled: !disabled,
                                  colors: c,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: isPullup && mode == 'bodyweight'
                                    ? _KnownBodyweightTile(colors: c)
                                    : _InputTile(
                                        controller: weight,
                                        label: isPullup && mode == 'assisted'
                                            ? 'ПОМОЩЬ'
                                            : 'ВЕС',
                                        semanticLabel:
                                            isPullup && mode == 'assisted'
                                            ? 'Помощь, кг'
                                            : 'Вес, кг',
                                        suffix: 'кг',
                                        decimal: true,
                                        enabled: !disabled,
                                        colors: c,
                                      ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 7),
                          Text(
                            isPullup && mode == 'bodyweight'
                                ? 'Запишем подтягивания без дополнительного веса.'
                                : 'Пустой вес — неизвестно. Не нужно указывать 0 вместо неизвестного.',
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 11.5,
                              height: 1.35,
                            ),
                          ),
                          if (latest != null && latestParts.isNotEmpty) ...[
                            const SizedBox(height: 13),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: c.panelHigh,
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.history_rounded,
                                    color: c.accent,
                                    size: 19,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(
                                      'Прошлый подход: ${latestParts.join(' · ')}',
                                      style: TextStyle(
                                        color: c.text,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: disabled ? null : _usePrevious,
                                    style: TextButton.styleFrom(
                                      foregroundColor: c.accent,
                                    ),
                                    child: const Text('Повторить'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Theme(
                            data: Theme.of(
                              context,
                            ).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              childrenPadding: const EdgeInsets.only(bottom: 8),
                              initiallyExpanded: expanded,
                              title: Text(
                                'Дополнительно',
                                style: TextStyle(
                                  color: c.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                'Запас, заметка${exercise.timed ? ', повторения' : ', время'}${isPullup ? ', тест' : ''}',
                                style: TextStyle(color: c.muted, fontSize: 12),
                              ),
                              iconColor: c.accent,
                              collapsedIconColor: c.muted,
                              onExpansionChanged: (v) => expanded = v,
                              children: [
                                TextField(
                                  controller: exercise.timed ? reps : seconds,
                                  enabled: !disabled,
                                  keyboardType: TextInputType.number,
                                  style: TextStyle(color: c.text),
                                  decoration: InputDecoration(
                                    labelText: exercise.timed
                                        ? 'Повторения (необязательно)'
                                        : 'Время подхода, секунд (необязательно)',
                                  ),
                                ),
                                TextField(
                                  controller: rir,
                                  enabled: !disabled,
                                  keyboardType: TextInputType.number,
                                  style: TextStyle(color: c.text),
                                  decoration: const InputDecoration(
                                    labelText:
                                        'Запас повторений (необязательно)',
                                  ),
                                ),
                                TextField(
                                  controller: note,
                                  enabled: !disabled,
                                  maxLength: 300,
                                  style: TextStyle(color: c.text),
                                  decoration: const InputDecoration(
                                    labelText: 'Заметка (необязательно)',
                                  ),
                                ),
                                if (isPullup)
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: test,
                                    onChanged: disabled
                                        ? null
                                        : (v) => setState(() => test = v),
                                    title: Text(
                                      'Технический тест',
                                      style: TextStyle(color: c.text),
                                    ),
                                    subtitle: Text(
                                      'Только чистые повторения, без боли.',
                                      style: TextStyle(color: c.muted),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            'При боли остановись. Работай с техникой и страховкой.',
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: SizedBox(
                      width: double.infinity,
                      height: 58,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: c.button,
                          foregroundColor: c.onButton,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        onPressed: disabled ? null : _save,
                        icon: const Icon(Icons.check_rounded),
                        label: Text(
                          disabled ? 'Сохраняем…' : 'Записать подход',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InputTile extends StatelessWidget {
  final TextEditingController controller;
  final String label, semanticLabel, suffix;
  final bool decimal, enabled;
  final _GymColors colors;
  const _InputTile({
    required this.controller,
    required this.label,
    required this.semanticLabel,
    required this.suffix,
    required this.enabled,
    required this.colors,
    this.decimal = false,
  });
  @override
  Widget build(BuildContext context) => Container(
    height: 103,
    padding: const EdgeInsets.fromLTRB(14, 11, 12, 6),
    decoration: BoxDecoration(
      color: colors.panel,
      border: Border.all(color: colors.stroke),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.muted,
            fontSize: 10.5,
            letterSpacing: .8,
            fontWeight: FontWeight.w800,
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: decimal,
                  ),
                  textInputAction: TextInputAction.next,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                  ),
                  decoration: InputDecoration(
                    semanticCounterText: '',
                    labelText: semanticLabel,
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    labelStyle: const TextStyle(fontSize: 0),
                    hintText: '—',
                    hintStyle: TextStyle(
                      color: colors.muted.withValues(alpha: .6),
                      fontSize: 27,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              Text(
                suffix,
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _KnownBodyweightTile extends StatelessWidget {
  final _GymColors colors;
  const _KnownBodyweightTile({required this.colors});
  @override
  Widget build(BuildContext context) => Container(
    height: 103,
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: colors.panel,
      border: Border.all(color: colors.stroke),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ВЕС',
          style: TextStyle(
            color: colors.muted,
            fontSize: 10.5,
            letterSpacing: .8,
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        Text(
          'Свой вес',
          style: TextStyle(
            color: colors.text,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          'без добавления',
          style: TextStyle(color: colors.muted, fontSize: 11),
        ),
      ],
    ),
  );
}

/// Full-viewport rest view. Timing itself lives in the persisted GymSession.
class GymRestScreen extends StatelessWidget {
  final GymSession session;
  final GymGuidedStep? next;
  final DateTime now;
  final bool busy;
  final VoidCallback onOverview,
      onAdjustDown,
      onAdjustUp,
      onPauseResume,
      onEditTime,
      onSkip;
  final VoidCallback? onFullRest;
  const GymRestScreen({
    super.key,
    required this.session,
    required this.next,
    required this.now,
    required this.busy,
    required this.onOverview,
    required this.onAdjustDown,
    required this.onAdjustUp,
    required this.onPauseResume,
    required this.onEditTime,
    required this.onSkip,
    this.onFullRest,
  });

  @override
  Widget build(BuildContext context) {
    final c = _GymColors(context), remaining = session.restRemainingAt(now);
    final paused = session.restPausedSeconds != null;
    final total = math.max(
      1,
      math.max(session.restTotalSeconds ?? 0, remaining),
    );
    final fraction = (remaining / total).clamp(0.0, 1.0);
    final transition = session.restIsTransition;
    final title = remaining == 0
        ? 'Готово!'
        : transition
        ? 'Переход'
        : 'Отдых';
    final nextText = next == null
        ? 'Кардио и итоги занятия'
        : next!.exercise.name;
    final nextDetail = next == null
        ? 'Ты можешь завершить занятие или записать кардио.'
        : '${next!.index > next!.exercise.plannedSets ? 'Доп. подход ${next!.index}' : 'Подход ${next!.index} из ${next!.exercise.plannedSets}'}${next!.exercise.targetFor(next!.index).isEmpty ? '' : ' · ${next!.exercise.targetFor(next!.index)}'}';
    return Scaffold(
      backgroundColor: c.background,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: c.dark
                ? [
                    const Color(0xFF142920),
                    const Color(0xFF0B1411),
                    const Color(0xFF0D1514),
                  ]
                : [
                    const Color(0xFFE1F4E8),
                    const Color(0xFFF4F7F5),
                    const Color(0xFFF4F7F5),
                  ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: c.accent.withValues(alpha: .13),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              transition
                                  ? 'МЕЖДУ УПРАЖНЕНИЯМИ'
                                  : 'ВОССТАНОВЛЕНИЕ',
                              style: TextStyle(
                                color: c.accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .9,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: busy ? null : onOverview,
                      style: TextButton.styleFrom(foregroundColor: c.text),
                      icon: const Icon(
                        Icons.format_list_bulleted_rounded,
                        size: 19,
                      ),
                      label: const Text('Список'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 500),
                      child: Column(
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: c.text,
                              fontSize: 27,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.4,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            remaining == 0
                                ? 'Можно продолжать, когда будешь готов'
                                : paused
                                ? 'Таймер на паузе'
                                : transition
                                ? 'Спокойно переходи к следующему упражнению'
                                : 'Восстанови дыхание и подготовься к подходу',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 13.5,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 18),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final size = math.min(
                                238.0,
                                constraints.maxWidth * .68,
                              );
                              return SizedBox(
                                width: size,
                                height: size,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: _TimerRingPainter(
                                          fraction,
                                          c.accent,
                                          c.stroke,
                                        ),
                                      ),
                                    ),
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: size * .78,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              _clock(remaining),
                                              style: TextStyle(
                                                color: c.text,
                                                fontSize: size * .24,
                                                height: 1,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: -2,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          remaining == 0
                                              ? 'ВРЕМЯ ВЫШЛО'
                                              : paused
                                              ? 'ПАУЗА'
                                              : 'ОСТАЛОСЬ',
                                          style: TextStyle(
                                            color: c.muted,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 10,
                                            letterSpacing: 1.6,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 17),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Expanded(
                                child: _RestControl(
                                  label: '−15 с',
                                  onPressed: busy ? null : onAdjustDown,
                                  colors: c,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: _RestControl(
                                  label: paused ? 'Продолжить' : 'Пауза',
                                  icon: paused
                                      ? Icons.play_arrow_rounded
                                      : Icons.pause_rounded,
                                  onPressed: busy ? null : onPauseResume,
                                  colors: c,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _RestControl(
                                  label: '+15 с',
                                  onPressed: busy ? null : onAdjustUp,
                                  colors: c,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: busy ? null : onEditTime,
                                style: TextButton.styleFrom(
                                  foregroundColor: c.accent,
                                ),
                                icon: const Icon(Icons.tune_rounded, size: 17),
                                label: const Text('Изменить время'),
                              ),
                              if (transition && onFullRest != null)
                                TextButton(
                                  onPressed: busy ? null : onFullRest,
                                  style: TextButton.styleFrom(
                                    foregroundColor: c.accent,
                                  ),
                                  child: const Text('Полный отдых'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: c.panel,
                              border: Border.all(color: c.stroke),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: c.accent.withValues(alpha: .14),
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                  child: Icon(
                                    Icons.arrow_forward_rounded,
                                    color: c.accent,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'ДАЛЕЕ',
                                        style: TextStyle(
                                          color: c.muted,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 1,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        nextText,
                                        style: TextStyle(
                                          color: c.text,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        nextDetail,
                                        style: TextStyle(
                                          color: c.muted,
                                          fontSize: 12.5,
                                          height: 1.3,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'На заблокированном телефоне звук может не прозвучать. Время обновится, когда вернёшься.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 10.5,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: SizedBox(
                      width: double.infinity,
                      height: 58,
                      child: FilledButton.icon(
                        onPressed: busy ? null : onSkip,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.button,
                          foregroundColor: c.onButton,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: Text(
                          remaining == 0
                              ? 'Продолжить'
                              : 'Пропустить и продолжить',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RestControl extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final _GymColors colors;
  const _RestControl({
    required this.label,
    required this.onPressed,
    required this.colors,
    this.icon,
  });
  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: colors.text,
      side: BorderSide(color: colors.stroke),
      backgroundColor: colors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 17), const SizedBox(width: 4)],
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _TimerRingPainter extends CustomPainter {
  final double progress;
  final Color accent, track;
  const _TimerRingPainter(this.progress, this.accent, this.track);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    canvas.drawCircle(rect.center, rect.width / 2, base);
    if (progress <= 0) return;
    final active = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [
          accent.withValues(alpha: .55),
          accent,
          const Color(0xFFB8F7A6),
        ],
      ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, active);
  }

  @override
  bool shouldRepaint(covariant _TimerRingPainter old) =>
      old.progress != progress || old.accent != accent || old.track != track;
}
