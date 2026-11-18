import 'dart:convert';
import 'dart:io';
import 'package:fitness_tracker/main.dart';
import 'package:fitness_tracker/smart/gym_models.dart';
import 'package:fitness_tracker/smart/gym_plan.dart';
import 'package:fitness_tracker/smart/gym_ui.dart' show gymNumber, gymClock;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

GymSet setRow(
  String name,
  int index, {
  int? reps,
  int? seconds,
  double? weight,
  String mode = 'unknown',
  bool test = false,
}) => GymSet(
  index: index,
  recordedAt: DateTime.utc(2026, 10, 25, 9),
  exerciseName: name,
  reps: reps,
  seconds: seconds,
  weightKg: weight,
  pullupMode: mode,
  isTest: test,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t = DateTime.utc(2026, 10, 25, 9);

  test(
    'Complete seven-day template includes all five pull-up days and optional Sunday test',
    () {
      final days = gymPlan();
      expect(days.map((d) => d.id).toList(), [
        'mon',
        'tue',
        'wed',
        'thu',
        'fri',
        'sat',
        'sun',
      ]);
      expect(
        days
            .where(
              (d) => d.blocks
                  .expand((b) => b.exercises)
                  .any((e) => isPullupName(e.name)),
            )
            .map((d) => d.id),
        ['mon', 'tue', 'wed', 'thu', 'fri', 'sun'],
      );
      expect(gymDay('mon').blocks.single.exercises.single.targets, [
        '8',
        '6',
        '6',
        '5',
        '4',
      ]);
      expect(gymDay('tue').blocks[1].exercises[1].plannedSets, 3);
      expect(gymDay('wed').blocks.single.exercises.single.plannedSets, 2);
      expect(gymDay('thu').blocks.last.exercises.single.plannedSets, 2);
      expect(gymDay('fri').blocks.first.exercises.first.plannedSets, 3);
      expect(gymDay('sun').blocks.where((b) => b.optional).length, 2);
      expect(gymDay('sun').blocks[1].exercises.single.isTest, isTrue);
      expect(gymDay('sat').cardioPlan, contains('24 мин'));
    },
  );

  test(
    'Specific rest ranges and unequal pairs are preserved, no phantom set',
    () {
      final b = gymDay('thu').blocks.firstWhere((x) => x.id == 'B');
      expect((b.restMinSeconds, b.restMaxSeconds), (90, 90));
      expect((b.exercises[0].plannedSets, b.exercises[1].plannedSets), (2, 3));
      for (var i = 1; i <= 2; i++) {
        expect(b.nextRound(), i);
        expect(b.nextExercise()!.id, 'B1');
        b.exercises[0].sets.add(setRow(b.exercises[0].name, i, reps: 12));
        expect(b.nextExercise()!.id, 'B2');
        b.exercises[1].sets.add(setRow(b.exercises[1].name, i, reps: 15));
      }
      expect(b.nextRound(), 3);
      expect(b.nextExercise()!.id, 'B2');
      b.exercises[1].sets.add(setRow(b.exercises[1].name, 3, reps: 15));
      expect(b.nextExercise(), isNull);
      final sunB = gymDay('sun').blocks.firstWhere((x) => x.id == 'B');
      expect(
        (sunB.exercises[0].plannedSets, sunB.exercises[1].plannedSets),
        (3, 2),
      );
    },
  );

  test(
    'Template is snapshotted per session and substitutions keep actual historical name',
    () {
      final s = gymDay('tue').start('abc_1', t);
      final exercise = s.exercise('B', 'B2');
      exercise.sets.add(
        setRow(
          'Подтягивания лёгкие',
          1,
          reps: 8,
          mode: 'bodyweight',
          weight: 0,
        ),
      );
      exercise.name = 'Тяга верхнего блока (лёгкая)';
      exercise.sets.add(setRow(exercise.name, 2, reps: 10, weight: 25));
      final copy = s.clone();
      expect(
        copy.exercise('B', 'B2').sets.first.exerciseName,
        'Подтягивания лёгкие',
      );
      expect(copy.allSets.where((x) => x.isPullup).length, 1);
      expect(gymDay('tue').blocks[1].exercises[1].name, 'Подтягивания лёгкие');
    },
  );

  test(
    'Rest uses wall-clock deadlines; pause, adjust, restore and finish are accurate',
    () {
      final s = gymDay('tue').start('timer', t);
      s.startRest(t, 150, 'A');
      var copy = s.clone();
      expect(copy.restRemainingAt(t.add(const Duration(seconds: 40))), 110);
      copy.pauseSession(t.add(const Duration(seconds: 45)));
      expect(copy.elapsedBaseSeconds, 45);
      expect(copy.restPausedSeconds, 105);
      expect(copy.restRemainingAt(t.add(const Duration(hours: 1))), 105);
      copy.adjustRest(t, -15);
      expect(copy.restPausedSeconds, 90);
      copy.resumeSession(t.add(const Duration(hours: 1)));
      copy.resumeRest(t.add(const Duration(hours: 1)));
      expect(
        copy.restRemainingAt(t.add(const Duration(hours: 1, seconds: 60))),
        30,
      );
      expect(copy.restRemainingAt(t.add(const Duration(hours: 2))), 0);
      copy.finish(t.add(const Duration(hours: 1, seconds: 60)));
      expect(copy.elapsedBaseSeconds, 105);
      expect(copy.completed, isTrue);
      expect(copy.restDeadline, isNull);
      expect(copy.clone().running, isFalse);
    },
  );

  test(
    'Intervals progress through eight 1:2 cycles and survive pause/reload',
    () {
      final s = gymDay('sat').start('interval', t);
      s.startIntervals(t);
      expect(s.intervalElapsedAt(t.add(const Duration(seconds: 59))), 59);
      expect(s.intervalElapsedAt(t.add(const Duration(seconds: 60))), 60);
      expect(
        s.clone().intervalElapsedAt(t.add(const Duration(seconds: 181))),
        181,
      );
      s.pauseIntervals(t.add(const Duration(seconds: 68)));
      expect(s.clone().intervalElapsedAt(t.add(const Duration(hours: 2))), 68);
      s.resumeIntervals(t.add(const Duration(hours: 2)));
      expect(
        s.intervalElapsedAt(t.add(const Duration(hours: 2, seconds: 10))),
        78,
      );
      expect(s.intervalElapsedAt(t.add(const Duration(hours: 3))), 1440);
      s.finish(t.add(const Duration(hours: 3)));
      expect(s.clone().intervalResumedAt, isNull);
      expect(
        s.clone().intervalElapsedAt(t.add(const Duration(hours: 4))),
        1440,
      );
    },
  );

  test(
    'Known volume excludes unknown weights, body weight and machine assistance',
    () {
      final s = gymDay('fri').start('volume', t);
      final bench = s.exercise('A', 'A2'), pull = s.exercise('A', 'A1');
      bench.sets.addAll([
        setRow(bench.name, 1, reps: 8, weight: 30),
        setRow(bench.name, 2, reps: 10),
      ]);
      pull.sets.addAll([
        setRow(pull.name, 1, reps: 8, weight: 0, mode: 'bodyweight'),
        setRow(pull.name, 2, reps: 6, weight: 10, mode: 'weighted'),
        setRow(pull.name, 3, reps: 12, weight: 20, mode: 'assisted'),
        setRow(pull.name, 4, reps: 9, weight: 10, mode: 'unknown'),
      ]);
      expect(s.setCount, 6);
      expect(s.knownReps, 53);
      expect(s.volumeRows.length, 3);
      expect(s.externalVolumeKg, 300);
    },
  );

  test('Test results compare only explicit bodyweight technical tests', () {
    expect(
      setRow(
        'Подтягивания',
        1,
        reps: 12,
        mode: 'bodyweight',
        test: true,
      ).isComparableTest,
      isTrue,
    );
    expect(
      setRow(
        'Подтягивания',
        1,
        reps: 12,
        mode: 'assisted',
        test: true,
      ).isComparableTest,
      isFalse,
    );
    expect(
      setRow(
        'Подтягивания',
        1,
        reps: 12,
        mode: 'weighted',
        test: true,
      ).isComparableTest,
      isFalse,
    );
    expect(
      setRow(
        'Подтягивания',
        1,
        reps: 12,
        mode: 'unknown',
        test: true,
      ).isComparableTest,
      isFalse,
    );
    expect(
      setRow(
        'Тяга верхнего блока',
        1,
        reps: 12,
        mode: 'bodyweight',
        test: true,
      ).isComparableTest,
      isFalse,
    );
  });

  test('Display preserves decimal load and formats countdown', () {
    expect(gymNumber(1.25), '1.25');
    expect(gymNumber(30.0), '30');
    expect(gymClock(150), '2:30');
    expect(gymClock(3602), '1:00:02');
  });

  test(
    'Calendar cycle ignores time-of-day and DST; future start is not invented',
    () {
      expect(cycleWeek(DateTime(2026, 10, 19), DateTime(2026, 10, 25)), 1);
      expect(cycleWeek(DateTime(2026, 10, 19), DateTime(2026, 11, 23)), 6);
      expect(cycleWeek(DateTime(2026, 11, 2), DateTime(2026, 10, 25)), isNull);
    },
  );

  test(
    'Reject malformed, duplicate, invalid or oversized untrusted documents',
    () {
      final s = gymDay('tue').start('safe', t);
      final doc = s.toJson();
      expect(
        () => validateGymDocument('gym_session_other', jsonEncode(doc)),
        throwsFormatException,
      );
      expect(
        () => validateGymDocument(
          'gym_session_safe',
          jsonEncode({...doc, 'planDay': 'oops'}),
        ),
        throwsFormatException,
      );
      expect(
        () => validateGymDocument('gym_session_safe', 'x' * 1000001),
        throwsFormatException,
      );
      expect(
        () => GymSet.fromJson(
          setRow(
            'Подтягивания',
            1,
            reps: 1,
            mode: 'bodyweight',
            weight: 4,
          ).toJson(),
        ),
        throwsFormatException,
      );
      expect(
        () => GymSet.fromJson(setRow('Жим', 1).toJson()),
        throwsFormatException,
      );
      final b = (doc['blocks'] as List).first as Map<String, dynamic>;
      final e = (b['exercises'] as List).first as Map<String, dynamic>;
      e['sets'] = [
        setRow('Жим лёжа', 1, reps: 8).toJson(),
        setRow('Жим лёжа', 1, reps: 9).toJson(),
      ];
      expect(
        () => validateGymDocument('gym_session_safe', jsonEncode(doc)),
        throwsFormatException,
      );
    },
  );

  test(
    'Weekly checks preserve cycle and other weeks; invalid imports are rejected',
    () {
      final firstWeek = DateTime(2026, 10, 26, 23, 30);
      final nextWeek = DateTime(2026, 11, 2);
      const initial = '{"version":1,"cycleStart":"2026-10-26"}';
      final a = gymSetWeekCheck(initial, firstWeek, 'recovery', true);
      final b = gymSetWeekCheck(a, firstWeek, 'liss', true);
      final c = gymSetWeekCheck(b, nextWeek, 'journal', true);
      expect(jsonDecode(c)['cycleStart'], '2026-10-26');
      expect(gymWeekChecks(c, firstWeek), {'recovery': true, 'liss': true});
      expect(gymWeekChecks(c, nextWeek), {'journal': true});
      final d = gymSetWeekCheck(c, firstWeek, 'recovery', false);
      expect(gymWeekChecks(d, firstWeek), {'liss': true});
      expect(gymWeekChecks(d, nextWeek), {'journal': true});
      expect(
        () => gymSetWeekCheck(d, firstWeek, 'other', true),
        throwsFormatException,
      );
      for (final invalid in [
        {
          '2026-10-27': {'recovery': true},
        }, // Tuesday is not a week key.
        {
          '2026-10-26': {'other': true},
        },
        {
          '2026-10-26': {'liss': 'true'},
        },
      ]) {
        expect(
          () => validateGymDocument(
            gymSettingsKey,
            jsonEncode({'version': 1, 'weeklyChecks': invalid}),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('Forward migration changes only non-retryable CAS conflict codes', () {
    String withoutComments(String path) => File(path)
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('--'))
        .join('\n');
    final previous = withoutComments(
      'supabase/migrations/20261029130000_gym_documents.sql',
    );
    final forward = withoutComments(
      'supabase/migrations/20261030130000_document_conflict_http409.sql',
    );
    expect(previous.split("'40001'").length - 1, 2);
    expect(forward, previous.replaceAll("'40001'", "'PT409'"));
    expect(forward, contains('revoke all on function'));
    expect(forward, contains('to authenticated'));
  });

  for (final code in ['PT409', '40001']) {
    test(
      'Sync handles $code conflicts without overwriting local gym data',
      () async {
        LocalPreferences.memoryForTests = true;
        SharedPreferences.setMockInitialValues({});
        final p = AppDataProvider();
        await p.init();
        final s = gymDay('tue').start('conflict_$code', t);
        final key = '$gymSessionPrefix${s.id}', raw = jsonEncode(s.toJson());
        await p.storage.writeGymDocument(key, null, raw);
        final fake = MockClient((request) async {
          if (request.url.path.endsWith('/fitness_sleep_documents')) {
            return http.Response(
              jsonEncode({'code': 'PGRST205', 'message': 'Table not present'}),
              404,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          if (request.url.path.endsWith('/fitness_documents')) {
            return http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          if (request.url.path.endsWith('/rpc/write_fitness_document')) {
            return http.Response(
              jsonEncode({
                'code': code,
                'message': 'Concurrent document change',
              }),
              409,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return http.Response('Unexpected request', 500, request: request);
        });
        final client = SupabaseClient(
          'https://sync.test.invalid',
          'test-public',
          httpClient: fake,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        await client.auth.setInitialSession(
          jsonEncode({
            'access_token': 'fake',
            'token_type': 'bearer',
            'user': {
              'id': 'mock-account',
              'aud': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-10-25T00:00:00Z',
            },
          }),
        );
        SmartRemote.instance.client = client;
        try {
          await SmartRemote.instance.sync(
            p.storage.local,
            validate: validateAppDocument,
          );
          expect(
            SmartRemote.instance.status,
            contains('Конкурентное изменение'),
          );
          expect(p.storage.local.getString(key), raw);
        } finally {
          SmartRemote.instance.client = null;
          await client.dispose();
          fake.close();
          p.dispose();
        }
      },
    );
  }

  test(
    'Per-session CAS, failure safety, backup/import and old data preservation',
    () async {
      LocalPreferences.memoryForTests = true;
      LocalPreferences.rejectWriteKeyForTests = null;
      SharedPreferences.setMockInitialValues({});
      final p = AppDataProvider();
      await p.init();
      try {
        final store = p.storage;
        final s = gymDay('tue').start('store_1', t);
        final key = '$gymSessionPrefix${s.id}', raw = jsonEncode(s.toJson());
        expect(LocalPreferences.appKey(key), isTrue);
        expect(LocalPreferences.appKey('gym_session_bad/xx'), isFalse);
        await store.local.setInt('water_intake_2026-10-25', 250);
        await store.writeGymDocument(key, null, raw);
        final changed = s.clone();
        changed
            .exercise('A', 'A1')
            .sets
            .add(setRow('Жим лёжа', 1, reps: 8, weight: 30));
        final raw2 = jsonEncode(changed.toJson());
        await store.writeGymDocument(key, raw, raw2);
        await expectLater(
          store.writeGymDocument(key, raw, null),
          throwsStateError,
        );
        expect(store.local.getString(key), raw2);
        LocalPreferences.rejectWriteKeyForTests = key;
        await expectLater(
          store.writeGymDocument(key, raw2, raw),
          throwsStateError,
        );
        expect(store.local.getString(key), raw2);
        LocalPreferences.rejectWriteKeyForTests = null;
        final weekly = gymSetWeekCheck(null, t, 'recovery', true);
        await store.writeGymDocument(gymSettingsKey, null, weekly);
        final backup = await store.exportData();
        expect((backup['data'] as Map)[key], raw2);
        expect((backup['data'] as Map)[gymSettingsKey], weekly);
        expect(await store.importData(backup), isTrue);
        expect(store.local.getString(key), raw2);
        expect(
          gymWeekChecks(store.local.getString(gymSettingsKey), t)['recovery'],
          isTrue,
        );
        expect(store.local.getInt('water_intake_2026-10-25'), 250);
        await store.writeGymDocument(key, raw2, null);
        expect(store.local.getString(key), isNull);
      } finally {
        LocalPreferences.rejectWriteKeyForTests = null;
        p.dispose();
      }
    },
  );
}
