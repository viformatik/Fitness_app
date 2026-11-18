import 'dart:convert';

import 'lossless_json.dart';

class FoodEditException extends StateError {
  FoodEditException(super.message);
}

/// Change only fields explicitly changed in the decoded model. Original numeric
/// and timestamp spellings remain intact, including unchanged micronutrients.
String patchFoodRow(
  String source,
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) {
  final oldMicros = Map<String, dynamic>.from(before['micros'] as Map);
  final newMicros = Map<String, dynamic>.from(after['micros'] as Map);
  final changes = <String, String>{};
  for (final key in after.keys) {
    if (key == 'micros') {
      if (oldMicros.length == newMicros.length &&
          oldMicros.entries.every(
            (entry) =>
                newMicros.containsKey(entry.key) &&
                newMicros[entry.key] == entry.value,
          )) {
        continue;
      }
      final originalMicros = rawJsonObjectValue(source, 'micros');
      final readable = originalMicros != null && originalMicros != 'null'
          ? uniqueJsonObject(originalMicros)
          : <String, dynamic>{};
      final encodedMicros = <String>[];
      for (final entry in newMicros.entries) {
        final previous = oldMicros[entry.key];
        final existing = readable.containsKey(entry.key)
            ? rawJsonObjectValue(originalMicros!, entry.key)
            : null;
        final token = previous == entry.value && existing != null
            ? existing
            : jsonEncode(entry.value);
        encodedMicros.add('${jsonEncode(entry.key)}:$token');
      }
      changes[key] = '{${encodedMicros.join(',')}}';
    } else if (before[key] != after[key]) {
      changes[key] = jsonEncode(after[key]);
    }
  }
  return patchJsonObjectRaw(source, changes);
}

/// A day's food records share one JSON document. Do not reconstruct a day
/// whose rows have fields this client cannot understand or stable duplicate
/// identities; keep each original row as text for lossless targeted edits.
({List<Map<String, dynamic>> rows, List<String> rawRows}) safeFoodDocument(
  Object? raw, {
  required Set<String> knownMicros,
}) {
  const fields = {
    'id',
    'name',
    'caloriesPer100g',
    'proteinPer100g',
    'fatPer100g',
    'carbsPer100g',
    'micros',
    'microsEstimated',
    'amountGrams',
    'mealType',
    'date',
    'loggedAt',
    'timeKnown',
  };
  FoodEditException unsafe() => FoodEditException(
    'В дневнике есть неизвестные или некорректные данные. '
    'Записи не изменены; сохраните резервную копию и откройте их '
    'в совместимой версии приложения.',
  );
  if (raw == null) return (rows: <Map<String, dynamic>>[], rawRows: <String>[]);
  if (raw is! String) throw unsafe();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw unsafe();
    final rawRows = rawJsonArrayElements(raw);
    final rows = <Map<String, dynamic>>[];
    final ids = <String>{};
    for (final source in rawRows) {
      final row = uniqueJsonObject(source);
      if (row.keys.any((key) => !fields.contains(key)) ||
          row['id'] is! String ||
          (row['id'] as String).trim().isEmpty ||
          !ids.add(row['id'] as String)) {
        throw unsafe();
      }
      for (final flag in ['microsEstimated', 'timeKnown']) {
        if (row[flag] != null && row[flag] is! bool) throw unsafe();
      }
      if (row['loggedAt'] != null &&
          (row['loggedAt'] is! String ||
              DateTime.tryParse(row['loggedAt'] as String) == null)) {
        throw unsafe();
      }
      if (row['micros'] != null) {
        final sourceMicros = rawJsonObjectValue(source, 'micros');
        if (sourceMicros == null) throw unsafe();
        final micros = uniqueJsonObject(sourceMicros);
        if (micros.keys.any((key) => !knownMicros.contains(key)) ||
            micros.values.any(
              (value) => value is! num || !value.isFinite || value < 0,
            )) {
          throw unsafe();
        }
      }
      rows.add(row);
    }
    return (rows: rows, rawRows: rawRows);
  } on FoodEditException {
    rethrow;
  } catch (_) {
    throw unsafe();
  }
}
