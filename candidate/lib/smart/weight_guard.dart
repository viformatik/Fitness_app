import 'dart:convert';

import 'lossless_json.dart';

class WeightEditException implements Exception {
  final String message;
  const WeightEditException(this.message);
  @override
  String toString() => message;
}

const _unsafeWeightHistory = WeightEditException(
  'История веса содержит неизвестные или некорректные данные. '
  'Обновите приложение; исходные записи не изменены.',
);

/// Validate a whole history before changing its shared document. Keep the
/// exact source for each untouched row, rather than decoding/re-encoding its
/// dates, notes and possibly higher-precision numeric literals.
({List<Map<String, dynamic>> rows, List<String> rawRows}) safeWeightDocument(
  Object? raw,
) {
  const allowed = {'id', 'weight', 'date', 'note'};
  if (raw == null) return (rows: <Map<String, dynamic>>[], rawRows: <String>[]);
  if (raw is! String) throw _unsafeWeightHistory;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw _unsafeWeightHistory;
    final rawRows = rawJsonArrayElements(raw);
    final rows = <Map<String, dynamic>>[];
    final ids = <String>{};
    for (var index = 0; index < decoded.length; index++) {
      // Decode each row separately to reject even escaped duplicate keys.
      final row = uniqueJsonObject(rawRows[index]);
      if (row.keys.any((key) => !allowed.contains(key))) {
        throw _unsafeWeightHistory;
      }
      final id = row['id'];
      final weight = row['weight'];
      final date = row['date'];
      final note = row['note'];
      if (id is! String ||
          id.trim().isEmpty ||
          !ids.add(id) ||
          weight is! num ||
          !weight.isFinite ||
          weight <= 0 ||
          date is! String ||
          DateTime.tryParse(date) == null ||
          (note != null && note is! String)) {
        throw _unsafeWeightHistory;
      }
      rows.add(row);
    }
    return (rows: rows, rawRows: rawRows);
  } on WeightEditException {
    rethrow;
  } catch (_) {
    throw _unsafeWeightHistory;
  }
}

List<Map<String, dynamic>> safeWeightRows(Object? raw) =>
    safeWeightDocument(raw).rows;

/// Replace only changed values in the selected row. A note-only edit, for
/// example, must not round a legacy weight or normalize its original date.
String patchWeightRow(
  String source,
  Map<String, dynamic> original,
  Map<String, dynamic> replacement,
) {
  final changes = <String, dynamic>{};
  for (final entry in replacement.entries) {
    final key = entry.key;
    final before = original[key];
    final after = entry.value;
    var unchanged = before == after;
    if (key == 'weight' && before is num && after is num) {
      unchanged = before.toDouble() == after.toDouble();
    } else if (key == 'date' && before is String && after is String) {
      final a = DateTime.tryParse(before);
      final b = DateTime.tryParse(after);
      unchanged = a != null && b != null && a.isAtSameMomentAs(b);
    }
    if (!unchanged) changes[key] = after;
  }
  return patchJsonObject(source, changes);
}
