// Synthetic integration test: the real Flutter sync code talks to local
// PostgREST and PostgreSQL, not a mock transport or the production project.
// It is skipped unless checks/postgrest_contract.py supplies local-only config.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/sleep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Flutter's test binding normally returns synthetic HTTP 400 for all traffic.
// A real IOClient is created only for this opt-in, loopback-guarded test.
class _RealLocalHttpOverrides extends HttpOverrides {}

class LocalRestTransport extends http.BaseClient {
  final Uri base;
  final http.Client _inner;
  Future<void> Function(http.BaseRequest)? beforeSend;
  LocalRestTransport(this.base)
    : _inner = IOClient(
        HttpOverrides.runWithHttpOverrides(
          () => HttpClient()..findProxy = (_) => 'DIRECT',
          _RealLocalHttpOverrides(),
        ),
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Fail closed: even a misconfigured test cannot contact the real cloud.
    final uri = request.url;
    if (base.scheme != 'http' ||
        base.host != '127.0.0.1' ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port != base.port ||
        !uri.path.startsWith('/rest/v1/')) {
      throw StateError('Only the disposable loopback PostgREST is allowed');
    }
    await beforeSend?.call(request);
    // Supabase adds /rest/v1; the isolated PostgREST serves paths at root.
    final target = uri.replace(path: uri.path.substring('/rest/v1'.length));
    final outbound = http.Request(request.method, target)
      ..followRedirects = false
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    return _inner.send(outbound);
  }

  @override
  void close() => _inner.close();
}

String syntheticSession(String uid, String token) => jsonEncode({
  'access_token': token,
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3500,
  'refresh_token': 'synthetic-offline-test-only',
  'user': {
    'id': uid,
    'aud': 'authenticated',
    'app_metadata': {},
    'user_metadata': {},
    'created_at': '2026-10-25T00:00:00Z',
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final enabled = env['FITNESS_POSTGREST_LOCAL'] == '1';
  if (!enabled) {
    test(
      'local PostgREST integration is opt-in',
      () {},
      skip: 'Run checks/postgrest_contract.py for isolated integration tests.',
    );
    return;
  }
  final base = Uri.parse(env['FITNESS_POSTGREST_URL'] ?? '');
  if (base.scheme != 'http' || base.host != '127.0.0.1' || !base.hasPort) {
    throw StateError('Only a local disposable PostgREST URL is permitted');
  }
  final uidA = env['FITNESS_TEST_UID_A'] ?? '';
  final uidB = env['FITNESS_TEST_UID_B'] ?? '';
  final tokenA = env['FITNESS_TEST_JWT_A'] ?? '';
  final tokenB = env['FITNESS_TEST_JWT_B'] ?? '';
  final phase = env['FITNESS_TEST_PHASE'];
  if (uidA.isEmpty ||
      uidB.isEmpty ||
      tokenA.isEmpty ||
      tokenB.isEmpty ||
      !['before', 'after'].contains(phase)) {
    throw StateError('Missing synthetic local integration settings');
  }
  final day = phase == 'before' ? '2026-10-20' : '2026-10-21';
  final water = 'water_intake_$day';
  final sleep = 'sleep_day_$day';
  final sleepRecord = encodeSleepDay(SleepDay(day: day, minutes: 420));
  final cloudHasSleep = phase == 'after';
  final remote = SmartRemote.instance;
  late LocalRestTransport transportA, transportB;
  late SupabaseClient clientA, clientB;
  late LocalPreferences deviceA, deviceB, otherUserDevice;

  Future<LocalPreferences> freshStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalPreferences.open();
  }

  SupabaseClient buildClient(LocalRestTransport transport) => SupabaseClient(
    base.toString(),
    'synthetic-local-publishable-key',
    httpClient: transport,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
  );

  Future<void> sync(LocalPreferences store) =>
      remote.sync(store, validate: validateAppDocument);

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.beforeWriteForTests = null;
    deviceA = await freshStore();
    deviceB = await freshStore();
    otherUserDevice = await freshStore();
    transportA = LocalRestTransport(base);
    transportB = LocalRestTransport(base);
    clientA = buildClient(transportA);
    clientB = buildClient(transportB);
    await clientA.auth.setInitialSession(syntheticSession(uidA, tokenA));
    await clientB.auth.setInitialSession(syntheticSession(uidB, tokenB));
    remote.client = clientA;
    remote.conflicts.clear();
    remote.sleepCloudAvailable = null;
  });

  tearDown(() async {
    remote.unbindLocalForTests();
    remote.client = null;
    remote.conflicts.clear();
    LocalPreferences.beforeWriteForTests = null;
    await clientA.dispose();
    await clientB.dispose();
    transportA.close();
    transportB.close();
    LocalPreferences.memoryForTests = false;
  });

  test(
    'two devices synchronize and a stale water conflict cannot erase an edit',
    () async {
      await deviceA.setInt(water, 250);
      await deviceA.setString(sleep, sleepRecord);
      await sync(deviceA);
      expect(remote.sleepCloudAvailable, cloudHasSleep);
      expect(deviceA.getString(sleep), sleepRecord);
      await sync(deviceB);
      expect(deviceB.getInt(water), 250);
      expect(deviceB.getString(sleep), cloudHasSleep ? sleepRecord : null);

      await deviceA.setInt(water, 400);
      await deviceB.setInt(water, 500);
      await sync(deviceA);
      await sync(deviceB);
      expect(deviceB.getInt(water), 500);
      expect(remote.conflicts, hasLength(1));
      var conflict = remote.conflicts.single;
      expect(conflict.key, water);
      expect(conflict.remote, 400);
      await deviceB.setInt(water, 700);
      for (final keepDevice in [true, false]) {
        await expectLater(
          remote.resolve(
            deviceB,
            conflict,
            keepDevice,
            validate: validateAppDocument,
          ),
          throwsStateError,
        );
      }
      expect(deviceB.getInt(water), 700);
      final cloudRow = await clientA
          .from('fitness_documents')
          .select('payload')
          .eq('key', water)
          .single();
      expect(cloudRow['payload'], 400);
      await sync(deviceB); // refresh the comparison after the local edit
      conflict = remote.conflicts.single;
      expect(conflict.local, 700);
      await remote.resolve(
        deviceB,
        conflict,
        false,
        validate: validateAppDocument,
      );
      expect(deviceB.getInt(water), 400);
      expect(remote.conflicts, isEmpty);

      // A fresh keep-device choice is still allowed and propagates normally.
      await deviceA.setInt(water, 500);
      await deviceB.setInt(water, 600);
      await sync(deviceA);
      await sync(deviceB);
      conflict = remote.conflicts.single;
      await remote.resolve(
        deviceB,
        conflict,
        true,
        validate: validateAppDocument,
      );
      await sync(deviceA);
      expect(deviceA.getInt(water), 600);

      await deviceB.remove(water);
      await sync(deviceB);
      await sync(deviceA);
      expect(deviceA.getInt(water), isNull);
      expect(deviceA.getString(sleep), sleepRecord);
    },
  );

  test(
    'cloud choice rejects a later real HTTP revision, including ABA',
    () async {
      // Distinct keys for each phase and from the other integration tests.
      final reviewWater = phase == 'before'
          ? 'water_intake_2026-10-22'
          : 'water_intake_2026-10-24';
      await deviceA.setInt(reviewWater, 250);
      await sync(deviceA);
      await sync(deviceB);
      await deviceA.setInt(reviewWater, 400);
      await deviceB.setInt(reviewWater, 500);
      await sync(deviceA);
      await sync(deviceB);
      final shown = remote.conflicts.single;
      expect(shown.key, reviewWater);
      expect(shown.remote, 400);
      final first = await clientA
          .from('fitness_documents')
          .select('payload,revision')
          .eq('user_id', uidA)
          .eq('key', reviewWater)
          .single();
      final firstRevision = first['revision'] as int;
      await clientA.rpc(
        'write_fitness_document',
        params: {
          'p_key': reviewWater,
          'p_payload': 700,
          'p_expected': firstRevision,
        },
      );
      await expectLater(
        remote.resolve(deviceB, shown, false, validate: validateAppDocument),
        throwsStateError,
      );
      expect(deviceB.getInt(reviewWater), 500);
      expect(remote.conflicts, contains(shown));
      // Bring the payload back to its displayed value, but not its revision.
      await clientA.rpc(
        'write_fitness_document',
        params: {
          'p_key': reviewWater,
          'p_payload': 400,
          'p_expected': firstRevision + 1,
        },
      );
      await expectLater(
        remote.resolve(deviceB, shown, false, validate: validateAppDocument),
        throwsStateError,
      );
      expect(deviceB.getInt(reviewWater), 500);
      await sync(deviceB);
      final refreshed = remote.conflicts.single;
      expect(refreshed.remote, 400);
      expect(refreshed.revision, firstRevision + 2);
      await remote.resolve(
        deviceB,
        refreshed,
        false,
        validate: validateAppDocument,
      );
      expect(deviceB.getInt(reviewWater), 400);
      expect(remote.conflicts, isEmpty);

      if (cloudHasSleep) {
        const reviewDay = '2026-10-24';
        const reviewSleep = 'sleep_day_$reviewDay';
        String sleepValue(int minutes) =>
            encodeSleepDay(SleepDay(day: reviewDay, minutes: minutes));
        await deviceA.setString(reviewSleep, sleepValue(420));
        await sync(deviceA);
        await sync(deviceB);
        await deviceA.setString(reviewSleep, sleepValue(480));
        await deviceB.setString(reviewSleep, sleepValue(500));
        await sync(deviceA);
        await sync(deviceB);
        final shownSleep = remote.conflicts.single;
        expect(shownSleep.key, reviewSleep);
        expect(shownSleep.remote, sleepValue(480));
        final sleepRow = await clientA
            .from('fitness_sleep_documents')
            .select('revision')
            .eq('user_id', uidA)
            .eq('key', reviewSleep)
            .single();
        await clientA.rpc(
          'write_fitness_sleep_document',
          params: {
            'p_key': reviewSleep,
            'p_payload': sleepValue(510),
            'p_expected': sleepRow['revision'],
          },
        );
        await expectLater(
          remote.resolve(
            deviceB,
            shownSleep,
            false,
            validate: validateAppDocument,
          ),
          throwsStateError,
        );
        expect(deviceB.getString(reviewSleep), sleepValue(500));
        await sync(deviceB);
        final refreshedSleep = remote.conflicts.single;
        expect(refreshedSleep.remote, sleepValue(510));
        await remote.resolve(
          deviceB,
          refreshedSleep,
          false,
          validate: validateAppDocument,
        );
        expect(deviceB.getString(reviewSleep), sleepValue(510));
      }
    },
  );

  test('local edit during HTTP sync triggers another automatic sync', () async {
    final syncWater = phase == 'before'
        ? 'water_intake_2026-10-26'
        : 'water_intake_2026-10-27';
    await deviceA.setInt(syncWater, 250);
    await sync(deviceA);
    await deviceA.setInt(syncWater, 500);
    await deviceA.setString('smart_settings', '{"autoSync":true}');
    final completed = Completer<void>();
    remote.bindLocal(deviceA, validateAppDocument, () async {
      if (!completed.isCompleted) completed.complete();
    }, () async {});
    final started = Completer<void>(), release = Completer<void>();
    transportA.beforeSend = (request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('/fitness_sleep_documents') &&
          !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    try {
      final syncing = sync(deviceA);
      await started.future.timeout(const Duration(seconds: 5));
      await deviceA.setInt(syncWater, 750);
      release.complete();
      await syncing;
      expect(deviceA.getInt(syncWater), 750);
      expect(remote.status, contains('локальн'));
      await completed.future.timeout(const Duration(seconds: 10));
      final row = await clientA
          .from('fitness_documents')
          .select('payload')
          .eq('user_id', uidA)
          .eq('key', syncWater)
          .single();
      expect(row['payload'], 750);
      expect(remote.status, contains('Синхронизировано'));
    } finally {
      if (!release.isCompleted) release.complete();
      transportA.beforeSend = null;
    }
  });

  test(
    'different account is isolated and cannot reuse a bound local diary',
    () async {
      final ownKey = phase == 'before'
          ? 'steps_2026-10-23'
          : 'steps_2026-10-24';
      await deviceA.setInt(ownKey, 111);
      await sync(deviceA);
      remote.client = clientB;
      await sync(otherUserDevice);
      expect(otherUserDevice.getInt(ownKey), isNull);
      await otherUserDevice.setInt(ownKey, 222);
      await sync(otherUserDevice);
      await expectLater(sync(deviceA), throwsStateError);
      expect(deviceA.getInt(ownKey), 111);
      remote.client = clientA;
      await sync(deviceA);
      expect(deviceA.getInt(ownKey), 111);
    },
  );
}
