import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/sleep.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeCloud {
  final oldRows = <String, Map<String, dynamic>>{};
  final sleepRows = <String, Map<String, dynamic>>{};
  bool missingSleepTable = false, forbiddenSleepTable = false;
  bool failedSleepTable = false, networkDown = false;
  String missingCode = 'PGRST205';
  Future<void> Function()? onSleepRead;
  int sleepCalls = 0, oldCalls = 0;

  http.Response reply(http.Request request, Object body, int status) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );

  // Model the key equality filter used by the conflict-review recheck.
  // This fake remains in-memory and does not model RLS or a live server.
  List<Map<String, dynamic>> filteredRows(
    http.Request request,
    Map<String, Map<String, dynamic>> rows,
  ) {
    final filter = request.url.queryParameters['key'];
    if (filter == null) return rows.values.toList();
    if (!filter.startsWith('eq.')) throw StateError('Unexpected key filter');
    final value = rows[filter.substring(3)];
    return value == null ? [] : [value];
  }

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/fitness_documents')) {
      oldCalls++;
      return reply(request, filteredRows(request, oldRows), 200);
    }
    if (path.endsWith('/fitness_sleep_documents')) {
      sleepCalls++;
      await onSleepRead?.call();
      if (networkDown) {
        throw http.ClientException('Synthetic offline failure', request.url);
      }
      if (missingSleepTable) {
        return reply(request, {
          'code': missingCode,
          'message': 'Table not present',
        }, 404);
      }
      if (failedSleepTable) {
        return reply(request, {
          'code': 'XX000',
          'message': 'Synthetic internal failure',
        }, 500);
      }
      if (forbiddenSleepTable) {
        return reply(request, {
          'code': '42501',
          'message': 'permission denied',
        }, 403);
      }
      return reply(request, filteredRows(request, sleepRows), 200);
    }
    if (path.endsWith('/rpc/write_fitness_document') ||
        path.endsWith('/rpc/write_fitness_sleep_document')) {
      final sleepRpc = path.endsWith('/rpc/write_fitness_sleep_document');
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      final key = data['p_key'] as String;
      if (key.startsWith(sleepDayPrefix) != sleepRpc) {
        throw StateError('Sleep data sent to the wrong table');
      }
      final table = sleepRpc ? sleepRows : oldRows;
      final old = table[key];
      if ((old?['revision']) != data['p_expected']) {
        return reply(request, {
          'code': 'PT409',
          'message': 'Concurrent document change',
        }, 409);
      }
      final rev = ((old?['revision'] as int?) ?? 0) + 1;
      table[key] = {'key': key, 'payload': data['p_payload'], 'revision': rev};
      return reply(request, rev, 200);
    }
    throw StateError('Unexpected request in fully mocked test: $path');
  }
}

String session(String uid) => jsonEncode({
  'access_token': 'synthetic',
  'token_type': 'bearer',
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
  const user = 'mock-sleep-account', key = 'sleep_day_2026-10-25';
  String record(int minutes) =>
      encodeSleepDay(SleepDay(day: '2026-10-25', minutes: minutes));
  late FakeCloud cloud;
  late MockClient transport;
  late SupabaseClient client;
  late LocalPreferences a, b;
  final remote = SmartRemote.instance;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    SharedPreferences.setMockInitialValues({});
    a = await LocalPreferences.open();
    SharedPreferences.setMockInitialValues({});
    b = await LocalPreferences.open();
    cloud = FakeCloud();
    transport = MockClient(cloud.handle);
    client = SupabaseClient(
      'https://sync.test.invalid',
      'synthetic-public',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
    );
    await client.auth.setInitialSession(session(user));
    remote.client = client;
    remote.conflicts.clear();
    remote.sleepCloudAvailable = null;
  });
  tearDown(() async {
    remote.client = null;
    remote.conflicts.clear();
    LocalPreferences.onAppWrite = null;
    await client.dispose();
    transport.close();
  });
  Future<void> sync(LocalPreferences p) =>
      remote.sync(p, validate: validateAppDocument);

  test(
    'mock cloud sync and import exclude each other before any replacement',
    () async {
      final provider = AppDataProvider();
      await provider.init();
      final local = provider.storage.local;
      const water = 'water_intake_2026-10-25';
      await local.setInt(water, 250);
      final readStarted = Completer<void>(), finishRead = Completer<void>();
      final importingStarted = Completer<void>(),
          finishImport = Completer<void>();
      cloud.onSleepRead = () async {
        if (!readStarted.isCompleted) readStarted.complete();
        await finishRead.future;
      };
      try {
        final syncing = sync(local);
        await readStarted.future;
        expect(remote.busy, isTrue);
        await expectLater(
          provider.storage.importData({
            'data': {water: 800},
          }),
          throwsStateError,
        );
        expect(local.getInt(water), 250);
        expect(local.get(LocalPreferences.importJournalKey), isNull);
        finishRead.complete();
        await syncing;
        expect(cloud.oldRows[water]!['payload'], 250);
        final staleConflict = SyncConflict(water, 250, 500, 1);
        remote.conflicts.add(staleConflict);

        cloud.onSleepRead = null;
        LocalPreferences.beforeWriteForTests = (key) async {
          if (key == water && !importingStarted.isCompleted) {
            importingStarted.complete();
            await finishImport.future;
          }
        };
        final importing = provider.storage.importData({
          'data': {water: 800},
        });
        await importingStarted.future;
        final requestsBefore = cloud.oldCalls + cloud.sleepCalls;
        await expectLater(sync(local), throwsStateError);
        expect(cloud.oldCalls + cloud.sleepCalls, requestsBefore);
        finishImport.complete();
        expect(await importing, isTrue);
        expect(local.getInt(water), 800);
        expect(cloud.oldRows[water]!['payload'], 250);
        expect(remote.conflicts, isEmpty);
        await expectLater(
          remote.resolve(
            local,
            staleConflict,
            false,
            validate: validateAppDocument,
          ),
          throwsStateError,
        );
        expect(local.getInt(water), 800);
        expect(
          (jsonDecode(provider.storage.importBackupJson()!) as Map)['data'],
          {water: 250},
        );
        expect(local.importSyncPaused, isTrue);
        final callsBeforeConfirmation = cloud.oldCalls + cloud.sleepCalls;
        await expectLater(sync(local), throwsStateError);
        await expectLater(
          remote.sync(
            local,
            validate: validateAppDocument,
            confirmedImportGeneration: 'stale-generation',
          ),
          throwsStateError,
        );
        expect(cloud.oldCalls + cloud.sleepCalls, callsBeforeConfirmation);
        expect(cloud.oldRows[water]!['payload'], 250);
        await remote.sync(
          local,
          validate: validateAppDocument,
          confirmedImportGeneration: local.diaryGeneration,
        );
        expect(cloud.oldRows[water]!['payload'], 800);
        expect(local.importSyncPaused, isFalse);
      } finally {
        if (!finishRead.isCompleted) finishRead.complete();
        if (!finishImport.isCompleted) finishImport.complete();
        LocalPreferences.beforeWriteForTests = null;
        provider.dispose();
      }
    },
  );

  test(
    'scheduled and subsequent autosync stay paused after an import',
    () async {
      final provider = AppDataProvider();
      await provider.init();
      final local = provider.storage.local;
      const water = 'water_intake_2026-10-25';
      final settings = jsonEncode({'autoSync': true});
      await local.setString('smart_settings', settings);
      remote.bindLocal(
        local,
        validateAppDocument,
        () async {},
        () => provider.storage.pendingMutations,
      );
      try {
        expect(
          await provider.storage.importData({
            'data': {water: 800, 'smart_settings': settings},
          }),
          isTrue,
        );
        expect(local.importSyncPaused, isTrue);
        await local.setInt('steps_2026-10-25', 200);
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(cloud.oldCalls + cloud.sleepCalls, 0);
        await remote.sync(
          local,
          validate: validateAppDocument,
          confirmedImportGeneration: local.diaryGeneration,
        );
        expect(cloud.oldRows[water]!['payload'], 800);
        expect(local.importSyncPaused, isFalse);
      } finally {
        remote.unbindLocalForTests();
        provider.dispose();
      }
    },
  );

  test(
    'sync failure or conflict keeps the import pause until resolution',
    () async {
      final provider = AppDataProvider();
      await provider.init();
      final local = provider.storage.local;
      const water = 'water_intake_2026-10-25';
      try {
        await local.setInt(water, 250);
        await sync(local);
        cloud.oldRows[water] = {'key': water, 'payload': 400, 'revision': 2};
        await provider.storage.importData({
          'data': {water: 800},
        });
        final generation = local.diaryGeneration;
        cloud.networkDown = true;
        await expectLater(
          remote.sync(
            local,
            validate: validateAppDocument,
            confirmedImportGeneration: generation,
          ),
          throwsA(isA<http.ClientException>()),
        );
        expect(local.importSyncPaused, isTrue);
        cloud.networkDown = false;
        await remote.sync(
          local,
          validate: validateAppDocument,
          confirmedImportGeneration: generation,
        );
        expect(remote.conflicts, hasLength(1));
        expect(local.importSyncPaused, isTrue);
        await remote.resolve(
          local,
          remote.conflicts.single,
          true,
          validate: validateAppDocument,
        );
        await remote.sync(
          local,
          validate: validateAppDocument,
          confirmedImportGeneration: generation,
        );
        expect(local.importSyncPaused, isFalse);
        expect(cloud.oldRows[water]!['payload'], 800);
      } finally {
        provider.dispose();
      }
    },
  );

  group('import confirmation UI', () {
    late AppDataProvider provider;
    const water = 'water_intake_2026-10-25';
    setUp(() async {
      provider = AppDataProvider();
      await provider.init();
      await provider.storage.importData({
        'data': {water: 800},
      });
    });
    tearDown(() => provider.dispose());
    testWidgets('manual sync after import requires an explicit confirmation', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CloudPanel(provider: provider)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('Автосинхронизация приостановлена после импорта.'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Синхронизировать сейчас'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Синхронизировать после импорта?'), findsOneWidget);
      expect(cloud.oldCalls + cloud.sleepCalls, 0);
      await tester.runAsync(() async {
        await tester.tap(find.text('Отмена'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(provider.storage.local.importSyncPaused, isTrue);
      expect(cloud.oldCalls + cloud.sleepCalls, 0);
      await tester.runAsync(() async {
        await tester.tap(find.text('Синхронизировать сейчас'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Синхронизировать после импорта?'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Синхронизировать'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(cloud.oldRows[water]!['payload'], 800);
      expect(provider.storage.local.importSyncPaused, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  test(
    'two mocked devices sync, detect conflict, reject stale choice, resolve and propagate tombstone',
    () async {
      await a.setString(key, record(450));
      await sync(a);
      expect(remote.sleepCloudAvailable, isTrue);
      expect(cloud.sleepRows[key]!['payload'], record(450));
      expect(
        cloud.oldRows.keys.where((k) => k.startsWith(sleepDayPrefix)),
        isEmpty,
      );
      await sync(b);
      expect(b.getString(key), record(450));
      expect(await a.compareAndPut(key, record(450), record(420)), isTrue);
      expect(await b.compareAndPut(key, record(450), record(480)), isTrue);
      await sync(a);
      await sync(b);
      expect(remote.conflicts, hasLength(1));
      final firstConflict = remote.conflicts.single;
      expect(firstConflict.key, key);
      expect(b.getString(key), record(480));
      expect(cloud.sleepRows[key]!['payload'], record(420));
      expect(await b.compareAndPut(key, record(480), record(500)), isTrue);
      await expectLater(
        remote.resolve(b, firstConflict, false, validate: validateAppDocument),
        throwsStateError,
      );
      expect(b.getString(key), record(500));
      await sync(b);
      final refreshed = remote.conflicts.single;
      await remote.resolve(b, refreshed, false, validate: validateAppDocument);
      expect(b.getString(key), record(420));
      expect(await a.compareAndPut(key, record(420), null), isTrue);
      await sync(a);
      expect(cloud.sleepRows[key]!['payload'], isNull);
      expect(cloud.sleepRows[key]!['revision'], 3);
      await sync(b);
      expect(b.getString(key), isNull);
      expect(remote.conflicts, isEmpty);
    },
  );

  test(
    'missing server table preserves old baseline and local sleep while other docs sync',
    () async {
      cloud.missingSleepTable = true;
      await a.setString(key, record(450));
      await a.setInt('steps_2026-10-25', 1234);
      await a.setString('_baseline_$user', jsonEncode({key: record(420)}));
      await sync(a);
      expect(remote.sleepCloudAvailable, isFalse);
      expect(remote.status, contains('Сон остаётся на устройстве'));
      expect(a.getString(key), record(450));
      expect(cloud.oldRows['steps_2026-10-25']!['payload'], 1234);
      expect(
        (jsonDecode(a.getString('_baseline_$user')!) as Map)[key],
        record(420),
      );
      cloud.missingCode = '42P01';
      await sync(a);
      expect(remote.sleepCloudAvailable, isFalse);
      expect(
        (jsonDecode(a.getString('_baseline_$user')!) as Map)[key],
        record(420),
      );
      cloud.missingSleepTable = false;
      cloud.sleepRows[key] = {
        'key': key,
        'payload': record(420),
        'revision': 1,
      };
      await sync(a);
      expect(cloud.sleepRows[key]!['payload'], record(450));
      expect(a.getString(key), record(450));
      expect(remote.sleepCloudAvailable, isTrue);
    },
  );

  test(
    'server and network failures are not mistaken for a missing table',
    () async {
      await a.setString(key, record(450));
      await a.setInt('steps_2026-10-25', 1234);
      cloud.failedSleepTable = true;
      await expectLater(sync(a), throwsA(isA<PostgrestException>()));
      expect(remote.status, contains('не завершена'));
      expect(remote.sleepCloudAvailable, isNull);
      expect(cloud.oldRows, isEmpty);
      cloud.failedSleepTable = false;
      cloud.networkDown = true;
      await expectLater(sync(a), throwsA(isA<http.ClientException>()));
      expect(a.getString(key), record(450));
      expect(a.getString('_baseline_$user'), isNull);
      expect(cloud.oldRows, isEmpty);
    },
  );

  test(
    'permission failure or malformed remote sleep never partially pushes ordinary documents',
    () async {
      await a.setString(key, record(450));
      await a.setInt('steps_2026-10-25', 1234);
      cloud.forbiddenSleepTable = true;
      await expectLater(sync(a), throwsA(isA<PostgrestException>()));
      expect(cloud.oldRows, isEmpty);
      expect(a.getString(key), record(450));
      expect(remote.status, contains('не завершена'));
      cloud.forbiddenSleepTable = false;
      cloud.sleepRows[key] = {'key': key, 'payload': '{bad', 'revision': 1};
      await expectLater(sync(a), throwsFormatException);
      expect(cloud.oldRows, isEmpty);
      expect(a.getString(key), record(450));
      expect(a.getString('_baseline_$user'), isNull);
    },
  );

  test(
    'a local edit during an in-flight remote pull becomes a conflict',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      cloud.sleepRows[key] = {
        'key': key,
        'payload': record(450),
        'revision': 1,
      };
      cloud.onSleepRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final pending = sync(a);
      await started.future;
      expect(await a.compareAndPut(key, null, record(480)), isTrue);
      release.complete();
      await pending;
      expect(a.getString(key), record(480));
      expect(cloud.sleepRows[key]!['payload'], record(450));
      expect(remote.conflicts.single.key, key);
      expect(remote.conflicts.single.local, record(480));
    },
  );

  test(
    'two devices resolve a recipe conflict by keeping the local version',
    () async {
      String recipes(String name) => jsonEncode([
        {
          'id': 'recipe-1',
          'name': name,
          'servings': 1,
          'ingredients': [
            {
              'name': 'Крупа',
              'grams': 100,
              'caloriesPer100g': 100,
              'proteinPer100g': 5,
              'fatPer100g': 3,
              'carbsPer100g': 10,
            },
          ],
        },
      ]);
      final first = recipes('Начало'),
          one = recipes('Первое устройство'),
          two = recipes('Второе устройство');
      await a.setString('recipes', first);
      await a.setInt('steps_2026-10-25', 900);
      await a.setString(key, record(450));
      await sync(a);
      await sync(b);
      expect(b.getString('recipes'), first);
      expect(b.getString(key), record(450));
      expect(await a.compareAndPut('recipes', first, one), isTrue);
      expect(await b.compareAndPut('recipes', first, two), isTrue);
      await sync(a);
      await sync(b);
      expect(remote.conflicts.single.key, 'recipes');
      await remote.resolve(
        b,
        remote.conflicts.single,
        true,
        validate: validateAppDocument,
      );
      expect(cloud.oldRows['recipes']!['payload'], two);
      await sync(a);
      expect(a.getString('recipes'), two);
      expect(a.getInt('steps_2026-10-25'), 900);
      expect(a.getString(key), record(450));
    },
  );

  test(
    'recipe pull and conflict resolution do not overwrite a concurrent local edit',
    () async {
      String recipes(String name) => jsonEncode([
        {
          'id': 'recipe-1',
          'name': name,
          'servings': 1,
          'ingredients': [
            {
              'name': 'Ингредиент',
              'grams': 100,
              'caloriesPer100g': 100,
              'proteinPer100g': 5,
              'fatPer100g': 3,
              'carbsPer100g': 10,
            },
          ],
        },
      ]);
      final remoteValue = recipes('В облаке');
      final localValue = recipes('На устройстве');
      final localNewer = recipes('Правка после сравнения');
      cloud.oldRows['recipes'] = {
        'key': 'recipes',
        'payload': remoteValue,
        'revision': 1,
      };
      final started = Completer<void>(), release = Completer<void>();
      cloud.onSleepRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final pending = sync(a);
      await started.future;
      expect(await a.compareAndPut('recipes', null, localValue), isTrue);
      release.complete();
      await pending;
      expect(a.getString('recipes'), localValue);
      expect(remote.conflicts.single.key, 'recipes');
      final stale = remote.conflicts.single;
      expect(await a.compareAndPut('recipes', localValue, localNewer), isTrue);
      await expectLater(
        remote.resolve(a, stale, false, validate: validateAppDocument),
        throwsStateError,
      );
      expect(a.getString('recipes'), localNewer);
      cloud.onSleepRead = null;
      await sync(a);
      await remote.resolve(
        a,
        remote.conflicts.single,
        false,
        validate: validateAppDocument,
      );
      expect(a.getString('recipes'), remoteValue);
    },
  );

  test(
    'two mocked devices resolve a weight conflict without losing unrelated records',
    () async {
      String weights(double value) => jsonEncode([
        {
          'id': 'w1',
          'weight': value,
          'date': '2026-10-25T08:00:00.000',
          'note': null,
        },
      ]);
      final initial = weights(80),
          first = weights(79.25),
          second = weights(81.5);
      await a.setString('weight_entries', initial);
      await a.setInt('steps_2026-10-25', 900);
      await a.setString(key, record(450));
      await sync(a);
      await sync(b);
      expect(b.getString('weight_entries'), initial);
      expect(await a.compareAndPut('weight_entries', initial, first), isTrue);
      expect(await b.compareAndPut('weight_entries', initial, second), isTrue);
      await sync(a);
      await sync(b);
      expect(remote.conflicts.single.key, 'weight_entries');
      await remote.resolve(
        b,
        remote.conflicts.single,
        true,
        validate: validateAppDocument,
      );
      expect(cloud.oldRows['weight_entries']!['payload'], second);
      await sync(a);
      expect(a.getString('weight_entries'), second);
      expect(a.getInt('steps_2026-10-25'), 900);
      expect(a.getString(key), record(450));
    },
  );

  test(
    'weight and profile pulls and conflict choices never overwrite newer local edits',
    () async {
      String weights(double value) => jsonEncode([
        {
          'id': 'w1',
          'weight': value,
          'date': '2026-10-25T08:00:00.000',
          'note': null,
        },
      ]);
      String profile(double value) =>
          jsonEncode({'currentWeight': value, 'currentWeightConfirmed': true});
      final wCloud = weights(75), wLocal = weights(76), wNew = weights(77);
      final pCloud = profile(75), pLocal = profile(76), pNew = profile(77);
      cloud.oldRows['weight_entries'] = {
        'key': 'weight_entries',
        'payload': wCloud,
        'revision': 1,
      };
      cloud.oldRows['user_profile'] = {
        'key': 'user_profile',
        'payload': pCloud,
        'revision': 1,
      };
      final started = Completer<void>(), release = Completer<void>();
      cloud.onSleepRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final pending = sync(a);
      await started.future;
      expect(await a.compareAndPut('weight_entries', null, wLocal), isTrue);
      expect(await a.compareAndPut('user_profile', null, pLocal), isTrue);
      release.complete();
      await pending;
      expect(remote.conflicts.map((c) => c.key).toSet(), {
        'weight_entries',
        'user_profile',
      });
      expect(a.getString('weight_entries'), wLocal);
      expect(a.getString('user_profile'), pLocal);
      final weightConflict = remote.conflicts.firstWhere(
        (c) => c.key == 'weight_entries',
      );
      final profileConflict = remote.conflicts.firstWhere(
        (c) => c.key == 'user_profile',
      );
      expect(await a.compareAndPut('weight_entries', wLocal, wNew), isTrue);
      expect(await a.compareAndPut('user_profile', pLocal, pNew), isTrue);
      await expectLater(
        remote.resolve(a, weightConflict, false, validate: validateAppDocument),
        throwsStateError,
      );
      await expectLater(
        remote.resolve(
          a,
          profileConflict,
          false,
          validate: validateAppDocument,
        ),
        throwsStateError,
      );
      expect(a.getString('weight_entries'), wNew);
      expect(a.getString('user_profile'), pNew);
    },
  );

  test(
    'two mocked devices resolve a food-day conflict and retain unrelated data',
    () async {
      const foodKey = 'food_entries_2026-10-25';
      String foodDay(double grams) => jsonEncode([
        FoodEntry(
          id: 'mock-food',
          name: 'Тестовая еда',
          caloriesPer100g: 120,
          proteinPer100g: 10,
          fatPer100g: 2,
          carbsPer100g: 15,
          amountGrams: grams,
          mealType: MealType.breakfast,
          date: DateTime(2026, 10, 25),
          loggedAt: DateTime(2026, 10, 25, 8),
        ).toJson(),
      ]);
      final initial = foodDay(100), first = foodDay(125), second = foodDay(150);
      await a.setString(foodKey, initial);
      await a.setInt('water_intake_2026-10-25', 600);
      await a.setString(key, record(420));
      await sync(a);
      await sync(b);
      expect(await a.compareAndPut(foodKey, initial, first), isTrue);
      expect(await b.compareAndPut(foodKey, initial, second), isTrue);
      await sync(a);
      await sync(b);
      expect(remote.conflicts.single.key, foodKey);
      await remote.resolve(
        b,
        remote.conflicts.single,
        true,
        validate: validateAppDocument,
      );
      expect(cloud.oldRows[foodKey]!['payload'], second);
      await sync(a);
      expect(a.getString(foodKey), second);
      expect(a.getInt('water_intake_2026-10-25'), 600);
      expect(a.getString(key), record(420));
    },
  );

  test(
    'food pull and stale conflict choice cannot overwrite a newer local edit',
    () async {
      const foodKey = 'food_entries_2026-10-25';
      String foodDay(double grams) => jsonEncode([
        FoodEntry(
          id: 'mock-food',
          name: 'Тестовая еда',
          caloriesPer100g: 120,
          proteinPer100g: 10,
          fatPer100g: 2,
          carbsPer100g: 15,
          amountGrams: grams,
          mealType: MealType.breakfast,
          date: DateTime(2026, 10, 25),
          loggedAt: DateTime(2026, 10, 25, 8),
        ).toJson(),
      ]);
      final server = foodDay(100), local = foodDay(125), newer = foodDay(150);
      cloud.oldRows[foodKey] = {
        'key': foodKey,
        'payload': server,
        'revision': 1,
      };
      final started = Completer<void>(), release = Completer<void>();
      cloud.onSleepRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final pending = sync(a);
      await started.future;
      expect(await a.compareAndPut(foodKey, null, local), isTrue);
      release.complete();
      await pending;
      expect(remote.conflicts.single.key, foodKey);
      final stale = remote.conflicts.single;
      expect(await a.compareAndPut(foodKey, local, newer), isTrue);
      await expectLater(
        remote.resolve(a, stale, false, validate: validateAppDocument),
        throwsStateError,
      );
      expect(a.getString(foodKey), newer);
    },
  );

  test(
    'queued local water edit must not be overwritten by a cloud pull',
    () async {
      const water = 'water_intake_2026-10-25';
      await a.setInt(water, 100);
      await a.setString('_bound_user', user);
      await a.setString('_baseline_$user', jsonEncode({water: 100}));
      cloud.oldRows[water] = {'key': water, 'payload': 300, 'revision': 1};
      final editStarted = Completer<void>(), releaseEdit = Completer<void>();
      final cloudRead = Completer<void>();
      cloud.onSleepRead = () async {
        if (!cloudRead.isCompleted) cloudRead.complete();
      };
      LocalPreferences.beforeWriteForTests = (written) async {
        if (written == water && !editStarted.isCompleted) {
          editStarted.complete();
          await releaseEdit.future;
        }
      };
      try {
        final editing = a.setInt(water, 200);
        await editStarted.future;
        final syncing = sync(a);
        await cloudRead.future;
        // Let the sync enqueue its conditional write behind the blocked edit.
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        releaseEdit.complete();
        await editing;
        await syncing;
        expect(a.getInt(water), 200);
        expect(cloud.oldRows[water]!['payload'], 300);
        expect(remote.conflicts.single.key, water);
        expect(remote.conflicts.single.local, 200);
      } finally {
        if (!releaseEdit.isCompleted) releaseEdit.complete();
        LocalPreferences.beforeWriteForTests = null;
      }
    },
  );

  test(
    'stale conflict resolution never replaces a newer local water edit',
    () async {
      const water = 'water_intake_2026-10-25';
      await a.setInt(water, 250);
      await a.setString('_bound_user', user);
      final stale = SyncConflict(water, 250, 500, 1);
      remote.conflicts.add(stale);
      await a.setInt(water, 800);
      await expectLater(
        remote.resolve(a, stale, false, validate: validateAppDocument),
        throwsStateError,
      );
      expect(a.getInt(water), 800);
      expect(remote.conflicts, contains(stale));
    },
  );

  test(
    'stale keep-device choice cannot upload an unseen local deletion',
    () async {
      const water = 'water_intake_2026-10-25';
      await a.setInt(water, 250);
      await a.setString('_bound_user', user);
      cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
      final stale = SyncConflict(water, 250, 500, 1);
      remote.conflicts.add(stale);
      await a.remove(water);
      await expectLater(
        remote.resolve(a, stale, true, validate: validateAppDocument),
        throwsStateError,
      );
      expect(a.getInt(water), isNull);
      expect(cloud.oldRows[water]!['payload'], 500);
      expect(cloud.oldRows[water]!['revision'], 1);
      expect(remote.conflicts, contains(stale));
    },
  );

  test('keep-device choice waits for an already queued local edit', () async {
    const water = 'water_intake_2026-10-25';
    await a.setInt(water, 250);
    await a.setString('_bound_user', user);
    cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
    final stale = SyncConflict(water, 250, 500, 1);
    remote.conflicts.add(stale);
    final started = Completer<void>(), release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    try {
      final editing = a.setInt(water, 800);
      await started.future;
      // Install an error handler immediately so a failure is observed safely.
      final resolution = remote
          .resolve(a, stale, true, validate: validateAppDocument)
          .then((_) => false, onError: (Object _) => true);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(cloud.oldRows[water]!['payload'], 500);
      release.complete();
      await editing;
      expect(await resolution, isTrue);
      expect(a.getInt(water), 800);
      expect(cloud.oldRows[water]!['payload'], 500);
      expect(remote.conflicts, contains(stale));
    } finally {
      if (!release.isCompleted) release.complete();
      LocalPreferences.beforeWriteForTests = null;
    }
  });

  test(
    'stale cloud choices preserve newer steps, flags and settings',
    () async {
      await a.setString('_bound_user', user);
      final cases = <(String, Object, Object, Object)>[
        ('steps_2026-10-25', 100, 200, 300),
        ('workout_completed_2026-10-25', true, false, false),
        ('smart_settings', '{}', '{"theme":"light"}', '{"theme":"dark"}'),
        ('workout_entries_2026-10-25', '[]', '[]', '[ ]'),
        ('custom_foods', '[]', '[]', '[ ]'),
      ];
      for (final (key, oldLocal, oldRemote, currentLocal) in cases) {
        remote.conflicts.clear();
        await a.put(key, oldLocal);
        final stale = SyncConflict(key, oldLocal, oldRemote, 1);
        remote.conflicts.add(stale);
        await a.put(key, currentLocal);
        await expectLater(
          remote.resolve(a, stale, false, validate: validateAppDocument),
          throwsStateError,
          reason: key,
        );
        expect(a.get(key), currentLocal, reason: key);
        expect(remote.conflicts, contains(stale), reason: key);
      }
    },
  );

  test(
    'account change while remote sleep is read blocks all pulls and pushes',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      cloud.sleepRows[key] = {
        'key': key,
        'payload': record(450),
        'revision': 1,
      };
      cloud.onSleepRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final pending = sync(a);
      await started.future;
      await client.auth.setInitialSession(session('another-mock-account'));
      release.complete();
      await expectLater(pending, throwsStateError);
      expect(a.getString(key), isNull);
      expect(a.getString('_baseline_$user'), isNull);
      expect(a.getString('_bound_user'), user);
    },
  );
}
