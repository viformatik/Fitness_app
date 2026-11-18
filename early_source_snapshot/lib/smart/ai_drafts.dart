import 'dart:async';
import 'dart:convert';
import 'engine.dart';
import 'local_store.dart';

const aiMeals = [
  'breakfast',
  'lunch',
  'snack',
  'dinner',
  'preWorkout',
  'postWorkout',
];

/// Only allow known nutrients. Missing means unknown, never zero. Values are
/// per 100 g in the units shown in microLabels, not for the entire portion.
Map<String, double> validateAiMicros(Object? raw) {
  if (raw == null) return {};
  if (raw is! Map)
    throw const FormatException('AI вернул некорректный состав витаминов.');
  final result = <String, double>{};
  for (final entry in raw.entries) {
    if (!microLabels.containsKey(entry.key)) continue;
    final value = entry.value;
    if (value is! num || !value.isFinite || value < 0 || value > 100000) {
      throw const FormatException('Проверьте значения витаминов и минералов.');
    }
    result[entry.key as String] = value.toDouble();
  }
  return result;
}

/// Only fill gaps: an AI guess must not silently overwrite existing package or user values.
Map<String, double> mergeMicronutrientEstimates(
  Map<String, double> existing,
  Object? rawEstimates,
) => {...validateAiMicros(rawEstimates), ...existing};

/// One contract for remote responses and locally cached drafts. Nutrition is per 100 g.
List<Json> validateAiItems(Object? raw) {
  if (raw is! List || raw.length > 30) {
    throw const FormatException(
      'AI вернул некорректный список продуктов. Попробуйте уточнить описание.',
    );
  }
  return raw.map((row) {
    if (row is! Map ||
        row['name'] is! String ||
        (row['name'] as String).trim().isEmpty ||
        (row['name'] as String).length > 200) {
      throw const FormatException(
        'Не удалось проверить название продукта. Повторите распознавание.',
      );
    }
    for (final key in ['grams', 'calories', 'protein', 'fat', 'carbs']) {
      final v = row[key];
      if (v is! num ||
          !v.isFinite ||
          v < 0 ||
          (key == 'grams' ? v <= 0 || v > 20000 : v > 1000)) {
        throw const FormatException(
          'AI вернул неподходящие значения порции или КБЖУ. Уточните описание.',
        );
      }
    }
    return <String, dynamic>{
      'name': (row['name'] as String).trim(),
      for (final key in ['grams', 'calories', 'protein', 'fat', 'carbs'])
        key: number(row[key]),
      'micros': validateAiMicros(row['micros']),
      'meal': aiMeals.contains(row['meal']) ? row['meal'] : 'snack',
      'assumptions': row['assumptions'] is String
          ? (row['assumptions'] as String).substring(
              0,
              (row['assumptions'] as String).length.clamp(0, 2000),
            )
          : 'Состав и порция оценены приблизительно.',
    };
  }).toList();
}

class AiPortionTotals {
  final double grams, calories, protein, fat, carbs;
  const AiPortionTotals(
    this.grams,
    this.calories,
    this.protein,
    this.fat,
    this.carbs,
  );
  factory AiPortionTotals.fromItems(Iterable<Json> items) {
    double grams = 0, calories = 0, protein = 0, fat = 0, carbs = 0;
    for (final row in items) {
      final g = number(row['grams']);
      grams += g;
      calories += number(row['calories']) * g / 100;
      protein += number(row['protein']) * g / 100;
      fat += number(row['fat']) * g / 100;
      carbs += number(row['carbs']) * g / 100;
    }
    return AiPortionTotals(grams, calories, protein, fat, carbs);
  }
}

class AiRequestFailure implements Exception {
  final String message;
  const AiRequestFailure(this.message);
  @override
  String toString() => message;
}

String aiServerErrorMessage(int status, Object? details) {
  final reason = details is Map ? '${details['error'] ?? ''}' : '';
  if (status == 0)
    return 'Не удалось связаться с сервером. Возможно, облако временно недоступно или есть проблема с интернетом. Запрос остаётся на экране; попробуйте позже.';
  if (status == 401 || status == 403)
    return 'Сессия завершилась. Войдите в аккаунт в разделе ниже и повторите запрос.';
  if (reason.contains('GEMINI_API_KEY')) {
    return 'AI ещё не настроен: добавьте GEMINI_API_KEY в Supabase → Edge Functions → Secrets. Ключ нужен только на сервере, не на Vercel.';
  }
  if (status == 429) {
    return reason.contains('15 requests')
        ? 'Достигнут лимит: 15 распознаваний в час на аккаунт. Попробуйте позже или повторите блюдо из недавних без нового запроса.'
        : 'У AI-провайдера закончилась текущая квота. Попробуйте позже. Платный резервный API не используется.';
  }
  if (status == 413)
    return 'Фото слишком большое. Выберите изображение до 4 МБ.';
  if (status == 400)
    return 'Не удалось прочитать описание или фото. Укажите еду и порцию, используйте JPG, PNG или WebP.';
  if (reason.contains('Quota service'))
    return 'Сервис AI временно недоступен: требуется проверить настройку лимитов на сервере.';
  return 'AI не ответил или занят. Повторите позже — продукты автоматически не добавлялись.';
}

String friendlyAiError(Object error) {
  if (error is AiRequestFailure) return error.message;
  if (error is TimeoutException)
    return 'Время ожидания AI истекло. Описание и фото сохранены на экране. Попробуйте ещё раз.';
  if (error is ArgumentError)
    return '${error.message ?? 'Проверьте введённые данные'}';
  if (error is StateError) return error.message;
  if (error is FormatException) return error.message;
  return 'Не удалось выполнить действие. Проверьте интернет и разрешения браузера. Ваш дневник не изменён.';
}

/// Only normalized food estimates, never photos, prompts, tokens or health profiles.
/// Device-local, separated by account; excluded from cloud sync and diary exports.
class AiDraftCache {
  final LocalPreferences store;
  final String owner;
  AiDraftCache(this.store, this.owner);
  String get key => '_ai_drafts_$owner';
  List<Json> read() {
    final raw = store.decoded(key);
    if (raw is! List) return [];
    final result = <Json>[];
    for (final row in raw.take(5)) {
      try {
        if (row is! Map) continue;
        final items = validateAiItems(row['items']);
        if (items.isNotEmpty)
          result.add({
            'items': items,
            'createdAt': '${row['createdAt'] ?? ''}',
          });
      } catch (_) {
        /* A corrupt optional cache never blocks the diary. */
      }
    }
    return result;
  }

  Future<void> remember(List<Json> items) async {
    final normalized = validateAiItems(items);
    if (normalized.isEmpty) return;
    final signature = jsonEncode(normalized);
    final history = read()
        .where((e) => jsonEncode(e['items']) != signature)
        .toList();
    history.insert(0, {
      'items': normalized,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await store.setString(key, jsonEncode(history.take(5).toList()));
  }

  Future<void> clear() async {
    await store.remove(key);
  }
}

/// Strict allowlist for data leaving the device. Refinement shares this draft only.
Json buildAiFoodRequest({
  String text = '',
  List<int>? image,
  String mime = 'image/jpeg',
  String mode = 'food',
  List<Json>? previousItems,
}) {
  if (!['food', 'label', 'refine', 'micronutrients'].contains(mode))
    throw ArgumentError('Неизвестный режим AI.');
  final input = text.trim();
  if (input.length > 4000)
    throw ArgumentError('Описание должно быть короче 4000 символов.');
  if (mode == 'label' && image == null)
    throw ArgumentError('Добавьте чёткое фото таблицы пищевой ценности.');
  if (mode == 'refine' &&
      (input.isEmpty || previousItems == null || previousItems.isEmpty))
    throw ArgumentError('Напишите уточнение к открытому черновику.');
  if (mode == 'refine' && image != null)
    throw ArgumentError(
      'Уточнение отправляет только черновик и текст, без исходного фото.',
    );
  if (input.isEmpty && image == null)
    throw ArgumentError('Добавьте описание или фото.');
  if (image != null &&
      (image.length > 4 * 1024 * 1024 ||
          !['image/jpeg', 'image/png', 'image/webp'].contains(mime)))
    throw ArgumentError('Нужно фото JPG, PNG или WebP до 4 МБ.');
  return {
    'text': input,
    'mode': mode,
    if (image != null) 'image': base64Encode(image),
    if (image != null) 'mime': mime,
    if (mode == 'refine') 'previousItems': validateAiItems(previousItems),
  };
}

/// Supplement recognition is opt-in, shares only text and optional selected
/// label image. Amounts not stated/read clearly stay unknown for manual review.
Json buildAiSupplementRequest({
  String text = '',
  List<int>? image,
  String mime = 'image/jpeg',
}) {
  final input = text.trim();
  if (input.length > 4000)
    throw ArgumentError('Описание должно быть короче 4000 символов.');
  if (input.isEmpty && image == null)
    throw ArgumentError(
      'Напишите добавки и количество или добавьте фото этикетки.',
    );
  if (image != null &&
      (image.length > 4 * 1024 * 1024 ||
          !['image/jpeg', 'image/png', 'image/webp'].contains(mime))) {
    throw ArgumentError('Нужно фото JPG, PNG или WebP до 4 МБ.');
  }
  return {
    'text': input,
    'mode': 'supplement',
    if (image != null) 'image': base64Encode(image),
    if (image != null) 'mime': mime,
  };
}
