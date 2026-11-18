import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/catalog.dart';
import 'package:fitness_tracker/smart/engine.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/regional_foods.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider provider;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    SharedPreferences.setMockInitialValues({});
    provider = AppDataProvider();
    await provider.init();
  });
  tearDown(() => provider.dispose());

  test('curated dairy list has real fat variants and brands', () {
    expect(regionalDairyFoods.length, 49);
    expect(FoodCatalog.regionalSource, regionalDairySource);
    final names = FoodDatabase.allFoods.map((f) => f.name).toSet();
    for (final fat in [
      '0%', '0,5%', '1%', '1,5%', '2%', '2,5%', '3%', '3,2%',
      '3,5%', '3,7%', '4%', '6%',
    ]) {
      expect(
        names.any((n) => n.contains(fat) && n.contains('Молоко')),
        isTrue,
        reason: 'Missing generic milk variant $fat',
      );
    }
    expect(names.any((n) => n.contains('топлёное')), isTrue);
    expect(names.any((n) => n.contains('безлактозное')), isTrue);
    expect(names.any((n) => n.contains('высокобелковое')), isTrue);
    expect(names.any((n) => n.contains('козье')), isTrue);
  });

  test('local brands are searchable in Cyrillic and translit', () {
    expect(
      FoodDatabase.search('Благода').any((f) => f.brand?.contains('Благода') ?? false),
      isTrue,
    );
    expect(
      FoodDatabase.search('ТМК').any((f) => f.brand?.contains('ТМК') ?? false),
      isTrue,
    );
    expect(
      FoodDatabase.search('Селянське').any((f) => f.brand?.contains('Селянське') ?? false),
      isTrue,
    );
    expect(
      FoodDatabase.search('Selyanske').any((f) => f.brand?.contains('Селянське') ?? false),
      isTrue,
    );
    final byLatin = FoodCatalog.filter(
      FoodDatabase.allFoods,
      query: 'blagoda',
      source: FoodCatalog.regionalSource,
    );
    expect(byLatin, isNotEmpty);
    expect(byLatin.every((f) => f.name.contains('Благода')), isTrue);
  });

  test('fat chips map to exact 2.5% milk products, not all dairy', () {
    final results = FoodCatalog.filter(
      FoodDatabase.allFoods,
      query: 'молоко fat25',
      source: FoodCatalog.regionalSource,
    );
    expect(results, isNotEmpty);
    expect(results.every((f) => f.name.contains('2,5%')), isTrue);
    expect(results.any((f) => f.name.contains('Селянське')), isTrue);
    expect(results.any((f) => f.name.contains('Благода')), isTrue);
  });

  test('fat sort puts low-fat milk first', () {
    final results = FoodCatalog.filter(
      FoodDatabase.allFoods,
      query: 'молоко',
      source: FoodCatalog.regionalSource,
      sort: FoodCatalog.fatSort,
    );
    expect(results.length, 49);
    expect(results.first.fat, lessThanOrEqualTo(0.1));
    expect(results.last.fat, greaterThanOrEqualTo(results.first.fat));
  });

  test('published Selianske values include provenance and barcode', () {
    final item = regionalDairyFoods.firstWhere(
      (f) => f.name == 'Молоко «Селянське» 2,5%',
    );
    expect(item.calories, 52);
    expect(item.protein, 2.8);
    expect(item.fat, 2.5);
    expect(item.carbs, 4.7);
    expect(item.barcode, '4820003481547');
    expect(item.brand, 'Селянське');
    expect(item.note, contains('опубликованной'));
    expect(
      item.sourceUrl,
      anyOf(contains('loostdorf.com'), contains('listex.info')),
    );
    expect(item.micros['calcium'], 120);
    expect(item.keywords, contains('fat25'));
  });

  test('Fialt-Agro Blagoda values are explicitly approximate', () {
    final item = regionalDairyFoods.firstWhere(
      (f) => f.name == 'Молоко «Благода (Фиальт-Агро)» 2,5%',
    );
    expect(item.brand, 'Благода (Фиальт-Агро)');
    expect(item.calories, 52);
    expect(item.fat, 2.5);
    expect(item.note, contains('Ориентировочно'));
    expect(item.note, contains('сверьте'));
    expect(item.sourceUrl, contains('novostipmr.com'));
    expect(item.sourceUrl, contains('huday.ru'));
  });

  test('quick add search shows local Cyrillic milk before generic staples', () {
    final found = provider.searchFoods('молоко');
    expect(found, isNotEmpty);
    expect(found.first.source, anyOf(pmrSource, regionalDairySource));
    expect(found.first.name, contains('Молоко'));
    expect(FoodCatalog.hasCyrillic(found.first.name), isTrue);
  });

  testWidgets('AddFoodDialog exposes milk fat and brand chips', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AddFoodDialog(
                  mealType: MealType.breakfast,
                  provider: provider,
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.text('Молоко — жирность и местные бренды:'), findsOneWidget);
    expect(find.text('Наши производители:'), findsOneWidget);
    for (final label in ['0,5%', '1%', '1,5%', '2,5%', '3,2%', '3,5%', 'Селянське']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    for (final label in ['Благода', 'ТМК', 'ТХК', 'БМК', 'Акватир', 'Квинт']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
  });
}
