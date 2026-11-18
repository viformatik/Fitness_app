import 'dart:async';
import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A previous import could not be rolled back yet. Its checkpoint is retained;
/// application writes must remain blocked until recovery succeeds.
class ImportRecoveryRequired implements Exception {
  const ImportRecoveryRequired();

  @override
  String toString() =>
      'Нужно восстановить незавершённый импорт. Освободите место и перезапустите приложение.';
}

/// Existing storage keys are retained. Migration is one-way and non-destructive:
/// legacy preferences are not deleted. App documents live in Hive after migration.
class LocalPreferences {
  static bool memoryForTests = false;
  static String? rejectWriteKeyForTests;
  static String? directoryForTests;

  /// Test-only hook for deterministic interleavings in an isolated memory or
  /// temporary-directory store. Never invoked in a normal application store.
  static Future<void> Function(String key)? beforeWriteForTests;
  static void Function()? onAppWrite;
  static Future<void> close() async {
    await _box?.close();
    _box = null;
  }

  static Box<dynamic>? _box;
  // Hive is shared by wrappers in this isolate, so their queues must be shared
  // as well. Separate in-memory test stores intentionally keep separate queues.
  static final Map<String, Future<void>> _hiveWrites = {};
  // Hive's eager keystore settles transactions in FIFO order. A later write
  // to a different key can fail before an earlier IndexedDB transaction ends;
  // allowing both into Hive can then roll back the wrong in-memory transaction.
  // Admit wrapper operations to this one box sequentially, without swallowing
  // their errors for callers. This is only an in-isolate application guard:
  // direct Hive calls, startup migration, other tabs/processes and devices are
  // not coordinated by this tail.
  static Future<void> _hiveOperationTail = Future<void>.value();
  final Map<String, Object> _memory;
  final Map<String, Future<void>> _memoryWrites = {};
  LocalPreferences._(this._memory);

  // The checkpoint is deliberately not an appKey: it must never be synced,
  // exported as a normal document, or removed by an ordinary clear operation.
  static const importJournalKey = '_pending_import_v1';

  /// Changes before replacement starts, invalidating pre-import undo actions.
  /// It is a local version token, not a credential or an exported document.
  static const diaryGenerationKey = '_diary_generation_v1';
  String get diaryGeneration => getString(diaryGenerationKey) ?? '';

  /// Local-only safety latch. It is deliberately not exported or synced.
  /// A confirmed manual sync is required after an import before automatic
  /// sync can resume, including after an application restart.
  static const importSyncPauseKey = '_import_sync_pause_v1';
  bool get importSyncPaused => getBool(importSyncPauseKey) == true;
  static const importPendingPrefix = 'P1:';
  static const importCommittedPrefix = 'C1:';
  static final Object _importZoneKey = Object();
  static Completer<void>? _importGate;
  static Object? _importToken;
  // Imports retain local AI/privacy settings; an explicit clear-all removes
  // them. Only the latter must fence concurrent writes to these keys as well.
  static bool _blockLocalPrivacyWrites = false;
  static int _queuedPrivacyClears = 0;
  static bool _recoveryFailedInProcess = false;
  static bool get importInProgress => _importGate != null;

  // Invalidates authorizations captured by asynchronous AI/voice work. This is
  // deliberately process-local: other tabs and already transmitted requests
  // are not cancelled. Reaccepting consent must not revive an earlier request.
  static final ValueNotifier<int> _privacyEpoch = ValueNotifier<int>(0);
  static int get privacyEpoch => _privacyEpoch.value;
  static ValueListenable<int> get privacyChanges => _privacyEpoch;
  static bool privacyEpochIsCurrent(int epoch) =>
      epoch == _privacyEpoch.value && !localPrivacyClearInProgress;
  static void invalidatePrivacyEpoch() => _privacyEpoch.value++;

  // Mark clear as soon as the caller queues it, not only after older diary
  // mutations finish. A failed/rejected clear still invalidates old work.
  static void beginQueuedPrivacyClear() {
    _queuedPrivacyClears++;
    invalidatePrivacyEpoch();
  }

  static void endQueuedPrivacyClear() {
    assert(_queuedPrivacyClears > 0);
    _queuedPrivacyClears--;
  }

  /// Existing privacy approvals must not authorize new work during clear-all.
  /// This only reflects the operation in this Dart isolate.
  static bool get localPrivacyClearInProgress =>
      _queuedPrivacyClears > 0 ||
      (_importGate != null && _blockLocalPrivacyWrites);

  static void markImportRecoveryFailed() => _recoveryFailedInProcess = true;
  static void clearImportRecoveryFailure() => _recoveryFailedInProcess = false;
  bool get hasPendingImport {
    final journal = get(importJournalKey);
    return _recoveryFailedInProcess ||
        (journal != null &&
            (journal is! String || !journal.startsWith(importCommittedPrefix)));
  }

  bool get hasImportBackup {
    final journal = get(importJournalKey);
    return journal is String && journal.startsWith(importCommittedPrefix);
  }

  static bool get _insideImport =>
      _importToken != null &&
      identical(Zone.current[_importZoneKey], _importToken);

  /// Excludes direct document and checkpoint writes while a checkpointed
  /// import/recovery is running. A full clear also fences writes to local
  /// privacy settings so a newly created key cannot escape its key snapshot.
  /// Only in-isolate coordination is provided, not a browser-tab or process
  /// lock.
  Future<T> runExclusiveImport<T>(
    Future<T> Function() action, {
    bool blockLocalPrivacyWrites = false,
  }) async {
    if (_importGate != null) {
      throw StateError('Дождитесь завершения другого импорта или очистки');
    }
    final gate = Completer<void>();
    final token = Object();
    _importGate = gate;
    _importToken = token;
    _blockLocalPrivacyWrites = blockLocalPrivacyWrites;
    if (blockLocalPrivacyWrites) invalidatePrivacyEpoch();
    try {
      // Writes submitted before the gate finish before the snapshot/clear.
      final queue = memoryForTests ? _memoryWrites : _hiveWrites;
      await Future.wait(queue.values.toList());
      return await runZoned(action, zoneValues: {_importZoneKey: token});
    } finally {
      _blockLocalPrivacyWrites = false;
      _importToken = null;
      _importGate = null;
      gate.complete();
    }
  }

  Future<T> _queueWrite<T>(String key, Future<T> Function() action) =>
      _queueWrites({key}, action);

  /// Reserve every key before waiting, so single-key writes and batches are
  /// ordered consistently even when batches overlap on different subsets.
  /// For the shared Hive box, also serialize operations across distinct keys;
  /// the in-memory test backend keeps its existing per-key scheduling.
  Future<T> _queueWrites<T>(Set<String> keys, Future<T> Function() action) {
    if (!_insideImport) {
      final hasAppKey = keys.any(appKey);
      final hasLocalPrivacyKey = keys.any(localPrivacyKey);
      final hasImportJournal = keys.contains(importJournalKey);
      final gate = _importGate;
      if (gate != null &&
          (hasAppKey ||
              hasImportJournal ||
              (_blockLocalPrivacyWrites && hasLocalPrivacyKey))) {
        // A direct write may carry a stale screen snapshot even if the stored
        // value happened to become identical again. Reject it after the gate
        // opens rather than replaying an intent against replaced/cleared data.
        return gate.future.then<T>(
          (_) => throw StateError(
            'Во время импорта или очистки данные могли измениться. Обновите экран и повторите запись.',
          ),
        );
      }
      if (hasAppKey && hasPendingImport) {
        return Future<T>.error(const ImportRecoveryRequired());
      }
    }
    final usingMemory = memoryForTests;
    final queue = usingMemory ? _memoryWrites : _hiveWrites;
    final prior = keys
        .map((key) => queue[key])
        .whereType<Future<void>>()
        .toSet();
    if (!usingMemory) prior.add(_hiveOperationTail);
    final next = Future.wait(prior).then<T>((_) => action());
    // A failure is still returned by `next`; only the ordering tail is made
    // successful so a later deliberate action can run and report its outcome.
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    if (!usingMemory) _hiveOperationTail = tail;
    for (final key in keys) {
      queue[key] = tail;
    }
    tail.then((_) {
      for (final key in keys) {
        if (identical(queue[key], tail)) queue.remove(key);
      }
    });
    return next;
  }

  /// Wait for earlier writes to this key, then check the displayed snapshot
  /// without changing it. Useful before uploading a user's conflict choice.
  /// This coordinates only this isolate, not other tabs or processes.
  Future<bool> matchesQueued(
    String key,
    Object? expected, {
    bool Function()? authorizationGuard,
  }) => _queueWrite(key, () async {
    if (authorizationGuard != null && !authorizationGuard()) {
      throw StateError('Аккаунт или привязка изменились. Проверка отменена.');
    }
    return get(key) == expected;
  });

  /// Conditional updates, ordinary writes and removals to a key participate
  /// in the same in-isolate queue. This is not a cross-tab/process lock.
  Future<bool> compareAndPut(
    String key,
    Object? expected,
    Object? value, {
    bool Function()? authorizationGuard,
  }) => _queueWrite(key, () async {
    if (authorizationGuard != null && !authorizationGuard()) {
      throw StateError('Аккаунт или привязка изменились. Запись отменена.');
    }
    if (get(key) != expected) return false;
    if (value == null) {
      await _removeUnlocked(key);
    } else {
      await _putUnlocked(key, value);
    }
    return true;
  });

  // Keep this allowlist in one place for both clear-all and its write fence.
  // It does not include the account binding, sync baseline or import journal.
  static bool localPrivacyKey(String key) =>
      key == '_voice_notice_v1' ||
      const [
        '_ai_drafts_',
        '_ai_consent_',
        '_ai_favorites_',
        '_ai_undo_',
      ].any(key.startsWith);

  static bool appKey(String key) =>
      RegExp(
        r'^supplement_entries_[0-9]{4}-[0-9]{2}-[0-9]{2}$',
      ).hasMatch(key) ||
      RegExp(r'^gym_session_[a-zA-Z0-9_-]{1,80}$').hasMatch(key) ||
      RegExp(r'^sleep_day_[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(key) ||
      const [
        'food_entries_',
        'workout_entries_',
        'water_intake_',
        'steps_',
        'workout_completed_',
      ].any(key.startsWith) ||
      const {
        'weight_entries',
        'user_profile',
        'quick_foods',
        'recipes',
        'reminders',
        'smart_settings',
        'meal_templates',
        'custom_foods',
        'gym_plan_settings',
      }.contains(key);

  static Future<LocalPreferences> open() async {
    final prefs = await SharedPreferences.getInstance();
    if (memoryForTests) {
      return LocalPreferences._({
        for (final key in prefs.getKeys())
          if (prefs.get(key) != null) key: prefs.get(key)!,
      });
    }
    if (_box == null || !_box!.isOpen) {
      if (directoryForTests != null) {
        Hive.init(directoryForTests);
      } else {
        await Hive.initFlutter();
      }
      _box = await Hive.openBox<dynamic>('fitness_v2');
    }
    if (_box!.get('_migration_v1') != true) {
      for (final key in prefs.getKeys().where(appKey)) {
        if (!_box!.containsKey(key)) await _box!.put(key, prefs.get(key));
      }
      await _box!.put('_migration_v1', true);
      await _box!.flush();
    }
    return LocalPreferences._({});
  }

  Object? get(String key) => memoryForTests ? _memory[key] : _box!.get(key);
  String? getString(String key) => get(key) as String?;
  int? getInt(String key) => get(key) as int?;
  bool? getBool(String key) => get(key) as bool?;
  List<String>? getStringList(String key) =>
      (get(key) as List?)?.cast<String>();
  Set<String> getKeys() =>
      memoryForTests ? _memory.keys.toSet() : _box!.keys.cast<String>().toSet();
  Future<bool> setString(String key, String value) => put(key, value);
  Future<bool> setInt(String key, int value) => put(key, value);
  Future<bool> setBool(String key, bool value) => put(key, value);
  Future<bool> setDouble(String key, double value) => put(key, value);
  Future<bool> setStringList(String key, List<String> value) => put(key, value);
  Future<bool> put(String key, Object value) =>
      _queueWrite(key, () => _putUnlocked(key, value));

  /// Write a small, frozen group through one Hive batch. On the patched web
  /// backend it uses one IndexedDB transaction and resolves after commit. This
  /// is not a hardware-flush guarantee or an atomic multi-document cloud sync.
  /// Single-key operations on any of these keys share the same local queue.
  Future<bool> putBatch(Map<String, Object> values) {
    if (values.isEmpty) return Future<bool>.value(true);
    final frozen = <String, Object>{};
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is String ||
          value is int ||
          value is bool ||
          (value is double && value.isFinite)) {
        frozen[entry.key] = value;
      } else {
        throw ArgumentError('Неподдерживаемое значение в пакете записей');
      }
    }
    return _queueWrites(frozen.keys.toSet(), () async {
      // Test faults and hooks run before any memory or Hive value is changed.
      for (final key in frozen.keys) {
        if (memoryForTests && key == rejectWriteKeyForTests) {
          throw StateError('Simulated storage write failure');
        }
        final hook = beforeWriteForTests;
        if (hook != null && (memoryForTests || directoryForTests != null)) {
          await hook(key);
        }
      }
      if (memoryForTests) {
        _memory.addAll(frozen);
      } else {
        await _box!.putAll(frozen);
      }
      if (frozen.keys.any(appKey)) onAppWrite?.call();
      return true;
    });
  }

  Future<bool> _putUnlocked(String key, Object value) async {
    if (memoryForTests && key == rejectWriteKeyForTests) {
      throw StateError('Simulated storage write failure');
    }
    final hook = beforeWriteForTests;
    if (hook != null && (memoryForTests || directoryForTests != null)) {
      await hook(key);
    }
    if (memoryForTests) {
      _memory[key] = value;
    } else {
      await _box!.put(key, value);
    }
    if (appKey(key)) onAppWrite?.call();
    return true;
  }

  Future<bool> remove(String key) =>
      _queueWrite(key, () => _removeUnlocked(key));

  Future<bool> _removeUnlocked(String key) async {
    final hook = beforeWriteForTests;
    if (hook != null && (memoryForTests || directoryForTests != null)) {
      await hook(key);
    }
    if (memoryForTests) {
      _memory.remove(key);
    } else {
      await _box!.delete(key);
    }
    if (appKey(key)) onAppWrite?.call();
    return true;
  }

  Future<bool> clear({
    bool includeLocalAi = true,
    bool includeCommittedImportBackup = false,
  }) {
    // Removing application records propagates tombstones on the next sync.
    // Local AI/voice privacy state is not exported; an import retains it.
    // Only a deliberate full clear may remove its retained import backup, and
    // only from inside the privacy-blocking gate. An interrupted or invalidly
    // prefixed checkpoint is not removed by this method.
    if (includeCommittedImportBackup &&
        (!_insideImport || !_blockLocalPrivacyWrites || !includeLocalAi)) {
      return Future<bool>.error(
        StateError('Для удаления копии требуется подтверждённая полная очистка.'),
      );
    }
    // A direct clear() without the gate does not fence new keys: its selected
    // set is only the snapshot taken here.
    final keys = getKeys()
        .where((k) => appKey(k) || (includeLocalAi && localPrivacyKey(k)))
        .toSet();
    // Reserve even an absent journal key so concurrent local writes cannot
    // slip between the safety recheck and the selected deletion batch.
    if (includeCommittedImportBackup) keys.add(importJournalKey);
    if (keys.isEmpty) return Future<bool>.value(true);
    return _queueWrites(keys, () async {
      if (includeCommittedImportBackup && hasPendingImport) {
        throw const ImportRecoveryRequired();
      }
      // Invoke test-only faults before changing any key. On web the Hive
      // deleteAll batch uses one IndexedDB transaction and waits for commit;
      // other storage layers and the surrounding clear-all steps are not
      // thereby made into a cross-system or hardware-durable transaction.
      final hook = beforeWriteForTests;
      if (hook != null && (memoryForTests || directoryForTests != null)) {
        for (final key in keys) {
          await hook(key);
        }
      }
      if (memoryForTests) {
        for (final key in keys) {
          _memory.remove(key);
        }
      } else {
        await _box!.deleteAll(keys);
      }
      if (keys.any(appKey)) onAppWrite?.call();
      return true;
    });
  }

  Map<String, dynamic> snapshot() => {
    for (final k in getKeys().where(appKey)) k: get(k),
  };

  /// Wait for outstanding application-key writes, then execute a synchronous
  /// capture without yielding back to the event loop between the final queue
  /// check and the read. New writes can arrive while older writes drain, so
  /// recheck with a bounded number of rounds instead of returning a partial
  /// snapshot indefinitely. A write submitted after capture belongs to a
  /// later point in time. This coordinates only this Dart isolate: old tabs,
  /// other processes, the filesystem and the cloud are not locked here.
  Future<T> readAfterAppWrites<T>(T Function() capture) async {
    if (_insideImport) {
      throw StateError('Дождитесь завершения импорта или очистки.');
    }
    final queue = memoryForTests ? _memoryWrites : _hiveWrites;
    for (var round = 0; ; round++) {
      if (hasPendingImport) throw const ImportRecoveryRequired();
      if (importInProgress) {
        throw StateError('Дождитесь завершения импорта или очистки.');
      }
      final pending = queue.entries
          .where((entry) => appKey(entry.key))
          .map((entry) => entry.value)
          .toSet();
      if (pending.isEmpty) return capture();
      if (round >= 8) {
        throw StateError(
          'Дождитесь завершения сохранения и повторите экспорт.',
        );
      }
      await Future.wait(pending);
    }
  }

  /// Wait for Hive's storage layer. This does not promise durability against
  /// every browser, hardware failure, or operating-system cache policy.
  Future<void> flush() async {
    if (!memoryForTests) await _box!.flush();
  }

  dynamic decoded(String key) {
    final value = get(key);
    if (value is! String) return value;
    try {
      return jsonDecode(value);
    } catch (_) {
      return value;
    }
  }
}
