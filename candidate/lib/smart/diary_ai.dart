import 'dart:convert';
import '../legacy.dart';
import 'ai_drafts.dart';
import 'engine.dart';

/// Food-only snapshot: real IDs, profile, weight, supplements and other history
/// never leave the device. References exist only for this one request.
class DiaryAiSnapshot {
  static const maxEntries = 60;
  final DateTime firstDay, lastDay;
  final Map<String, FoodEntry> byRef;

  DiaryAiSnapshot({
    required DateTime firstDay,
    required DateTime lastDay,
    required List<FoodEntry> entries,
  }) : firstDay = DateTime(firstDay.year, firstDay.month, firstDay.day),
       lastDay = DateTime(lastDay.year, lastDay.month, lastDay.day),
       byRef = {
         for (var i = 0; i < entries.length; i++) 'f${i + 1}': entries[i],
       } {
    if (this.firstDay.isAfter(this.lastDay)) {
      throw ArgumentError('Начало периода позже окончания.');
    }
    if (entries.length > maxEntries) {
      throw ArgumentError(
        'За период больше $maxEntries записей еды. Выберите более короткий период.',
      );
    }
    if (entries.any((e) => !_within(e.date, this.firstDay, this.lastDay))) {
      throw ArgumentError('Запись находится вне выбранного периода.');
    }
  }

  Json request(String question, {required bool replaceKnownMicros}) {
    final text = question.trim();
    if (text.isEmpty || text.length > 2000) {
      throw ArgumentError('Введите запрос длиной до 2000 символов.');
    }
    final rows = <Json>[];
    for (final entry in byRef.entries) {
      final e = entry.value;
      rows.add({
        'ref': entry.key,
        'day': dayKey(e.date),
        'name': e.name,
        'grams': e.amountGrams,
        'calories': e.caloriesPer100g,
        'protein': e.proteinPer100g,
        'fat': e.fatPer100g,
        'carbs': e.carbsPer100g,
        'meal': e.mealType.name,
        'micros': validateAiMicros(e.micros),
      });
    }
    return {
      'mode': 'diary',
      'text': text,
      'firstDay': dayKey(firstDay),
      'lastDay': dayKey(lastDay),
      'replaceKnownMicros': replaceKnownMicros,
      'entries': rows,
    };
  }
}

bool _within(DateTime date, DateTime first, DateTime last) {
  final day = DateTime(date.year, date.month, date.day);
  return !day.isBefore(first) && !day.isAfter(last);
}

DateTime _parseDay(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('ИИ вернул неподходящую дату.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || dayKey(parsed) != value) {
    throw const FormatException('ИИ вернул неподходящую дату.');
  }
  return DateTime(parsed.year, parsed.month, parsed.day);
}

Json foodAsAiItem(FoodEntry e) => {
  'name': e.name,
  'grams': e.amountGrams,
  'calories': e.caloriesPer100g,
  'protein': e.proteinPer100g,
  'fat': e.fatPer100g,
  'carbs': e.carbsPer100g,
  'meal': e.mealType.name,
  'micros': e.micros,
  'assumptions': 'Проверьте предложенные значения.',
};

/// A proposal is local only and does not mutate the diary.
class DiaryAiSuggestion {
  final String kind, reason;

  /// Ephemeral request reference, never the real diary ID.
  final String reference;
  final FoodEntry? original;
  FoodEntry? proposed;
  bool selected = false;
  DiaryAiSuggestion({
    required this.kind,
    required this.reason,
    this.reference = '',
    this.original,
    this.proposed,
  });
  DateTime get date => original?.date ?? proposed!.date;

  /// The existing editor is an explicit user change, so all edited values are
  /// accepted, including previously filled micronutrients.
  void edit(Json raw, {DateTime? date}) {
    if (kind == 'delete' || proposed == null)
      throw StateError('Удаление нельзя редактировать.');
    final item = validateAiItems([raw]).single;
    final old = proposed!;
    final newDate = date ?? old.date;
    if (kind == 'update' && dayKey(newDate) != dayKey(original!.date)) {
      throw ArgumentError('Существующую запись нельзя переносить между днями.');
    }
    final micros = validateAiMicros(item['micros']);
    proposed = old.copyWith(
      name: item['name'] as String,
      amountGrams: number(item['grams']),
      caloriesPer100g: number(item['calories']),
      proteinPer100g: number(item['protein']),
      fatPer100g: number(item['fat']),
      carbsPer100g: number(item['carbs']),
      mealType: MealType.values.firstWhere((m) => m.name == item['meal']),
      micros: micros,
      microsEstimated: old.microsEstimated || !_same(micros, old.micros),
      date: newDate,
      loggedAt: kind == 'add' ? newDate : old.loggedAt,
    );
  }
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

class DiaryAiResult {
  final String analysis;
  final List<DiaryAiSuggestion> suggestions;
  const DiaryAiResult(this.analysis, this.suggestions);
}

/// Validate server/model output again on-device and bind references to the
/// exact original snapshot. A model cannot choose real IDs or act outside range.
DiaryAiResult validateDiaryAiResult(
  Object? raw,
  DiaryAiSnapshot snapshot, {
  required bool replaceKnownMicros,
}) {
  if (raw is! Map ||
      raw['analysis'] is! String ||
      (raw['analysis'] as String).trim().isEmpty ||
      (raw['analysis'] as String).length > 8000 ||
      raw['actions'] is! List ||
      (raw['actions'] as List).length > 30) {
    throw const FormatException(
      'Не удалось проверить ответ ИИ. Дневник не изменён.',
    );
  }
  final actions = <DiaryAiSuggestion>[];
  final touched = <String>{};
  for (final action in raw['actions'] as List) {
    if (action is! Map ||
        !['update', 'delete', 'add'].contains(action['kind']) ||
        action['reason'] is! String ||
        (action['reason'] as String).length > 1000 ||
        action['ref'] is! String ||
        action['patch'] is! Map) {
      throw const FormatException(
        'Не удалось проверить предложенное действие.',
      );
    }
    final kind = action['kind'] as String;
    final ref = action['ref'] as String;
    final date = _parseDay(action['day']);
    if (!_within(date, snapshot.firstDay, snapshot.lastDay)) {
      throw const FormatException(
        'Предложение за пределами выбранного периода.',
      );
    }
    final original = kind == 'add' ? null : snapshot.byRef[ref];
    if (kind == 'add') {
      if (ref.isNotEmpty)
        throw const FormatException('Некорректная новая запись.');
    } else if (original == null ||
        dayKey(original.date) != dayKey(date) ||
        !touched.add(ref)) {
      throw const FormatException(
        'Предложение ссылается на неверную или повторную запись.',
      );
    }
    final reason = (action['reason'] as String).trim();
    if (kind == 'delete') {
      actions.add(
        DiaryAiSuggestion(
          kind: kind,
          reason: reason,
          reference: ref,
          original: original,
        ),
      );
      continue;
    }
    final patch = action['patch'] as Map;
    const keys = {
      'name',
      'grams',
      'calories',
      'protein',
      'fat',
      'carbs',
      'meal',
      'micros',
    };
    if (patch.keys.any((k) => k is! String || !keys.contains(k))) {
      throw const FormatException('ИИ вернул неподдерживаемое поле изменения.');
    }
    if (kind == 'add' &&
        !{
          'name',
          'grams',
          'calories',
          'protein',
          'fat',
          'carbs',
          'meal',
        }.every(patch.containsKey)) {
      throw const FormatException(
        'Для новой записи нужны дата, порция, КБЖУ и приём пищи.',
      );
    }
    final base = original == null
        ? <String, dynamic>{}
        : foodAsAiItem(original);
    for (final key in [
      'name',
      'grams',
      'calories',
      'protein',
      'fat',
      'carbs',
      'meal',
    ]) {
      if (patch.containsKey(key)) base[key] = patch[key];
    }
    final suggestedMicros = validateAiMicros(patch['micros']);
    final beforeMicros = original?.micros ?? <String, double>{};
    base['micros'] = replaceKnownMicros
        ? {...beforeMicros, ...suggestedMicros}
        : {...suggestedMicros, ...beforeMicros};
    base['assumptions'] = reason;
    final item = validateAiItems([base]).single;
    final mealName = item['meal'] as String;
    // Do not silently normalize a malicious or unsupported meal from an action.
    if (patch.containsKey('meal') && !aiMeals.contains(patch['meal'])) {
      throw const FormatException('Некорректный приём пищи.');
    }
    final meal = MealType.values.firstWhere((m) => m.name == mealName);
    final microMap = validateAiMicros(item['micros']);
    final proposed = original == null
        ? FoodEntry(
            id: newId(),
            name: item['name'] as String,
            amountGrams: number(item['grams']),
            caloriesPer100g: number(item['calories']),
            proteinPer100g: number(item['protein']),
            fatPer100g: number(item['fat']),
            carbsPer100g: number(item['carbs']),
            micros: microMap,
            microsEstimated: microMap.isNotEmpty,
            mealType: meal,
            date: date,
            loggedAt: date,
            timeKnown: false,
          )
        : original.copyWith(
            name: item['name'] as String,
            amountGrams: number(item['grams']),
            caloriesPer100g: number(item['calories']),
            proteinPer100g: number(item['protein']),
            fatPer100g: number(item['fat']),
            carbsPer100g: number(item['carbs']),
            micros: microMap,
            microsEstimated:
                original.microsEstimated || !_same(microMap, original.micros),
            mealType: meal,
          );
    if (original != null && _same(original.toJson(), proposed.toJson()))
      continue;
    actions.add(
      DiaryAiSuggestion(
        kind: kind,
        reason: reason,
        reference: ref,
        original: original,
        proposed: proposed,
      ),
    );
  }
  return DiaryAiResult((raw['analysis'] as String).trim(), actions);
}
