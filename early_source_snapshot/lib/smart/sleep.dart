import 'dart:convert';

import 'local_store.dart';

const sleepDayPrefix = 'sleep_day_';

String sleepDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

bool validSleepDay(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (year < 1) return false;
  final date = DateTime.utc(year, month, day);
  return sleepDateKey(date) == value;
}

String sleepDocumentKey(DateTime date) =>
    '$sleepDayPrefix${sleepDateKey(date)}';

/// One explicit, self-reported total for a chosen calendar day, including naps
/// if the user chooses. Absence is represented by no document, not zero.
/// There is no inferred bedtime, wake time, sleep quality or Health source.
class SleepDay {
  final String day;
  final int minutes;

  const SleepDay({required this.day, required this.minutes});

  factory SleepDay.fromJson(Map<String, dynamic> data) {
    const fields = {'version', 'day', 'minutes', 'source'};
    if (data.keys.toSet().difference(fields).isNotEmpty ||
        data.length != fields.length ||
        data['version'] != 1 ||
        data['source'] != 'manual' ||
        data['day'] is! String ||
        !validSleepDay(data['day'] as String) ||
        data['minutes'] is! int ||
        (data['minutes'] as int) < 0 ||
        (data['minutes'] as int) > 1440) {
      throw const FormatException('Некорректная запись сна');
    }
    return SleepDay(
      day: data['day'] as String,
      minutes: data['minutes'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'day': day,
    'minutes': minutes,
    'source': 'manual',
  };
}

void validateSleepDocument(String key, Object? raw) {
  if (!key.startsWith(sleepDayPrefix) ||
      !validSleepDay(key.substring(sleepDayPrefix.length))) {
    throw const FormatException('Некорректная дата записи сна');
  }
  if (raw == null) return; // sync tombstone
  if (raw is! String || utf8.encode(raw).length > 4096) {
    throw const FormatException('Некорректный документ сна');
  }
  final data = jsonDecode(raw);
  if (data is! Map) throw const FormatException('Некорректная запись сна');
  final entry = SleepDay.fromJson(Map<String, dynamic>.from(data));
  if (entry.day != key.substring(sleepDayPrefix.length)) {
    throw const FormatException('Дата сна не совпадает с документом');
  }
}

String encodeSleepDay(SleepDay day) {
  final raw = jsonEncode(day.toJson());
  validateSleepDocument('$sleepDayPrefix${day.day}', raw);
  return raw;
}

String formatSleepMinutes(int minutes) =>
    '${minutes ~/ 60} ч ${minutes % 60} мин';

class SleepRead {
  final SleepDay? value;
  final bool unreadable;
  const SleepRead({this.value, this.unreadable = false});
}

SleepRead readSleepDay(LocalPreferences store, DateTime date) {
  final key = sleepDocumentKey(date);
  final raw = store.get(key);
  if (raw == null) return const SleepRead();
  try {
    validateSleepDocument(key, raw);
    return SleepRead(
      value: SleepDay.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw as String) as Map),
      ),
    );
  } catch (_) {
    return const SleepRead(unreadable: true);
  }
}

class SleepRangeSummary {
  final int recordedDays, unreadableDays, totalMinutes;
  const SleepRangeSummary({
    required this.recordedDays,
    required this.unreadableDays,
    required this.totalMinutes,
  });
  double? get averageMinutes =>
      recordedDays == 0 ? null : totalMinutes / recordedDays;
}

/// Summarizes only recorded days; missing days are not added to the divisor.
/// No record is sent to an AI provider or written by this function.
SleepRangeSummary summarizeSleep(
  Map<String, Object?> documents,
  DateTime from,
  DateTime to,
) {
  final first = sleepDateKey(from), last = sleepDateKey(to);
  if (first.compareTo(last) > 0)
    throw ArgumentError('Начало периода позже конца.');
  var count = 0, bad = 0, total = 0;
  for (final item in documents.entries) {
    if (!item.key.startsWith(sleepDayPrefix) || item.value == null) continue;
    final day = item.key.substring(sleepDayPrefix.length);
    // Invalid keys cannot be assigned confidently to a period; do not hide
    // their existence even if their lexical form looks out of range.
    if (!validSleepDay(day)) {
      bad++;
      continue;
    }
    if (day.compareTo(first) < 0 || day.compareTo(last) > 0) continue;
    try {
      validateSleepDocument(item.key, item.value);
      final decoded = jsonDecode(item.value! as String);
      final entry = SleepDay.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      total += entry.minutes;
      count++;
    } catch (_) {
      bad++;
    }
  }
  return SleepRangeSummary(
    recordedDays: count,
    unreadableDays: bad,
    totalMinutes: total,
  );
}
