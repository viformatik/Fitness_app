import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/lossless_json.dart';
import 'package:fitness_tracker/smart/weight_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

WeightEntry measurement({
  String id = 'weight-1',
  double value = 79.251,
  String? note = '  утром  ',
  DateTime? date,
}) => WeightEntry(
  id: id,
  weight: value,
  note: note,
  date: date ?? DateTime(2026, 10, 20, 8, 30),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDataProvider p;
  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
    AppTheme.configure({});
  });
  tearDown(() {
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    p.dispose();
    AppTheme.configure({});
  });

  test(
    'fractional history is durable, latest profile and stable equal-time ordering',
    () async {
      final first = measurement();
      final second = measurement(id: 'weight-2', value: 80.123);
      final a = await p.addWeightEntry(first);
      expect(a.warning, isNull);
      expect(p.profile.currentWeight, 79.251);
      expect(p.profile.currentWeightConfirmed, isTrue);
      await p.addWeightEntry(second);
      expect(p.weightEntries.map((e) => e.weight), [79.251, 80.123]);
      expect(p.profile.currentWeight, 80.123);
      final older = measurement(
        id: 'old',
        value: 100.25,
        date: DateTime(2025, 1, 1),
      );
      await p.addWeightEntry(older);
      expect(p.profile.currentWeight, 80.123);
      await p.reloadAll();
      expect(p.weightEntries.map((e) => e.weight), [100.25, 79.251, 80.123]);
      expect(p.weightEntries[1].note, '  утром  ');
      expect(() => p.weightEntries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'failed history write keeps the document and provider unchanged; retry works',
    () async {
      await p.addWeightEntry(measurement());
      final before = p.storage.local.getString('weight_entries');
      final profileBefore = p.storage.local.getString('user_profile');
      final snapshot = p.captureWeightEdit(p.weightEntries.single);
      LocalPreferences.rejectWriteKeyForTests = 'weight_entries';
      await expectLater(
        p.updateWeightEntry(measurement(value: 77.5), snapshot: snapshot),
        throwsStateError,
      );
      expect(p.storage.local.getString('weight_entries'), before);
      expect(p.storage.local.getString('user_profile'), profileBefore);
      expect(p.weightEntries.single.weight, 79.251);
      LocalPreferences.rejectWriteKeyForTests = null;
      final saved = await p.updateWeightEntry(
        measurement(value: 77.5),
        snapshot: snapshot,
      );
      expect(saved.warning, isNull);
      expect(p.weightEntries.single.weight, 77.5);
      expect(p.profile.currentWeight, 77.5);
    },
  );

  test(
    'profile failure is partial success, history is not duplicated or rolled back',
    () async {
      LocalPreferences.rejectWriteKeyForTests = 'user_profile';
      final result = await p.addWeightEntry(measurement());
      expect(result.warning, contains('сохранено, но'));
      expect(p.weightEntries, hasLength(1));
      expect(p.weightEntries.single.weight, 79.251);
      expect(p.profile.currentWeightConfirmed, isFalse);
      expect(p.storage.local.getString('user_profile'), isNull);
      expect(
        jsonDecode(p.storage.local.getString('weight_entries')!) as List,
        hasLength(1),
      );
    },
  );

  test(
    'independent or unknown profile value is preserved when adding history',
    () async {
      await p.updateProfile(p.profile.copyWith(currentWeight: 88));
      final before = p.storage.local.getString('user_profile');
      final result = await p.addWeightEntry(measurement());
      expect(result.warning, contains('профиле оставлен без изменения'));
      expect(p.storage.local.getString('user_profile'), before);
      expect(p.profile.currentWeight, 88);
      expect(p.weightEntries.single.weight, 79.251);

      await p.storage.local.setString(
        'user_profile',
        jsonEncode({
          'currentWeight': 95,
          'futureProfileField': {'keep': 'unchanged'},
        }),
      );
      await p.reloadAll();
      final futureRaw = p.storage.local.getString('user_profile');
      final next = await p.addWeightEntry(
        measurement(id: 'weight-2', value: 81),
      );
      expect(next.warning, contains('не обновился'));
      expect(p.storage.local.getString('user_profile'), futureRaw);
      expect(p.weightEntries, hasLength(2));
    },
  );

  test(
    'a concurrent conditional profile edit is not overwritten by a weight save',
    () async {
      await p.addWeightEntry(measurement());
      final store = p.storage.local;
      final beforeHistory = store.getString('weight_entries');
      final profileBefore = store.getString('user_profile')!;
      final changedProfile = Map<String, dynamic>.from(
        jsonDecode(profileBefore) as Map,
      )..['ageYears'] = 29;
      Future<bool>? concurrent;
      LocalPreferences.onAppWrite = () {
        if (concurrent == null &&
            store.getString('weight_entries') != beforeHistory) {
          concurrent = store.compareAndPut(
            'user_profile',
            profileBefore,
            jsonEncode(changedProfile),
          );
        }
      };
      final result = await p.addWeightEntry(
        measurement(id: 'weight-2', value: 80.5),
      );
      expect(await concurrent, isTrue);
      final after = jsonDecode(store.getString('user_profile')!) as Map;
      expect(after['ageYears'], 29);
      expect(p.weightEntries, hasLength(2));
      if (after['currentWeight'] != 80.5) {
        expect(result.warning, contains('не обновился'));
      }
      LocalPreferences.onAppWrite = null;
    },
  );

  test(
    'stale profile updates are rejected and the durable profile is reloaded',
    () async {
      await p.updateProfile(p.profile.copyWith(ageYears: 18));
      final store = p.storage.local;
      final next = Map<String, dynamic>.from(
        jsonDecode(store.getString('user_profile')!) as Map,
      )..['ageYears'] = 29;
      final remoteRaw = jsonEncode(next);
      await store.setString('user_profile', remoteRaw);
      await expectLater(
        p.updateProfile(p.profile.copyWith(targetProtein: 123)),
        throwsA(isA<ProfileEditException>()),
      );
      expect(store.getString('user_profile'), remoteRaw);
      expect(p.profile.ageYears, 29);
      expect(p.profile.targetProtein, isNot(123));
    },
  );

  test('settings cannot truncate unknown profile fields', () async {
    final raw = jsonEncode({
      'ageYears': 29,
      'currentWeight': 80,
      'future': {'preserve': 'exactly'},
    });
    await p.storage.local.setString('user_profile', raw);
    await p.reloadAll();
    await expectLater(
      p.updateProfile(p.profile.copyWith(ageYears: 30)),
      throwsA(isA<ProfileEditException>()),
    );
    expect(p.storage.local.getString('user_profile'), raw);
    expect(p.profile.ageYears, 29);
  });

  test(
    'failed competing profile edits restore the actual stored profile',
    () async {
      await p.updateProfile(p.profile.copyWith(ageYears: 18));
      final before = p.storage.local.getString('user_profile');
      LocalPreferences.rejectWriteKeyForTests = 'user_profile';
      Future<bool> accepted(Future<void> change) async {
        try {
          await change;
          return true;
        } catch (_) {
          return false;
        }
      }

      final first = accepted(p.updateProfile(p.profile.copyWith(ageYears: 19)));
      final second = accepted(
        p.updateProfile(p.profile.copyWith(ageYears: 20)),
      );
      expect(await Future.wait([first, second]), [false, false]);
      expect(p.storage.local.getString('user_profile'), before);
      expect(p.profile.ageYears, 18);
    },
  );

  test('settings and weight changes cannot overwrite one another', () async {
    await p.addWeightEntry(measurement());
    final store = p.storage.local;
    final beforeHistory = store.getString('weight_entries');
    Future<void>? edit;
    LocalPreferences.onAppWrite = () {
      if (edit == null && store.getString('weight_entries') != beforeHistory) {
        edit = p.updateProfile(p.profile.copyWith(ageYears: 29));
      }
    };
    final result = await p.addWeightEntry(
      measurement(id: 'weight-2', value: 80.5),
    );
    expect(edit, isNotNull);
    await edit;
    LocalPreferences.onAppWrite = null;
    final stored = UserProfile.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(store.getString('user_profile')!) as Map,
      ),
    );
    expect(stored.ageYears, 29);
    expect(p.profile.ageYears, 29);
    expect(p.weightEntries, hasLength(2));
    if (stored.currentWeight != 80.5) {
      expect(result.warning, contains('не обновился'));
    }
    expect(p.profile.currentWeight, stored.currentWeight);
  });

  test(
    'untouched rows and unchanged fields retain their exact JSON digits',
    () async {
      const first =
          r'{"id":"high","weight":78.1234567891234567890123,"date":"2026-01-01T00:00:00.123456789Z","note":"старое \" } , [ текст"}';
      const second =
          r'{"id":"other","weight":81.234000000000000000012345,"date":"2026-01-02T00:00:00Z"}';
      await p.storage.local.setString(
        'weight_entries',
        '[ $first,\n $second ]',
      );
      await p.reloadAll();
      await p.addWeightEntry(measurement(id: 'new'));
      var raw = p.storage.local.getString('weight_entries')!;
      expect(raw, contains(first));
      expect(raw, contains(second));
      final old = p.weightEntries.firstWhere((entry) => entry.id == 'high');
      await p.updateWeightEntry(
        WeightEntry(
          id: old.id,
          weight: old.weight,
          date: old.date,
          note: 'новое',
        ),
      );
      raw = p.storage.local.getString('weight_entries')!;
      expect(raw, contains('78.1234567891234567890123'));
      expect(raw, contains('2026-01-01T00:00:00.123456789Z'));
      expect(raw, contains('"note":"новое"'));
      expect(raw, contains(second));
      final other = p.weightEntries.firstWhere((entry) => entry.id == 'other');
      await p.updateWeightEntry(
        WeightEntry(id: other.id, weight: 82.75, date: other.date),
      );
      raw = p.storage.local.getString('weight_entries')!;
      expect(
        raw,
        contains(
          r'{"id":"other","weight":82.75,"date":"2026-01-02T00:00:00Z"}',
        ),
      );
    },
  );

  test('ambiguous duplicate JSON properties are not rewritten', () {
    for (final raw in [
      r'[{"id":"x","id":"y","weight":80,"date":"2026-01-01"}]',
      r'[{"id":"x","i\u0064":"y","weight":80,"date":"2026-01-01"}]',
      r'[{"id":"x","weight":80,"weight":81,"date":"2026-01-01"}]',
    ]) {
      expect(() => safeWeightRows(raw), throwsA(isA<WeightEditException>()));
    }
  });

  test('raw row scanner handles escaped text and whitespace', () {
    for (final note in [
      '',
      'текст',
      r'строка "} [ , \\',
      'строка\nстрока',
      '😀',
    ]) {
      final row = jsonEncode({
        'id': 'x',
        'weight': 80.25,
        'date': '2026-01-01',
        'note': note,
      });
      final document = safeWeightDocument(' \n[ \t$row \r ] ');
      expect(document.rawRows, [row]);
      expect(document.rows.single['note'], note);
    }
  });

  test(
    'profile settings retain untouched source precision and reject duplicate keys',
    () async {
      const source =
          r'{"ageYears":18,"height":180.123456789123456789,"heightConfirmed":true,"currentWeight":79.123456789123456789,"currentWeightConfirmed":true}';
      await p.storage.local.setString('user_profile', source);
      await p.reloadAll();
      await p.updateProfile(p.profile.copyWith(ageYears: 19));
      final saved = p.storage.local.getString('user_profile')!;
      expect(saved, contains('180.123456789123456789'));
      expect(saved, contains('79.123456789123456789'));
      expect(saved, contains('"ageYears":19'));

      const duplicate = r'{"ageYears":18,"age\u0059ears":19,"height":180}';
      await p.storage.local.setString('user_profile', duplicate);
      await p.reloadAll();
      await expectLater(
        p.updateProfile(p.profile.copyWith(ageYears: 20)),
        throwsA(isA<ProfileEditException>()),
      );
      expect(p.storage.local.getString('user_profile'), duplicate);
      final partial = await p.addWeightEntry(measurement());
      expect(partial.warning, contains('не обновился'));
      expect(p.storage.local.getString('user_profile'), duplicate);
    },
  );

  test(
    'distinct high-precision profile values are not confused by double rounding',
    () async {
      const history =
          r'[{"id":"old","weight":79.1234567891234567111,"date":"2026-01-01"}]';
      const profile =
          r'{"currentWeight":79.1234567891234567222,"currentWeightConfirmed":true}';
      await p.storage.local.setString('weight_entries', history);
      await p.storage.local.setString('user_profile', profile);
      await p.reloadAll();
      final result = await p.addWeightEntry(measurement(id: 'new', value: 81));
      expect(result.warning, contains('оставлен без изменения'));
      expect(p.storage.local.getString('user_profile'), profile);
      expect(
        p.storage.local.getString('weight_entries'),
        contains('79.1234567891234567111'),
      );
    },
  );

  test(
    'profile update copies an exact latest weight while retaining other numbers',
    () async {
      const history =
          r'[{"id":"precise","weight":78.123456789123456789,"date":"2026-01-01"},{"id":"latest","weight":80,"date":"2026-01-02"}]';
      const profile =
          r'{"currentWeight":80.00,"currentWeightConfirmed":true,"height":180.123456789123456789,"heightConfirmed":true}';
      await p.storage.local.setString('weight_entries', history);
      await p.storage.local.setString('user_profile', profile);
      await p.reloadAll();
      final old = p.weightEntries.firstWhere((entry) => entry.id == 'precise');
      final result = await p.updateWeightEntry(
        WeightEntry(id: old.id, weight: old.weight, date: DateTime(2026, 2, 1)),
      );
      expect(result.warning, isNull);
      final saved = p.storage.local.getString('user_profile')!;
      expect(saved, contains('"currentWeight":78.123456789123456789'));
      expect(saved, contains('"height":180.123456789123456789'));
    },
  );

  test(
    'confirming a default-number measurement writes the value explicitly',
    () async {
      await p.updateProfile(p.profile.copyWith(currentWeight: 85.9));
      final saved =
          jsonDecode(p.storage.local.getString('user_profile')!) as Map;
      expect(saved['currentWeight'], 85.9);
      expect(saved['currentWeightConfirmed'], isTrue);
      expect(saved.containsKey('ageYears'), isTrue);
      expect(saved['ageYears'], isNull);
      await p.reloadAll();
      expect(p.profile.currentWeightConfirmed, isTrue);
    },
  );

  test(
    'exact JSON decimal comparison handles exponents and trailing zeroes',
    () {
      expect(sameJsonNumber('80.00', '8e1'), isTrue);
      expect(sameJsonNumber('0.0123000', '123e-4'), isTrue);
      expect(sameJsonNumber('-0', '0.0'), isTrue);
      expect(
        sameJsonNumber('79.1234567891234567111', '79.1234567891234567222'),
        isFalse,
      );
      expect(sameJsonNumber('NaN', 'NaN'), isFalse);
    },
  );

  test('invalid measurements never touch history', () async {
    for (final value in [double.nan, double.infinity, 0.0, -1.0, 300.01]) {
      await expectLater(
        p.addWeightEntry(measurement(value: value)),
        throwsA(isA<WeightEditException>()),
      );
      expect(p.storage.local.getString('weight_entries'), isNull);
      expect(p.weightEntries, isEmpty);
    }
  });

  test(
    'last delete is explicit and leaves separately stored profile intact',
    () async {
      await p.addWeightEntry(measurement());
      final profile = p.storage.local.getString('user_profile');
      final result = await p.deleteWeightEntry('weight-1');
      expect(result.warning, contains('удалено'));
      expect(result.warning, contains('в профиле не изменён'));
      expect(p.weightEntries, isEmpty);
      expect(p.storage.local.getString('user_profile'), profile);
      expect(p.profile.currentWeight, 79.251);
    },
  );

  test(
    'future fields in any row block edits without altering the history',
    () async {
      final raw = jsonEncode([
        measurement().toJson(),
        {
          ...measurement(id: 'other', value: 81).toJson(),
          'futureMeasurement': {'preserve': true},
        },
      ]);
      await p.storage.local.setString('weight_entries', raw);
      await p.reloadAll();
      await expectLater(
        p.deleteWeightEntry('weight-1'),
        throwsA(isA<WeightEditException>()),
      );
      await expectLater(
        p.addWeightEntry(measurement(id: 'new')),
        throwsA(isA<WeightEditException>()),
      );
      expect(p.storage.local.getString('weight_entries'), raw);
      expect(p.weightEntries, hasLength(2));
      final bads = [
        jsonEncode([measurement().toJson(), measurement().toJson()]),
        jsonEncode([
          {'weight': 80, 'date': '2026-01-01'},
        ]),
        jsonEncode([
          {'id': 'x', 'weight': -1, 'date': '2026-01-01'},
        ]),
        jsonEncode([
          {'id': 'x', 'weight': 80, 'date': 'invalid'},
        ]),
      ];
      for (final bad in bads) {
        expect(() => safeWeightRows(bad), throwsA(isA<WeightEditException>()));
      }
    },
  );

  test('stale or competing snapshots never overwrite another change', () async {
    await p.addWeightEntry(measurement());
    final old = p.weightEntries.single;
    final stale = p.captureWeightEdit(old);
    await p.updateWeightEntry(measurement(value: 78.125));
    final updated = p.storage.local.getString('weight_entries');
    await expectLater(
      p.deleteWeightEntry(old.id, snapshot: stale),
      throwsA(isA<WeightEditException>()),
    );
    expect(p.storage.local.getString('weight_entries'), updated);
    // The UI model can be stale even if it captures the newest raw document.
    final staleModel = p.captureWeightEdit(old);
    await expectLater(
      p.updateWeightEntry(measurement(value: 77), snapshot: staleModel),
      throwsA(isA<WeightEditException>()),
    );
    expect(p.weightEntries.single.weight, 78.125);

    final snapshot1 = p.captureWeightEdit(), snapshot2 = p.captureWeightEdit();
    Future<bool> add(String id) async {
      try {
        await p.addWeightEntry(
          measurement(id: id, value: 81),
          snapshot: id == 'a' ? snapshot1 : snapshot2,
        );
        return true;
      } on WeightEditException {
        return false;
      }
    }

    final outcomes = await Future.wait([add('a'), add('b')]);
    expect(outcomes.where((v) => v), hasLength(1));
    expect(p.weightEntries, hasLength(2));
    expect(p.weightEntries.first.weight, 78.125);
  });

  Future<void> openEditor(
    WidgetTester tester,
    WeightEntry? entry,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => WeightEntryDialog(provider: p, entry: entry),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'edit preserves untouched precision and note; failure can be retried',
    (tester) async {
      await tester.runAsync(() => p.addWeightEntry(measurement()));
      final before = p.storage.local.getString('weight_entries');
      await openEditor(tester, p.weightEntries.single, const Size(320, 740));
      final field = find.widgetWithText(TextField, 'Вес');
      expect(tester.widget<TextField>(field).controller!.text, '79.251');
      LocalPreferences.rejectWriteKeyForTests = 'weight_entries';
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await p.storage.pendingMutations;
      });
      await tester.pump();
      expect(find.textContaining('Не удалось изменить запись'), findsOneWidget);
      expect(p.storage.local.getString('weight_entries'), before);
      LocalPreferences.rejectWriteKeyForTests = null;
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await p.storage.pendingMutations;
      });
      await tester.pumpAndSettle();
      expect(find.byType(WeightEntryDialog), findsNothing);
      expect(p.weightEntries.single.weight, 79.251);
      expect(p.weightEntries.single.note, '  утром  ');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'profile failure closes the saved measurement and shows a partial-success warning',
    (tester) async {
      await openEditor(tester, null, const Size(320, 740));
      await tester.enterText(find.widgetWithText(TextField, 'Вес'), '78,125');
      LocalPreferences.rejectWriteKeyForTests = 'user_profile';
      await tester.runAsync(() async {
        await tester.tap(find.text('Добавить'));
        await p.storage.pendingMutations;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(find.byType(WeightEntryDialog), findsNothing);
      expect(find.textContaining('сохранено, но текущий вес'), findsOneWidget);
      expect(p.weightEntries, hasLength(1));
      expect(p.weightEntries.single.weight, 78.125);
      expect(p.storage.local.getString('user_profile'), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delete asks first; cancelling keeps data and confirming does not erase food',
    (tester) async {
      await tester.runAsync(() async {
        await p.addWeightEntry(measurement());
        await p.storage.local.setString('food_entries_2026-10-20', '[]');
      });
      await openEditor(tester, p.weightEntries.single, const Size(320, 740));
      await tester.runAsync(() => tester.tap(find.text('Удалить').first));
      await tester.pumpAndSettle();
      expect(find.text('Удалить измерение?'), findsOneWidget);
      await tester.tap(find.text('Отмена').last);
      await tester.pumpAndSettle();
      expect(p.weightEntries, hasLength(1));
      await tester.runAsync(() => tester.tap(find.text('Удалить').first));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Удалить').last));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => p.storage.pendingMutations);
      await tester.pumpAndSettle();
      expect(p.weightEntries, isEmpty);
      expect(p.storage.local.getString('food_entries_2026-10-20'), '[]');
      expect(find.textContaining('в профиле не изменён'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stale editor cannot overwrite the newer measurement', (
    tester,
  ) async {
    await tester.runAsync(() => p.addWeightEntry(measurement()));
    await openEditor(tester, p.weightEntries.single, const Size(390, 844));
    await tester.runAsync(() => p.updateWeightEntry(measurement(value: 78.25)));
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить'));
      await p.storage.pendingMutations;
    });
    await tester.pump();
    expect(find.textContaining('История веса изменилась'), findsOneWidget);
    expect(p.weightEntries.single.weight, 78.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets('prefilled last measurement is visibly marked for review', (
    tester,
  ) async {
    await tester.runAsync(() => p.addWeightEntry(measurement()));
    await openEditor(tester, null, const Size(320, 740));
    expect(
      find.textContaining('Подставлено последнее измерение'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Вес'))
          .controller!
          .text,
      '79.251',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard inset in short landscape keeps the editor scrollable', (
    tester,
  ) async {
    await openEditor(tester, null, const Size(900, 320));
    tester.view.viewInsets = const FakeViewPadding(bottom: 150);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Вес');
    await tester.ensureVisible(field);
    await tester.enterText(field, '83,625');
    await tester.pump();
    expect(tester.takeException(), isNull);
    final button = find.text('Добавить');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(tester.getRect(button).bottom, lessThanOrEqualTo(170));
    await tester.runAsync(() async {
      await tester.tap(button);
      await p.storage.pendingMutations;
    });
    await tester.pumpAndSettle();
    expect(p.weightEntries.single.weight, 83.625);
    expect(tester.takeException(), isNull);
  });

  testWidgets('weight dialog can be used in short landscape', (tester) async {
    await openEditor(tester, null, const Size(900, 320));
    final field = find.widgetWithText(TextField, 'Вес');
    await tester.ensureVisible(field);
    await tester.enterText(field, '84,375');
    await tester.ensureVisible(find.text('Добавить'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Добавить'));
      await p.storage.pendingMutations;
    });
    await tester.pumpAndSettle();
    expect(p.weightEntries.single.weight, 84.375);
    expect(tester.takeException(), isNull);
  });
}
