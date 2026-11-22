import 'dart:convert';

typedef _ValueSpan = ({int start, int end});

int _skipSpace(String text, int at) {
  while (at < text.length &&
      (text.codeUnitAt(at) == 0x20 ||
          text.codeUnitAt(at) == 0x09 ||
          text.codeUnitAt(at) == 0x0a ||
          text.codeUnitAt(at) == 0x0d)) {
    at++;
  }
  return at;
}

int _scanString(String text, int at) {
  if (text[at] != '"') throw const FormatException();
  at++;
  while (at < text.length) {
    if (text[at] == r'\') {
      at += 2;
    } else if (text[at] == '"') {
      return at + 1;
    } else {
      at++;
    }
  }
  throw const FormatException();
}

// The caller validates the JSON with jsonDecode first. A source slice keeps
// digits and spellings that decoding and re-encoding on web could change.
int _scanValue(String text, int at) {
  if (text[at] == '"') return _scanString(text, at);
  if (text[at] == '{' || text[at] == '[') {
    var depth = 0;
    while (at < text.length) {
      final char = text[at];
      if (char == '"') {
        at = _scanString(text, at);
        continue;
      }
      if (char == '{' || char == '[') depth++;
      if (char == '}' || char == ']') {
        depth--;
        if (depth == 0) return at + 1;
      }
      at++;
    }
    throw const FormatException();
  }
  while (at < text.length &&
      !const {',', '}', ']', ' ', '\t', '\n', '\r'}.contains(text[at])) {
    at++;
  }
  return at;
}

List<String> rawJsonArrayElements(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! List) throw const FormatException();
  var at = _skipSpace(text, 0);
  if (text[at++] != '[') throw const FormatException();
  final rows = <String>[];
  at = _skipSpace(text, at);
  while (text[at] != ']') {
    final start = at;
    at = _scanValue(text, at);
    rows.add(text.substring(start, at));
    at = _skipSpace(text, at);
    if (text[at] == ',') {
      at = _skipSpace(text, at + 1);
    } else if (text[at] != ']') {
      throw const FormatException();
    }
  }
  if (rows.length != decoded.length) throw const FormatException();
  return rows;
}

Map<String, _ValueSpan> _objectValues(String text) {
  var at = _skipSpace(text, 0);
  if (text[at++] != '{') throw const FormatException();
  final fields = <String, _ValueSpan>{};
  at = _skipSpace(text, at);
  while (text[at] != '}') {
    final keyEnd = _scanString(text, at);
    final key = jsonDecode(text.substring(at, keyEnd));
    if (key is! String || fields.containsKey(key)) {
      // Rewriting duplicate JSON keys can discard information.
      throw const FormatException();
    }
    at = _skipSpace(text, keyEnd);
    if (text[at++] != ':') throw const FormatException();
    at = _skipSpace(text, at);
    final start = at;
    at = _scanValue(text, at);
    fields[key] = (start: start, end: at);
    at = _skipSpace(text, at);
    if (text[at] == ',') {
      at = _skipSpace(text, at + 1);
    } else if (text[at] != '}') {
      throw const FormatException();
    }
  }
  return fields;
}

Map<String, dynamic> uniqueJsonObject(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException();
  final fields = _objectValues(text);
  if (fields.length != decoded.length) throw const FormatException();
  return Map<String, dynamic>.from(decoded);
}

String? rawJsonObjectValue(String text, String key) {
  uniqueJsonObject(text);
  final field = _objectValues(text)[key];
  return field == null ? null : text.substring(field.start, field.end);
}

/// Overwrite only the specified top-level values. All other source tokens are
/// retained verbatim; ambiguous duplicate keys make the operation fail closed.
String patchJsonObject(String text, Map<String, dynamic> updates) =>
    patchJsonObjectRaw(text, {
      for (final entry in updates.entries) entry.key: jsonEncode(entry.value),
    });

/// As above, but callers provide complete, already encoded JSON value tokens.
/// Each token is validated separately before it is inserted.
String patchJsonObjectRaw(String text, Map<String, String> encodedUpdates) {
  uniqueJsonObject(text);
  final fields = _objectValues(text);
  final changes = <({int start, int end, String value})>[];
  final additions = <String>[];
  for (final entry in encodedUpdates.entries) {
    jsonDecode(entry.value);
    final field = fields[entry.key];
    if (field == null) {
      additions.add('${jsonEncode(entry.key)}:${entry.value}');
    } else {
      changes.add((start: field.start, end: field.end, value: entry.value));
    }
  }
  changes.sort((a, b) => b.start.compareTo(a.start));
  var result = text;
  for (final change in changes) {
    result = result.replaceRange(change.start, change.end, change.value);
  }
  if (additions.isNotEmpty) {
    final close = result.lastIndexOf('}');
    final prefix = fields.isEmpty ? '' : ',';
    result = result.replaceRange(close, close, '$prefix${additions.join(',')}');
  }
  return result;
}

/// Compare JSON number literals exactly rather than through a binary double.
/// Unparseable values fail closed instead of being treated as equal.
bool sameJsonNumber(String? left, String? right) {
  if (left == null || right == null) return false;
  final pattern = RegExp(
    r'^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$',
  );
  String? normalize(String value) {
    final match = pattern.firstMatch(value);
    if (match == null) return null;
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent == null) return null;
    final fraction = match.group(3) ?? '';
    final significant = '${match.group(2)}$fraction'.replaceFirst(
      RegExp(r'^0+'),
      '',
    );
    if (significant.isEmpty) return '0';
    final digits = significant.replaceFirst(RegExp(r'0+$'), '');
    final power =
        exponent - fraction.length + significant.length - digits.length;
    return '${match.group(1)}$digits:$power';
  }

  final a = normalize(left);
  final b = normalize(right);
  return a != null && b != null && a == b;
}
