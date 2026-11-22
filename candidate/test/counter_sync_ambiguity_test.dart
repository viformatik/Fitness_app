// Synthetic-only regression: two devices can independently produce the same
// daily water total. Equality of aggregates cannot prove equality of intent.
import 'dart:async';
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sleep_sync_test.dart' show FakeCloud, session;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const user = 'synthetic-counter-user';
  const water = 'water_intake_2026-10-25';
  final remote = SmartRemote.instance;
  late FakeCloud cloud;
  late MockClient transport;
  late SupabaseClient client;
  late LocalPreferences a, b;
  late bool loseNextWriteResponse;
  Future<void> Function()? afterWrite;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    SharedPreferences.setMockInitialValues({});
    a = await LocalPreferences.open();
    SharedPreferences.setMockInitialValues({});
    b = await LocalPreferences.open();
    cloud = FakeCloud();
    loseNextWriteResponse = false;
    afterWrite = null;
    transport = MockClient((request) async {
      final response = await cloud.handle(request);
      if (request.url.path.endsWith('/rpc/write_fitness_document') &&
          response.statusCode == 200) {
        await afterWrite?.call();
        if (loseNextWriteResponse) {
          loseNextWriteResponse = false;
          throw http.ClientException('Synthetic response lost', request.url);
        }
      }
      return response;
    });
    client = SupabaseClient(
      'https://counter-sync.test.invalid',
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
    remote.unbindLocalForTests();
    remote.client = null;
    remote.conflicts.clear();
    LocalPreferences.onAppWrite = null;
    LocalPreferences.beforeWriteForTests = null;
    await client.dispose();
    transport.close();
    LocalPreferences.memoryForTests = false;
  });

  Future<void> sync(LocalPreferences store) =>
      remote.sync(store, validate: validateAppDocument);

  Future<SyncConflict> prepareMatching(
    String key,
    int baseline,
    int next,
  ) async {
    await a.setInt(key, baseline);
    await sync(a);
    await sync(b);
    await a.setInt(key, next);
    await b.setInt(key, next);
    await sync(a);
    await sync(b);
    expect(remote.conflicts, hasLength(1));
    return remote.conflicts.single;
  }

  test('equal independent water additions require review', () async {
    // Each synthetic device independently records another 250 ml.
    final conflict = await prepareMatching(water, 250, 500);
    expect(conflict.key, water);
    expect(conflict.matchingCounterNeedsReview, isTrue);
    expect(conflict.counterBaseline, 250);
    expect(b.getInt(water), 500);
    expect(cloud.oldRows[water]!['payload'], 500);
    expect(jsonDecode(b.getString('_baseline_$user')!)[water], 250);
  });

  test('equal independent step additions also require review', () async {
    const steps = 'steps_2026-10-25';
    final conflict = await prepareMatching(steps, 1000, 2000);
    expect(conflict.matchingCounterNeedsReview, isTrue);
    expect(conflict.counterBaseline, 1000);
    expect(b.getInt(steps), 2000);
    expect(cloud.oldRows[steps]!['payload'], 2000);
  });

  test('no known baseline is treated as unknown, not zero', () async {
    await a.setInt(water, 500);
    cloud.oldRows[water] = {'key': water, 'payload': 500, 'revision': 1};
    await sync(a);
    expect(remote.conflicts, hasLength(1));
    expect(remote.conflicts.single.matchingCounterNeedsReview, isTrue);
    expect(remote.conflicts.single.counterBaseline, isNull);
    expect(a.getInt(water), 500);
    expect(cloud.oldRows[water]!['revision'], 1);
    await sync(a);
    expect(remote.conflicts.single.matchingCounterNeedsReview, isTrue);
    expect(remote.conflicts.single.counterBaseline, isNull);
    expect(cloud.oldRows[water]!['revision'], 1);
  });

  test(
    'independent first additions also warn without a previous daily value',
    () async {
      await sync(a); // Records an empty baseline; no water is invented.
      await sync(b);
      await a.setInt(water, 250);
      await b.setInt(water, 250);
      await sync(a);
      await sync(b);
      expect(remote.conflicts.single.matchingCounterNeedsReview, isTrue);
      expect(remote.conflicts.single.counterBaseline, isNull);
    },
  );

  test('an unchanged synchronized counter does not warn again', () async {
    await a.setInt(water, 500);
    await sync(a);
    await sync(b);
    await sync(a);
    await sync(b);
    expect(remote.conflicts, isEmpty);
    expect(a.getInt(water), 500);
    expect(b.getInt(water), 500);
  });

  for (final key in [water, 'steps_2026-10-25']) {
    test(
      'a cloud-only counter change is pulled without a review: $key',
      () async {
        await a.setInt(key, 250);
        await sync(a);
        await sync(b);
        await a.setInt(key, 500);
        await sync(a);
        await sync(b);
        expect(remote.conflicts, isEmpty);
        expect(b.getInt(key), 500);
        expect(jsonDecode(b.getString('_baseline_$user')!)[key], 500);
      },
    );

    test(
      'a device-only counter change is pushed without a review: $key',
      () async {
        await a.setInt(key, 250);
        await sync(a);
        await sync(b);
        await b.setInt(key, 500);
        await sync(b);
        expect(remote.conflicts, isEmpty);
        expect(cloud.oldRows[key]!['payload'], 500);
        await sync(a);
        expect(remote.conflicts, isEmpty);
        expect(a.getInt(key), 500);
      },
    );
  }

  test(
    'a lost successful upload response can cause a conservative warning',
    () async {
      await a.setInt(water, 250);
      await sync(a);
      await a.setInt(water, 500);
      loseNextWriteResponse = true;
      await expectLater(sync(a), throwsA(isA<http.ClientException>()));
      // The server committed, but this device has not advanced its baseline.
      expect(cloud.oldRows[water]!['payload'], 500);
      expect(cloud.oldRows[water]!['revision'], 2);
      expect(jsonDecode(a.getString('_baseline_$user')!)[water], 250);
      await sync(a);
      expect(remote.conflicts.single.matchingCounterNeedsReview, isTrue);
      expect(remote.conflicts.single.counterBaseline, 250);
      expect(cloud.oldRows[water]!['revision'], 2);
    },
  );

  test('matching counters need explicit confirmation and CAS', () async {
    final conflict = await prepareMatching(water, 250, 500);
    await expectLater(
      remote.resolve(b, conflict, true, validate: validateAppDocument),
      throwsStateError,
    );
    await expectLater(
      remote.resolve(
        b,
        conflict,
        false,
        validate: validateAppDocument,
        confirmedMatchingCounter: true,
      ),
      throwsStateError,
    );
    expect(remote.conflicts, contains(conflict));
    expect(cloud.oldRows[water]!['revision'], 2);
    expect(jsonDecode(b.getString('_baseline_$user')!)[water], 250);
    await remote.resolve(
      b,
      conflict,
      true,
      validate: validateAppDocument,
      confirmedMatchingCounter: true,
    );
    expect(remote.conflicts, isEmpty);
    expect(cloud.oldRows[water]!['payload'], 500);
    expect(cloud.oldRows[water]!['revision'], 3);
    expect(jsonDecode(b.getString('_baseline_$user')!)[water], 500);
    await sync(b);
    expect(remote.conflicts, isEmpty);
  });

  test('a newer local total makes the confirmation stale', () async {
    final conflict = await prepareMatching(water, 250, 500);
    await b.setInt(water, 750);
    await expectLater(
      remote.resolve(
        b,
        conflict,
        true,
        validate: validateAppDocument,
        confirmedMatchingCounter: true,
      ),
      throwsStateError,
    );
    expect(b.getInt(water), 750);
    expect(cloud.oldRows[water]!['payload'], 500);
    await sync(b);
    final refreshed = remote.conflicts.single;
    expect(refreshed.matchingCounterNeedsReview, isFalse);
    expect(refreshed.local, 750);
    expect(refreshed.remote, 500);
    await remote.resolve(b, refreshed, true, validate: validateAppDocument);
    expect(cloud.oldRows[water]!['payload'], 750);
    await sync(a);
    expect(a.getInt(water), 750);
  });

  test(
    'a newer cloud total fails CAS rather than accepting a stale review',
    () async {
      final conflict = await prepareMatching(water, 250, 500);
      cloud.oldRows[water] = {'key': water, 'payload': 600, 'revision': 3};
      await expectLater(
        remote.resolve(
          b,
          conflict,
          true,
          validate: validateAppDocument,
          confirmedMatchingCounter: true,
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(b.getInt(water), 500);
      expect(cloud.oldRows[water]!['payload'], 600);
      expect(remote.conflicts, contains(conflict));
      await sync(b);
      expect(remote.conflicts.single.matchingCounterNeedsReview, isFalse);
      expect(remote.conflicts.single.remote, 600);
    },
  );

  test('a local edit while confirmation is in flight remains local', () async {
    final conflict = await prepareMatching(water, 250, 500);
    final written = Completer<void>(), release = Completer<void>();
    afterWrite = () async {
      written.complete();
      await release.future;
    };
    try {
      final resolving = remote.resolve(
        b,
        conflict,
        true,
        validate: validateAppDocument,
        confirmedMatchingCounter: true,
      );
      await written.future;
      await b.setInt(water, 750);
      release.complete();
      await resolving;
      expect(b.getInt(water), 750);
      expect(cloud.oldRows[water]!['payload'], 500);
      expect(jsonDecode(b.getString('_baseline_$user')!)[water], 500);
      afterWrite = null;
      await sync(b);
      expect(cloud.oldRows[water]!['payload'], 750);
      expect(b.getInt(water), 750);
      expect(remote.conflicts, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      afterWrite = null;
    }
  });

  test(
    'an account change after the server commits does not advance the old baseline',
    () async {
      final conflict = await prepareMatching(water, 250, 500);
      final written = Completer<void>(), release = Completer<void>();
      afterWrite = () async {
        written.complete();
        await release.future;
      };
      try {
        // Observe errors immediately so the deliberately delayed response is safe.
        final resolving = remote
            .resolve(
              b,
              conflict,
              true,
              validate: validateAppDocument,
              confirmedMatchingCounter: true,
            )
            .then((_) => false, onError: (Object error) => error is StateError);
        await written.future;
        await client.auth.setInitialSession(session('another-synthetic-user'));
        release.complete();
        expect(await resolving, isTrue);
        // An already-sent request cannot be retracted. The fake server committed
        // it, but no baseline or conflict state is silently moved to the account.
        expect(cloud.oldRows[water]!['revision'], 3);
        expect(jsonDecode(b.getString('_baseline_$user')!)[water], 250);
        expect(b.getString('_baseline_another-synthetic-user'), isNull);
        expect(remote.conflicts, contains(conflict));
        expect(b.getInt(water), 500);
      } finally {
        if (!release.isCompleted) release.complete();
        afterWrite = null;
      }
    },
  );

  test('account change blocks confirmation of the old comparison', () async {
    final conflict = await prepareMatching(water, 250, 500);
    await client.auth.setInitialSession(session('another-synthetic-user'));
    await expectLater(
      remote.resolve(
        b,
        conflict,
        true,
        validate: validateAppDocument,
        confirmedMatchingCounter: true,
      ),
      throwsStateError,
    );
    expect(b.getInt(water), 500);
    expect(cloud.oldRows[water]!['revision'], 2);
  });

  test(
    'matching non-counter flags keep their existing merge behavior',
    () async {
      const flag = 'workout_completed_2026-10-25';
      await a.setBool(flag, false);
      await sync(a);
      await sync(b);
      await a.setBool(flag, true);
      await b.setBool(flag, true);
      await sync(a);
      await sync(b);
      expect(remote.conflicts, isEmpty);
      expect(b.getBool(flag), isTrue);
    },
  );

  testWidgets('review dialog allows cancellation and explicit confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final provider = AppDataProvider();
    await provider.init();
    try {
      final local = provider.storage.local;
      await a.setInt(water, 250);
      await sync(a);
      await sync(local);
      await a.setInt(water, 500);
      await local.setInt(water, 500);
      await sync(a);
      await sync(local);
      expect(remote.conflicts.single.matchingCounterNeedsReview, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CloudPanel(provider: provider)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Итоги совпадают'), findsOneWidget);
      expect(find.text('Оставить устройство'), findsNothing);
      await tester.ensureVisible(find.text('Подтвердить этот итог'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Подтвердить этот итог'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      // The panel intentionally shows an indeterminate progress indicator while
      // the confirmation dialog is open, so pumpAndSettle would never settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Подтвердить итог?'), findsOneWidget);
      expect(
        find.textContaining('Мы не знаем, нужно ли их суммировать.'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Проверить позже'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(remote.conflicts, hasLength(1));
      expect(cloud.oldRows[water]!['revision'], 2);
      expect(find.text('Подтвердить итог?'), findsNothing);
      await tester.ensureVisible(find.text('Подтвердить этот итог'));
      expect(
        tester
            .widget<TextButton>(
              find
                  .ancestor(
                    of: find.text('Подтвердить этот итог'),
                    matching: find.byType(TextButton),
                  )
                  .first,
            )
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Подтвердить этот итог'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Подтвердить итог?'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Подтвердить'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The dialog's closing animation completes under the fake clock; only
      // then does the callback start its asynchronous mocked network request.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(remote.conflicts, isEmpty);
      expect(local.getInt(water), 500);
      expect(cloud.oldRows[water]!['payload'], 500);
      expect(cloud.oldRows[water]!['revision'], 3);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
    }
  });
}
