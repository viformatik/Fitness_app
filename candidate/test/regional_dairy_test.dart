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

  test('dairy entries distinguish estimates and do not invent micronutrients', () {
    expect(regionalDairyFoods, hasLength(29));
    expect(FoodCatalog.regionalSource, regionalDairySource);
    final typical = regionalDairyFoods.where((f) => f.name.contains('(типовое)'));
    expect(typical, hasLength(20));
    expect(typical.every((f) => (f.note ?? '').contains('Ориентировочно')), isTrue);
    expect(typical.every((f) => f.brand == null && f.barcode == null), isTrue);
    expect(regionalDairyFoods.every((f) => f.micros.isEmpty), isTrue);
  });

  test('known brand and transliteration search use recovered metadata', () {
    expect(FoodDatabase.search('ТМК').any((f) => f.brand?.contains('ТМК') ?? false), isTrue);
    expect(FoodDatabase.search('Селянське').any((f) => f.brand == 'Селянське'), isTrue);
    expect(FoodDatabase.search('Selyanske').any((f) => f.brand == 'Селянське'), isTrue);
  });

  test('fat filter identifies 2.5 percent milk', () {
    final results = FoodCatalog.filter(FoodDatabase.allFoods,
        query: 'молоко fat25', source: FoodCatalog.regionalSource);
    expect(results, isNotEmpty);
    expect(results.every((f) => f.name.contains('2,5%')), isTrue);
    expect(results.any((f) => f.name.contains('Селянське')), isTrue);
  });

  test('fat sort puts the lowest-fat recovered milk first', () {
    final results = FoodCatalog.filter(FoodDatabase.allFoods,
        query: 'молоко', source: FoodCatalog.regionalSource, sort: FoodCatalog.fatSort);
    expect(results, hasLength(29));
    expect(results.first.fat, lessThanOrEqualTo(0.1));
    expect(results.last.fat, greaterThanOrEqualTo(results.first.fat));
  });

  test('Selianske barcode and provenance are specific to the recovered package', () {
    final item = regionalDairyFoods.firstWhere((f) => f.barcode == '4820003481547');
    expect(item.name, contains('Селянське'));
    expect(item.calories, 52);
    expect(item.fat, 2.5);
    expect(item.brand, 'Селянське');
    expect(item.note, contains('Open Food Facts'));
    expect(item.micros, isEmpty);
    expect(item.keywords, contains('fat25'));
  });

  test('Russian Молочная Благодать is not presented as PMR Благода', () {
    final items = regionalDairyFoods.where((f) => f.brand == 'Молочная Благодать');
    expect(items, hasLength(3));
    expect(items.every((f) => f.name.contains('Россия')), isTrue);
    expect(items.every((f) => (f.note ?? '').contains('не приднестровск')), isTrue);
    expect(regionalDairyFoods.any((f) => f.brand == 'Благода (Фиальт-Агро)'), isFalse);
  });

  test('quick search shows recovered local milk before generic staples', () {
    final found = provider.searchFoods('молоко');
    expect(found, isNotEmpty);
    expect(found.first.source, anyOf(pmrSource, regionalDairySource));
    expect(found.first.name, contains('Молоко'));
  });

  testWidgets('mobile food dialog offers confirmed ТХК and generic milk, not unsupported producers', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => showDialog<void>(context: context,
          builder: (_) => AddFoodDialog(mealType: MealType.breakfast, provider: provider)),
      child: const Text('Открыть'),
    )))));
    await tester.tap(find.text('Открыть')); await tester.pumpAndSettle();
    expect(find.text('ТХК'), findsOneWidget);
    expect(find.text('Типовое молоко'), findsOneWidget);
    expect(find.text('Благода'), findsNothing);
    expect(find.text('БМК'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
