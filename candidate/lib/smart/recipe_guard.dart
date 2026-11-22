import 'dart:convert';

import 'engine.dart' show microLabels;

/// UI bound on newly entered ingredient or yield weights, in grams.
const recipeMaxInputGrams = 1000000.0;

/// A deliberately user-facing error that never contains the recipe document.
class RecipeEditException implements Exception {
  final String message;
  const RecipeEditException(this.message);
  @override
  String toString() => message;
}

/// Read the existing recipe list for a *single-document* edit without dropping
/// future fields. This client cannot safely rewrite a newer schema, even when
/// the new field is in a different recipe in the same shared document.
List<Map<String, dynamic>> safeRecipeRows(Object? raw) {
  const recipeFields = {
    'id',
    'name',
    'servings',
    'cookedWeight',
    'ingredients',
  };
  const ingredientFields = {
    'name',
    'grams',
    'caloriesPer100g',
    'proteinPer100g',
    'fatPer100g',
    'carbsPer100g',
    'micros',
    'microsEstimated',
  };
  const unsupported = RecipeEditException(
    'В рецептах есть данные неизвестного формата. Обновите приложение; '
    'исходные рецепты не изменены.',
  );
  if (raw == null) return [];
  if (raw is! String) throw unsupported;
  try {
    final value = jsonDecode(raw);
    if (value is! List) throw unsupported;
    final rows = <Map<String, dynamic>>[];
    for (final item in value) {
      if (item is! Map || item.keys.any((key) => key is! String)) {
        throw unsupported;
      }
      final row = Map<String, dynamic>.from(item);
      if (row.keys.any((key) => !recipeFields.contains(key))) {
        throw unsupported;
      }
      final ingredients = row['ingredients'];
      if (ingredients is! List) throw unsupported;
      for (final ingredient in ingredients) {
        if (ingredient is! Map ||
            ingredient.keys.any(
              (key) => key is! String || !ingredientFields.contains(key),
            )) {
          throw unsupported;
        }
        if (ingredient.containsKey('microsEstimated') &&
            ingredient['microsEstimated'] is! bool) {
          throw unsupported;
        }
        final micros = ingredient['micros'];
        if (micros != null &&
            (micros is! Map ||
                micros.keys.any(
                  (key) => key is! String || !microLabels.containsKey(key),
                ) ||
                micros.values.any(
                  (value) => value is! num || !value.isFinite || value < 0,
                ))) {
          throw unsupported;
        }
      }
      rows.add(row);
    }
    return rows;
  } on RecipeEditException {
    rethrow;
  } catch (_) {
    throw unsupported;
  }
}
