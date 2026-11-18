// Synthetic tests only. No real diary, account, server or deployment is used.
import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/csv_reader.dart';
import 'package:fitness_tracker/smart/engine.dart' show exportCsv;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/sleep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const water = 'water_intake_2026-10-25';
  const steps = 'steps_2026-10-25';

  // StorageService is a singleton: this deliberately runs before its first
  // initialization in this separate test process.
  test('an unopened store is not exported as an empty diary', () async {
    await expectLater(StorageService().exportData(), throwsStateError);
  });

  group('snapshot export', () {
    late AppDataProvider provider;
    setUp(() async {
      LocalPreferences.memoryForTests = true;
      LocalPreferences.directoryForTests = null;
      LocalPreferences.beforeWriteForTests = null;
      LocalPreferences.rejectWriteKeyForTests = null;
      LocalPreferences.onAppWrite = null;
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.busy = false;
      SharedPreferences.setMockInitialValues({});
      provider = AppDataProvider();
      await provider.init();
    });
    tearDown(() {
      LocalPreferences.beforeWriteForTests = null;
      LocalPreferences.rejectWriteKeyForTests = null;
      LocalPreferences.onAppWrite = null;
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.busy = false;
      provider.dispose();
      LocalPreferences.memoryForTests = false;
    });

    test('unknown value is not silently omitted from a backup', () async {
      final local = provider.storage.local;
      await local.setInt(steps, 100);
      await local.put(water, {'unexpected': 'synthetic'});
      final before = local.snapshot();
      await expectLater(provider.storage.exportData(), throwsStateError);
      expect(local.snapshot(), before);
    });

    test('non-finite number fails before offering JSON or CSV', () async {
      final local = provider.storage.local;
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        await local.setDouble(water, value);
        await expectLater(provider.storage.exportData(), throwsStateError);
        expect((local.get(water) as double).isFinite, isFalse);
      }
    });

    test(
      'string lists are included by value, including dynamically typed lists',
      () async {
        final local = provider.storage.local;
        final dynamicList = <Object>['один', 'два'];
        await local.put('quick_foods', dynamicList);
        final exported = await provider.storage.exportData();
        expect((exported['data'] as Map)['quick_foods'], ['один', 'два']);
        dynamicList.add('три');
        expect((exported['data'] as Map)['quick_foods'], ['один', 'два']);
      },
    );

    test(
      'pending import is not represented as a normal completed backup',
      () async {
        final local = provider.storage.local;
        await local.setInt(water, 250);
        final previous = jsonEncode({
          'version': 1,
          'data': {water: 500},
        });
        await local.setString(
          LocalPreferences.importJournalKey,
          'P1:$previous',
        );
        expect(local.hasPendingImport, isTrue);
        await expectLater(
          provider.storage.exportData(),
          throwsA(isA<ImportRecoveryRequired>()),
        );
        final recovery =
            jsonDecode(provider.storage.importBackupJson()!) as Map;
        expect(recovery['data'], {water: 500});
        expect(local.getInt(water), 250);
      },
    );

    test(
      'running cloud synchronization prevents a mixed local export',
      () async {
        final local = provider.storage.local;
        await local.setInt(water, 250);
        SmartRemote.instance.busy = true;
        await expectLater(provider.storage.exportData(), throwsStateError);
        expect(local.getInt(water), 250);
        SmartRemote.instance.busy = false;
        expect((await provider.storage.exportData())['data'], {water: 250});
      },
    );

    test('export waits for an earlier direct local write to finish', () async {
      final local = provider.storage.local;
      await local.setInt(water, 250);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final writing = local.setInt(water, 500);
      await started.future;
      var finished = false;
      final exporting = provider.storage.exportData().then((value) {
        finished = true;
        return value;
      });
      try {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(finished, isFalse);
        release.complete();
        expect(await writing, isTrue);
        final copy = await exporting;
        expect((copy['data'] as Map)[water], 500);
      } finally {
        if (!release.isCompleted) release.complete();
        await writing;
        await exporting;
      }
    });

    test(
      'export orders after a queued diary write and excludes private keys',
      () async {
        final local = provider.storage.local;
        await local.setString('_ai_consent_synthetic', 'private');
        await local.setString('_voice_notice_v1', 'private');
        final day = DateTime(2026, 10, 25);
        final write = provider.storage.setWaterIntake(day, 750);
        final backup = provider.storage.exportData();
        await write;
        final data = (await backup)['data'] as Map;
        expect(data, {water: 750});
        expect(jsonEncode(data), isNot(contains('private')));
      },
    );

    test(
      'export waits for import replacement and refuses stale generation',
      () async {
        final local = provider.storage.local;
        await local.setInt(water, 250);
        final started = Completer<void>(), release = Completer<void>();
        LocalPreferences.beforeWriteForTests = (key) async {
          if (key == water && !started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        final importing = provider.storage.importData({
          'data': {water: 500},
        });
        await started.future;
        final rejected = expectLater(
          provider.storage.exportData(),
          throwsStateError,
        );
        release.complete();
        expect(await importing, isTrue);
        await rejected;
        expect((await provider.storage.exportData())['data'], {water: 500});
      },
    );

    test('export waits for clear and refuses a stale generation', () async {
      final local = provider.storage.local;
      await local.setInt(water, 250);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final clearing = provider.storage.clearAll();
      await started.future;
      final rejected = expectLater(
        provider.storage.exportData(),
        throwsStateError,
      );
      release.complete();
      await clearing;
      await rejected;
      expect((await provider.storage.exportData())['data'], isEmpty);
    });

    test('a failed import rolls back before a new export', () async {
      final local = provider.storage.local;
      await local.setInt(water, 250);
      var rejectedNew = false;
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == steps && !rejectedNew) {
          rejectedNew = true;
          throw StateError('synthetic replacement failure');
        }
      };
      await expectLater(
        provider.storage.importData({
          'data': {water: 500, steps: 1234},
        }),
        throwsStateError,
      );
      LocalPreferences.beforeWriteForTests = null;
      expect(local.hasPendingImport, isFalse);
      expect((await provider.storage.exportData())['data'], {water: 250});
    });

    test(
      'out-of-range integers cannot silently lose browser precision',
      () async {
        final local = provider.storage.local;
        for (final value in [
          9007199254740992,
          -9007199254740992,
          -9223372036854775808,
        ]) {
          await local.setInt(water, value);
          await expectLater(provider.storage.exportData(), throwsStateError);
          expect(local.get(water), value);
        }
        await local.setInt(water, 9007199254740991);
        expect((await provider.storage.exportData())['data'], {
          water: 9007199254740991,
        });
      },
    );

    test(
      'new direct writes arriving during drain are included before capture',
      () async {
        final local = provider.storage.local;
        await local.setInt(water, 250);
        await local.setInt(steps, 100);
        final startedWater = Completer<void>(),
            releaseWater = Completer<void>();
        final startedSteps = Completer<void>(),
            releaseSteps = Completer<void>();
        LocalPreferences.beforeWriteForTests = (key) async {
          if (key == water && !startedWater.isCompleted) {
            startedWater.complete();
            await releaseWater.future;
          } else if (key == steps && !startedSteps.isCompleted) {
            startedSteps.complete();
            await releaseSteps.future;
          }
        };
        final writeWater = local.setInt(water, 500);
        await startedWater.future;
        var finished = false;
        final exporting = provider.storage.exportData().then((value) {
          finished = true;
          return value;
        });
        await Future<void>.delayed(Duration.zero);
        final writeSteps = local.setInt(steps, 200);
        try {
          await startedSteps.future;
          releaseWater.complete();
          await writeWater;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(finished, isFalse);
          releaseSteps.complete();
          await writeSteps;
          expect((await exporting)['data'], {water: 500, steps: 200});
        } finally {
          if (!releaseWater.isCompleted) releaseWater.complete();
          if (!releaseSteps.isCompleted) releaseSteps.complete();
          await Future.wait([writeWater, writeSteps]);
          await exporting;
        }
      },
    );

    test('a failed direct write is not exported as if it committed', () async {
      final local = provider.storage.local;
      await local.setInt(water, 250);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == water) {
          started.complete();
          await release.future;
          throw StateError('synthetic failed write');
        }
      };
      final rejected = expectLater(local.setInt(water, 500), throwsStateError);
      await started.future;
      final exporting = provider.storage.exportData();
      release.complete();
      await rejected;
      expect((await exporting)['data'], {water: 250});
      expect(local.getInt(water), 250);
    });

    test('a multi-document weight update finishes before export', () async {
      final local = provider.storage.local;
      await provider.storage.addWeightEntry(
        WeightEntry(
          id: 'synthetic-old',
          weight: 80,
          date: DateTime(2026, 10, 24),
        ),
      );
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == 'user_profile' && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final updating = provider.storage.addWeightEntry(
        WeightEntry(
          id: 'synthetic-new',
          weight: 79,
          date: DateTime(2026, 10, 25),
        ),
      );
      await started.future;
      var finished = false;
      final exporting = provider.storage.exportData().then((value) {
        finished = true;
        return value;
      });
      try {
        expect(
          (jsonDecode(local.getString('weight_entries')!) as List),
          hasLength(2),
        );
        expect(
          (jsonDecode(local.getString('user_profile')!)
              as Map)['currentWeight'],
          80,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(finished, isFalse);
        release.complete();
        await updating;
        final data = (await exporting)['data'] as Map;
        expect(
          (jsonDecode(data['weight_entries'] as String) as List),
          hasLength(2),
        );
        expect(
          (jsonDecode(data['user_profile'] as String) as Map)['currentWeight'],
          79,
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await updating;
        await exporting;
      }
    });

    test('sync starting while writes drain rejects the snapshot', () async {
      final local = provider.storage.local;
      await local.setInt(water, 250);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final writing = local.setInt(water, 500);
      await started.future;
      final rejected = expectLater(
        provider.storage.exportData(),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      SmartRemote.instance.busy = true;
      release.complete();
      await writing;
      await rejected;
      SmartRemote.instance.busy = false;
      expect((await provider.storage.exportData())['data'], {water: 500});
    });

    test(
      'an empty CSV export cannot be offered as a restorable backup',
      () async {
        expect((await provider.storage.exportData())['data'], isEmpty);
        expect(() => exportCsv({}), throwsFormatException);
      },
    );

    test(
      'normal JSON and CSV preserve valid synthetic documents and privacy',
      () async {
        final local = provider.storage.local;
        final date = DateTime(2026, 10, 25, 12);
        await provider.storage.setWaterIntake(
          date,
          0,
        ); // explicit zero, not absent
        await provider.storage.setSteps(date, 1234);
        await provider.storage.addFoodEntry(
          FoodEntry(
            id: 'synthetic-food',
            name: 'Синтетическая еда',
            caloriesPer100g: 101.25,
            proteinPer100g: 3,
            fatPer100g: 4,
            carbsPer100g: 5,
            amountGrams: 125.5,
            mealType: MealType.lunch,
            date: date,
          ),
        );
        await provider.updateProfile(provider.profile.copyWith(ageYears: 18));
        await provider.storage.writeSleepDocument(
          'sleep_day_2026-10-25',
          null,
          encodeSleepDay(const SleepDay(day: '2026-10-25', minutes: 420)),
        );
        await local.setString(
          '_ai_consent_synthetic',
          'private-not-for-export',
        );
        final payload = await provider.storage.exportData();
        final data = Map<String, dynamic>.from(payload['data'] as Map);
        final jsonRoundTrip = jsonDecode(jsonEncode(payload)) as Map;
        final csvRoundTrip = importCsv(exportCsv(data));
        expect(jsonRoundTrip['data'], data);
        expect(csvRoundTrip, data);
        expect(data[water], 0);
        expect(data[steps], 1234);
        expect(
          (jsonDecode(data['user_profile'] as String) as Map)['ageYears'],
          18,
        );
        expect(data['sleep_day_2026-10-25'], isNotNull);
        expect(jsonEncode(payload), isNot(contains('private-not-for-export')));
        expect(
          await provider.storage.importData(
            Map<String, dynamic>.from(jsonRoundTrip),
          ),
          isTrue,
        );
        expect(local.snapshot(), data);
        expect(
          local.getString('_ai_consent_synthetic'),
          'private-not-for-export',
        );
      },
    );
  });
}
