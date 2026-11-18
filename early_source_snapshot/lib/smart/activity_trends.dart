import 'dart:convert';

import 'sleep.dart';

enum ActivityMetric { steps, sleep }

/// A read-only chart guard, not a storage limit. Extreme legacy values stay in
/// the diary but are marked uncalculable so integer totals cannot overflow.
const maxChartStepsPerDay = 10000000;

/// One chronological interval, with missing and unreadable days separate from
/// actual recorded zeros. Numeric sums are never rounded here.
class ActivityBucket {
  final DateTime firstDay, lastDay;
  final int calendarDays, recordedDays, unreadableDays, total;
  const ActivityBucket({
    required this.firstDay,
    required this.lastDay,
    required this.calendarDays,
    required this.recordedDays,
    required this.unreadableDays,
    required this.total,
  });
  int get missingDays => calendarDays - recordedDays - unreadableDays;
  double? get average => recordedDays == 0 ? null : total / recordedDays;
}

class ActivitySeries {
  final ActivityMetric metric;
  final DateTime firstDay, lastDay;
  final List<ActivityBucket> buckets;
  final int calendarDays,
      recordedDays,
      unreadableDays,
      unassignedDocuments,
      total;
  ActivitySeries({
    required this.metric,
    required this.firstDay,
    required this.lastDay,
    required List<ActivityBucket> buckets,
    required this.calendarDays,
    required this.recordedDays,
    required this.unreadableDays,
    required this.unassignedDocuments,
    required this.total,
  }) : buckets = List.unmodifiable(buckets);
  double? get average => recordedDays == 0 ? null : total / recordedDays;
}

/// A sparse, read-only projection of existing documents. Equal-width groups
/// avoid thousands of chart bars for long periods; only actual document keys
/// are inspected. Dates are interpreted as calendar days using UTC arithmetic
/// to avoid daylight-saving 23/25-hour shifts. No data is transmitted or saved.
ActivitySeries buildActivitySeries(
  Map<String, Object?> documents,
  DateTime first,
  DateTime last,
  ActivityMetric metric, {
  int maxBuckets = 14,
}) {
  if (maxBuckets < 1 ||
      maxBuckets > 100 ||
      first.year < 1 ||
      first.year > 9999 ||
      last.year < 1 ||
      last.year > 9999) {
    throw ArgumentError('Некорректный период графика.');
  }
  final from = DateTime.utc(first.year, first.month, first.day);
  final to = DateTime.utc(last.year, last.month, last.day);
  final days = to.difference(from).inDays + 1;
  if (days < 1 || days > 37000)
    throw ArgumentError('Некорректный период графика.');
  final span = (days + maxBuckets - 1) ~/ maxBuckets;
  final count = (days + span - 1) ~/ span;
  final recorded = List<int>.filled(count, 0);
  final unreadable = List<int>.filled(count, 0);
  final totals = List<int>.filled(count, 0);
  final prefix = metric == ActivityMetric.steps ? 'steps_' : sleepDayPrefix;
  var unassigned = 0;
  for (final item in documents.entries) {
    if (!item.key.startsWith(prefix) || item.value == null) continue;
    final dayString = item.key.substring(prefix.length);
    if (!validSleepDay(dayString)) {
      // It cannot be placed confidently inside or outside the chosen period.
      unassigned++;
      continue;
    }
    final date = DateTime.utc(
      int.parse(dayString.substring(0, 4)),
      int.parse(dayString.substring(5, 7)),
      int.parse(dayString.substring(8, 10)),
    );
    final offset = date.difference(from).inDays;
    if (offset < 0 || offset >= days) continue;
    final index = offset ~/ span;
    try {
      final int value;
      if (metric == ActivityMetric.steps) {
        final raw = item.value;
        if (raw is! int || raw < 0 || raw > maxChartStepsPerDay) {
          throw const FormatException('steps');
        }
        value = raw;
      } else {
        validateSleepDocument(item.key, item.value);
        final object = jsonDecode(item.value! as String);
        value = SleepDay.fromJson(
          Map<String, dynamic>.from(object as Map),
        ).minutes;
      }
      totals[index] += value;
      recorded[index]++;
    } catch (_) {
      unreadable[index]++;
    }
  }
  final buckets = <ActivityBucket>[];
  for (var i = 0; i < count; i++) {
    final offset = i * span;
    final bucketDays = (days - offset).clamp(1, span);
    buckets.add(
      ActivityBucket(
        firstDay: from.add(Duration(days: offset)),
        lastDay: from.add(Duration(days: offset + bucketDays - 1)),
        calendarDays: bucketDays,
        recordedDays: recorded[i],
        unreadableDays: unreadable[i],
        total: totals[i],
      ),
    );
  }
  return ActivitySeries(
    metric: metric,
    firstDay: from,
    lastDay: to,
    buckets: buckets,
    calendarDays: days,
    recordedDays: recorded.fold(0, (a, b) => a + b),
    unreadableDays: unreadable.fold(0, (a, b) => a + b),
    unassignedDocuments: unassigned,
    total: totals.fold(0, (a, b) => a + b),
  );
}
