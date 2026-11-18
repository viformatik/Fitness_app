import 'dart:convert';
import 'package:flutter/material.dart';
import '../legacy.dart';
import 'ai_actions.dart';
import 'ai_preferences.dart';
import 'local_store.dart';
import 'ai_drafts.dart' show friendlyAiError;
import 'remote.dart';
import 'workout_calc.dart';
import 'engine.dart' as smart;

Future<void> showWorkoutEditor(
  BuildContext context,
  AppDataProvider provider, {
  WorkoutEntry? entry,
}) => Navigator.push<void>(
  context,
  MaterialPageRoute<void>(
    builder: (_) => WorkoutEditorScreen(provider: provider, entry: entry),
  ),
);

class _SegmentInput {
  String activityId;
  final TextEditingController minutes, distance;
  _SegmentInput({
    this.activityId = 'other',
    String minutes = '',
    String distance = '',
  }) : minutes = TextEditingController(text: minutes),
       distance = TextEditingController(text: distance);
  void dispose() {
    minutes.dispose();
    distance.dispose();
  }
}

class _ExerciseInput {
  final TextEditingController name, sets, reps, weight;
  _ExerciseInput({
    String name = '',
    String sets = '',
    String reps = '',
    String weight = '',
  }) : name = TextEditingController(text: name),
       sets = TextEditingController(text: sets),
       reps = TextEditingController(text: reps),
       weight = TextEditingController(text: weight);
  void dispose() {
    name.dispose();
    sets.dispose();
    reps.dispose();
    weight.dispose();
  }
}

class WorkoutEditorScreen extends StatefulWidget {
  final AppDataProvider provider;
  final WorkoutEntry? entry;
  const WorkoutEditorScreen({super.key, required this.provider, this.entry});
  @override
  State<WorkoutEditorScreen> createState() => _WorkoutEditorScreenState();
}

class _WorkoutEditorScreenState extends State<WorkoutEditorScreen> {
  final weight = TextEditingController(),
      manualKcal = TextEditingController(),
      note = TextEditingController(),
      prompt = TextEditingController();
  final segments = <_SegmentInput>[], exercises = <_ExerciseInput>[];
  late final DateTime day;
  late final String draftId;
  bool manual = false, busy = false, fromAi = false;
  int budgetPercent = 100;
  String? error, aiRemarks;
  @override
  void initState() {
    super.initState();
    final e = widget.entry, d = e?.details;
    day = e?.date ?? widget.provider.selectedDate;
    draftId = e?.id ?? newId();
    // Earlier manual records did not capture body weight; never invent it.
    // A new estimate may use the profile only after that weight was confirmed.
    final existingWeight = d?.weightKg;
    weight.text = existingWeight != null
        ? existingWeight.toString()
        : e == null && widget.provider.profile.currentWeightConfirmed == true
        ? widget.provider.profile.currentWeight.toString()
        : '';
    note.text = e?.note ?? '';
    manual = d?.calorieMode == 'manual' || (e != null && d == null);
    manualKcal.text = e == null ? '' : '${e.caloriesBurned}';
    budgetPercent = d?.budgetPercent ?? 100;
    fromAi = d?.source == 'ai';
    if (d != null) {
      for (final s in d.segments)
        segments.add(
          _SegmentInput(
            activityId: s.activityId,
            minutes: '${s.minutes}',
            distance: s.distanceKm?.toString() ?? '',
          ),
        );
      for (final x in d.exercises)
        exercises.add(
          _ExerciseInput(
            name: x.name,
            sets: x.sets?.toString() ?? '',
            reps: x.reps?.toString() ?? '',
            weight: x.weightKg?.toString() ?? '',
          ),
        );
    } else {
      segments.add(
        _SegmentInput(minutes: e == null ? '' : '${e.durationMinutes}'),
      );
    }
  }

  @override
  void dispose() {
    weight.dispose();
    manualKcal.dispose();
    note.dispose();
    prompt.dispose();
    for (final s in segments) s.dispose();
    for (final e in exercises) e.dispose();
    super.dispose();
  }

  void changed([Object? _]) {
    if (mounted) setState(() => error = null);
  }

  String fmt(num n) => n.toString().replaceFirst(RegExp(r'\.0$'), '');
  String macroFmt(num n) =>
      n.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  double? parse(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
  Object? optional(String s) {
    if (s.trim().isEmpty) return null;
    final n = parse(s);
    if (n == null || !n.isFinite)
      throw const FormatException('Проверьте числа в тренировке.');
    return n;
  }

  int requiredInt(String s, String name, {int min = 1, int max = 1440}) {
    final n = parse(s);
    if (n == null ||
        !n.isFinite ||
        n != n.roundToDouble() ||
        n < min ||
        n > max)
      throw FormatException('$name: введите целое число от $min до $max.');
    return n.toInt();
  }

  WorkoutDetails buildDetails() {
    final ss = <Map<String, dynamic>>[];
    for (final s in segments) {
      final minutes = requiredInt(s.minutes.text, 'Длительность');
      final distance = optional(s.distance.text);
      ss.add({
        'activityId': s.activityId,
        'minutes': minutes,
        if (distance != null) 'distanceKm': distance,
      });
    }
    final xx = <Map<String, dynamic>>[];
    for (final e in exercises) {
      final name = e.name.text.trim();
      final any =
          e.sets.text.trim().isNotEmpty ||
          e.reps.text.trim().isNotEmpty ||
          e.weight.text.trim().isNotEmpty;
      if (name.isEmpty && !any) continue;
      if (name.isEmpty)
        throw const FormatException('Укажите название каждого упражнения.');
      final sets = optional(e.sets.text),
          reps = optional(e.reps.text),
          load = optional(e.weight.text);
      xx.add({
        'name': name,
        if (sets != null) 'sets': sets,
        if (reps != null) 'reps': reps,
        if (load != null) 'weightKg': load,
      });
    }
    final w = optional(weight.text);
    return WorkoutDetails.fromJson({
      'version': 1,
      'segments': ss,
      'exercises': xx,
      if (w != null) 'weightKg': w,
      'calorieMode': manual ? 'manual' : 'estimate',
      'budgetPercent': budgetPercent,
      'source': fromAi ? 'ai' : 'manual',
    });
  }

  int kcalFor(WorkoutDetails d) {
    if (manual)
      return requiredInt(
        manualKcal.text,
        'Активные калории',
        min: 0,
        max: 30000,
      );
    return calculateWorkoutEnergy(d.segments, d.weightKg!).active.round();
  }

  WorkoutType kind(WorkoutDetails d) {
    final hasStrength = d.segments.any((s) => s.activity.family == 'strength');
    final hasCardio = d.segments.any((s) => s.activity.family == 'cardio');
    if (hasStrength && hasCardio) return WorkoutType.strengthCardio;
    if (hasStrength) return WorkoutType.strength;
    if (hasCardio) return WorkoutType.cardio;
    return widget.entry?.type ?? WorkoutType.strengthCardio;
  }

  WorkoutEnergy? get preview {
    try {
      final d = buildDetails();
      if (manual) return null;
      return calculateWorkoutEnergy(d.segments, d.weightKg!);
    } catch (_) {
      return null;
    }
  }

  bool get sameDate => dayKey(widget.provider.selectedDate) == dayKey(day);
  bool get unchanged {
    if (widget.entry == null) return true;
    final matches = widget.provider.todayWorkoutEntries.where(
      (e) => e.id == widget.entry!.id,
    );
    return matches.length == 1 &&
        jsonEncode(matches.first.toJson()) ==
            jsonEncode(widget.entry!.toJson());
  }

  Future<void> parseWithAi() async {
    if (busy) return;
    final account = SmartRemote.instance.client?.auth.currentUser?.id;
    if (account == null) {
      setState(
        () => error =
            'Для ИИ войдите в аккаунт в разделе Smart. Ручной ввод работает офлайн.',
      );
      return;
    }
    final privacyEpoch = LocalPreferences.privacyEpoch;
    final text = prompt.text.trim();
    if (text.isEmpty || text.length > 4000) {
      setState(() => error = 'Введите описание тренировки до 4000 символов.');
      return;
    }
    final consent = await ensureAiConsent(
      context,
      widget.provider.storage.local,
      account,
    );
    if (!consent || !mounted) return;
    if (exercises.isNotEmpty ||
        segments.any((s) => s.minutes.text.trim().isNotEmpty)) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Заменить черновик?'),
          content: const Text(
            'ИИ предложит новые этапы и упражнения. Сохранённый дневник не изменится.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Продолжить'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (SmartRemote.instance.client?.auth.currentUser?.id != account ||
          !AiConsent(
            widget.provider.storage.local,
            account,
          ).validFor(privacyEpoch)) {
        throw StateError('Аккаунт или согласие изменились. Повторите запрос.');
      }
      final result = await SmartRemote.instance.parseWorkout(text);
      if (!mounted) return;
      if (SmartRemote.instance.client?.auth.currentUser?.id != account ||
          !AiConsent(
            widget.provider.storage.local,
            account,
          ).validFor(privacyEpoch)) {
        throw StateError(
          'Аккаунт или согласие изменились. Результат не применён.',
        );
      }
      final ss = (result['segments'] as List).cast<Map<String, dynamic>>(),
          xx = (result['exercises'] as List).cast<Map<String, dynamic>>();
      if (ss.isEmpty && xx.isEmpty)
        throw StateError(
          'Тренировка не распознана. Уточните описание или заполните вручную.',
        );
      final oldSegments = List<_SegmentInput>.of(segments);
      final oldExercises = List<_ExerciseInput>.of(exercises);
      segments.clear();
      exercises.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final s in oldSegments) s.dispose();
        for (final e in oldExercises) e.dispose();
      });
      for (final s in ss)
        segments.add(
          _SegmentInput(
            activityId: s['activityId'] as String,
            minutes: (s['minutes'] as int) > 0 ? '${s['minutes']}' : '',
            distance: (s['distanceKm'] as double) > 0
                ? fmt(s['distanceKm'] as double)
                : '',
          ),
        );
      if (segments.isEmpty) segments.add(_SegmentInput());
      for (final x in xx)
        exercises.add(
          _ExerciseInput(
            name: x['name'] as String,
            sets: (x['sets'] as int) > 0 ? '${x['sets']}' : '',
            reps: (x['reps'] as int) > 0 ? '${x['reps']}' : '',
            weight: (x['weightKg'] as double) > 0
                ? fmt(x['weightKg'] as double)
                : '',
          ),
        );
      setState(() {
        manual = false;
        fromAi = true;
        aiRemarks = result['remarks'] as String;
      });
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy) return;
    try {
      if (!sameDate)
        throw StateError(
          'Выбранный день изменился. Откройте тренировку заново.',
        );
      if (!unchanged)
        throw StateError(
          'Тренировка изменилась после открытия. Закройте и откройте её заново.',
        );
      final d = buildDetails(),
          kcal = kcalFor(d),
          credit = (kcal * d.budgetPercent / 100).round();
      final estimated = d.calorieMode == 'estimate'
          ? calculateWorkoutEnergy(d.segments, d.weightKg!)
          : null;
      final prev = widget.entry?.budgetCalories ?? 0;
      final oldGoal = widget.provider.adjustedCaloriesTarget;
      final oldMacros = widget.provider.macroTargets;
      final adaptMacros = widget.provider.metabolism.adaptMacros;
      final newGoal = oldGoal == null ? null : oldGoal - prev + credit;
      final macroText = adaptMacros
          ? (() {
              final current = oldMacros;
              final old = smart.MetabolicSettings.workoutBonus(
                prev,
                widget.entry?.type.name ?? kind(d).name,
              );
              final added = smart.MetabolicSettings.workoutBonus(
                credit,
                kind(d).name,
              );
              String goal(
                String label,
                double? value,
                double before,
                double after,
              ) => value == null
                  ? '$label не подтверждена'
                  : '$label ${macroFmt(value - before + after)} г';
              return 'Ориентир БЖУ после сохранения: ${goal('Б', current.protein, old.protein, added.protein)} · ${goal('Ж', current.fat, old.fat, added.fat)} · ${goal('У', current.carbs, old.carbs, added.carbs)}.';
            })()
          : 'Адаптация БЖУ выключена: цели БЖУ не изменятся.';
      final exerciseSummary = d.exercises.isEmpty
          ? 'Упражнения не указаны.'
          : d.knownVolumeExercises == 0
          ? 'Упражнений: ${d.exercises.length}. Объём неизвестен: не хватает данных.'
          : 'Упражнений: ${d.exercises.length}. Известный объём: ${fmt(d.volumeKg)} кг (${d.knownVolumeExercises} из ${d.exercises.length}); остальное неизвестно.';
      final setsKnown = d.exercises.where((x) => x.sets != null).toList();
      final repsKnown = d.exercises
          .where((x) => x.sets != null && x.reps != null)
          .toList();
      final setsTotal = setsKnown.fold<int>(0, (v, x) => v + x.sets!);
      final repsTotal = repsKnown.fold<int>(0, (v, x) => v + x.sets! * x.reps!);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            widget.entry == null
                ? 'Проверить тренировку'
                : 'Проверить изменения',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${formatDateRu(day)} · ${d.minutes} мин'),
                if (d.knownDistanceKm != null)
                  Text(
                    'Известная дистанция: ${fmt(d.knownDistanceKm!)} км (${d.knownDistanceSegments} из ${d.segments.length} этапов).',
                  ),
                const SizedBox(height: 8),
                for (final s in d.segments)
                  Text(
                    '${s.activity.label} · ${s.minutes} мин${s.distanceKm == null ? '' : ' · ${fmt(s.distanceKm!)} км'}${estimated == null ? '' : ' · MET ${fmt(s.activity.met!)} (код ${s.activity.code})'}',
                  ),
                const SizedBox(height: 8),
                Text(
                  estimated == null
                      ? 'Активные калории вручную: $kcal ккал'
                      : 'Примерно активных: $kcal ккал · всего с покоем: ${estimated.gross.round()} ккал',
                ),
                if (estimated != null)
                  Text(
                    'Активные: (MET − 1) × ${fmt(d.weightKg!)} кг × часы, сумма по этапам. Общий расход: MET × вес × часы.',
                  ),
                Text(
                  oldGoal == null
                      ? 'Эта запись: +$credit ккал (${d.budgetPercent}%). Цель калорий не подтверждена.'
                      : 'Эта запись: +$credit ккал (${d.budgetPercent}%). Дневной лимит: $oldGoal → $newGoal ккал.',
                ),
                Text(macroText),
                const SizedBox(height: 8),
                Text(exerciseSummary),
                if (setsKnown.isNotEmpty)
                  Text(
                    'Известно подходов: $setsTotal (${setsKnown.length} из ${d.exercises.length} упражнений).',
                  ),
                if (repsKnown.isNotEmpty)
                  Text(
                    'Известно повторений всего: $repsTotal (${repsKnown.length} из ${d.exercises.length} упражнений).',
                  ),
                for (final x in d.exercises)
                  Text(
                    '${x.name}: ${x.sets == null ? '?' : '${x.sets}'} подходов × ${x.reps == null ? '?' : '${x.reps}'} повторений; внешний вес ${x.weightKg == null ? 'неизвестен' : '${fmt(x.weightKg!)} кг'}',
                  ),
                const SizedBox(height: 8),
                const Text(
                  'Проверьте числа. MET — приблизительная оценка; подходы и вес сами по себе калории не измеряют. Если базовая активность уже включает тренировку, не учитывайте её повторно.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Назад'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(widget.entry == null ? 'Добавить' : 'Сохранить'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (!sameDate || !unchanged)
        throw StateError(
          'День или запись изменились после проверки. Откройте редактор заново.',
        );
      final currentMacros = widget.provider.macroTargets;
      if (widget.provider.adjustedCaloriesTarget != oldGoal ||
          widget.provider.metabolism.adaptMacros != adaptMacros ||
          currentMacros.protein != oldMacros.protein ||
          currentMacros.fat != oldMacros.fat ||
          currentMacros.carbs != oldMacros.carbs) {
        throw StateError(
          'Дневные цели изменились после проверки. Проверьте тренировку снова.',
        );
      }
      setState(() {
        busy = true;
        error = null;
      });
      final entry = WorkoutEntry(
        id: draftId,
        type: kind(d),
        durationMinutes: d.minutes,
        caloriesBurned: kcal,
        date: day,
        note: note.text.trim().isEmpty ? null : note.text.trim(),
        details: d,
      );
      if (widget.entry == null) {
        await widget.provider.addWorkoutEntry(entry);
      } else {
        await widget.provider.updateWorkoutEntry(entry);
      }
      if (widget.provider.persistenceError != null)
        throw StateError(widget.provider.persistenceError!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is FormatException
              ? e.message
              : e is StateError
              ? e.message
              : e.toString(),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    if (busy || widget.entry == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить тренировку?'),
        content: const Text(
          'Учтённые калории и адаптация БЖУ будут пересчитаны.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!sameDate || !unchanged) {
      setState(
        () =>
            error = 'День или тренировка изменились. Откройте редактор заново.',
      );
      return;
    }
    setState(() => busy = true);
    await widget.provider.deleteWorkoutEntry(widget.entry!.id);
    if (!mounted) return;
    if (widget.provider.persistenceError != null) {
      setState(() {
        busy = false;
        error = widget.provider.persistenceError;
      });
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = preview;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry == null ? 'Новая тренировка' : 'Тренировка'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'День: ${formatDateRu(day)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Укажите этапы и упражнения. Расход — приблизительный, зависит от веса, времени и выбранного вида активности.',
              ),
              if (widget.entry != null && widget.entry!.details == null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Старая запись: её расход мог включать калории покоя. Проверьте число перед сохранением; прежнее значение не пересчитывается автоматически.',
                  ),
                ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Описать тренировку через ИИ',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Text(
                        'Отправляется только ваше описание. Проверьте результат; неизвестное останется пустым. Не вводите медицинские или личные сведения.',
                      ),
                      TextField(
                        controller: prompt,
                        enabled: !busy,
                        maxLines: 3,
                        maxLength: 4000,
                        decoration: const InputDecoration(
                          labelText: 'Описание тренировки',
                          hintText:
                              'Силовая обычная 40 минут: жим 3 подхода по 10 с весом 30 кг',
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : parseWithAi,
                          icon: const Icon(Icons.auto_awesome),
                          label: const Text('Разобрать с ИИ'),
                        ),
                      ),
                      if (aiRemarks != null && aiRemarks!.isNotEmpty)
                        Text('ИИ: $aiRemarks'),
                      if (fromAi)
                        const Text(
                          'Черновик ИИ: проверьте все поля. В дневник ещё ничего не добавлено.',
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Этапы тренировки',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'Длительность каждого этапа включает соответствующие паузы. Не дублируйте минуты в разных этапах.',
              ),
              for (var i = 0; i < segments.length; i++) ...[
                Card(
                  key: ObjectKey(segments[i]),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Этап ${i + 1}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            if (segments.length > 1)
                              IconButton(
                                tooltip: 'Удалить этап ${i + 1}',
                                onPressed: busy
                                    ? null
                                    : () {
                                        final removed = segments[i];
                                        setState(() {
                                          segments.removeAt(i);
                                          error = null;
                                        });
                                        WidgetsBinding.instance
                                            .addPostFrameCallback(
                                              (_) => removed.dispose(),
                                            );
                                      },
                                icon: const Icon(Icons.delete_outline),
                              ),
                          ],
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: segments[i].activityId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Вид и интенсивность',
                          ),
                          items: [
                            for (final a in workoutActivities)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(
                                  a.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  segments[i].activityId = v ?? 'other';
                                  error = null;
                                }),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: segments[i].minutes,
                                enabled: !busy,
                                keyboardType: TextInputType.number,
                                onChanged: changed,
                                decoration: const InputDecoration(
                                  labelText: 'Минуты',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: segments[i].distance,
                                enabled: !busy,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                onChanged: changed,
                                decoration: const InputDecoration(
                                  labelText: 'Дистанция, км',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: busy || segments.length >= 20
                      ? null
                      : () => setState(() => segments.add(_SegmentInput())),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить этап'),
                ),
              ),
              const SizedBox(height: 12),
              Text('Упражнения', style: Theme.of(context).textTheme.titleLarge),
              const Text(
                'Подходы и повторения можно оставить пустыми. Вес — внешний вес, не вес тела. Для разных весов добавьте несколько строк.',
              ),
              for (var i = 0; i < exercises.length; i++) ...[
                Card(
                  key: ObjectKey(exercises[i]),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text('Упражнение ${i + 1}')),
                            IconButton(
                              tooltip: 'Удалить упражнение ${i + 1}',
                              onPressed: busy
                                  ? null
                                  : () {
                                      final removed = exercises[i];
                                      setState(() => exercises.removeAt(i));
                                      WidgetsBinding.instance
                                          .addPostFrameCallback(
                                            (_) => removed.dispose(),
                                          );
                                    },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                        TextField(
                          controller: exercises[i].name,
                          enabled: !busy,
                          maxLength: 120,
                          onChanged: changed,
                          decoration: const InputDecoration(
                            labelText: 'Название упражнения',
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: exercises[i].sets,
                                enabled: !busy,
                                keyboardType: TextInputType.number,
                                onChanged: changed,
                                decoration: const InputDecoration(
                                  labelText: 'Подходы',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: exercises[i].reps,
                                enabled: !busy,
                                keyboardType: TextInputType.number,
                                onChanged: changed,
                                decoration: const InputDecoration(
                                  labelText: 'Повторения',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: exercises[i].weight,
                          enabled: !busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: changed,
                          decoration: const InputDecoration(
                            labelText: 'Внешний вес, кг (необ.)',
                            helperText:
                                '0 — без внешнего веса; пусто — неизвестно',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: busy || exercises.length >= 30
                      ? null
                      : () => setState(() => exercises.add(_ExerciseInput())),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить упражнение'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Калории и дневной лимит',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ввести активные калории вручную'),
                subtitle: const Text(
                  'Например, по часам. Не вводите общий расход вместе с калориями покоя.',
                ),
                value: manual,
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        manual = v;
                        error = null;
                      }),
              ),
              TextField(
                controller: weight,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: changed,
                decoration: InputDecoration(
                  labelText: 'Ваш вес, кг',
                  helperText:
                      widget.entry == null &&
                          widget.provider.profile.currentWeightConfirmed == true
                      ? 'Из профиля: проверьте вес для дня тренировки.'
                      : 'Вес для дня тренировки; пусто — неизвестен.',
                ),
              ),
              if (manual)
                TextField(
                  controller: manualKcal,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  onChanged: changed,
                  decoration: const InputDecoration(
                    labelText: 'Активные калории, ккал',
                  ),
                )
              else if (p == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Для расчёта выберите вид и длительность каждого этапа и проверьте вес.',
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Примерно ${p.active.round()} активных ккал · всего с покоем ${p.gross.round()} ккал.',
                  ),
                ),
              const Text(
                'В дневной лимит питания прибавляется выбранная доля активных калорий:',
              ),
              Text('Учитывать в дневном лимите: $budgetPercent%'),
              Slider(
                value: budgetPercent.toDouble(),
                min: 0,
                max: 100,
                divisions: 100,
                label: '$budgetPercent%',
                onChanged: busy
                    ? null
                    : (v) => setState(() => budgetPercent = v.round()),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Если ваш базовый коэффициент активности уже включает тренировку, повторный учёт завысит лимит. Значения БЖУ — ориентиры, не назначение питания.',
                ),
              ),
              const Text(
                'Источник MET: справочник физической активности взрослых, 2024 (pacompendium.com). Значения усреднённые, предназначены для взрослых 19–59 лет и особенно неточны для других возрастов и индивидуальных особенностей.',
              ),
              TextField(
                controller: note,
                enabled: !busy,
                maxLines: 2,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Примечание (необ.)',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: busy ? null : save,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(
                  widget.entry == null
                      ? 'Проверить и добавить'
                      : 'Проверить и сохранить',
                ),
              ),
              if (widget.entry != null)
                TextButton.icon(
                  onPressed: busy ? null : remove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить тренировку'),
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
