import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../legacy.dart';
import 'sleep.dart';

/// Reuses the diary provider and selected date. This is self-reported sleep,
/// not a clinical assessment or an automatic Health integration.
class SleepDayCard extends StatelessWidget {
  final AppDataProvider provider;
  const SleepDayCard({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final selected = provider.selectedDate;
    final date = DateTime(selected.year, selected.month, selected.day);
    final key = sleepDocumentKey(date);
    final result = readSleepDay(provider.storage.local, date);
    final raw = provider.storage.local.get(key);
    final value = result.value;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Сон', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              result.unreadable
                  ? 'Запись не удалось прочитать. Она не изменена.'
                  : value == null
                  ? 'За выбранный день не записан.'
                  : '${formatSleepMinutes(value.minutes)} · введено вручную',
            ),
            const SizedBox(height: 6),
            const Text(
              'Укажите общую длительность за выбранный день. Это ваши данные, не оценка качества сна. '
              'Health пока не подключён.',
            ),
            const SizedBox(height: 6),
            const Text(
              'Запись хранится на устройстве; облачная синхронизация сна требует отдельной настройки сервера.',
            ),
            if (!result.unreadable) ...[
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SleepEditor(
                    provider: provider,
                    date: date,
                    expected: raw as String?,
                    initial: value,
                  ),
                ),
                icon: const Icon(Icons.bedtime_outlined),
                label: Text(value == null ? 'Записать сон' : 'Изменить сон'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SleepEditor extends StatefulWidget {
  final AppDataProvider provider;
  final DateTime date;
  final String? expected;
  final SleepDay? initial;
  const SleepEditor({
    super.key,
    required this.provider,
    required this.date,
    required this.expected,
    required this.initial,
  });

  @override
  State<SleepEditor> createState() => _SleepEditorState();
}

class _SleepEditorState extends State<SleepEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController hours, minutes;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final amount = widget.initial?.minutes;
    hours = TextEditingController(
      text: amount == null ? '' : '${amount ~/ 60}',
    );
    minutes = TextEditingController(
      text: amount == null ? '' : '${amount % 60}',
    );
  }

  @override
  void dispose() {
    hours.dispose();
    minutes.dispose();
    super.dispose();
  }

  String? _number(String? input, int limit) {
    final value = int.tryParse((input ?? '').trim());
    if (value == null || value < 0 || value > limit)
      return 'Введите число от 0 до $limit';
    return null;
  }

  bool get dateUnchanged =>
      sleepDateKey(widget.provider.selectedDate) == sleepDateKey(widget.date);

  Future<void> _save() async {
    if (busy || !form.currentState!.validate()) return;
    final h = int.parse(hours.text.trim()), m = int.parse(minutes.text.trim());
    if (h * 60 + m > 1440) {
      setState(() => error = 'За один день можно записать не более 24 часов.');
      return;
    }
    if (!dateUnchanged) {
      setState(
        () => error = 'Выбранная дата изменилась. Откройте запись заново.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final entry = SleepDay(
        day: sleepDateKey(widget.date),
        minutes: h * 60 + m,
      );
      await widget.provider.storage.writeSleepDocument(
        sleepDocumentKey(widget.date),
        widget.expected,
        encodeSleepDay(entry),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              e is StateError && e.message.toString().contains('изменилась')
              ? 'Запись изменилась. Закройте редактор и проверьте её заново.'
              : 'Не удалось сохранить сон. Исходная запись не изменена.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Удалить запись сна?'),
          content: const Text(
            'Удалится только запись за выбранный день. Остальные данные останутся.',
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
      if (confirmed != true || !mounted) return;
      if (!dateUnchanged) {
        setState(
          () => error = 'Выбранная дата изменилась. Откройте запись заново.',
        );
        return;
      }
      await widget.provider.storage.writeSleepDocument(
        sleepDocumentKey(widget.date),
        widget.expected,
        null,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              e is StateError && e.message.toString().contains('изменилась')
              ? 'Запись изменилась. Закройте редактор и проверьте её заново.'
              : 'Не удалось удалить запись. Исходные данные не изменены.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Сон · ${formatDateRu(widget.date)}'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Введите общую длительность сна. Поля обязательны; 0 ч 0 мин — явно записанное значение.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: hours,
              enabled: !busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Часы (0–24)'),
              validator: (value) => _number(value, 24),
            ),
            TextFormField(
              controller: minutes,
              enabled: !busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Минуты (0–59)'),
              validator: (value) => _number(value, 59),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      if (widget.initial != null)
        TextButton(
          onPressed: busy ? null : _delete,
          child: const Text('Удалить запись'),
        ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: busy ? null : _save,
        child: const Text('Сохранить'),
      ),
    ],
  );
}
