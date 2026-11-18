// Synthetic-only tests. The cloud is a MockClient, not Supabase or a real diary.
import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/sleep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sleep_sync_test.dart' show FakeCloud, session;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const user = 'synthetic-review-user';
  const water = 'water_intake_2026-10-25';
  const sleep = 'sleep_day_2026-10-25';
  final remote = SmartRemote.instance;
  late LocalPreferences local;
  late FakeCloud cloud;
  late SupabaseClient client;
  late MockClient transport;
  var targetedReads = 0;
  var failTargetedRead = false;
  Future<void> Function()? duringTargetedRead;
  List<Map<String, dynamic>>? forcedTargetRows;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    SharedPreferences.setMockInitialValues({});
    local = await LocalPreferences.open();
    cloud = FakeCloud();
    targetedReads = 0;
    failTargetedRead = false;
    duringTargetedRead = null;
    forcedTargetRows = null;
    transport = MockClient((request) async {
      final target =
          request.method == 'GET' &&
          (request.url.path.endsWith('/fitness_documents') ||
              request.url.path.endsWith('/fitness_sleep_documents')) &&
          request.url.queryParameters.containsKey('key');
      if (!target) return cloud.handle(request);
      targetedReads++;
      if (request.url.queryParameters['user_id'] != 'eq.$user') {
        throw StateError('Targeted read did not constrain the synthetic owner');
      }
      await duringTargetedRead?.call();
      if (failTargetedRead) {
        return cloud.reply(request, {
          'code': 'XX000',
          'message': 'Synthetic cloud unavailable',
        }, 503);
      }
      if (forcedTargetRows != null) {
        return cloud.reply(request, forcedTargetRows!, 200);
      }
      // Simulate the PostgREST key filter, including absent rows and tombstones.
      final filter = request.url.queryParameters['key']!;
      if (!filter.startsWith('eq.')) throw StateError('Unexpected filter');
      final key = filter.substring(3);
      final rows = request.url.path.endsWith('/fitness_sleep_documents')
          ? cloud.sleepRows
          : cloud.oldRows;
      final row = rows[key];
      return cloud.reply(request, row == null ? [] : [row], 200);
    });
    client = SupabaseClient(
      'https://synthetic-review.test.invalid',
      'synthetic-public',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
    );
    await client.auth.setInitialSession(session(user));
    remote.client = client;
    remote.conflicts.clear();
    await local.setString('_bound_user', user);
  });

  tearDown(() async {
    remote.unbindLocalForTests();
    remote.client = null;
    remote.conflicts.clear();
    LocalPreferences.onAppWrite = null;
    LocalPreferences.beforeWriteForTests = null;
    await client.dispose();
    transport.close();
    LocalPreferences.memoryForTests = false;
  });

  Future<SyncConflict> waterConflict({
    Object? shownRemote = 500,
    int revision = 1,
  }) async {
    await local.setInt(water, 250);
    await local.setString('_baseline_$user', jsonEncode({water: 100}));
    final conflict = SyncConflict(water, 250, shownRemote, revision);
    remote.conflicts.add(conflict);
    return conflict;
  }

  Future<void> chooseCloud(SyncConflict conflict) =>
      remote.resolve(local, conflict, false, validate: validateAppDocument);

  void expectWaterUnchanged(SyncConflict conflict) {
    expect(local.getInt(water), 250);
    expect(jsonDecode(local.getString('_baseline_$user')!)[water], 100);
    expect(remote.conflicts, contains(conflict));
  }

  test(
    'newer cloud revision must not replace local data using stale choice',
    () async {
      final conflict = await waterConflict();
      cloud.oldRows[water] = {'key': water, 'payload': 750, 'revision': 2};
      await expectLater(chooseCloud(conflict), throwsStateError);
      expectWaterUnchanged(conflict);
      expect(cloud.oldRows[water]!['payload'], 750);
      expect(targetedReads, 1);
    },
  );

  test('equal cloud payload with newer revision is still stale', () async {
    final conflict = await waterConflict();
    cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 2};
    await expectLater(chooseCloud(conflict), throwsStateError);
    expectWaterUnchanged(conflict);
  });

  test(
    'changed payload at the same revision is rejected conservatively',
    () async {
      final conflict = await waterConflict();
      cloud.oldRows[water] = {'key': water, 'payload': 800, 'revision': 1};
      await expectLater(chooseCloud(conflict), throwsStateError);
      expectWaterUnchanged(conflict);
    },
  );

  test(
    'missing formerly present row is not mistaken for the reviewed value',
    () async {
      final conflict = await waterConflict();
      await expectLater(chooseCloud(conflict), throwsStateError);
      expectWaterUnchanged(conflict);
    },
  );

  test(
    'a failed cloud recheck retains local value and unresolved conflict',
    () async {
      final conflict = await waterConflict();
      cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
      failTargetedRead = true;
      await expectLater(
        chooseCloud(conflict),
        throwsA(isA<PostgrestException>()),
      );
      expectWaterUnchanged(conflict);
    },
  );

  test('unchanged reviewed cloud revision remains selectable', () async {
    final conflict = await waterConflict();
    cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
    await chooseCloud(conflict);
    expect(targetedReads, 1);
    expect(local.getInt(water), 500);
    expect(jsonDecode(local.getString('_baseline_$user')!)[water], 500);
    expect(remote.conflicts, isEmpty);
    expect(cloud.oldRows[water]!['revision'], 1);
  });

  test(
    'a reviewed absent row can be chosen only while it remains absent',
    () async {
      final conflict = await waterConflict(shownRemote: null, revision: 0);
      await chooseCloud(conflict);
      expect(targetedReads, 1);
      expect(local.getInt(water), isNull);
      expect(remote.conflicts, isEmpty);
    },
  );

  test('a reviewed tombstone is different from an absent row', () async {
    final conflict = await waterConflict(shownRemote: null, revision: 4);
    await expectLater(chooseCloud(conflict), throwsStateError);
    expectWaterUnchanged(conflict);
    cloud.oldRows[water] = {'key': water, 'payload': null, 'revision': 4};
    await chooseCloud(conflict);
    expect(local.getInt(water), isNull);
    expect(remote.conflicts, isEmpty);
  });

  test(
    'sleep conflict uses the sleep table and rejects a newer revision',
    () async {
      String value(int minutes) =>
          encodeSleepDay(SleepDay(day: '2026-10-25', minutes: minutes));
      final device = value(420), shown = value(480), newer = value(510);
      await local.setString(sleep, device);
      final conflict = SyncConflict(sleep, device, shown, 1);
      remote.conflicts.add(conflict);
      cloud.sleepRows[sleep] = {'key': sleep, 'payload': newer, 'revision': 2};
      await expectLater(chooseCloud(conflict), throwsStateError);
      expect(local.getString(sleep), device);
      expect(cloud.sleepRows[sleep]!['payload'], newer);
      expect(remote.conflicts, contains(conflict));
      expect(targetedReads, 1);
    },
  );

  test(
    'new cloud row invalidates an earlier choice of an absent row',
    () async {
      final conflict = await waterConflict(shownRemote: null, revision: 0);
      cloud.oldRows[water] = {'key': water, 'payload': null, 'revision': 1};
      await expectLater(chooseCloud(conflict), throwsStateError);
      expectWaterUnchanged(conflict);
    },
  );

  test('malformed, unexpected, and duplicate cloud rows fail closed', () async {
    final conflict = await waterConflict();
    final malformed = <List<Map<String, dynamic>>>[
      [
        {'key': water, 'revision': 1},
      ],
      [
        {'key': water, 'payload': 500, 'revision': '1'},
      ],
      [
        {'key': water, 'payload': 500, 'revision': 0},
      ],
      [
        {'key': 'steps_2026-10-25', 'payload': 500, 'revision': 1},
      ],
      [
        {'key': water, 'payload': 500, 'revision': 1},
        {'key': water, 'payload': 500, 'revision': 1},
      ],
    ];
    for (final rows in malformed) {
      forcedTargetRows = rows;
      await expectLater(
        chooseCloud(conflict),
        throwsStateError,
        reason: '$rows',
      );
      expectWaterUnchanged(conflict);
    }
  });

  test(
    'a changed local document during the recheck is not overwritten',
    () async {
      final conflict = await waterConflict();
      cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
      final started = Completer<void>(), release = Completer<void>();
      duringTargetedRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      try {
        final resolving = chooseCloud(conflict);
        final result = resolving.then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await started.future.timeout(const Duration(seconds: 5));
        await local.setInt(water, 900);
        release.complete();
        expect(await result, isA<StateError>());
        expect(local.getInt(water), 900);
        expect(jsonDecode(local.getString('_baseline_$user')!)[water], 100);
        expect(remote.conflicts, contains(conflict));
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test(
    'account change during the recheck leaves the device untouched',
    () async {
      final conflict = await waterConflict();
      cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
      final started = Completer<void>(), release = Completer<void>();
      duringTargetedRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      try {
        final resolving = chooseCloud(conflict);
        final result = resolving.then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await started.future.timeout(const Duration(seconds: 5));
        await client.auth.setInitialSession(
          session('different-synthetic-user'),
        );
        release.complete();
        expect(await result, isA<StateError>());
        expectWaterUnchanged(conflict);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test('new comparison allows selecting the latest cloud revision', () async {
    final conflict = await waterConflict();
    cloud.oldRows[water] = {'key': water, 'payload': 750, 'revision': 2};
    await expectLater(chooseCloud(conflict), throwsStateError);
    await remote.sync(local, validate: validateAppDocument);
    final refreshed = remote.conflicts.single;
    expect(refreshed.remote, 750);
    expect(refreshed.revision, 2);
    await chooseCloud(refreshed);
    expect(local.getInt(water), 750);
    expect(jsonDecode(local.getString('_baseline_$user')!)[water], 750);
    expect(remote.conflicts, isEmpty);
  });

  test('RISK REPRODUCED: cloud can change after the freshness read', () async {
    final conflict = await waterConflict();
    cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
    final writeStarted = Completer<void>(), finishWrite = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water && !writeStarted.isCompleted) {
        writeStarted.complete();
        await finishWrite.future;
      }
    };
    try {
      final resolving = chooseCloud(conflict);
      await writeStarted.future.timeout(const Duration(seconds: 5));
      cloud.oldRows[water] = {'key': water, 'payload': 750, 'revision': 2};
      finishWrite.complete();
      await resolving;
      // This passing diagnostic asserts the remaining race, NOT safety.
      expect(local.getInt(water), 500);
      expect(cloud.oldRows[water]!['payload'], 750);
      expect(remote.conflicts, isEmpty);
    } finally {
      if (!finishWrite.isCompleted) finishWrite.complete();
    }
  });
}
