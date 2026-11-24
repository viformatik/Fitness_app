// Synthetic-only test: the cloud is an in-memory MockClient, never Supabase.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _user = 'synthetic-cloud-review';
const _water = 'water_intake_2026-10-25';
const _sleep = 'sleep_day_2026-10-25';

String _session(String uid) => jsonEncode({
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

class _Cloud {
  final rows = <String, Map<String, dynamic>>{};
  final sleepRows = <String, Map<String, dynamic>>{};

  http.Response reply(http.Request request, Object body, int status) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/fitness_documents') ||
        path.endsWith('/fitness_sleep_documents')) {
      final table = path.endsWith('/fitness_sleep_documents') ? sleepRows : rows;
      return reply(request, table.values.toList(), 200);
    }
    if (path.endsWith('/rpc/write_fitness_document') ||
        path.endsWith('/rpc/write_fitness_sleep_document')) {
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      final key = data['p_key'] as String;
      final table =
          path.endsWith('/rpc/write_fitness_sleep_document') ? sleepRows : rows;
      final rev = ((table[key]?['revision'] as int?) ?? 0) + 1;
      table[key] = {'key': key, 'payload': data['p_payload'], 'revision': rev};
      return reply(request, rev, 200);
    }
    throw StateError('Unexpected request in a synthetic test: $path');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final remote = SmartRemote.instance;
  late LocalPreferences local;
  late _Cloud cloud;
  late SupabaseClient client;
  late MockClient transport;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    SharedPreferences.setMockInitialValues({});
    local = await LocalPreferences.open();
    await local.setInt(_water, 250);
    await local.setString(_sleep, 'synthetic-local-sleep');
    await local.setString('_baseline_$_user', jsonEncode({_water: 250}));
    cloud = _Cloud();
    transport = MockClient(cloud.handle);
    client = SupabaseClient(
      'https://synthetic-cloud.test.invalid',
      'synthetic-public',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
    );
    await client.auth.setInitialSession(_session(_user));
    remote.client = client;
    remote.conflicts.clear();
    await local.setString('_bound_user', _user);
  });

  tearDown(() async {
    remote.client = null;
    remote.conflicts.clear();
    LocalPreferences.onAppWrite = null;
    await client.dispose();
    transport.close();
    LocalPreferences.memoryForTests = false;
  });

  Future<void> sync() =>
      remote.sync(local, validate: validateAppDocument);

  test('row without payload is rejected before local water is erased', () async {
    cloud.rows[_water] = {'key': _water, 'revision': 1};
    await expectLater(sync(), throwsStateError);
    expect(local.getInt(_water), 250);
  });

  test('sleep row without payload is rejected before local sleep is erased',
      () async {
    cloud.sleepRows[_sleep] = {'key': _sleep, 'revision': 1};
    await expectLater(sync(), throwsStateError);
    expect(local.getString(_sleep), 'synthetic-local-sleep');
  });

  test('row without a valid revision cannot replace local data', () async {
    cloud.rows[_water] = {'key': _water, 'payload': 900};
    await expectLater(sync(), throwsStateError);
    expect(local.getInt(_water), 250);

    cloud.rows[_water] = {'key': _water, 'payload': 900, 'revision': 0};
    await expectLater(sync(), throwsStateError);
    expect(local.getInt(_water), 250);

    cloud.rows[_water] = {
      'key': _water,
      'payload': 900,
      'revision': 9007199254740992,
    };
    await expectLater(sync(), throwsStateError);
    expect(local.getInt(_water), 250);
  });

  test('explicit null payload with a valid revision is a real tombstone',
      () async {
    cloud.rows[_water] = {
      'key': _water,
      'payload': null,
      'revision': 2,
    };
    await sync();
    expect(local.getInt(_water), isNull);
  });
}
