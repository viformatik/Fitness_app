import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../legacy.dart';
import 'engine.dart';
import 'remote.dart';
import 'russian_product_names.dart';

/// Offline-first local catalog. English USDA rows were removed at the user's
/// request; names containing Latin letters are not displayed. Online brand
/// search is explicit, rate-limited and filtered using the same policy.
class FoodCatalog {
  static const localSource = 'База Fitness Smart';
  static const regionalSource = regionalDairySource;
  static const pmrSource = 'Продукция ПМР';
  static const mySource = 'Мои продукты';
  static const offSource = onlineBrandSource;
  static const allSources = 'Все источники';
  static bool hasCyrillic(String value) => containsCyrillicProductText(value);
  static bool isRussianName(String value) => isRussianProductName(value);
  static const allCategories = 'Все категории';
  static const anyNutrient = 'Любой нутриент';
  static const relevanceSort = 'Сначала подходящие';
  static const proteinSort = 'Больше белка';
  static const calorieSort = 'Меньше калорий';
  static const nutrientSort = 'Больше выбранного нутриента';
  static const nameSort = 'По названию';
  static const fatSort = 'По жирности';

  /// The server returns already normalized per-100 g values. Validate again:
  /// third-party data must never be able to create negative or infinite macros.
  static List<FoodItem> parseOnlineResponse(String body) {
    final doc = jsonDecode(body);
    if (doc is! Map || doc['items'] is! List) {
      throw const FormatException('Некорректный ответ каталога брендов');
    }
    final result = <FoodItem>[];
    for (final row in (doc['items'] as List).take(30)) {
      if (row is! Map || row['name'] is! String) continue;
      final name = (row['name'] as String).trim();
      if (!isRussianName(name)) continue;
      final values = <double>[];
      for (final key in ['calories', 'protein', 'fat', 'carbs']) {
        final value = row[key];
        if (value is! num || !value.isFinite || value < 0 || value > 1500) {
          values.clear();
          break;
        }
        values.add(value.toDouble());
      }
      if (name.isEmpty || name.length > 180 || values.length != 4) continue;
      final micros = <String, double>{};
      final rawMicros = row['micros'];
      if (rawMicros is Map) {
        for (final entry in rawMicros.entries) {
          final value = entry.value;
          if (microLabels.containsKey(entry.key) &&
              value is num &&
              value.isFinite &&
              value >= 0 &&
              value < 100000) {
            micros[entry.key as String] = value.toDouble();
          }
        }
      }
      final rawCategory = row['category'] is String
          ? (row['category'] as String).trim()
          : '';
      final rawBrand = row['brand'] is String
          ? (row['brand'] as String).trim()
          : '';
      result.add(
        FoodItem(
          name,
          values[0],
          values[1],
          values[2],
          values[3],
          micros,
          isRussianName(rawCategory) ? rawCategory : 'Упакованные продукты',
          offSource,
          isRussianName(rawBrand) ? rawBrand : null,
          row['barcode'] is String ? row['barcode'] as String : null,
        ),
      );
    }
    return result;
  }

  static Future<List<FoodItem>> searchOnline(
    String query, {
    http.Client? client,
    String? baseUrl,
  }) async {
    final q = query.trim();
    if (q.length < 2 || q.length > 80) {
      throw ArgumentError('Для поиска брендов введите от 2 до 80 символов');
    }
    final root = baseUrl ?? SmartRemote.url;
    if (root.isEmpty) throw StateError('Каталог брендов не настроен');
    final own = client ?? http.Client();
    try {
      final uri = Uri.parse(
        '$root/functions/v1/food-search',
      ).replace(queryParameters: {'q': q});
      final response = await own
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 429) {
        throw StateError(
          'Лимит поиска брендов исчерпан. Повторите через минуту.',
        );
      }
      if (response.statusCode != 200) {
        throw StateError(
          'Каталог брендов временно недоступен. Попробуйте позже.',
        );
      }
      return parseOnlineResponse(utf8.decode(response.bodyBytes));
    } on TimeoutException {
      throw StateError('Каталог брендов не ответил. Оффлайн-база доступна.');
    } finally {
      if (client == null) own.close();
    }
  }

  static List<List<String>> searchAlternatives(String query) {
    final normalized = query
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r'[^a-zа-я0-9]+'), ' ')
        .trim();
    if (normalized.isEmpty) return [];
    return normalized.split(' ').where((t) => t.isNotEmpty).map((token) {
      final alternatives = <String>{token};
      final translit = transliterate(token);
      if (translit.isNotEmpty && translit != token) alternatives.add(translit);
      for (final alias in synonymPrefixes.entries) {
        if (token.startsWith(alias.key)) {
          alternatives.addAll(alias.value);
        }
      }
      for (final entry in foodSynonyms.entries) {
        if (entry.key == token || entry.key == translit) {
          alternatives.addAll(entry.value);
        }
      }
      return alternatives.toList();
    }).toList();
  }

  static List<FoodItem> filter(
    Iterable<FoodItem> foods, {
    String query = '',
    String category = allCategories,
    String source = allSources,
    String nutrient = anyNutrient,
    String sort = relevanceSort,
    bool highProtein = false,
    bool lowCalorie = false,
    bool lowSugar = false,
  }) {
    final alternatives = searchAlternatives(query);
    final scored = <(FoodItem, int)>[];
    for (final food in foods) {
      // Hide names containing Latin letters without modifying stored records.
      if (!isRussianName(food.name)) continue;
      if (category != allCategories && food.category != category) continue;
      if (source != allSources && food.source != source) continue;
      if (nutrient != anyNutrient && !food.micros.containsKey(nutrient))
        continue;
      if (highProtein && food.protein < 20) continue;
      if (lowCalorie && food.calories > 100) continue;
      if (lowSugar && (food.micros['sugars'] ?? 999) > 5) continue;
      final haystack = [
        food.name,
        food.category,
        food.source,
        food.brand ?? '',
        food.barcode ?? '',
        food.keywords,
      ].join(' ').toLowerCase().replaceAll('ё', 'е');
      var score = 0;
      var matched = true;
      for (final group in alternatives) {
        final found = group.any((term) => haystack.contains(term));
        if (!found) {
          matched = false;
          break;
        }
        score += 10;
      }
      if (!matched) continue;
      if (query.trim().length >= 2) {
        final direct = alternatives.firstOrNull ?? const <String>[];
        if (direct.any((term) => haystack.startsWith(term))) score += 30;
        if (food.source == mySource) score += 12;
        if (food.source == pmrSource) score += 20;
        if (food.source == regionalSource) score += 16;
        if (food.source == localSource) score += 8;
      }
      if (food.micros.isNotEmpty) score += 2;
      scored.add((food, score));
    }
    final priority = {
      mySource: 0,
      pmrSource: 1,
      regionalSource: 2,
      localSource: 3,
      offSource: 4,
    };
    int sourceRank(FoodItem f) => priority[f.source] ?? 5;
    if (sort == proteinSort) {
      scored.sort((a, b) => b.$1.protein.compareTo(a.$1.protein));
    } else if (sort == calorieSort) {
      scored.sort((a, b) => a.$1.calories.compareTo(b.$1.calories));
    } else if (sort == nutrientSort) {
      final key = nutrient != anyNutrient ? nutrient : 'vitaminC';
      num density(FoodItem f) =>
          (f.micros[key] ?? -1) / (f.calories > 10 ? f.calories : 10);
      scored.sort((a, b) => density(b.$1).compareTo(density(a.$1)));
    } else if (sort == nameSort) {
      scored.sort(
        (a, b) => a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase()),
      );
    } else if (sort == fatSort) {
      scored.sort((a, b) {
        final byFat = a.$1.fat.compareTo(b.$1.fat);
        if (byFat != 0) return byFat;
        return a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase());
      });
    } else {
      scored.sort((a, b) {
        final byScore = b.$2.compareTo(a.$2);
        if (byScore != 0) return byScore;
        final bySource = sourceRank(a.$1).compareTo(sourceRank(b.$1));
        if (bySource != 0) return bySource;
        return a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase());
      });
    }
    return scored.map((e) => e.$1).toList();
  }

  static String transliterate(String value) {
    const multi = {
      'shch': 'щ',
      'zh': 'ж',
      'kh': 'х',
      'ch': 'ч',
      'sh': 'ш',
      'yu': 'ю',
      'ya': 'я',
      'ye': 'е',
      'yo': 'ё',
    };
    const single = {
      'a': 'а',
      'b': 'б',
      'v': 'в',
      'g': 'г',
      'd': 'д',
      'e': 'е',
      'z': 'з',
      'i': 'и',
      'j': 'й',
      'k': 'к',
      'l': 'л',
      'm': 'м',
      'n': 'н',
      'o': 'о',
      'p': 'п',
      'r': 'р',
      's': 'с',
      't': 'т',
      'u': 'у',
      'f': 'ф',
      'h': 'х',
      'c': 'ц',
      'y': 'ы',
      'w': 'в',
      'q': 'к',
      'x': 'кс',
    };
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (ch.codeUnitAt(0) >= 1040 && ch.codeUnitAt(0) <= 1103) {
        final mapped = const {
          'щ': 'shch',
          'ж': 'zh',
          'х': 'kh',
          'ч': 'ch',
          'ш': 'sh',
          'ю': 'yu',
          'я': 'ya',
          'ё': 'yo',
          'а': 'a',
          'б': 'b',
          'в': 'v',
          'г': 'g',
          'д': 'd',
          'е': 'e',
          'з': 'z',
          'и': 'i',
          'й': 'y',
          'к': 'k',
          'л': 'l',
          'м': 'm',
          'н': 'n',
          'о': 'o',
          'п': 'p',
          'р': 'r',
          'с': 's',
          'т': 't',
          'у': 'u',
          'ф': 'f',
          'ц': 'ts',
          'ы': 'y',
          'ь': '',
          'ъ': '',
          'э': 'e',
        }[ch.toLowerCase()];
        out.write(mapped ?? ch);
      } else {
        out.write(ch);
      }
    }
    // Keep the constants referenced for future reverse lookup without
    // pretending transliteration can uniquely reconstruct Cyrillic spelling.
    assert(multi.isNotEmpty && single.isNotEmpty);
    return out.toString();
  }

  static const synonymPrefixes = <String, List<String>>{
    'курин': ['chicken', 'poultry', 'broiler'],
    'говяж': ['beef'],
    'свин': ['pork'],
    'рыб': ['fish', 'salmon', 'tuna', 'cod'],
    'яблоч': ['apple'],
    'банан': ['banana'],
    'молоч': ['milk', 'dairy'],
    'сырн': ['cheese'],
    'творож': ['cottage', 'cheese', 'curd'],
    'яичн': ['egg'],
    'овсян': ['oat', 'oats'],
    'гречн': ['buckwheat'],
    'рисов': ['rice'],
    'картофел': ['potato'],
    'броккол': ['broccoli'],
    'апельсин': ['orange'],
    'миндал': ['almond'],
    'лосос': ['salmon'],
    'тунц': ['tuna'],
  };

  static const foodSynonyms = <String, List<String>>{
    'курица': ['chicken', 'poultry', 'broiler'],
    'говядина': ['beef'],
    'свинина': ['pork'],
    'рыба': ['fish', 'salmon', 'tuna', 'cod'],
    'лосось': ['salmon'],
    'тунец': ['tuna'],
    'треска': ['cod'],
    'яйцо': ['egg'],
    'яйца': ['egg'],
    'молоко': ['milk'],
    'сыр': ['cheese'],
    'творог': ['cottage', 'curd', 'cheese'],
    'йогурт': ['yogurt'],
    'кефир': ['kefir', 'yogurt'],
    'овсянка': ['oats', 'oatmeal'],
    'гречка': ['buckwheat'],
    'рис': ['rice'],
    'макароны': ['pasta', 'macaroni'],
    'хлеб': ['bread'],
    'картошка': ['potato'],
    'картофель': ['potato'],
    'помидор': ['tomato'],
    'огурцы': ['cucumber'],
    'брокколи': ['broccoli'],
    'яблоко': ['apple'],
    'банан': ['banana'],
    'апельсин': ['orange'],
    'орехи': ['nuts', 'almond', 'walnut'],
    'масло': ['oil', 'butter'],
    'фасоль': ['beans'],
    'чечевица': ['lentils'],
    'нут': ['chickpea', 'garbanzo'],
    'tvorog': ['cottage', 'curd', 'cheese'],
    'grechka': ['buckwheat'],
    'ovsyanka': ['oats', 'oatmeal'],
    'kuritsa': ['chicken'],
    'yabloko': ['apple'],
    'moloko': ['milk'],
    'yogurt': ['yoghurt'],
    'kefir': ['кефир'],
    'selyanske': ['селянське', 'селянске', 'selianske'],
    'selianske': ['селянське', 'selyanske'],
    'selyanskoe': ['селянське', 'селянское'],
    'blagoda': ['благода'],
    'blagodat': ['благодать'],
    'tmk': ['тмк'],
    'prostokvashino': ['простоквашино'],
    'domik': ['домик в деревне'],
    'molkom': ['молком'],
    'thk': ['тхк', 'тираспольский хлебокомбинат'],
    'tirhleb': ['тхк', 'тираспольский хлебокомбинат'],
    'bmk': ['бмк', 'бендерский мясокомбинат'],
    'pmr': ['пмр', 'приднестровье'],
    'pridnestrove': ['приднестровье', 'пмр'],
    'khp': ['кхп', 'комбинат хлебопродуктов'],
    'akvatir': ['акватир'],
    'kvint': ['квинт'],
    'tira': ['тирасполь'],
    'bendery': ['бендеры'],
    'rybnica': ['рыбница'],
  };
}
