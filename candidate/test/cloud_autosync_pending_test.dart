// Synthetic-only synchronization timing checks; no network or real diary.
import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sleep_sync_test.dart' show FakeCloud, session;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const user = 'synthetic-busy-user';
  const water = 'water_intake_2026-10-25';
  const steps = 'steps_2026-10-25';
  final remote = SmartRemote.instance;
  late LocalPreferences local;
  late FakeCloud cloud;
  late MockClient transport;
  late SupabaseClient client;
  Future<void> Function(http.Request)? beforeCloudWrite;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.beforeWriteForTests = null;
    SharedPreferences.setMockInitialValues({});
    local = await LocalPreferences.open();
    cloud = FakeCloud();
    beforeCloudWrite = null;
    transport = MockClient((request) async {
      if (request.url.path.endsWith('/rpc/write_fitness_document')) {
        await beforeCloudWrite?.call(request);
      }
      return cloud.handle(request);
    });
    client = SupabaseClient(
      'https://synthetic-busy.test.invalid',
      'synthetic-public',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
    );
    await client.auth.setInitialSession(session(user));
    remote.client = client;
    remote.conflicts.clear();
    await local.setString('_bound_user', user);
    await local.setString('_baseline_$user', jsonEncode({water: 100}));
    await local.setInt(water, 250);
    cloud.oldRows[water] = {'key': water, 'payload': 100, 'revision': 1};
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

  Future<void> sync() => remote.sync(local, validate: validateAppDocument);

  test('a local edit after manual sync marks the diary as pending', () async {
    await sync();
    expect(remote.status, contains('Синхронизировано'));
    remote.bindLocal(local, validateAppDocument, () async {}, () async {});
    await local.setInt(water, 500);
    expect(remote.status, contains('локальн'));
    expect(remote.status, isNot(contains('Синхронизировано')));
    expect(cloud.oldRows[water]!['payload'], 250);
    await sync();
    expect(cloud.oldRows[water]!['payload'], 500);
    expect(remote.status, contains('Синхронизировано'));
  });

  test(
    'pending status retains the warning when sleep is unavailable',
    () async {
      cloud.missingSleepTable = true;
      await sync();
      expect(remote.status, contains('Сон остаётся на устройстве'));
      remote.bindLocal(local, validateAppDocument, () async {}, () async {});
      await local.setInt(water, 500);
      expect(remote.status, contains('локальн'));
      expect(remote.status, contains('Сон остаётся на устройстве'));
    },
  );

  test('a new local edit is automatically synced when enabled', () async {
    await local.setString('smart_settings', '{"autoSync":true}');
    await sync();
    final completed = Completer<void>();
    remote.bindLocal(local, validateAppDocument, () async {
      if (!completed.isCompleted) completed.complete();
    }, () async {});
    await local.setInt(water, 500);
    expect(remote.status, contains('локальн'));
    await completed.future.timeout(const Duration(seconds: 7));
    expect(cloud.oldRows[water]!['payload'], 500);
    expect(remote.status, contains('Синхронизировано'));
  });

  test(
    'manual sync does not claim completion when a newer local edit exists',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      cloud.onSleepRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      try {
        final syncing = sync();
        await started.future.timeout(const Duration(seconds: 5));
        await local.setInt(water, 500);
        release.complete();
        await syncing;
        expect(local.getInt(water), 500);
        expect(cloud.oldRows[water]!['payload'], 250);
        expect(remote.conflicts, isEmpty);
        expect(remote.status, contains('локальн'));
        expect(remote.status, isNot(contains('Синхронизировано')));
        cloud.onSleepRead = null;
        await sync();
        expect(cloud.oldRows[water]!['payload'], 500);
        expect(remote.status, contains('Синхронизировано'));
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test('auto sync retries a local edit completed while it was busy', () async {
    await local.setString('smart_settings', '{"autoSync":true}');
    final autoCompleted = Completer<void>();
    remote.bindLocal(local, validateAppDocument, () async {
      if (!autoCompleted.isCompleted) autoCompleted.complete();
    }, () async {});
    final started = Completer<void>(), release = Completer<void>();
    cloud.onSleepRead = () async {
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    try {
      final syncing = sync();
      await started.future.timeout(const Duration(seconds: 5));
      await local.setInt(water, 500);
      release.complete();
      await syncing;
      expect(local.getInt(water), 500);
      expect(cloud.oldRows[water]!['payload'], 250);
      expect(remote.status, contains('локальн'));
      await autoCompleted.future.timeout(const Duration(seconds: 7));
      expect(cloud.oldRows[water]!['payload'], 500);
      expect(jsonDecode(local.getString('_baseline_$user')!)[water], 500);
      expect(remote.status, contains('Синхронизировано'));
    } finally {
      if (!release.isCompleted) release.complete();
    }
  });

  test('a new document during sync is also reported as pending', () async {
    final started = Completer<void>(), release = Completer<void>();
    cloud.onSleepRead = () async {
      if (!started.isCompleted) started.complete();
      await release.future;
    };
    try {
      final syncing = sync();
      await started.future.timeout(const Duration(seconds: 5));
      await local.setInt(steps, 1234);
      release.complete();
      await syncing;
      expect(local.getInt(steps), 1234);
      expect(cloud.oldRows.containsKey(steps), isFalse);
      expect(remote.status, contains('локальн'));
      cloud.onSleepRead = null;
      await sync();
      expect(cloud.oldRows[steps]!['payload'], 1234);
    } finally {
      if (!release.isCompleted) release.complete();
    }
  });

  test(
    'new changes do not silently clear the import confirmation latch',
    () async {
      const generation = 'synthetic-import-generation';
      await local.setString(LocalPreferences.diaryGenerationKey, generation);
      await local.setBool(LocalPreferences.importSyncPauseKey, true);
      final started = Completer<void>(), release = Completer<void>();
      cloud.onSleepRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      try {
        final syncing = remote.sync(
          local,
          validate: validateAppDocument,
          confirmedImportGeneration: generation,
        );
        await started.future.timeout(const Duration(seconds: 5));
        await local.setInt(water, 500);
        release.complete();
        await syncing;
        expect(cloud.oldRows[water]!['payload'], 250);
        expect(local.getInt(water), 500);
        expect(local.importSyncPaused, isTrue);
        expect(remote.status, contains('локальн'));
        cloud.onSleepRead = null;
        await remote.sync(
          local,
          validate: validateAppDocument,
          confirmedImportGeneration: generation,
        );
        expect(cloud.oldRows[water]!['payload'], 500);
        expect(local.importSyncPaused, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test('disabling auto sync while busy prevents the scheduled retry', () async {
    await local.setString('smart_settings', '{"autoSync":true}');
    remote.bindLocal(local, validateAppDocument, () async {}, () async {});
    final started = Completer<void>(), release = Completer<void>();
    cloud.onSleepRead = () async {
      if (!started.isCompleted) started.complete();
      await release.future;
    };
    try {
      final syncing = sync();
      await started.future.timeout(const Duration(seconds: 5));
      await local.setInt(water, 500);
      await local.setString('smart_settings', '{"autoSync":false}');
      release.complete();
      await syncing;
      expect(remote.status, contains('локальн'));
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      expect(cloud.oldRows[water]!['payload'], 250);
      expect(local.getInt(water), 500);
      expect(cloud.sleepCalls, 1);
    } finally {
      if (!release.isCompleted) release.complete();
    }
  });

  test(
    'a write during a failed sync gets one retry when auto is enabled',
    () async {
      await local.setString('smart_settings', '{"autoSync":true}');
      final autoCompleted = Completer<void>();
      remote.bindLocal(local, validateAppDocument, () async {
        if (!autoCompleted.isCompleted) autoCompleted.complete();
      }, () async {});
      final started = Completer<void>(), release = Completer<void>();
      cloud.onSleepRead = () async {
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      try {
        final syncing = sync();
        final result = syncing.then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await started.future.timeout(const Duration(seconds: 5));
        await local.setInt(water, 500);
        cloud.networkDown = true;
        release.complete();
        expect(await result, isA<http.ClientException>());
        expect(remote.status, contains('не завершена'));
        cloud.networkDown = false;
        await autoCompleted.future.timeout(const Duration(seconds: 7));
        expect(cloud.oldRows[water]!['payload'], 500);
        expect(remote.status, contains('Синхронизировано'));
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test(
    'an edit during conflict upload is reported and retried automatically',
    () async {
      await local.setString('smart_settings', '{"autoSync":true}');
      final autoCompleted = Completer<void>();
      remote.bindLocal(local, validateAppDocument, () async {
        if (!autoCompleted.isCompleted) autoCompleted.complete();
      }, () async {});
      cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
      final conflict = SyncConflict(water, 250, 500, 1);
      remote.conflicts.add(conflict);
      final started = Completer<void>(), release = Completer<void>();
      beforeCloudWrite = (_) async {
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      try {
        final resolving = remote.resolve(
          local,
          conflict,
          true,
          validate: validateAppDocument,
        );
        await started.future.timeout(const Duration(seconds: 5));
        await local.setInt(water, 750);
        release.complete();
        await resolving;
        expect(local.getInt(water), 750);
        expect(cloud.oldRows[water]!['payload'], 250);
        expect(remote.status, contains('локальн'));
        beforeCloudWrite = null;
        await autoCompleted.future.timeout(const Duration(seconds: 7));
        expect(cloud.oldRows[water]!['payload'], 750);
        expect(remote.status, contains('Синхронизировано'));
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );
}
