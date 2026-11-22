import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../legacy.dart';
import 'install_stub.dart'
    if (dart.library.js_interop) 'install_web.dart'
    as install;

/// Copies nutrition, portion and meal, but never invents a time of eating.
/// Each copy is a new diary entry; source entries are never edited.
List<FoodEntry> makePreviousDayCopies(
  List<FoodEntry> source,
  DateTime target,
) => [
  for (final entry in source)
    FoodEntry(
      name: entry.name,
      caloriesPer100g: entry.caloriesPer100g,
      proteinPer100g: entry.proteinPer100g,
      fatPer100g: entry.fatPer100g,
      carbsPer100g: entry.carbsPer100g,
      micros: Map<String, double>.of(entry.micros),
      microsEstimated: entry.microsEstimated,
      amountGrams: entry.amountGrams,
      mealType: entry.mealType,
      date: DateTime(target.year, target.month, target.day),
      loggedAt: DateTime(target.year, target.month, target.day),
      timeKnown: false,
    ),
];

/// Preview before adding, one durable batch write, and a safe undo of unchanged
/// copies only. Dates are captured before the asynchronous read and dialog.
class RepeatPreviousDay extends StatefulWidget {
  final AppDataProvider provider;
  const RepeatPreviousDay({super.key, required this.provider});

  @override
  State<RepeatPreviousDay> createState() => _RepeatPreviousDayState();
}

class _RepeatPreviousDayState extends State<RepeatPreviousDay> {
  bool _busy = false;

  Future<void> _repeat() async {
    if (_busy) return;
    setState(() => _busy = true);
    final provider = widget.provider;
    final selected = provider.selectedDate;
    final target = DateTime(selected.year, selected.month, selected.day);
    // Calendar arithmetic avoids daylight-saving transitions around midnight.
    final previous = DateTime(target.year, target.month, target.day - 1);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await provider.storage.pendingMutations;
      final generation = provider.storage.local.diaryGeneration;
      bool sameGeneration() =>
          provider.storage.local.diaryGeneration == generation;
      final original = await provider.storage.getFoodEntries(previous);
      if (!mounted) return;
      if (original.isEmpty) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text('За ${formatDateRu(previous)} нет записей о еде.'),
          ),
        );
        return;
      }
      final calories = original.fold<double>(0, (sum, e) => sum + e.calories);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Повторить питание?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Из ${formatDateRu(previous)} в ${formatDateRu(target)}'),
                const SizedBox(height: 8),
                Text('${original.length} записей · ${calories.round()} ккал'),
                const SizedBox(height: 10),
                for (final meal in MealType.values)
                  if (original.any((entry) => entry.mealType == meal)) ...[
                    Text(meal.label, style: Theme.of(ctx).textTheme.titleSmall),
                    for (final entry in original.where(
                      (e) => e.mealType == meal,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(top: 3, bottom: 3),
                        child: Text(
                          '${entry.name} · ${formatGrams(entry.amountGrams)} г',
                        ),
                      ),
                    const SizedBox(height: 6),
                  ],
                const SizedBox(height: 4),
                const Text(
                  'Копии добавятся к существующим записям. Вода, шаги и тренировки не переносятся. Время еды не задаётся — его можно указать в редакторе.',
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
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Добавить копии'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      final copies = makePreviousDayCopies(original, target);
      await provider.addFoodEntriesBatch(
        copies,
        authorizationGuard: sameGeneration,
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Добавлено записей: ${copies.length} · ${formatDateRu(target)}',
          ),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () async {
              try {
                await provider.undoFoodEntriesBatch(
                  copies,
                  authorizationGuard: sameGeneration,
                );
                messenger.showSnackBar(
                  const SnackBar(content: Text('Копирование отменено.')),
                );
              } catch (_) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Не удалось отменить: возможно, одна из копий уже изменена. Проверьте дневник.',
                    ),
                    duration: Duration(seconds: 8),
                  ),
                );
              }
            },
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось повторить питание. Проверьте сохранение и попробуйте ещё раз.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: _busy ? null : _repeat,
    icon: const Icon(Icons.content_copy_rounded, size: 18),
    label: const Text('Повторить предыдущий день'),
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ),
  );
}

/// The native browser prompt is used when offered; manual instructions remain
/// available for Safari and browsers that do not expose beforeinstallprompt.
Future<void> showInstallHelp(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final available = kIsWeb && install.canInstallWebApp;
  final installed = kIsWeb && install.isWebAppInstalled;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: .76,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            Text(
              'На главный экран',
              style: Theme.of(ctx).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            const Text('Открывайте дневник с экрана телефона, как приложение.'),
            const SizedBox(height: 16),
            if (installed) ...[
              const Text('Приложение уже открыто с главного экрана.'),
              const SizedBox(height: 12),
            ] else if (available) ...[
              FilledButton.icon(
                onPressed: () async {
                  // Start the prompt directly in the user gesture.
                  final resultFuture = install.requestWebAppInstall();
                  Navigator.pop(ctx);
                  final result = await resultFuture;
                  if (result == 'accepted') {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Запрос на установку отправлен браузеру.',
                        ),
                      ),
                    );
                  } else if (result == 'unavailable') {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Используйте меню браузера, чтобы добавить сайт на главный экран.',
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.install_mobile_rounded),
                label: const Text('Установить приложение'),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'Android · Chrome',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Откройте меню ⋮ → «Установить приложение» или «Добавить на главный экран».',
            ),
            const SizedBox(height: 14),
            Text('iPhone · Safari', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Нажмите «Поделиться» → «На экран Домой» → «Добавить».'),
            const SizedBox(height: 16),
            const Text(
              'Дневник хранится на устройстве. Перед очисткой браузера сохраните копию в Smart → «Вся история и резервные копии». На iPhone данные сайта и значка могут храниться отдельно — при необходимости перенесите их через экспорт и импорт.',
            ),
            const SizedBox(height: 12),
            const Text(
              'После первой загрузки приложение и местный каталог могут открываться без сети. AI, поиск онлайн-брендов и синхронизация требуют интернет.',
            ),
          ],
        ),
      ),
    ),
  );
}
