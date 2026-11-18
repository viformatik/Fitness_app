import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'activity_trends.dart';
import 'sleep.dart' show formatSleepMinutes;

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String _integer(int value) {
  final digits = value.toString();
  final parts = <String>[];
  for (var end = digits.length; end > 0; end -= 3) {
    parts.insert(0, digits.substring(math.max(0, end - 3), end));
  }
  return parts.join(' ');
}

String _value(ActivityMetric metric, double value) =>
    metric == ActivityMetric.sleep
    ? formatSleepMinutes(value.round())
    : '${_integer(value.round())} шагов';

String _interval(ActivityBucket bucket) => bucket.firstDay == bucket.lastDay
    ? _date(bucket.firstDay)
    : '${_date(bucket.firstDay)} — ${_date(bucket.lastDay)}';

String _bucketDescription(ActivityMetric metric, ActivityBucket bucket) {
  final result = bucket.average == null
      ? bucket.unreadableDays > 0
            ? 'нет пригодных данных'
            : 'нет записей'
      : bucket.calendarDays == 1
      ? _value(metric, bucket.average!)
      : 'среднее ≈ ${_value(metric, bucket.average!)}';
  return '${_interval(bucket)}: $result; записано ${bucket.recordedDays} из ${bucket.calendarDays}'
      '${bucket.missingDays > 0 ? '; без записи ${bucket.missingDays}' : ''}'
      '${bucket.unreadableDays > 0 ? '; не рассчитано ${bucket.unreadableDays}' : ''}.';
}

/// A local-only chart over the exact period of the surrounding overview.
/// Touch and two labelled buttons select a group without horizontal scrolling.
class ActivityTrendPanel extends StatefulWidget {
  final ActivitySeries steps, sleep;
  const ActivityTrendPanel({
    super.key,
    required this.steps,
    required this.sleep,
  });
  @override
  State<ActivityTrendPanel> createState() => _ActivityTrendPanelState();
}

class _ActivityTrendPanelState extends State<ActivityTrendPanel> {
  ActivityMetric metric = ActivityMetric.steps;
  int? selected;

  @override
  void didUpdateWidget(covariant ActivityTrendPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.steps.firstDay != widget.steps.firstDay ||
        oldWidget.steps.lastDay != widget.steps.lastDay)
      selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final data = metric == ActivityMetric.steps ? widget.steps : widget.sleep;
    final index = (selected ?? data.buckets.length - 1).clamp(
      0,
      data.buckets.length - 1,
    );
    final bucket = data.buckets[index];
    final scheme = Theme.of(context).colorScheme;
    final label = metric == ActivityMetric.steps ? 'Шаги' : 'Сон';
    final summary = data.average == null
        ? '$label: нет пригодных записей за ${data.calendarDays} дн.'
        : '$label: среднее ≈ ${_value(metric, data.average!)} за ${data.recordedDays} дн. с записью из ${data.calendarDays}.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Графики активности',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ActivityMetric>(
              segments: const [
                ButtonSegment(value: ActivityMetric.steps, label: Text('Шаги')),
                ButtonSegment(value: ActivityMetric.sleep, label: Text('Сон')),
              ],
              selected: {metric},
              onSelectionChanged: (value) =>
                  setState(() => metric = value.first),
            ),
            const SizedBox(height: 10),
            Text(summary),
            if (data.unreadableDays > 0 || data.unassignedDocuments > 0) ...[
              const SizedBox(height: 6),
              Text(
                'Не рассчитано записей в периоде: ${data.unreadableDays}; '
                'записей с неопределённой датой: ${data.unassignedDocuments}. Данные не изменены.',
                style: TextStyle(color: scheme.error),
              ),
            ],
            const SizedBox(height: 6),
            const Text(
              'Столбец — среднее только по дням с записью; пропуски не считаются нулями. '
              'Нажмите на столбец или используйте стрелки.',
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                return Semantics(
                  label: 'График: $label',
                  value: _bucketDescription(metric, bucket),
                  increasedValue: index < data.buckets.length - 1
                      ? _bucketDescription(metric, data.buckets[index + 1])
                      : null,
                  decreasedValue: index > 0
                      ? _bucketDescription(metric, data.buckets[index - 1])
                      : null,
                  onIncrease: index < data.buckets.length - 1
                      ? () => setState(() => selected = index + 1)
                      : null,
                  onDecrease: index > 0
                      ? () => setState(() => selected = index - 1)
                      : null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (event) {
                      if (constraints.maxWidth <= 0) return;
                      final tapped =
                          (event.localPosition.dx /
                                  constraints.maxWidth *
                                  data.buckets.length)
                              .floor()
                              .clamp(0, data.buckets.length - 1);
                      setState(() => selected = tapped);
                    },
                    child: SizedBox(
                      width: double.infinity,
                      height: 130,
                      child: CustomPaint(
                        key: const ValueKey('activityTrendPlot'),
                        painter: _TrendPainter(
                          data.buckets,
                          index,
                          scheme.primary,
                          scheme.outline,
                          scheme.error,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            const Text(
              '● запись, включая 0    ○ нет записи    × не рассчитано',
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Предыдущий период графика',
                  onPressed: index > 0
                      ? () => setState(() => selected = index - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_bucketDescription(metric, bucket)),
                  ),
                ),
                IconButton(
                  tooltip: 'Следующий период графика',
                  onPressed: index < data.buckets.length - 1
                      ? () => setState(() => selected = index + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            Text(
              metric == ActivityMetric.sleep
                  ? 'Сон введён вручную. График остаётся на устройстве и не отправляется в ИИ.'
                  : 'Источник старых записей шагов может быть не указан. График строится на устройстве.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<ActivityBucket> buckets;
  final int selected;
  final Color primary, outline, error;
  const _TrendPainter(
    this.buckets,
    this.selected,
    this.primary,
    this.outline,
    this.error,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (buckets.isEmpty || size.width <= 0 || size.height <= 0) return;
    final slot = size.width / buckets.length;
    final bottom = size.height - 10;
    final plotHeight = size.height - 25;
    var maxValue = 0.0;
    for (final bucket in buckets) {
      maxValue = math.max(maxValue, bucket.average ?? 0);
    }
    if (maxValue <= 0) maxValue = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(selected * slot, 0, slot, size.height),
        const Radius.circular(6),
      ),
      Paint()..color = primary.withValues(alpha: .12),
    );
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()..color = outline,
    );
    for (var i = 0; i < buckets.length; i++) {
      final b = buckets[i];
      final x = (i + .5) * slot;
      if (b.average != null) {
        final height = b.average == 0
            ? 0.0
            : math.max(3.0, b.average! / maxValue * plotHeight);
        if (height == 0) {
          canvas.drawCircle(Offset(x, bottom), 3, Paint()..color = primary);
        } else {
          final width = math.max(2.0, math.min(22.0, slot * .55));
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x - width / 2, bottom - height, width, height),
              const Radius.circular(3),
            ),
            Paint()..color = primary.withValues(alpha: .85),
          );
        }
      } else if (b.unreadableDays == 0) {
        canvas.drawCircle(
          Offset(x, bottom),
          3,
          Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (b.unreadableDays > 0) {
        final y = b.average == null ? bottom - 1 : 7.0;
        final p = Paint()
          ..color = error
          ..strokeWidth = 1.6;
        canvas.drawLine(Offset(x - 3, y - 3), Offset(x + 3, y + 3), p);
        canvas.drawLine(Offset(x + 3, y - 3), Offset(x - 3, y + 3), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.buckets != buckets ||
      old.selected != selected ||
      old.primary != primary ||
      old.outline != outline ||
      old.error != error;
}
