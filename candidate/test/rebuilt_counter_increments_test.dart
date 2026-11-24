// Regression: rapid counter increments must accumulate, not overwrite each
// other with a stale absolute snapshot. Synthetic data only.
import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final date = DateTime.parse('2026-11-24');
  const waterKey = 'water_intake_2026-11-24';
  const stepsKey = 'steps_2026-11-24';

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SmartRemote.instance.busy = false;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    SmartRemote.instance.busy = false;
    LocalPreferences.memoryForTests = false;
  });

  Future<List<AppDataProvider>> twoViews() async {
    final first = AppDataProvider();
    await first.init();
    final second = AppDataProvider();
    await second.init();
    return [first, second];
  }

  test('sequential increments total 750 ml', () async {
    final views = await twoViews();
    await views[0].addWater(250);
    await views[0].addWater(250);
    await views[0].addWater(250);
    expect(views[0].storage.local.getInt(waterKey), 750);
  });

  test('three concurrent water increments from two views total 750 ml', () async {
    final views = await twoViews();
    await Future.wait([
      views[0].addWater(250),
      views[1].addWater(250),
      views[0].addWater(250),
    ]);
    expect(views[0].storage.local.getInt(waterKey), 750);
    for (final view in views) {
      expect(view.todayWaterIntake, 750);
      await view.refresh();
      expect(view.todayWaterIntake, 750);
    }
  });

  test('three concurrent step increments from two views total 750 steps',
      () async {
    final views = await twoViews();
    await Future.wait([
      views[0].addSteps(250),
      views[1].addSteps(250),
      views[0].addSteps(250),
    ]);
    expect(views[0].storage.local.getInt(stepsKey), 750);
    for (final view in views) {
      expect(view.todaySteps, 750);
      await view.refresh();
      expect(view.todaySteps, 750);
    }
  });

  test('an explicit set still wins over earlier increments', () async {
    final views = await twoViews();
    await Future.wait([
      views[0].addWater(250),
      views[0].addWater(500),
      views[0].setWaterIntake(500),
    ]);
    expect(views[0].storage.local.getInt(waterKey), 500);
  });
}
