import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

FoodEntry food(String id, DateTime date, {double grams = 100}) => FoodEntry(
  id: id,
  name: 'Синтетическая еда $id',
  date: date,
  amountGrams: grams,
  caloriesPer100g: 120,
  proteinPer100g: 10,
  fatPer100g: 2,
  carbsPer100g: 15,
  mealType: MealType.breakfast,
  micros: {'vitaminC': 3},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = DateTime(2026, 10, 1);
  final second = DateTime(2026, 10, 2);
  final outside = DateTime(2026, 10, 3);
  late AppDataProvider p;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    p.dispose();
  });

  Future<FoodRangeSnapshot> capture() async => FoodRangeSnapshot(
    firstDay: first,
    lastDay: second,
    entries: await p.storage.getFoodEntriesInRange(first, second),
  );

  Future<void> apply(
    FoodEntry target,
    FoodRangeSnapshot range, {
    bool Function()? guard,
  }) => p.applyReviewedFoodChanges(
    date: target.date,
    expected: {target.id: target},
    changes: {target.id: target.copyWith(amountGrams: 200)},
    additions: [],
    expectedRange: range,
    authorizationGuard: guard,
  );

  test('unchanged whole period allows reviewed write', () async {
    final a = food('a', first), b = food('b', second);
    await p.storage.addFoodBatch([a]);
    await p.storage.addFoodBatch([b]);
    await apply(a, await capture());
    expect((await p.storage.getFoodEntries(first)).single.amountGrams, 200);
    expect((await p.storage.getFoodEntries(second)).single.id, 'b');
  });

  test('changed unrelated food in same day blocks entire write', () async {
    final a = food('a', first), b = food('b', first);
    await p.storage.addFoodBatch([a, b]);
    final range = await capture();
    await p.storage.updateFoodEntry(b.copyWith(amountGrams: 350));
    await expectLater(apply(a, range), throwsStateError);
    final now = await p.storage.getFoodEntries(first);
    expect(now.map((e) => e.amountGrams), [100, 350]);
  });

  test('a new food in another day within range blocks old analysis', () async {
    final a = food('a', first);
    await p.storage.addFoodBatch([a]);
    final range = await capture();
    await p.storage.addFoodBatch([food('later', second)]);
    await expectLater(apply(a, range), throwsStateError);
    expect((await p.storage.getFoodEntries(first)).single.amountGrams, 100);
  });

  test('deleting an unrelated food within range blocks old analysis', () async {
    final a = food('a', first), b = food('b', second);
    await p.storage.addFoodBatch([a]);
    await p.storage.addFoodBatch([b]);
    final range = await capture();
    await p.storage.deleteFoodEntry(b.id, second);
    await expectLater(apply(a, range), throwsStateError);
    expect((await p.storage.getFoodEntries(first)).single.amountGrams, 100);
  });

  test('new food outside selected range does not invalidate it', () async {
    final a = food('a', first);
    await p.storage.addFoodBatch([a]);
    final range = await capture();
    await p.storage.addFoodBatch([food('outside', outside)]);
    await apply(a, range);
    expect((await p.storage.getFoodEntries(first)).single.amountGrams, 200);
    expect((await p.storage.getFoodEntries(outside)).single.id, 'outside');
  });

  test('account guard is evaluated after enqueuing, before write', () async {
    final a = food('a', first);
    await p.storage.addFoodBatch([a]);
    final range = await capture();
    var sameOwner = true;
    final pending = apply(a, range, guard: () => sameOwner);
    sameOwner = false;
    await expectLater(pending, throwsStateError);
    expect((await p.storage.getFoodEntries(first)).single.amountGrams, 100);
  });

  test(
    'target day outside snapshot cannot be used to apply additions',
    () async {
      final range = await capture();
      await expectLater(
        p.applyReviewedFoodChanges(
          date: outside,
          expected: {},
          changes: {},
          additions: [food('new', outside)],
          expectedRange: range,
        ),
        throwsArgumentError,
      );
      expect(await p.storage.getFoodEntries(outside), isEmpty);
    },
  );

  test('captured nested nutrients do not change with caller map', () {
    final a = food('a', first);
    final range = FoodRangeSnapshot(
      firstDay: first,
      lastDay: second,
      entries: [a],
    );
    a.micros['vitaminC'] = 25;
    expect(range.entries.single.micros['vitaminC'], 3);
    expect(
      () => range.entries.single.micros['vitaminC'] = 99,
      throwsUnsupportedError,
    );
  });

  test(
    'baseline advances only by each confirmed day, in stored order',
    () async {
      final a = food('a', first), b = food('b', second);
      await p.storage.addFoodBatch([a]);
      await p.storage.addFoodBatch([b]);
      final before = await capture();
      final changedA = a.copyWith(amountGrams: 200);
      final added = food('new', first);
      final after = before.afterReviewedDay(
        date: first,
        changes: {'a': changedA},
        additions: [added],
      );
      expect(after.entries.map((e) => e.id), ['a', 'new', 'b']);
      await p.applyReviewedFoodChanges(
        date: first,
        expected: {'a': a},
        changes: {'a': changedA},
        additions: [added],
        expectedRange: before,
      );
      await apply(b, after);
      expect((await p.storage.getFoodEntries(second)).single.amountGrams, 200);
    },
  );

  test('advancing a baseline never absorbs an unrelated edit', () async {
    final a = food('a', first), b = food('b', second);
    await p.storage.addFoodBatch([a]);
    await p.storage.addFoodBatch([b]);
    final before = await capture();
    final changedA = a.copyWith(amountGrams: 200);
    final after = before.afterReviewedDay(
      date: first,
      changes: {'a': changedA},
      additions: [],
    );
    await p.applyReviewedFoodChanges(
      date: first,
      expected: {'a': a},
      changes: {'a': changedA},
      additions: [],
      expectedRange: before,
    );
    await p.storage.addFoodBatch([food('concurrent', first)]);
    await expectLater(apply(b, after), throwsStateError);
    expect((await p.storage.getFoodEntries(second)).single.amountGrams, 100);
  });

  test('snapshot cannot expand beyond limit before a proposed write', () {
    final many = List.generate(60, (i) => food('id$i', first));
    final range = FoodRangeSnapshot(
      firstDay: first,
      lastDay: second,
      entries: many,
    );
    expect(
      () => range.afterReviewedDay(
        date: second,
        changes: {},
        additions: [food('new', second)],
      ),
      throwsArgumentError,
    );
  });
}
