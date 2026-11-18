import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../legacy.dart';
import 'ai_actions.dart';
import 'ai_drafts.dart';
import 'ai_preferences.dart';
import 'local_store.dart';
import 'engine.dart';
import 'photo.dart';
import 'remote.dart';
import 'supplements.dart';

String supplementAmount(SupplementEntry entry) =>
    '${formatNutrient(entry.quantity)} ${supplementUnits[entry.unit]}';

String _entryInfo(SupplementEntry entry) {
  final parts = <String>[supplementAmount(entry)];
  if (entry.strength != null && discreteSupplementUnits.contains(entry.unit)) {
    parts.add(
      '${formatNutrient(entry.strength!)} ${supplementStrengthUnits[entry.strengthUnit]} на 1 ${supplementUnits[entry.unit]}',
    );
  }
  if (entry.creatineGrams != null) {
    parts.add('креатин ${formatNutrient(entry.creatineGrams!)} г');
  }
  for (final nutrient in entry.microTotals.entries.take(3)) {
    parts.add(
      '${microLabels[nutrient.key]}: ${formatNutrient(nutrient.value)}',
    );
  }
  if (entry.creatineGrams == null && entry.microTotals.isEmpty) {
    parts.add('состав или доза вещества не указаны');
  }
  return parts.join(' · ');
}

/// Local manual entry is always available. AI only opens on explicit action.
class SupplementPanel extends StatelessWidget {
  final AppDataProvider provider;
  const SupplementPanel({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final entries = provider.todaySupplementEntries;
    final creatine = entries
        .map((e) => e.creatineGrams)
        .whereType<double>()
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Записи за ${formatDateRu(provider.selectedDate)}'),
            ),
            TextButton.icon(
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: provider.selectedDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100, 12, 31),
                );
                if (date != null) await provider.setSelectedDate(date);
              },
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: const Text('День'),
            ),
          ],
        ),
        if (creatine.isNotEmpty)
          Text(
            'Креатин за день: ${formatNutrient(creatine.fold<double>(0, (a, b) => a + b))} г',
          ),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('Добавки за этот день не записаны.'),
          )
        else
          for (final entry in entries)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _entryInfo(entry),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (entry.source == 'ai')
                            const Text(
                              'Введено с ИИ · проверьте этикетку',
                              style: TextStyle(fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Изменить добавку',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final changed = await showDialog<SupplementEntry>(
                          context: context,
                          builder: (_) => SupplementEditorDialog(
                            initial: entry.toJson(),
                            date: entry.date,
                            id: entry.id,
                            source: entry.source,
                          ),
                        );
                        if (changed == null) return;
                        try {
                          await provider.updateSupplementEntry(changed);
                        } catch (_) {
                          if (context.mounted)
                            _message(
                              context,
                              'Не удалось изменить запись. Данные не удалены.',
                            );
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Удалить добавку',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Удалить запись?'),
                            content: Text(entry.name),
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
                        if (confirmed != true) return;
                        try {
                          await provider.deleteSupplementEntry(entry);
                        } catch (_) {
                          if (context.mounted)
                            _message(context, 'Не удалось удалить запись.');
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () async {
                final entry = await showDialog<SupplementEntry>(
                  context: context,
                  builder: (_) => SupplementEditorDialog(
                    initial: const {},
                    date: provider.selectedDate,
                    id: newId(),
                    source: 'manual',
                  ),
                );
                if (entry == null) return;
                try {
                  await provider.addSupplementEntriesBatch([entry]);
                  if (context.mounted) _message(context, 'Запись добавлена.');
                } catch (_) {
                  if (context.mounted)
                    _message(context, 'Не удалось сохранить запись.');
                }
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Добавить вручную'),
            ),
            OutlinedButton.icon(
              onPressed: () => showSupplementAiInput(context, provider),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Ввести с ИИ'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Записываются ваши количества, без назначения доз. Если сила таблетки или состав неизвестны, они не угадываются. Добавки здесь не прибавляют калории: продукты с КБЖУ вносите отдельно как еду.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

void _message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

Future<void> showSupplementAiInput(
  BuildContext context,
  AppDataProvider provider,
) async {
  final saved = await showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SupplementAiDialog(provider: provider),
  );
  if (saved != null && context.mounted)
    _message(context, 'Добавлено записей: $saved.');
}

class SupplementAiDialog extends StatefulWidget {
  final AppDataProvider provider;
  const SupplementAiDialog({super.key, required this.provider});
  @override
  State<SupplementAiDialog> createState() => _SupplementAiDialogState();
}

class _SupplementAiDialogState extends State<SupplementAiDialog> {
  final text = TextEditingController();
  Uint8List? image;
  String mime = 'image/jpeg';
  bool busy = false, picking = false;
  String? error, photoInfo;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> pickPhoto(ImageSource source) async {
    if (busy || picking) return;
    setState(() {
      picking = true;
      error = null;
    });
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 75,
        requestFullMetadata: false,
      );
      if (file == null) return;
      if (await file.length() > 12 * 1024 * 1024)
        throw ArgumentError('Фото больше 12 МБ.');
      final compressed = await compressPhoto(await file.readAsBytes());
      if (mounted)
        setState(() {
          image = compressed.bytes;
          mime = compressed.mime;
          photoInfo = 'Этикетка прикреплена: ${compressed.sizeLabel}';
        });
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> parse() async {
    if (busy || picking) return;
    if (text.text.trim().isEmpty && image == null) {
      setState(
        () => error = 'Опишите добавки и количество или приложите этикетку.',
      );
      return;
    }
    final account = SmartRemote.instance.client?.auth.currentUser?.id;
    if (account == null) {
      setState(
        () => error =
            'Для ИИ войдите в аккаунт в разделе Smart. Ручной ввод доступен без входа.',
      );
      return;
    }
    final date = widget.provider.selectedDate;
    final privacyEpoch = LocalPreferences.privacyEpoch;
    final input = text.text.trim(), photo = image, selectedMime = mime;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final accepted = await ensureAiConsent(
        context,
        widget.provider.storage.local,
        account,
      );
      if (!accepted || !mounted) return;
      if (SmartRemote.instance.client?.auth.currentUser?.id != account ||
          !AiConsent(
            widget.provider.storage.local,
            account,
          ).validFor(privacyEpoch)) {
        throw StateError(
          'Аккаунт или согласие изменились. Запрос не отправлен.',
        );
      }
      final recognized = await SmartRemote.instance.parseSupplements(
        text: input,
        image: photo,
        mime: selectedMime,
      );
      final result = prepareAiSupplementReview(
        recognized,
        hasTakenDescription: input.isNotEmpty,
      );
      if (!mounted) return;
      if (SmartRemote.instance.client?.auth.currentUser?.id != account) {
        throw StateError('Аккаунт изменился. Черновик не сохранён.');
      }
      if (!AiConsent(
        widget.provider.storage.local,
        account,
      ).validFor(privacyEpoch)) {
        throw StateError('Согласие изменилось. Черновик не применён.');
      }
      if (result.isEmpty)
        throw StateError(
          'Добавки не найдены. Уточните название и количество. Ничего не записано.',
        );
      setState(() => busy = false);
      final saved = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SupplementReviewDialog(
          items: result,
          provider: widget.provider,
          date: date,
          owner: account,
        ),
      );
      if (saved != null && mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) setState(() => error = friendlyAiError(e));
    } finally {
      if (mounted && busy) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !picking,
    child: AlertDialog(
      title: const Text('Добавки через ИИ'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Например: «5 г креатина и 1 капсула витамина D, 2000 МЕ в капсуле». ИИ не подбирает дозу.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: text,
                enabled: !busy,
                maxLines: 4,
                maxLength: 4000,
                decoration: const InputDecoration(
                  labelText: 'Что и сколько вы приняли',
                  hintText: 'Креатин 5 г, витамин C 500 мг',
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy || picking
                        ? null
                        : () => pickPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_outlined),
                    label: const Text('Этикетка из галереи'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || picking
                        ? null
                        : () => pickPhoto(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Камера'),
                  ),
                  if (image != null)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              image = null;
                              photoInfo = null;
                            }),
                      child: const Text('Убрать фото'),
                    ),
                ],
              ),
              if (photoInfo != null) Text(photoInfo!),
              const SizedBox(height: 8),
              const Text(
                'Фото может помочь прочитать состав, но не доказывает, сколько вы приняли. Неизвестные дозы останутся пустыми; перед записью всё можно исправить.',
                style: TextStyle(fontSize: 12),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (busy || picking) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy || picking ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        FilledButton(
          onPressed: busy || picking ? null : parse,
          child: Text(busy ? 'Распознаём…' : 'Распознать и проверить'),
        ),
      ],
    ),
  );
}

class SupplementReviewDialog extends StatefulWidget {
  final List<Json> items;
  final AppDataProvider provider;
  final DateTime date;
  final String? owner;
  const SupplementReviewDialog({
    super.key,
    required this.items,
    required this.provider,
    required this.date,
    this.owner,
  });
  @override
  State<SupplementReviewDialog> createState() => _SupplementReviewDialogState();
}

class _SupplementReviewDialogState extends State<SupplementReviewDialog> {
  late final items = validateAiSupplements(
    widget.items,
  ).map((e) => {...e, '_id': newId(), '_reviewed': false}).toList();
  bool saving = false;
  String? error;
  late final int reviewPrivacyEpoch;
  late final String reviewDiaryGeneration;
  late final String? reviewBinding;

  @override
  void initState() {
    super.initState();
    final local = widget.provider.storage.local;
    reviewPrivacyEpoch = LocalPreferences.privacyEpoch;
    reviewDiaryGeneration = local.diaryGeneration;
    reviewBinding = local.getString('_bound_user');
  }

  bool get authorized {
    final local = widget.provider.storage.local;
    final owner = widget.owner;
    if (!mounted ||
        local.diaryGeneration != reviewDiaryGeneration ||
        local.getString('_bound_user') != reviewBinding)
      return false;
    if (owner == null) return true; // Synthetic/manual ownerless review.
    return (reviewBinding == null || reviewBinding == owner) &&
        SmartRemote.instance.client?.auth.currentUser?.id == owner &&
        AiConsent(local, owner).validFor(reviewPrivacyEpoch);
  }

  SupplementEntry? entryFor(Json item) {
    try {
      return SupplementEntry.fromJson({
        'id': item['_id'],
        'name': item['name'],
        'quantity': item['quantity'],
        'unit': item['unit'],
        'nutrientKey': item['nutrientKey'],
        'date': widget.date.toIso8601String(),
        'strength': number(item['strength']) > 0 ? item['strength'] : null,
        'strengthUnit': item['strengthUnit'],
        'compositionPerUnit': item['compositionPerUnit'] ?? {},
        'source': 'ai',
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> edit(int index) async {
    final row = items[index];
    final changed = await showDialog<SupplementEntry>(
      context: context,
      builder: (_) => SupplementEditorDialog(
        initial: row,
        date: widget.date,
        id: row['_id'] as String,
        source: 'ai',
      ),
    );
    if (changed != null && mounted)
      setState(() {
        items[index] = {
          ...changed.toJson(),
          '_id': changed.id,
          '_reviewed': true,
          'assumptions': row['assumptions'],
        };
        error = null;
      });
  }

  Future<void> save() async {
    if (saving || items.isEmpty) return;
    if (items.any((item) => item['_reviewed'] != true)) {
      setState(
        () => error = 'Проверьте и подтвердите количество каждой добавки.',
      );
      return;
    }
    final entries = items.map(entryFor).toList();
    if (entries.any((e) => e == null)) {
      setState(
        () => error =
            'Укажите количество и единицы каждой записи. Неизвестное не заполняется автоматически.',
      );
      return;
    }
    if (!authorized) {
      setState(
        () => error =
            'Аккаунт, согласие или дневник изменились. Черновик не сохранён.',
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.provider.addSupplementEntriesBatch(
        entries.cast<SupplementEntry>(),
        authorizationGuard: () => authorized,
      );
      if (mounted) {
        setState(() => saving = false);
        Navigator.pop(context, entries.length);
      }
    } catch (_) {
      if (mounted)
        setState(() {
          saving = false;
          error =
              'Не удалось сохранить записи. Попробуйте ещё раз; дубли не добавятся.';
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('Проверьте добавки'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Запись за ${formatDateRu(widget.date)}'),
              const Text(
                'ИИ мог ошибиться. Сверьте название, количество и силу с упаковкой. Неизвестное не равно нулю; это не назначение доз.',
              ),
              for (final item in items)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${item['name']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Убрать добавку',
                              onPressed: saving
                                  ? null
                                  : () => setState(() => items.remove(item)),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        Text(
                          entryFor(item) == null
                              ? 'Количество или единица не указаны — нажмите «Изменить».'
                              : _entryInfo(entryFor(item)!),
                        ),
                        if ('${item['assumptions'] ?? ''}'.isNotEmpty)
                          Text(
                            '${item['assumptions']}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        TextButton.icon(
                          onPressed: saving
                              ? null
                              : () => edit(items.indexOf(item)),
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: Text(
                            item['_reviewed'] == true
                                ? 'Проверено · изменить'
                                : 'Проверить дозу',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (items.isEmpty) const Text('Все записи убраны.'),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (saving) const LinearProgressIndicator(),
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
          onPressed: saving || items.isEmpty ? null : save,
          child: Text(saving ? 'Сохраняем…' : 'Добавить ${items.length}'),
        ),
      ],
    ),
  );
}

/// Reused for both the AI review and fully offline manual input.
class SupplementEditorDialog extends StatefulWidget {
  final Json initial;
  final DateTime date;
  final String id, source;
  const SupplementEditorDialog({
    super.key,
    required this.initial,
    required this.date,
    required this.id,
    required this.source,
  });
  @override
  State<SupplementEditorDialog> createState() => _SupplementEditorDialogState();
}

class _SupplementEditorDialogState extends State<SupplementEditorDialog> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(
    text: '${widget.initial['name'] ?? ''}',
  );
  late final quantity = TextEditingController(
    text: number(widget.initial['quantity']) > 0
        ? '${widget.initial['quantity']}'
        : '',
  );
  late final strength = TextEditingController(
    text: number(widget.initial['strength']) > 0
        ? '${widget.initial['strength']}'
        : '',
  );
  late String unit = supplementUnits.containsKey(widget.initial['unit'])
      ? widget.initial['unit'] as String
      : '';
  late String strengthUnit =
      supplementStrengthUnits.containsKey(widget.initial['strengthUnit'])
      ? widget.initial['strengthUnit'] as String
      : '';
  late String nutrient =
      {
        ...supplementNutrientKeys,
        'creatine',
        'other',
      }.contains(widget.initial['nutrientKey'])
      ? widget.initial['nutrientKey'] as String
      : 'other';
  late Map<String, double> composition = {
    for (final e
        in (widget.initial['compositionPerUnit'] is Map
                ? widget.initial['compositionPerUnit'] as Map
                : const {})
            .entries)
      if (supplementNutrientKeys.contains(e.key) &&
          e.value is num &&
          (e.value as num).isFinite &&
          (e.value as num) >= 0)
        e.key as String: (e.value as num).toDouble(),
  };
  @override
  void dispose() {
    name.dispose();
    quantity.dispose();
    strength.dispose();
    super.dispose();
  }

  Future<void> editComposition() async {
    if (unit.isEmpty) {
      _message(context, 'Сначала выберите единицу количества.');
      return;
    }
    final changed = await showDialog<Map<String, double>>(
      context: context,
      builder: (_) =>
          SupplementCompositionDialog(initial: composition, unit: unit),
    );
    if (changed != null && mounted) setState(() => composition = changed);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Запись добавки'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: name,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Название'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Укажите название' : null,
              ),
              DropdownButtonFormField<String>(
                initialValue: nutrient,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Вещество'),
                items: [
                  for (final key in [
                    'creatine',
                    ...supplementNutrientKeys,
                    'other',
                  ])
                    DropdownMenuItem(
                      value: key,
                      child: Text(
                        supplementKindLabel(key),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => nutrient = value ?? 'other'),
              ),
              TextFormField(
                controller: quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Сколько принято',
                  hintText: 'Только указанное вами количество',
                ),
                validator: (v) {
                  final n = parseNutritionNumber(v ?? '');
                  return n == null || n <= 0 || n > 1000000
                      ? 'Введите количество больше 0'
                      : null;
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: unit.isEmpty ? null : unit,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Единица количества',
                ),
                items: [
                  for (final e in supplementUnits.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (value) {
                  final changedWithComposition =
                      composition.isNotEmpty && value != unit;
                  setState(() => unit = value ?? '');
                  if (changedWithComposition)
                    _message(
                      context,
                      'Проверьте состав: он указан на одну новую единицу.',
                    );
                },
                validator: (value) =>
                    value == null || value.isEmpty ? 'Выберите единицу' : null,
              ),
              if (discreteSupplementUnits.contains(unit)) ...[
                TextFormField(
                  controller: strength,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText:
                        'Доза вещества на 1 ${supplementUnits[unit]} (необязательно)',
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final n = parseNutritionNumber(v);
                    return n == null || n <= 0 || n > 100000000
                        ? 'Проверьте дозу'
                        : null;
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: strengthUnit.isEmpty ? null : strengthUnit,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Единица дозы на упаковке',
                  ),
                  items: [
                    for (final e in supplementStrengthUnits.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (value) =>
                      setState(() => strengthUnit = value ?? ''),
                  validator: (value) =>
                      strength.text.trim().isNotEmpty &&
                          (value == null || value.isEmpty)
                      ? 'Выберите единицу дозы'
                      : null,
                ),
              ],
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: editComposition,
                icon: const Icon(Icons.science_outlined),
                label: Text('Состав на 1 единицу · ${composition.length}'),
              ),
              const Text(
                'Для комплекса можно вписать значения с этикетки на одну таблетку, капсулу или порцию. Если доза не указана, оставьте поле пустым.',
                style: TextStyle(fontSize: 12),
              ),
              if (nutrient == 'vitaminD')
                const Text(
                  'Для витамина D: 1 мкг = 40 МЕ. Сверьте форму и этикетку.',
                  style: TextStyle(fontSize: 12),
                ),
              if (nutrient == 'vitaminA')
                const Text(
                  'Витамин A учитывается по явно указанному составу в мкг RAE: форма имеет значение.',
                  style: TextStyle(fontSize: 12),
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
          if (!form.currentState!.validate()) return;
          final rawStrength =
              discreteSupplementUnits.contains(unit) &&
                  strength.text.trim().isNotEmpty
              ? parseNutritionNumber(strength.text)
              : null;
          try {
            final result = SupplementEntry.fromJson({
              'id': widget.id,
              'name': name.text.trim(),
              'quantity': parseNutritionNumber(quantity.text)!,
              'unit': unit,
              'nutrientKey': nutrient,
              'date': widget.date.toIso8601String(),
              if (rawStrength != null) 'strength': rawStrength,
              if (rawStrength != null) 'strengthUnit': strengthUnit,
              'compositionPerUnit': composition,
              'source': widget.source,
            });
            Navigator.pop(context, result);
          } catch (_) {
            _message(context, 'Проверьте количество и состав.');
          }
        },
        child: const Text('Применить'),
      ),
    ],
  );
}

class SupplementCompositionDialog extends StatefulWidget {
  final Map<String, double> initial;
  final String unit;
  const SupplementCompositionDialog({
    super.key,
    required this.initial,
    required this.unit,
  });
  @override
  State<SupplementCompositionDialog> createState() =>
      _SupplementCompositionDialogState();
}

class _SupplementCompositionDialogState
    extends State<SupplementCompositionDialog> {
  final form = GlobalKey<FormState>();
  late final fields = {
    for (final k in supplementNutrientKeys)
      k: TextEditingController(text: widget.initial[k]?.toString() ?? ''),
  };
  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Состав добавки'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Значения с этикетки на 1 ${supplementUnits[widget.unit]}. Пусто — неизвестно; 0 — известное отсутствие.',
              ),
              for (final key in supplementNutrientKeys)
                TextFormField(
                  controller: fields[key],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(labelText: microLabels[key]),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final n = parseNutritionNumber(v);
                    return n == null || n > 100000000
                        ? 'Введите число ≥ 0'
                        : null;
                  },
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
          if (!form.currentState!.validate()) return;
          Navigator.pop(context, {
            for (final e in fields.entries)
              if (e.value.text.trim().isNotEmpty)
                e.key: parseNutritionNumber(e.value.text)!,
          });
        },
        child: const Text('Применить'),
      ),
    ],
  );
}
