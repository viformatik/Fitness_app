import 'dart:convert';
import 'local_store.dart';

/// RFC4180-style reader: escaped quotes, multiline cells, CRLF/LF and UTF-8 BOM.
List<List<String>> readCsv(String source) {
  final text = source.replaceFirst(RegExp('^\uFEFF'), '');
  final rows = <List<String>>[];
  var row = <String>[], cell = StringBuffer(), quoted = false, closed = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        cell.write(c);
      }
      continue;
    }
    if (c == '"' && cell.isEmpty && !closed) {
      quoted = true;
      continue;
    }
    if (c == ',') {
      row.add(cell.toString());
      cell = StringBuffer();
      closed = false;
    } else if (c == '\r' || c == '\n') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      rows.add(row);
      row = [];
      cell = StringBuffer();
      closed = false;
    } else {
      if (closed || c == '"') throw const FormatException('Некорректный CSV');
      cell.write(c);
    }
  }
  if (quoted) throw const FormatException('Незакрытая кавычка CSV');
  if (cell.isNotEmpty || row.isNotEmpty || closed) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

Map<String, dynamic> importCsv(String source) {
  final rows = readCsv(source);
  if (rows.isEmpty) throw const FormatException('Пустой CSV');
  final header = rows.first;
  final type = header.indexOf('record_type'),
      key = header.indexOf('id'),
      payload = header.indexOf('raw_json');
  if ([type, key, payload].any((i) => i < 0))
    throw const FormatException('Нужен CSV-экспорт этого приложения');
  final result = <String, dynamic>{};
  for (final row in rows.skip(1)) {
    if (row.every((c) => c.isEmpty)) continue;
    if (row.length != header.length)
      throw const FormatException('Неверное число столбцов');
    if (row[type] != 'document') continue;
    if (!LocalPreferences.appKey(row[key]) || result.containsKey(row[key]))
      throw const FormatException('Недопустимый или повторный ключ');
    var raw = row[payload];
    if (raw.startsWith("'")) raw = raw.substring(1);
    result[row[key]] = jsonDecode(raw);
  }
  if (result.isEmpty)
    throw const FormatException('CSV не содержит документов истории');
  return result;
}
