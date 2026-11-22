import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../legacy.dart';
import 'ai_actions.dart' show AiPrivacyControls;
import 'remote.dart' show SmartRemote;
import 'gym_ui.dart';
import 'gym_calendar.dart';
import 'nutrition_insights.dart';
import 'nutrition_insights_ui.dart';
import 'sleep.dart';
import 'supplement_ui.dart';
import 'ui.dart'
    show
        AiChatScreen,
        BackupPanel,
        CloudPanel,
        DaySlider,
        SmartHub,
        askPositiveNumber,
        openFoodCatalog;
import 'workout_ui.dart';

/// A small landing page, with the original full dashboard retained in More.
class SimpleHomeScreen extends StatelessWidget {
  final void Function(int index) openTab;
  const SimpleHomeScreen({super.key, required this.openTab});

  @override
  Widget build(BuildContext context) => Consumer<AppDataProvider>(
    builder: (context, p, _) {
      if (p.isLoading) return const Center(child: CircularProgressIndicator());
      final today = dayKey(p.selectedDate) == dayKey(DateTime.now());
      final hasWater = p.hasRecordedWater;
      final hasSteps = p.hasRecordedSteps;
      final gymIndex = readGymCalendar(p.storage.local);
      final gymDay = gymIndex.forDate(p.selectedDate);
      final sleep = readSleepDay(p.storage.local, p.selectedDate);
      final manualWorkouts = p.todayWorkoutEntries.length;
      final addFoodButton = FilledButton.icon(
        onPressed: () => showMealPicker(context, p),
        icon: const Icon(Icons.add_rounded, size: 19),
        label: const Text('Добавить еду'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );
      final addWaterButton = OutlinedButton.icon(
        onPressed: () => p.quickAddWater(),
        icon: const Icon(Icons.water_drop_outlined, size: 18),
        label: const Text('Вода +250 мл'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );
      final stackActions =
          MediaQuery.sizeOf(context).width < 360 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.25;
      return RefreshIndicator(
        onRefresh: p.refresh,
        child: CenteredBody(
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ТВОЙ ДНЕВНИК',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          today ? 'Сегодня' : 'Выбранный день',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          formatDateRu(p.selectedDate),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Ещё: настройки и данные',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const MoreScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(child: DaySlider(provider: p)),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Выбрать дату',
                    icon: const Icon(Icons.calendar_month_outlined),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: p.selectedDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                      );
                      if (date != null) await p.setSelectedDate(date);
                    },
                  ),
                ],
              ),
              DiaryErrorBanner(provider: p),
              if (p.metabolism.automatic && !p.automaticMetabolismActive)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Автоцель приостановлена: подтвердите профиль и настройки расчёта. '
                    'Пока используется сохранённый ручной ориентир.',
                  ),
                ),
              const SizedBox(height: 8),
              PremiumCard(
                gradient: AppTheme.heroGradient,
                radius: 26,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Всё важное рядом',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Записывай в своём темпе',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        RoundIconBadge(
                          icon: Icons.spa_rounded,
                          color: AppTheme.primary,
                          size: 44,
                          iconSize: 22,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final textScale = MediaQuery.textScalerOf(
                          context,
                        ).scale(1);
                        final columns =
                            constraints.maxWidth >= 500 && textScale <= 1.2
                            ? 4
                            : 2;
                        final width =
                            (constraints.maxWidth - 8 * (columns - 1)) /
                            columns;
                        final metrics = [
                          _HomeMetric(
                            label: 'ЕДА',
                            value: p.todayFoodEntries.isEmpty
                                ? 'Нет записей'
                                : '${formatNumber(p.todayCaloriesConsumed)} ккал',
                            color: AppTheme.primary,
                          ),
                          _HomeMetric(
                            label: 'ВОДА',
                            value: hasWater
                                ? '${formatNumber(p.todayWaterIntake)} мл'
                                : 'Не записана',
                            color: AppTheme.blue,
                          ),
                          _HomeMetric(
                            label: 'ШАГИ',
                            value: hasSteps
                                ? formatNumber(p.todaySteps)
                                : 'Не записаны',
                            color: AppTheme.amber,
                          ),
                          _HomeMetric(
                            label: 'СОН',
                            value: sleep.unreadable
                                ? 'Ошибка чтения'
                                : sleep.value == null
                                ? 'Не записан'
                                : formatSleepMinutes(sleep.value!.minutes),
                            color: AppTheme.secondary,
                          ),
                        ];
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final metric in metrics)
                              SizedBox(width: width, child: metric),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      manualWorkouts == 0 &&
                              gymDay.isEmpty &&
                              gymIndex.unreadable == 0
                          ? 'Тренировки: нет записей за выбранный день.'
                          : 'Ручные тренировки: ${manualWorkouts == 0 ? 'нет записей' : 'записей — $manualWorkouts'} · '
                                'записи зала и подтягиваний: ${gymDay.isEmpty && gymIndex.unreadable == 0 ? 'нет' : '${gymDay.length}${gymIndex.unreadable > 0 ? ' из прочитанных' : ''}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (manualWorkouts > 0 && gymDay.isNotEmpty)
                      const Text(
                        'Записи могут относиться к одному занятию и не суммируются.',
                      ),
                    if (gymIndex.unreadable > 0)
                      Text(
                        'История зала прочитана не полностью (${gymIndex.unreadable}). Данные за день могут быть неполными.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: 10),
                    Text(
                      'Показано только то, что записано за день.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              DailyNutritionTip(
                insight: analyzeRecordedNutrition(p.todayFoodEntries),
                openDetails: () => openTab(3),
              ),
              const SizedBox(height: 16),
              if (stackActions)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    addFoodButton,
                    const SizedBox(height: 8),
                    addWaterButton,
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(child: addFoodButton),
                    const SizedBox(width: 10),
                    Expanded(child: addWaterButton),
                  ],
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => showGym(context, p),
                  icon: const Icon(Icons.fitness_center_rounded),
                  label: const Text('Зал · план и подтягивания'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Быстрый доступ',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              _HomeLink(
                icon: Icons.auto_awesome_outlined,
                color: AppTheme.primary,
                title: 'Анализ дневника',
                subtitle: 'Сводка, тренды и подсказки ИИ',
                onTap: () => openTab(3),
              ),
              const SizedBox(height: 8),
              _HomeLink(
                icon: Icons.edit_note_rounded,
                color: AppTheme.blue,
                title: 'Дневник питания',
                subtitle:
                    '${p.todayFoodEntries.length} записей за выбранный день',
                onTap: () => openTab(1),
              ),
              const SizedBox(height: 8),
              _HomeLink(
                icon: Icons.directions_walk_rounded,
                color: AppTheme.amber,
                title: 'Шаги и ручная тренировка',
                subtitle: 'Добавить шаги или занятие',
                onTap: () => showQuickActivityActions(context, p),
              ),
              const SizedBox(height: 8),
              _HomeLink(
                icon: Icons.tune_rounded,
                color: AppTheme.secondary,
                title: 'Ещё',
                subtitle: 'Вес, настройки, каталог и синхронизация',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const MoreScreen()),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// Reused by the activity section; writes go through the same diary provider.
Future<void> showQuickActivityActions(
  BuildContext context,
  AppDataProvider p,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (ctx) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.directions_walk),
              title: const Text('Добавить 1 000 шагов'),
              onTap: () {
                Navigator.pop(ctx);
                p.quickAddSteps();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Указать шаги за день'),
              onTap: () async {
                Navigator.pop(ctx);
                final n = await askPositiveNumber(
                  context,
                  'Шаги за день',
                  p.todaySteps.toDouble(),
                  allowZero: true,
                  maxValue: 1000000,
                );
                if (n != null) await p.setSteps(n.round());
              },
            ),
            ListTile(
              leading: const Icon(Icons.water_drop_outlined),
              title: const Text('Указать воду за день'),
              onTap: () async {
                Navigator.pop(ctx);
                final n = await askPositiveNumber(
                  context,
                  'Вода за день, мл',
                  p.todayWaterIntake.toDouble(),
                  allowZero: true,
                  maxValue: 1000000,
                );
                if (n != null) await p.setWaterIntake(n.round());
              },
            ),
            ListTile(
              leading: const Icon(Icons.fitness_center),
              title: const Text('Записать тренировку вручную'),
              onTap: () {
                Navigator.pop(ctx);
                showWorkoutEditor(context, p);
              },
            ),
          ],
        ),
      ),
    ),
  ),
);

class _HomeMetric extends StatelessWidget {
  final String label, value;
  final Color color;
  const _HomeMetric({
    required this.label,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 72),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: color.withValues(alpha: .16)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: .6,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          value,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

class _HomeLink extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, subtitle;
  final VoidCallback onTap;
  const _HomeLink({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: AppTheme.surface,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            RoundIconBadge(icon: icon, color: color, size: 42, iconSize: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
          ],
        ),
      ),
    ),
  );
}

void _openPage(BuildContext context, String title, Widget child) {
  Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: child,
      ),
    ),
  );
}

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});
  @override
  Widget build(BuildContext context) => Consumer<AppDataProvider>(
    builder: (context, p, _) => Scaffold(
      appBar: AppBar(title: const Text('Ещё')),
      body: CenteredBody(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
          children: [
            Text(
              'Всё остальное — здесь',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 5),
            Text(
              'Настройки и дополнительные инструменты не мешают основному дневнику.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            _HomeLink(
              icon: Icons.sync_rounded,
              color: AppTheme.primary,
              title: 'Аккаунт и синхронизация',
              subtitle: 'Вход и сохранение в облаке',
              onTap: () => _openPage(
                context,
                'Синхронизация',
                CenteredBody(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [CloudPanel(provider: p)],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.privacy_tip_outlined,
              color: AppTheme.secondary,
              title: 'Конфиденциальность ИИ',
              subtitle: 'Проверить или отозвать согласие',
              onTap: () => _openPage(
                context,
                'Конфиденциальность ИИ',
                CenteredBody(
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      const Text(
                        'Согласие хранится только на этом устройстве и действует для текущего аккаунта. Отзыв не удаляет дневник.',
                      ),
                      if (SmartRemote.instance.client?.auth.currentUser == null)
                        const Padding(
                          padding: EdgeInsets.only(top: 14),
                          child: Text(
                            'Войдите в аккаунт, чтобы управлять его согласием.',
                          ),
                        )
                      else
                        AiPrivacyControls(
                          store: p.storage.local,
                          owner:
                              SmartRemote.instance.client?.auth.currentUser?.id,
                          busy: false,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.monitor_weight_outlined,
              color: AppTheme.blue,
              title: 'Вес',
              subtitle: 'Измерения и история',
              onTap: () => _openPage(context, 'Вес', const WeightScreen()),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.insights_rounded,
              color: AppTheme.secondary,
              title: 'Прогресс',
              subtitle: 'Графики и привычки',
              onTap: () =>
                  _openPage(context, 'Прогресс', const ProgressScreen()),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.medication_outlined,
              color: AppTheme.amber,
              title: 'Витамины и добавки',
              subtitle: 'Твои записи',
              onTap: () => _openPage(
                context,
                'Витамины и добавки',
                CenteredBody(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [SupplementPanel(provider: p)],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.menu_book_outlined,
              color: AppTheme.primary,
              title: 'Каталог продуктов',
              subtitle: 'ПМР, СНГ и свои продукты',
              onTap: () => openFoodCatalog(context, p),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.chat_bubble_outline,
              color: AppTheme.blue,
              title: 'ИИ для еды и фото',
              subtitle: 'Черновик перед сохранением',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const AiChatScreen()),
              ),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.settings_outlined,
              color: AppTheme.secondary,
              title: 'Настройки',
              subtitle: 'Профиль, цели и напоминания',
              onTap: () =>
                  _openPage(context, 'Настройки', const SettingsScreen()),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.save_outlined,
              color: AppTheme.blue,
              title: 'Резервная копия',
              subtitle: 'Экспорт и восстановление',
              onTap: () => _openPage(
                context,
                'Резервная копия',
                CenteredBody(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [BackupPanel(provider: p)],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.dashboard_outlined,
              color: AppTheme.amber,
              title: 'Расширенные инструменты',
              subtitle: 'Все прежние функции',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const SmartHub()),
              ),
            ),
            const SizedBox(height: 8),
            _HomeLink(
              icon: Icons.view_agenda_outlined,
              color: AppTheme.primary,
              title: 'Подробная главная',
              subtitle: 'Прежний вид со всеми карточками',
              onTap: () => _openPage(
                context,
                'Подробная главная',
                const DashboardScreen(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
