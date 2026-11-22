import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/ai_actions.dart';
import 'package:fitness_tracker/smart/ai_preferences.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/ui.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const water = 'water_intake_2026-10-25';
  const steps = 'steps_2026-10-25';
  const otherSteps = 'steps_2026-10-26';
  late AppDataProvider p;

  setUp(() async {
    LocalPreferences.memoryForTests = true;
    LocalPreferences.directoryForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SharedPreferences.setMockInitialValues({});
    p = AppDataProvider();
    await p.init();
  });

  tearDown(() async {
    LocalPreferences.beforeWriteForTests = null;
    LocalPreferences.rejectWriteKeyForTests = null;
    LocalPreferences.onAppWrite = null;
    LocalPreferences.clearImportRecoveryFailure();
    SmartRemote.instance.busy = false;
    p.dispose();
  });

  test(
    'successful import keeps one exportable prior copy; deletion preserves current data',
    () async {
      final local = p.storage.local;
      await local.setInt(water, 250);
      await local.setInt(steps, 1200);
      await local.setString('_ai_consent_test', 'private-local');
      final original = local.snapshot();
      expect(
        await p.storage.importData({
          'data': {water: 800},
        }),
        isTrue,
      );
      expect(local.getInt(water), 800);
      expect(local.getInt(steps), isNull);
      expect(local.hasPendingImport, isFalse);
      expect(local.hasImportBackup, isTrue);
      expect(local.importSyncPaused, isTrue);
      expect(
        local.snapshot().containsKey(LocalPreferences.importSyncPauseKey),
        isFalse,
      );
      final saved = jsonDecode(p.storage.importBackupJson()!) as Map;
      expect(saved['app'], 'fitness_tracker');
      expect(saved['data'], original);
      expect(local.getString('_ai_consent_test'), 'private-local');
      expect((await p.storage.exportData())['data'], {water: 800});

      expect(
        await p.storage.importData({
          'data': {steps: 400},
        }),
        isTrue,
      );
      expect((jsonDecode(p.storage.importBackupJson()!) as Map)['data'], {
        water: 800,
      });
      final current = local.snapshot();
      await p.discardImportBackup();
      expect(local.hasImportBackup, isFalse);
      expect(local.get(LocalPreferences.importJournalKey), isNull);
      expect(local.snapshot(), current);
      expect(local.getString('_ai_consent_test'), 'private-local');
    },
  );

  test(
    'failed checkpoint preparation never clears data or replaces an earlier backup',
    () async {
      final local = p.storage.local;
      await local.setInt(water, 250);
      expect(
        await p.storage.importData({
          'data': {water: 800},
        }),
        isTrue,
      );
      final oldBackup = local.getString(LocalPreferences.importJournalKey);
      final before = local.snapshot();
      LocalPreferences.rejectWriteKeyForTests =
          LocalPreferences.importJournalKey;
      await expectLater(
        p.storage.importData({
          'data': {steps: 100},
        }),
        throwsStateError,
      );
      expect(local.snapshot(), before);
      expect(local.getString(LocalPreferences.importJournalKey), oldBackup);
      expect(local.hasPendingImport, isFalse);
      expect(local.hasImportBackup, isTrue);
    },
  );

  test('failed sync-pause latch prevents data replacement', () async {
    final local = p.storage.local;
    await local.setInt(water, 250);
    LocalPreferences.rejectWriteKeyForTests =
        LocalPreferences.importSyncPauseKey;
    await expectLater(
      p.storage.importData({
        'data': {water: 800},
      }),
      throwsStateError,
    );
    expect(local.getInt(water), 250);
    expect(local.hasPendingImport, isFalse);
    expect(local.importSyncPaused, isFalse);
  });

  test(
    'failed rollback blocks writes and cloud until the original snapshot is restored',
    () async {
      final local = p.storage.local;
      await local.setInt(water, 250);
      await local.setString('_ai_favorites_test', 'not-in-backup');
      final before = local.snapshot();
      var failedImport = false;
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == steps && !failedImport) {
          failedImport = true;
          throw StateError('synthetic import failure');
        }
        if (key == water && failedImport) {
          throw StateError('synthetic rollback failure');
        }
      };
      await expectLater(
        p.storage.importData({
          'data': {steps: 300},
        }),
        throwsA(isA<ImportRecoveryRequired>()),
      );
      expect(local.hasPendingImport, isTrue);
      expect(
        (jsonDecode(p.storage.importBackupJson()!) as Map)['data'],
        before,
      );
      await expectLater(
        local.setInt(otherSteps, 10),
        throwsA(isA<ImportRecoveryRequired>()),
      );
      await expectLater(
        local.putBatch({otherSteps: 10, '_local_batch_marker': true}),
        throwsA(isA<ImportRecoveryRequired>()),
      );
      expect(local.get('_local_batch_marker'), isNull);
      await expectLater(
        SmartRemote.instance.sync(local, validate: validateAppDocument),
        throwsStateError,
      );
      LocalPreferences.beforeWriteForTests = null;
      await p.storage.recoverPendingImport();
      expect(local.hasPendingImport, isFalse);
      expect(local.get(LocalPreferences.importJournalKey), isNull);
      expect(local.snapshot(), before);
      expect(local.getString('_ai_favorites_test'), 'not-in-backup');
      await local.setInt(otherSteps, 10);
      expect(local.getInt(otherSteps), 10);
    },
  );

  test('direct stale writes and cloud sync cannot overlap an import', () async {
    final local = p.storage.local;
    await local.setInt(water, 250);
    final started = Completer<void>(), release = Completer<void>();
    LocalPreferences.beforeWriteForTests = (key) async {
      if (key == water && !started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    final importing = p.storage.importData({
      'data': {water: 800},
    });
    await started.future;
    expect(LocalPreferences.importInProgress, isTrue);
    final stale = expectLater(local.setInt(water, 999), throwsStateError);
    final other = expectLater(local.setInt(otherSteps, 222), throwsStateError);
    final batch = expectLater(
      local.putBatch({otherSteps: 333, '_local_batch_marker': true}),
      throwsStateError,
    );
    await expectLater(
      SmartRemote.instance.sync(local, validate: validateAppDocument),
      throwsStateError,
    );
    expect(local.getInt(water), 250);
    release.complete();
    expect(await importing, isTrue);
    await stale;
    await other;
    await batch;
    expect(local.getInt(water), 800);
    expect(local.getInt(otherSteps), isNull);
    expect(local.get('_local_batch_marker'), isNull);
    await local.setInt(otherSteps, 222); // explicit retry after refreshing
    expect(local.getInt(otherSteps), 222);
  });

  test(
    'queued edits and backup deletion cannot replay after an import',
    () async {
      final local = p.storage.local;
      final day = DateTime(2026, 10, 25);
      await local.setInt(water, 250);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final importing = p.storage.importData({
        'data': {water: 800},
      });
      await started.future;
      final staleWater = expectLater(
        p.storage.setWaterIntake(day, 999),
        throwsStateError,
      );
      final staleSteps = expectLater(
        p.storage.addSteps(day, 42),
        throwsStateError,
      );
      final staleDiscard = expectLater(
        p.discardImportBackup(),
        throwsStateError,
      );
      release.complete();
      expect(await importing, isTrue);
      await Future.wait([staleWater, staleSteps, staleDiscard]);
      expect(local.getInt(water), 800);
      expect(local.getInt(steps), isNull);
      expect(local.hasImportBackup, isTrue);
      expect(
        (jsonDecode(p.storage.importBackupJson()!) as Map)['data'][water],
        250,
      );
      // A new action after refreshing the screen is accepted normally.
      await p.storage.setWaterIntake(day, 900);
      expect(local.getInt(water), 900);
    },
  );

  test(
    'edits queued behind an import before its gate starts are rejected',
    () async {
      final local = p.storage.local;
      final day = DateTime(2026, 10, 25);
      await local.setInt(water, 250);
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (key) async {
        if (key == water && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final firstEdit = p.storage.setWaterIntake(day, 300);
      await started.future;
      final importing = p.storage.importData({
        'data': {water: 800},
      });
      expect(LocalPreferences.importInProgress, isFalse);
      final staleEdit = expectLater(
        p.storage.setWaterIntake(day, 999),
        throwsStateError,
      );
      release.complete();
      await firstEdit;
      expect(await importing, isTrue);
      await staleEdit;
      expect(local.getInt(water), 800);
      expect(
        (jsonDecode(p.storage.importBackupJson()!) as Map)['data'][water],
        300,
      );
    },
  );

  test('import refuses to start while a cloud operation is busy', () async {
    final local = p.storage.local;
    await local.setInt(water, 250);
    SmartRemote.instance.busy = true;
    await expectLater(
      p.storage.importData({
        'data': {water: 800},
      }),
      throwsStateError,
    );
    expect(local.getInt(water), 250);
    expect(local.get(LocalPreferences.importJournalKey), isNull);
  });

  test(
    'mismatched or changing account stops import and preserves its local snapshot',
    () async {
      final local = p.storage.local;
      await local.setInt(water, 250);
      await local.setString('_bound_user', 'owner-a');
      String session(String owner) => jsonEncode({
        'access_token': 'synthetic',
        'token_type': 'bearer',
        'user': {
          'id': owner,
          'aud': 'authenticated',
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-10-25T00:00:00Z',
        },
      });
      final client = SupabaseClient(
        'https://import-owner.test.invalid',
        'synthetic-public',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.setInitialSession(session('owner-b'));
      SmartRemote.instance.client = client;
      final started = Completer<void>(), release = Completer<void>();
      try {
        await expectLater(
          p.storage.importData({
            'data': {water: 800},
          }),
          throwsStateError,
        );
        expect(local.getInt(water), 250);
        expect(local.get(LocalPreferences.importJournalKey), isNull);

        await client.auth.setInitialSession(session('owner-a'));
        LocalPreferences.beforeWriteForTests = (key) async {
          if (key == water && !started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        final importing = expectLater(
          p.storage.importData({
            'data': {water: 800},
          }),
          throwsStateError,
        );
        await started.future;
        await client.auth.setInitialSession(session('owner-b'));
        release.complete();
        await importing;
        expect(local.getInt(water), 250);
        expect(local.getString('_bound_user'), 'owner-a');
        expect(local.hasPendingImport, isFalse);
        expect(local.get(LocalPreferences.importJournalKey), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        LocalPreferences.beforeWriteForTests = null;
        SmartRemote.instance.client = null;
        await client.dispose();
      }
    },
  );

  test(
    'pre-import AI undo cannot remove an identical imported food record',
    () async {
      final local = p.storage.local;
      final day = DateTime(2026, 10, 25);
      final entry = FoodEntry(
        id: 'same-synthetic-id',
        name: 'Синтетическое яблоко',
        caloriesPer100g: 50,
        proteinPer100g: 0,
        fatPer100g: 0,
        carbsPer100g: 12,
        amountGrams: 100,
        mealType: MealType.snack,
        date: day,
      );
      await p.setSelectedDate(day);
      await p.addFoodEntriesBatch([entry]);
      const owner = 'synthetic-import-owner';
      final client = SupabaseClient(
        'https://undo.test.invalid',
        'synthetic-public',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.setInitialSession(
        jsonEncode({
          'access_token': 'synthetic',
          'token_type': 'bearer',
          'user': {
            'id': owner,
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
            'created_at': '2026-10-25T00:00:00Z',
          },
        }),
      );
      SmartRemote.instance.client = client;
      try {
        final undo = AiUndoStore(local, owner);
        final oldGeneration = local.diaryGeneration;
        await undo.remember([entry.toJson()]);
        final snackbarSnapshot = undo.read();
        expect(snackbarSnapshot, hasLength(1));
        final originalDoc = local.getString('food_entries_${dayKey(day)}')!;
        expect(
          await p.storage.importData({
            'data': {'food_entries_${dayKey(day)}': originalDoc},
          }),
          isTrue,
        );
        await p.reloadAll();
        expect(local.diaryGeneration, isNot(oldGeneration));
        expect(undo.read(), isEmpty);
        await expectLater(
          undoAiAddition(p, owner, original: snackbarSnapshot),
          throwsStateError,
        );
        expect((await p.storage.getFoodEntries(day)).single.id, entry.id);
        // A delayed pre-import remember cannot make the old undo valid again.
        await undo.remember(snackbarSnapshot, generation: oldGeneration);
        expect(undo.read(), isEmpty);
      } finally {
        SmartRemote.instance.client = null;
        await client.dispose();
      }
    },
  );

  test(
    'a queued pre-import undo is rejected even if imported food is identical',
    () async {
      final day = DateTime(2026, 10, 25);
      final entry = FoodEntry(
        id: 'queued-synthetic-id',
        name: 'Синтетическая запись',
        caloriesPer100g: 50,
        proteinPer100g: 0,
        fatPer100g: 0,
        carbsPer100g: 12,
        amountGrams: 100,
        mealType: MealType.snack,
        date: day,
      );
      await p.setSelectedDate(day);
      await p.addFoodEntriesBatch([entry]);
      final local = p.storage.local;
      final generation = local.diaryGeneration;
      final key = 'food_entries_${dayKey(day)}';
      final originalDoc = local.getString(key)!;
      final started = Completer<void>(), release = Completer<void>();
      LocalPreferences.beforeWriteForTests = (written) async {
        if (written == key && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final importing = p.storage.importData({
        'data': {key: originalDoc},
      });
      await started.future;
      final staleUndo = expectLater(
        p.undoFoodEntriesBatch([
          entry,
        ], authorizationGuard: () => local.diaryGeneration == generation),
        throwsStateError,
      );
      release.complete();
      expect(await importing, isTrue);
      await staleUndo;
      expect((await p.storage.getFoodEntries(day)).single.id, entry.id);
    },
  );

  test(
    'clear waits for cloud activity and invalidates previously captured undo',
    () async {
      final day = DateTime(2026, 10, 25);
      final entry = FoodEntry(
        id: 'synthetic-clear-id',
        name: 'Синтетическая запись',
        caloriesPer100g: 50,
        proteinPer100g: 0,
        fatPer100g: 0,
        carbsPer100g: 12,
        amountGrams: 100,
        mealType: MealType.snack,
        date: day,
      );
      await p.storage.addFoodEntry(entry);
      final local = p.storage.local;
      final generation = local.diaryGeneration;
      SmartRemote.instance.busy = true;
      await expectLater(p.storage.clearAll(), throwsStateError);
      expect((await p.storage.getFoodEntries(day)).single.id, entry.id);
      SmartRemote.instance.busy = false;
      await p.storage.clearAll();
      expect(local.diaryGeneration, isNot(generation));
      await p.storage.addFoodEntry(entry);
      await expectLater(
        p.undoFoodEntriesBatch([
          entry,
        ], authorizationGuard: () => local.diaryGeneration == generation),
        throwsStateError,
      );
      expect((await p.storage.getFoodEntries(day)).single.id, entry.id);
    },
  );

  testWidgets(
    'an open custom-food editor cannot overwrite an imported catalog',
    (tester) async {
      final local = p.storage.local;
      String item(String name) => jsonEncode([
        {
          'name': name,
          'caloriesPer100g': 100.0,
          'proteinPer100g': 5.0,
          'fatPer100g': 3.0,
          'carbsPer100g': 10.0,
        },
      ]);
      await tester.runAsync(
        () => local.setString('custom_foods', item('Старый продукт')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CustomFoodPanel(provider: p)),
        ),
      );
      await tester.tap(find.text('Старый продукт'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Старая правка');
      await tester.runAsync(
        () => p.storage.importData({
          'data': {'custom_foods': item('Импортированный продукт')},
        }),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Сохранить'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(
        (jsonDecode(local.getString('custom_foods')!) as List).single['name'],
        'Импортированный продукт',
      );
      expect(find.textContaining('Дневник заменён'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an AI review opened before import cannot save its stale draft', (
    tester,
  ) async {
    final day = DateTime(2026, 10, 25);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<int>(
                context: context,
                builder: (_) => AiReviewDialog(
                  items: const [
                    {
                      'name': 'Синтетический творог',
                      'grams': 150.0,
                      'calories': 200.0,
                      'protein': 20.0,
                      'fat': 8.0,
                      'carbs': 12.0,
                      'meal': 'lunch',
                      'assumptions': 'Тест',
                    },
                  ],
                  provider: p,
                  date: day,
                ),
              ),
              child: const Text('Открыть черновик'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть черновик'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => p.storage.importData({
        'data': {water: 800},
      }),
    );
    await tester.pump();
    await tester.tap(find.text('Добавить 1 · 300 ккал'));
    await tester.pump();
    expect(find.textContaining('дневник заменён'), findsOneWidget);
    expect(await tester.runAsync(() => p.storage.getFoodEntries(day)), isEmpty);
    expect(p.storage.local.getInt(water), 800);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('backup panel can discard only the prior local copy', (
    tester,
  ) async {
    final local = p.storage.local;
    await tester.runAsync(() async {
      await local.setInt(water, 250);
      await p.storage.importData({
        'data': {water: 800},
      });
      await p.reloadAll();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BackupPanel(provider: p)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Скопировать копию до импорта'), findsOneWidget);
    // Start the async UI handler in the real zone so the singleton's queue
    // remains usable by later tests after this fake-async widget test ends.
    await tester.runAsync(() => tester.tap(find.text('Удалить эту копию')));
    await tester.pumpAndSettle();
    expect(find.text('Текущий дневник останется без изменений.'), findsNothing);
    expect(
      find.textContaining('Текущий дневник останется без изменений.'),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Удалить копию'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => p.storage.pendingMutations.timeout(const Duration(seconds: 2)),
    );
    expect(local.hasImportBackup, isFalse);
    expect(local.getInt(water), 800);
    expect(find.text('Скопировать копию до импорта'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unfinished or corrupt checkpoint displays fail-closed recovery screen',
    (tester) async {
      final local = p.storage.local;
      await tester.runAsync(() async {
        await local.setInt(water, 250);
        await local.setString(
          LocalPreferences.importJournalKey,
          '${LocalPreferences.importPendingPrefix}${jsonEncode({'version': 1, 'data': local.snapshot()})}',
        );
      });
      await tester.pumpWidget(MyApp(provider: p));
      await tester.pump();
      expect(find.byType(ImportRecoveryScreen), findsOneWidget);
      expect(find.byType(MainScreen), findsNothing);
      expect(find.text('Скопировать резервную копию'), findsOneWidget);
      expect(
        find.textContaining('Не очищайте данные браузера'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => local.setString(LocalPreferences.importJournalKey, 'P1:{broken'),
      );
      await tester.pumpWidget(MyApp(provider: p));
      await tester.pump();
      expect(find.byType(ImportRecoveryScreen), findsOneWidget);
      expect(
        find.textContaining(
          'Автоматически прочитать резервную копию не удалось',
        ),
        findsOneWidget,
      );
      expect(find.text('Скопировать резервную копию'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'reopening a real Hive box restores a simulated interrupted import before reads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fitness_import_recovery_',
      );
      await LocalPreferences.close();
      LocalPreferences.memoryForTests = false;
      LocalPreferences.directoryForTests = directory.path;
      SharedPreferences.setMockInitialValues({});
      try {
        final storage = StorageService();
        await storage.init();
        var local = storage.local;
        await local.setInt(water, 250);
        await local.setInt(steps, 1200);
        await local.setString('_ai_drafts_test', 'local-ai');
        final original = local.snapshot();
        // Recreate the exact durable state after a simulated interruption midway
        // through replacement; the original snapshot is held in one Hive key.
        await local.remove(water);
        await local.setInt(steps, 9999);
        await local.setString(
          LocalPreferences.importJournalKey,
          '${LocalPreferences.importPendingPrefix}${jsonEncode({'version': 1, 'data': original})}',
        );
        await local.flush();
        await LocalPreferences.close();
        await storage.init();
        local = storage.local;
        expect(local.snapshot(), original);
        expect(local.hasPendingImport, isFalse);
        expect(local.get(LocalPreferences.importJournalKey), isNull);
        expect(local.getString('_ai_drafts_test'), 'local-ai');

        expect(
          await storage.importData({
            'data': {water: 700},
          }),
          isTrue,
        );
        await LocalPreferences.close();
        await storage.init();
        local = storage.local;
        expect(local.snapshot(), {water: 700});
        expect(local.hasImportBackup, isTrue);
        expect(local.importSyncPaused, isTrue);
        expect(
          (jsonDecode(storage.importBackupJson()!) as Map)['data'],
          original,
        );
        await storage.clearAll();
        expect(local.snapshot(), isEmpty);
        expect(local.get(LocalPreferences.importJournalKey), isNull);
        expect(local.getString('_ai_drafts_test'), isNull);
      } finally {
        await LocalPreferences.close();
        LocalPreferences.memoryForTests = true;
        LocalPreferences.directoryForTests = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
