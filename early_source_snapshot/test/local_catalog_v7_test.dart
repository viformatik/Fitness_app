import 'dart:convert';

import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/catalog.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/local_catalog.dart';
import 'package:fitness_tracker/smart/regional_foods.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('entire offline catalog has Cyrillic names without Latin letters', () {
    final foods = FoodDatabase.allFoods;
    expect(foods.length, 454);
    expect(
      foods.every((f) => FoodCatalog.isRussianName(f.name)),
      isTrue,
      reason:
          'Visible product names must contain Cyrillic and no Latin letters',
    );
    expect(
      foods
          .where((f) => f.brand != null)
          .every((f) => !RegExp(r'[A-Za-z]').hasMatch(f.brand!)),
      isTrue,
      reason: 'Brand labels shown in UI must not contain Latin letters',
    );
    expect(foods.any((f) => f.source == pmrSource), isTrue);
    expect(foods.every((f) => !f.source.contains('USDA')), isTrue);
  });

  test(
    'display policy rejects mixed and extended Latin without altering input',
    () {
      for (final name in ['Молоко 3,2%', 'Творог × 2', 'Сыр Український']) {
        expect(FoodCatalog.isRussianName(name), isTrue, reason: name);
      }
      for (final name in [
        'Milk',
        'Молоко Milk',
        'Йогурт café',
        'Десерт é',
        'Напиток Ａ',
        'Витамин C',
        '123',
      ]) {
        expect(FoodCatalog.isRussianName(name), isFalse, reason: name);
      }
    },
  );

  test(
    'local catalog covers all major PMR producers and familiar CIS brands',
    () {
      final brands = <String>{
        ...localCatalogFoods.map((f) => f.brand ?? ''),
        ...regionalDairyFoods.map((f) => f.brand ?? ''),
      }.where((b) => b.isNotEmpty).map((b) => b.toLowerCase()).toList();
      for (final producer in [
        'Тираспольский хлебокомбинат',
        'Тираспольский молочный комбинат',
        'Бендерский мясокомбинат',
        'Благода',
        'Рыбницкий хлебокомбинат',
        'Каменский консервный завод',
        'Акватир',
        'Квинт',
      ]) {
        expect(
          brands.any((b) => b.contains(producer.toLowerCase())),
          isTrue,
          reason: 'Missing PMR producer/brand: $producer',
        );
      }
      for (final cis in [
        'Домик в деревне',
        'Простоквашино',
        'Селянське',
        'На здоров',
      ]) {
        expect(
          brands.any((b) => b.contains(cis.toLowerCase())),
          isTrue,
          reason: 'Missing familiar CIS brand: $cis',
        );
      }
    },
  );

  test('ТХК exact labels and producer aliases are searchable', () {
    expect(
      FoodCatalog.filter(
        FoodDatabase.allFoods,
        query: 'ТХК',
        source: FoodCatalog.pmrSource,
      ).length,
      greaterThanOrEqualTo(94),
    );
    expect(
      FoodCatalog.filter(
        FoodDatabase.allFoods,
        query: 'thk',
        source: FoodCatalog.pmrSource,
      ),
      isNotEmpty,
    );
    expect(
      FoodCatalog.filter(
        FoodDatabase.allFoods,
        query: 'тираспольский хлебокомбинат',
        source: FoodCatalog.pmrSource,
      ),
      isNotEmpty,
    );
    final exact = localCatalogFoods.firstWhere(
      (f) => f.name == 'Батон "Витебский"',
    );
    expect(exact.calories, 184);
    expect(exact.protein, 5.2);
    expect(exact.fat, 0.9);
    expect(exact.carbs, 38.2);
    expect(exact.note, contains('официальному каталогу ТХК'));
    expect(exact.note, contains('Сверьте упаковку'));
  });

  test('approximate local values are explicitly marked', () {
    final typical = localCatalogFoods.where(
      (f) => !(f.note ?? '').contains('официальному каталогу ТХК'),
    );
    expect(typical.length, greaterThan(200));
    expect(
      typical.every((f) => (f.note ?? '').contains('Ориентировочно')),
      isTrue,
    );
    expect(typical.every((f) => (f.note ?? '').contains('сверьте')), isTrue);
  });

  test('catalog filter and online parser reject mixed Latin names', () {
    final mixed = [
      FoodItem(
        'Яблоко местное',
        52,
        0.3,
        0.2,
        14,
        const {},
        'Фрукты',
        pmrSource,
      ),
      FoodItem(
        'Imported apple',
        52,
        0.3,
        0.2,
        14,
        const {},
        'Фрукты',
        FoodCatalog.offSource,
      ),
      FoodItem(
        'Яблоко Fresh',
        52,
        0.3,
        0.2,
        14,
        const {},
        'Фрукты',
        FoodCatalog.mySource,
      ),
    ];
    final filtered = FoodCatalog.filter(mixed);
    expect(filtered, hasLength(1));
    expect(filtered.single.name, 'Яблоко местное');
    expect(FoodCatalog.filter(mixed, query: 'Fresh'), isEmpty);
    expect(
      mixed.last.name,
      'Яблоко Fresh',
      reason: 'Filtering must not rewrite user objects',
    );

    final parsed = FoodCatalog.parseOnlineResponse(
      jsonEncode({
        'items': [
          {
            'name': 'Imported product',
            'calories': 100,
            'protein': 5,
            'fat': 5,
            'carbs': 10,
            'category': 'Dairy',
            'brand': 'Global Brand',
          },
          {
            'name': 'Йогурт Fresh',
            'calories': 60,
            'protein': 4,
            'fat': 2,
            'carbs': 6,
            'category': 'Молочное',
            'brand': 'Данон',
          },
          {
            'name': 'Йогурт местный',
            'calories': 60,
            'protein': 4,
            'fat': 2,
            'carbs': 6,
            'category': 'Молочные продукты',
            'brand': 'Данон',
          },
          {
            'name': 'Сыр местный',
            'calories': 250,
            'protein': 20,
            'fat': 18,
            'carbs': 1,
            'category': 'Сыр Cheese',
            'brand': 'Бренд Global',
          },
        ],
      }),
    );
    expect(parsed, hasLength(2));
    final yogurt = parsed.firstWhere((f) => f.name == 'Йогурт местный');
    expect(yogurt.brand, 'Данон');
    expect(yogurt.category, 'Молочные продукты');
    final cheese = parsed.firstWhere((f) => f.name == 'Сыр местный');
    expect(cheese.brand, isNull);
    expect(cheese.category, 'Упакованные продукты');
  });
}
