/// Model text is untrusted and cannot mutate the journal.
class JournalAiResult {
  final String summary;
  final List<String> observations, suggestions, limitations;
  const JournalAiResult({
    required this.summary,
    required this.observations,
    required this.suggestions,
    required this.limitations,
  });

  factory JournalAiResult.fromJson(Object? raw) {
    if (raw is! Map || raw['summary'] is! String) {
      throw const FormatException('Не удалось проверить ответ ИИ.');
    }
    final summary = (raw['summary'] as String).trim();
    if (summary.isEmpty || summary.length > 3000) {
      throw const FormatException('Не удалось проверить ответ ИИ.');
    }
    List<String> read(String key) {
      final value = raw[key];
      if (value is! List ||
          value.length > 8 ||
          value.any(
            (e) => e is! String || e.trim().isEmpty || e.length > 1500,
          )) {
        throw const FormatException('Не удалось проверить ответ ИИ.');
      }
      return value.cast<String>().map((e) => e.trim()).toList(growable: false);
    }

    return JournalAiResult(
      summary: summary,
      observations: read('observations'),
      suggestions: read('suggestions'),
      limitations: read('limitations'),
    );
  }
}
