import 'dart:convert';
import 'ai_drafts.dart';
import 'engine.dart';
import 'local_store.dart';

/// Consent is scoped to the account, device, provider and exact data-sharing policy.
/// Increment the version if provider, purpose or shared data categories change.
class AiConsent {
  static const policyVersion = 6;
  // If deletion is queued or fails, do not continue to treat the old stored
  // value as permission within this process. A fresh explicit acceptance may
  // restore it. A failed deletion cannot promise durability after a restart.
  static final Set<String> _revokedUntilReaccepted = {};
  final LocalPreferences store;
  final String owner;
  AiConsent(this.store, this.owner);
  String get key => '_ai_consent_$owner';
  bool get accepted {
    // A persisted approval may still be awaiting deletion. Fail closed while
    // a clear/revocation is in progress or a revocation failed in this process.
    if (LocalPreferences.localPrivacyClearInProgress ||
        _revokedUntilReaccepted.contains(key))
      return false;
    final raw = store.decoded(key);
    return raw is Map &&
        raw['version'] == policyVersion &&
        raw['provider'] == 'gemini' &&
        raw['adult'] == true;
  }

  /// A particular operation must retain both the approval and its original
  /// epoch. A later reacceptance does not reauthorize a previously sent call.
  bool validFor(int epoch) =>
      LocalPreferences.privacyEpochIsCurrent(epoch) && accepted;

  Future<void> accept({bool Function()? authorizationGuard}) async {
    final epoch = LocalPreferences.privacyEpoch;
    bool authorized() =>
        LocalPreferences.privacyEpochIsCurrent(epoch) &&
        (authorizationGuard?.call() ?? true);
    if (!authorized()) {
      throw StateError('Согласие изменилось. Подтвердите заново.');
    }
    final value = jsonEncode({
      'version': policyVersion,
      'provider': 'gemini',
      'adult': true,
      'acceptedAt': DateTime.now().toIso8601String(),
    });
    if (authorizationGuard == null) {
      await store.setString(key, value);
    } else {
      // Check again when this key reaches the in-isolate write queue. This is
      // not a transaction with platform auth after the storage write begins.
      final before = store.get(key);
      final changed = await store.compareAndPut(
        key,
        before,
        value,
        authorizationGuard: authorized,
      );
      if (!changed) {
        throw StateError('Согласие изменилось. Подтвердите заново.');
      }
    }
    if (!authorized()) {
      // The physical write may already have started; don't rely on it as an
      // approval in this process. Cross-tab and restart guarantees need more.
      _revokedUntilReaccepted.add(key);
      throw StateError('Согласие изменилось. Подтвердите заново.');
    }
    _revokedUntilReaccepted.remove(key);
  }

  Future<void> revoke() async {
    _revokedUntilReaccepted.add(key);
    LocalPreferences.invalidatePrivacyEpoch();
    await store.remove(key);
  }
}

/// Deliberately separate from recent drafts: pinned sets never age out of recents.
/// Local-only and account-scoped. No photos, input prompts or tokens are stored.
class AiFavorites {
  final LocalPreferences store;
  final String owner;
  AiFavorites(this.store, this.owner);
  String get key => '_ai_favorites_$owner';
  List<Json> read() {
    final raw = store.decoded(key);
    if (raw is! List) return [];
    final result = <Json>[];
    for (final row in raw.take(20)) {
      try {
        if (row is! Map ||
            row['name'] is! String ||
            (row['name'] as String).trim().isEmpty)
          continue;
        final items = validateAiItems(row['items']);
        if (items.isNotEmpty)
          result.add({
            'name': (row['name'] as String).substring(
              0,
              (row['name'] as String).length.clamp(0, 80),
            ),
            'items': items,
          });
      } catch (_) {
        /* Optional local cache cannot block the diary. */
      }
    }
    return result;
  }

  Future<void> save(String name, List<Json> items) async {
    final title = name.trim();
    if (title.isEmpty || title.length > 80)
      throw ArgumentError('Название должно содержать от 1 до 80 символов.');
    final normalized = validateAiItems(items);
    if (normalized.isEmpty)
      throw ArgumentError('Нет продуктов для избранного.');
    final records = read()
        .where(
          (e) => (e['name'] as String).toLowerCase() != title.toLowerCase(),
        )
        .toList();
    if (records.length >= 20)
      throw StateError(
        'Можно закрепить до 20 наборов. Удалите один из ненужных.',
      );
    records.insert(0, {'name': title, 'items': normalized});
    await store.setString(key, jsonEncode(records));
  }

  Future<void> remove(String name) async {
    await store.setString(
      key,
      jsonEncode(read().where((e) => e['name'] != name).toList()),
    );
  }
}

/// Exact original snapshots let undo refuse to delete entries edited since adding.
class AiUndoStore {
  final LocalPreferences store;
  final String owner;
  AiUndoStore(this.store, this.owner);
  String get key => '_ai_undo_$owner';
  List<Json> read() {
    final raw = store.decoded(key);
    final Object? rows;
    if (raw is Map) {
      if (raw['generation'] != store.diaryGeneration) return [];
      rows = raw['entries'];
    } else {
      // Legacy list-only undo remains valid only until the first import.
      if (store.diaryGeneration.isNotEmpty) return [];
      rows = raw;
    }
    if (rows is! List || rows.isEmpty || rows.length > 30) return [];
    if (rows.any(
      (e) => e is! Map || e['id'] is! String || e['date'] is! String,
    ))
      return [];
    return rows.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> remember(List<Json> entries, {String? generation}) async {
    if (entries.isEmpty || entries.length > 30)
      throw ArgumentError('Некорректный набор отмены.');
    final savedGeneration = generation ?? store.diaryGeneration;
    await store.setString(
      key,
      jsonEncode({'generation': savedGeneration, 'entries': entries}),
    );
  }

  Future<void> clear() async {
    await store.remove(key);
  }
}
