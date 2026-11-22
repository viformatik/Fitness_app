import 'dart:convert';
import 'package:flutter/material.dart';
import '../legacy.dart';
import 'ai_drafts.dart';
import 'ai_preferences.dart';
import 'engine.dart';
import 'local_store.dart';
import 'remote.dart';

Future<bool> ensureAiConsent(
  BuildContext context,
  LocalPreferences store,
  String account, {
  bool Function()? authorizationGuard,
}) async {
  final privacyEpoch = LocalPreferences.privacyEpoch;
  bool authorized() =>
      LocalPreferences.privacyEpochIsCurrent(privacyEpoch) &&
      SmartRemote.instance.client?.auth.currentUser?.id == account &&
      (authorizationGuard?.call() ?? true);
  if (!authorized()) return false;
  final consent = AiConsent(store, account);
  if (consent.accepted) return true;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('AI · одно согласие'),
      content: const SingleChildScrollView(
        child: Text(
          'Подтверждаю, что мне 18 лет или больше. Разрешаю отправлять в Google Gemini введённое описание еды, добавок или тренировки, выбранное фото и уточняемый черновик — только при запуске соответствующей функции. '
          'Отдельный анализ еды передаёт выбранные записи за период. Новый обзор может передать сводку выбранных разделов: питание, воду, шаги, тренировки, вес и добавки; точный состав показывается для проверки перед отправкой. Профиль, фотографии и свободные заметки автоматически в сводку не добавляются. '
          'Бесплатный Gemini может использовать запросы и ответы для улучшения продуктов; возможна проверка человеком. Google не разрешает отправлять личные, чувствительные или конфиденциальные сведения в бесплатный API. Настоящие записи дневника могут быть личными и чувствительными; не отправляйте их. Согласие не отменяет это ограничение. Для пользователей ЕЭЗ, Великобритании и Швейцарии по условиям провайдера нужен платный API. '
          '\n\nСогласие хранится для этого аккаунта на этом устройстве; его можно отозвать в разделе «Ещё → Конфиденциальность ИИ». При изменении условий спросим снова.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Не сейчас'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Мне 18+, запомнить'),
        ),
      ],
    ),
  );
  if (accepted != true || !context.mounted || !authorized()) return false;
  try {
    await consent.accept(authorizationGuard: authorized);
    return authorized() && consent.accepted;
  } catch (_) {
    if (context.mounted && authorized())
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось сохранить согласие на устройстве. Запрос не отправлен. Проверьте свободное место.',
          ),
        ),
      );
    return false;
  }
}

class AiPrivacyControls extends StatefulWidget {
  final LocalPreferences store;
  final String? owner;
  final bool busy;
  const AiPrivacyControls({
    super.key,
    required this.store,
    required this.owner,
    required this.busy,
  });
  @override
  State<AiPrivacyControls> createState() => _AiPrivacyControlsState();
}

class _AiPrivacyControlsState extends State<AiPrivacyControls> {
  bool pending = false;
  @override
  Widget build(BuildContext context) {
    final account = widget.owner;
    if (account == null) return const SizedBox.shrink();
    final consent = AiConsent(widget.store, account);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          consent.accepted
              ? 'Согласие на AI сохранено для этого аккаунта и устройства.'
              : 'Согласие на AI спросим один раз перед первым запросом.',
        ),
        if (consent.accepted)
          TextButton.icon(
            icon: const Icon(Icons.privacy_tip_outlined, size: 16),
            onPressed: widget.busy || pending
                ? null
                : () async {
                    setState(() => pending = true);
                    try {
                      await consent.revoke();
                    } catch (_) {
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Не удалось отозвать согласие. Попробуйте ещё раз.',
                            ),
                          ),
                        );
                    } finally {
                      if (mounted) setState(() => pending = false);
                    }
                  },
            label: const Text('Отозвать согласие на AI'),
          ),
      ],
    );
  }
}

Future<void> undoAiAddition(
  AppDataProvider provider,
  String account, {
  List<Json>? original,
}) async {
  if (SmartRemote.instance.client?.auth.currentUser?.id != account)
    throw StateError('Аккаунт изменился. Войдите в нужный аккаунт.');
  final store = provider.storage.local;
  final undo = AiUndoStore(store, account);
  final rows = original ?? undo.read();
  if (rows.isEmpty) return;
  final generation = store.diaryGeneration;
  bool valid() =>
      SmartRemote.instance.client?.auth.currentUser?.id == account &&
      store.diaryGeneration == generation &&
      jsonEncode(undo.read()) == jsonEncode(rows);
  if (!valid()) {
    throw StateError('Дневник или доступ изменились. Отмена остановлена.');
  }
  final entries = rows.map(FoodEntry.fromJson).toList();
  await provider.undoFoodEntriesBatch(entries, authorizationGuard: valid);
  if (valid()) await undo.clear();
}

Future<void> pinAiFavorite(
  BuildContext context,
  AppDataProvider provider,
  String account,
  List<Json> items,
) async {
  final input = TextEditingController(
    text: items.map((e) => e['name']).take(2).join(' + '),
  );
  String? title;
  try {
    title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Закрепить набор'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: input,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Название набора'),
            ),
            const Text(
              'Только на этом устройстве, без фото. Одинаковое название заменит прежний набор. До 20 наборов.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text),
            child: const Text('Закрепить'),
          ),
        ],
      ),
    );
  } finally {
    input.dispose();
  }
  if (title == null || !context.mounted) return;
  if (SmartRemote.instance.client?.auth.currentUser?.id != account)
    throw StateError('Аккаунт изменился. Набор не закреплён.');
  await AiFavorites(provider.storage.local, account).save(title, items);
  if (context.mounted)
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Набор добавлен в избранное. Повтор — без AI-запроса.'),
      ),
    );
}

class AiPersonalShortcuts extends StatefulWidget {
  final AppDataProvider provider;
  final String? owner;
  final bool busy;
  final Future<void> Function(List<Json>) onReview;
  const AiPersonalShortcuts({
    super.key,
    required this.provider,
    required this.owner,
    required this.busy,
    required this.onReview,
  });
  @override
  State<AiPersonalShortcuts> createState() => _AiPersonalShortcutsState();
}

class _AiPersonalShortcutsState extends State<AiPersonalShortcuts> {
  bool pending = false;
  String? error;
  @override
  Widget build(BuildContext context) {
    final account = widget.owner;
    if (account == null) return const SizedBox.shrink();
    final favorites = AiFavorites(widget.provider.storage.local, account);
    final records = favorites.read();
    final undo = AiUndoStore(widget.provider.storage.local, account).read();
    final date = undo.isEmpty
        ? null
        : DateTime.tryParse('${undo.first['date']}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (undo.isNotEmpty && date != null) ...[
          const Divider(height: 24),
          Text(
            'Последнее добавление: ${undo.length} поз. · ${formatDateRu(date)}',
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.undo),
            label: const Text('Отменить последнее добавление'),
            onPressed: widget.busy || pending
                ? null
                : () async {
                    setState(() {
                      pending = true;
                      error = null;
                    });
                    try {
                      await undoAiAddition(
                        widget.provider,
                        account,
                        original: undo,
                      );
                    } catch (e) {
                      if (mounted) setState(() => error = friendlyAiError(e));
                    } finally {
                      if (mounted) setState(() => pending = false);
                    }
                  },
          ),
        ],
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (records.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            leading: const Icon(Icons.star_outline),
            title: Text('Избранные наборы · ${records.length}'),
            subtitle: const Text('Повторить без AI-запроса'),
            children: [
              for (final record in records)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(record['name'] as String),
                  subtitle: Text(
                    '${AiPortionTotals.fromItems((record['items'] as List).cast<Json>()).calories.round()} ккал · проверить порцию',
                  ),
                  onTap: widget.busy || pending
                      ? null
                      : () => widget.onReview(
                          (record['items'] as List).cast<Json>(),
                        ),
                  trailing: IconButton(
                    tooltip: 'Убрать из избранного: ${record['name']}',
                    icon: const Icon(Icons.star),
                    onPressed: widget.busy || pending
                        ? null
                        : () async {
                            try {
                              await favorites.remove(record['name'] as String);
                              if (mounted) setState(() {});
                            } catch (e) {
                              if (mounted)
                                setState(() => error = friendlyAiError(e));
                            }
                          },
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
