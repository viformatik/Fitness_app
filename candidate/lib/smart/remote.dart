import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'engine.dart';
import 'local_store.dart';
import 'ai_drafts.dart';
import 'supplements.dart';
import 'sleep.dart';
import 'diary_ai.dart';
import 'journal_ai_result.dart';
import 'workout_calc.dart';

class SyncConflict {
  final String key;
  final dynamic local, remote;
  final int revision;

  /// The same daily aggregate may have been reached by independent additions.
  /// A value match is not proof that one of those actions is a duplicate.
  final bool matchingCounterNeedsReview;
  final int? counterBaseline;
  const SyncConflict(
    this.key,
    this.local,
    this.remote,
    this.revision, {
    this.matchingCounterNeedsReview = false,
    this.counterBaseline,
  });
}

class SmartRemote extends ChangeNotifier {
  static final instance = SmartRemote._();
  SmartRemote._();
  SupabaseClient? client;
  Timer? _debounce, _poll;
  // A local write (or an auth change) can arrive while sync is in flight.
  // Remember it instead of silently dropping the scheduling signal.
  bool _scheduleAfterBusy = false;
  LocalPreferences? _local;
  void Function(String, Object?)? _validate;
  Future<void> Function()? _onSynced, _beforeSync;
  static const _pendingLocalMessage =
      'Новые локальные изменения пока не синхронизированы. Повторите синхронизацию.';
  static const _sleepLocalMessage =
      'Сон остаётся на устройстве: серверная поддержка не настроена.';
  void bindLocal(
    LocalPreferences local,
    void Function(String, Object?) validate,
    Future<void> Function() onSynced,
    Future<void> Function() beforeSync,
  ) {
    _local = local;
    _validate = validate;
    _onSynced = onSynced;
    _beforeSync = beforeSync;
    LocalPreferences.onAppWrite = _onLocalWrite;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _autoSync());
    _schedule();
  }

  @visibleForTesting
  void unbindLocalForTests() {
    _debounce?.cancel();
    _poll?.cancel();
    _scheduleAfterBusy = false;
    _local = null;
    _validate = null;
    _onSynced = null;
    _beforeSync = null;
    LocalPreferences.onAppWrite = null;
  }

  bool get _autoEnabled {
    final local = _local;
    if (local == null || local.importSyncPaused) return false;
    final settings = local.decoded('smart_settings');
    return settings is Map && settings['autoSync'] == true;
  }

  void _onLocalWrite() {
    // A completed sync describes an earlier snapshot; do not keep presenting
    // it as current after a subsequent local edit, even when auto sync is off.
    if (!busy && status.startsWith('Синхронизировано.')) {
      status = sleepCloudAvailable == false
          ? '$_pendingLocalMessage $_sleepLocalMessage'
          : _pendingLocalMessage;
      notifyListeners();
    }
    _schedule();
  }

  void _schedule() {
    if (busy) {
      _scheduleAfterBusy = true;
      return;
    }
    if (!signedIn || !_autoEnabled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _autoSync);
  }

  // Only in-isolate coordination. Timers do not run after the app is closed,
  // and this cannot detect writes from old tabs or other processes.
  void _finishBusy({required bool shouldReschedule}) {
    busy = false;
    final requested = _scheduleAfterBusy;
    _scheduleAfterBusy = false;
    notifyListeners();
    if (requested && shouldReschedule) _schedule();
  }

  Future<void> _autoSync() async {
    if (busy ||
        !signedIn ||
        !_autoEnabled ||
        conflicts.isNotEmpty ||
        _local == null ||
        _validate == null)
      return;
    try {
      await _beforeSync?.call();
      await sync(_local!, validate: _validate!);
      await _onSynced?.call();
    } catch (_) {
      /* status is visible; retry on next foreground timer / local write. */
    }
  }

  bool busy = false;

  /// Null until a sync checks the separate sleep table. False means sleep is
  /// still local, not that it was deleted or successfully synchronized.
  bool? sleepCloudAvailable;
  String status = 'Облако не настроено';
  final List<SyncConflict> conflicts = [];
  // Synthetic candidate only: even build-time environment values cannot turn
  // cloud access on. This is not a production configuration.
  static const url = '';
  static const publicKey = '';

  Future<void> initialize() async {
    if (url.isEmpty || publicKey.isEmpty) return;
    try {
      await Supabase.initialize(url: url, publishableKey: publicKey);
      client = Supabase.instance.client;
      status = 'Войдите для синхронизации и AI';
      client!.auth.onAuthStateChange.listen((_) {
        sleepCloudAvailable = null;
        _schedule();
        notifyListeners();
      });
    } catch (_) {
      status = 'Ошибка настройки Supabase';
    }
  }

  bool get signedIn => client?.auth.currentUser != null;
  Future<void> login(
    String email,
    String password, {
    bool signup = false,
  }) async {
    final c = client;
    if (c == null)
      throw StateError('Задайте SUPABASE_URL и SUPABASE_PUBLISHABLE_KEY');
    if (signup) {
      if (password.length < 8)
        throw ArgumentError('Пароль должен содержать от 8 символов');
      await c.auth.signUp(email: email, password: password);
      status =
          'Регистрация отправлена. Если включена проверка email — подтвердите письмо.';
    } else {
      await c.auth.signInWithPassword(email: email, password: password);
      status =
          'Вход выполнен. Синхронизация по кнопке; локальные данные не стираются.';
    }
    notifyListeners();
  }

  Future<void> logout() async {
    await client?.auth.signOut();
    sleepCloudAvailable = null;
    status = 'Вы вышли. Локальный дневник остался на устройстве.';
    notifyListeners();
  }

  static bool equal(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  static bool _hasPendingLocalChanges(
    LocalPreferences store,
    Map<String, dynamic> baseline, {
    required bool sleepAvailable,
  }) {
    final current = store.snapshot();
    return {...baseline.keys, ...current.keys}
        .where(LocalPreferences.appKey)
        .where((key) => sleepAvailable || !key.startsWith(sleepDayPrefix))
        .any((key) => !equal(baseline[key], current[key]));
  }

  Future<void> sync(
    LocalPreferences store, {
    required void Function(String, Object?) validate,
    String? confirmedImportGeneration,
  }) async {
    if (busy) return;
    if (LocalPreferences.importInProgress || store.hasPendingImport) {
      throw StateError(
        'Синхронизация недоступна до завершения или восстановления импорта',
      );
    }
    if ((confirmedImportGeneration != null &&
            confirmedImportGeneration != store.diaryGeneration) ||
        (store.importSyncPaused && confirmedImportGeneration == null)) {
      throw StateError(
        'После импорта проверьте данные и подтвердите ручную синхронизацию.',
      );
    }
    final c = client;
    final uid = c?.auth.currentUser?.id;
    if (c == null || uid == null) throw StateError('Сначала войдите в аккаунт');
    // Prevent accidentally uploading a previous account's offline diary to a new user.
    final bound = store.getString('_bound_user');
    if (bound != null && bound != uid) {
      throw StateError(
        'Этот локальный дневник связан с другим аккаунтом. '
        'Сделайте экспорт и используйте отдельный профиль устройства. Автосмешивание запрещено.',
      );
    }
    busy = true;
    conflicts.clear();
    sleepCloudAvailable = null;
    status = 'Синхронизация…';
    notifyListeners();
    var completed = false;
    var localChangesPending = false;
    try {
      await store.setString('_bound_user', uid);
      final baselineRaw = store.getString('_baseline_$uid');
      final base = baselineRaw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(baselineRaw));
      final local = store.snapshot();
      Future<List<Map<String, dynamic>>> readRows(String table) async {
        final rows = <Map<String, dynamic>>[];
        for (var offset = 0; ; offset += 500) {
          final page = await c
              .from(table)
              .select('key,payload,revision')
              .eq('user_id', uid)
              .order('key')
              .range(offset, offset + 499);
          rows.addAll(page);
          if (page.length < 500) break;
          if (offset >= 50000)
            throw StateError('Слишком большая история для одной синхронизации');
        }
        return rows;
      }

      final rows = await readRows('fitness_documents');
      var sleepAvailable = true;
      var sleepRows = <Map<String, dynamic>>[];
      try {
        // A separate table keeps old clients working: they validate every key
        // in fitness_documents and would reject an unknown sleep document.
        sleepRows = await readRows('fitness_sleep_documents');
      } on PostgrestException catch (e) {
        if (e.code != 'PGRST205' && e.code != '42P01') rethrow;
        sleepAvailable = false;
      }
      if (c.auth.currentUser?.id != uid)
        throw StateError('Аккаунт изменился во время синхронизации');
      sleepCloudAvailable = sleepAvailable;
      final remote = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final key = row['key'] as String;
        if (key.startsWith(sleepDayPrefix) || remote.containsKey(key)) {
          throw StateError('Некорректные ключи облачных документов');
        }
        validate(key, row['payload']);
        remote[key] = row;
      }
      for (final row in sleepRows) {
        final key = row['key'] as String;
        if (!key.startsWith(sleepDayPrefix) || remote.containsKey(key)) {
          throw StateError('Некорректные ключи облачных документов сна');
        }
        validate(key, row['payload']);
        remote[key] = row;
      }
      var deferred = false;
      for (final key in {
        ...base.keys,
        ...local.keys,
        ...remote.keys,
      }.where(LocalPreferences.appKey)) {
        if (c.auth.currentUser?.id != uid ||
            store.getString('_bound_user') != uid) {
          throw StateError(
            'Аккаунт или привязка изменились во время синхронизации',
          );
        }
        if (!sleepAvailable && key.startsWith(sleepDayPrefix)) continue;
        final l = local[key], r = remote[key]?['payload'];
        final rev = (remote[key]?['revision'] as num?)?.toInt();
        final counter =
            key.startsWith('water_intake_') || key.startsWith('steps_');
        // If both values differ from a saved baseline, or no baseline exists,
        // equality of daily aggregates cannot prove that the actions match.
        // The same ambiguity also occurs after an upload succeeded but its
        // response was lost. Ask for review rather than adding or guessing.
        if (counter && l is int && r is int && l == r && !equal(base[key], l)) {
          conflicts.add(
            SyncConflict(
              key,
              l,
              r,
              rev ?? 0,
              matchingCounterNeedsReview: true,
              counterBaseline: base[key] is int ? base[key] as int : null,
            ),
          );
          continue;
        }
        switch (decideMerge(base[key], l, r, equal)) {
          case MergeDecision.unchanged:
            base[key] = l;
          case MergeDecision.conflict:
            conflicts.add(SyncConflict(key, l, r, rev ?? 0));
          case MergeDecision.pull:
            // Every document, including scalar water, steps and workout flags,
            // uses the same conditional per-key queue as local edits. Checking
            // the value before enqueuing a plain write is not sufficient: an
            // already queued edit could otherwise be overwritten. This only
            // coordinates this isolate, not other browser tabs or processes.
            if (await store.compareAndPut(
              key,
              l,
              r,
              authorizationGuard: () =>
                  c.auth.currentUser?.id == uid &&
                  store.getString('_bound_user') == uid,
            )) {
              base[key] = r;
            } else {
              conflicts.add(SyncConflict(key, store.get(key), r, rev ?? 0));
            }
          case MergeDecision.push:
            try {
              await _push(key, l, rev, uid);
              base[key] = l;
            } on PostgrestException catch (e) {
              // PT409 is an application-level CAS conflict (no PostgREST retry
              // loop); 40001 remains accepted for older backends.
              if (e.code == 'PT409' || e.code == '40001') {
                deferred = true;
                status =
                    'Конкурентное изменение. Нажмите синхронизацию ещё раз.';
                continue;
              }
              rethrow;
            }
        }
      }
      if (c.auth.currentUser?.id != uid ||
          store.getString('_bound_user') != uid) {
        throw StateError(
          'Аккаунт или привязка изменились во время синхронизации',
        );
      }
      await store.setString('_baseline_$uid', jsonEncode(base));
      localChangesPending = _hasPendingLocalChanges(
        store,
        base,
        sleepAvailable: sleepAvailable,
      );
      if (store.importSyncPaused &&
          confirmedImportGeneration != null &&
          !deferred &&
          conflicts.isEmpty &&
          !localChangesPending) {
        if (store.diaryGeneration != confirmedImportGeneration) {
          throw StateError('Данные изменились после подтверждения импорта.');
        }
        await store.remove(LocalPreferences.importSyncPauseKey);
        await store.flush();
      }
      // Recheck after the awaits above; app writes can complete during them.
      // This is a point-in-time local comparison, not a cloud-wide transaction.
      localChangesPending = _hasPendingLocalChanges(
        store,
        base,
        sleepAvailable: sleepAvailable,
      );
      final mainStatus = deferred
          ? 'Конкурентное изменение. Повторите синхронизацию.'
          : conflicts.isNotEmpty
          ? 'Конфликтов: ${conflicts.length}. Выберите версию каждого документа.'
          : localChangesPending
          ? _pendingLocalMessage
          : 'Синхронизировано. ${DateTime.now().toLocal()}';
      status = sleepAvailable ? mainStatus : '$mainStatus $_sleepLocalMessage';
      completed = true;
    } catch (_) {
      status = 'Синхронизация не завершена. Данные остаются локально.';
      rethrow;
    } finally {
      // Pulls also trigger the local-write callback; do not create a needless
      // loop when the resulting local snapshot is already fully synchronized.
      _finishBusy(shouldReschedule: !completed || localChangesPending);
    }
  }

  Future<void> _push(
    String key,
    dynamic payload,
    int? expected,
    String uid,
  ) async {
    if (client?.auth.currentUser?.id != uid)
      throw StateError('Аккаунт изменился во время записи');
    await client!.rpc(
      key.startsWith(sleepDayPrefix)
          ? 'write_fitness_sleep_document'
          : 'write_fitness_document',
      params: {'p_key': key, 'p_payload': payload, 'p_expected': expected},
    );
  }

  static String _staleConflictMessage(String key) => key == 'recipes'
      ? 'Список рецептов изменился после сравнения. Повторите синхронизацию.'
      : key.startsWith('food_entries_')
      ? 'Дневник питания изменился после сравнения. Повторите синхронизацию.'
      : key == 'weight_entries'
      ? 'История веса изменилась после сравнения. Повторите синхронизацию.'
      : key == 'user_profile'
      ? 'Профиль изменился после сравнения. Повторите синхронизацию.'
      : key.startsWith(sleepDayPrefix)
      ? 'Запись сна изменилась после сравнения. Повторите синхронизацию.'
      : 'Данные изменились после сравнения. Повторите синхронизацию.';

  /// Re-read exactly the cloud document shown to the user before replacing
  /// the local version. A changed revision is stale even if its payload is
  /// equal (ABA); a revisioned tombstone is not the same as an absent row.
  /// This is a freshness check, NOT an atomic transaction across the cloud
  /// and local Hive. Another client can still write after this read.
  Future<void> _checkCloudChoice(
    LocalPreferences store,
    SyncConflict conflict,
    SupabaseClient c,
    String uid,
  ) async {
    final rows = await c
        .from(
          conflict.key.startsWith(sleepDayPrefix)
              ? 'fitness_sleep_documents'
              : 'fitness_documents',
        )
        .select('key,payload,revision')
        .eq('user_id', uid)
        .eq('key', conflict.key)
        // A primary key should make a second row impossible. Ask for two so
        // a malformed or unexpected response is rejected, not silently used.
        .range(0, 1);
    if (!identical(client, c) ||
        c.auth.currentUser?.id != uid ||
        store.getString('_bound_user') != uid) {
      throw StateError(
        'Аккаунт или привязка изменились. Повторите синхронизацию.',
      );
    }
    final stale =
        rows.length > 1 ||
        (rows.isEmpty
            ? conflict.revision != 0 || conflict.remote != null
            : rows.single['key'] != conflict.key ||
                  !rows.single.containsKey('payload') ||
                  rows.single['revision'] is! int ||
                  (rows.single['revision'] as int) <= 0 ||
                  rows.single['revision'] != conflict.revision ||
                  !equal(rows.single['payload'], conflict.remote));
    if (stale) {
      throw StateError(
        'Облачная версия изменилась после сравнения. Повторите синхронизацию и проверьте обе версии.',
      );
    }
  }

  Future<void> resolve(
    LocalPreferences store,
    SyncConflict conflict,
    bool useLocal, {
    required void Function(String, Object?) validate,
    bool confirmedMatchingCounter = false,
  }) async {
    if (busy) throw StateError('Дождитесь завершения синхронизации');
    if (LocalPreferences.importInProgress || store.hasPendingImport) {
      throw StateError('Сначала завершите восстановление импорта');
    }
    final c = client;
    final uid = c?.auth.currentUser?.id;
    if (c == null || uid == null || store.getString('_bound_user') != uid)
      throw StateError('Сессия завершена или аккаунт изменился');
    if (!conflicts.contains(conflict)) {
      throw StateError('Сравнение устарело. Повторите синхронизацию.');
    }
    if (conflict.matchingCounterNeedsReview &&
        (!confirmedMatchingCounter || !useLocal)) {
      throw StateError(
        'Проверьте действия на обоих устройствах и подтвердите итог отдельно.',
      );
    }
    // For a matching-counter review, useLocal=true goes through _push with
    // the displayed cloud revision. A changed server value is rejected by CAS.
    // Conflict resolution can write locally or to the cloud; treat the whole
    // operation as busy so an import cannot overlap its asynchronous steps.
    busy = true;
    notifyListeners();
    try {
      // Apply only the version actually shown in the comparison. A newer local
      // edit (including a deletion) must never be uploaded without review.
      final value = useLocal ? conflict.local : conflict.remote;
      validate(conflict.key, value);
      if (useLocal) {
        // Wait behind already queued edits before testing the snapshot. The
        // network call itself is not made while holding the local write queue;
        // later edits remain local and are picked up by the next sync.
        if (!await store.matchesQueued(
          conflict.key,
          conflict.local,
          authorizationGuard: () =>
              client?.auth.currentUser?.id == uid &&
              store.getString('_bound_user') == uid,
        )) {
          throw StateError(_staleConflictMessage(conflict.key));
        }
        await _push(
          conflict.key,
          value,
          conflict.revision == 0 ? null : conflict.revision,
          uid,
        );
      } else {
        // The dialog might have been open while another device changed the
        // cloud. Refuse a stale displayed revision before touching local data.
        // This check is not atomic with the subsequent local write.
        await _checkCloudChoice(store, conflict, c, uid);
        // A comparison dialog can also remain open while *any* local document
        // is edited. Reject a stale choice instead of replacing the newer value.
        if (!await store.compareAndPut(
          conflict.key,
          conflict.local,
          value,
          authorizationGuard: () =>
              identical(client, c) &&
              c.auth.currentUser?.id == uid &&
              store.getString('_bound_user') == uid,
        )) {
          throw StateError(_staleConflictMessage(conflict.key));
        }
      }
      if (client?.auth.currentUser?.id != uid ||
          store.getString('_bound_user') != uid) {
        throw StateError(
          'Аккаунт или привязка изменились. Повторите синхронизацию.',
        );
      }
      final base = Map<String, dynamic>.from(
        jsonDecode(store.getString('_baseline_$uid') ?? '{}'),
      );
      base[conflict.key] = value;
      await store.setString('_baseline_$uid', jsonEncode(base));
      conflicts.remove(conflict);
      final localChangesPending = _hasPendingLocalChanges(
        store,
        base,
        sleepAvailable: sleepCloudAvailable != false,
      );
      status = conflicts.isNotEmpty
          ? 'Осталось конфликтов: ${conflicts.length}'
          : localChangesPending
          ? _pendingLocalMessage
          : 'Осталось конфликтов: 0';
    } finally {
      // A local edit can arrive while a conflict choice performs network I/O.
      // The debounce remains disabled when auto sync is off or import is paused.
      _finishBusy(shouldReschedule: true);
    }
  }

  /// Import invalidates conflict snapshots and persists an automatic-sync
  /// safety latch before local data is replaced.
  void afterLocalImport() {
    _debounce?.cancel();
    conflicts.clear();
    status =
        'Импорт завершён локально. Автосинхронизация приостановлена: проверьте данные и подтвердите ручную синхронизацию.';
    notifyListeners();
  }

  void afterLocalClear() {
    conflicts.clear();
    status =
        'Локальные данные очищены. При синхронизации удаления могут попасть в облако.';
    notifyListeners();
    _schedule();
  }

  // The project runs in eu-west-1. A stale legacy food-ai deployment remains
  // at another edge; route via the query parameter rather than an x-region
  // header so existing browser CORS preflight remains compatible.
  /// The input is a reviewed aggregate; this endpoint cannot modify records.
  Future<JournalAiResult> analyzeJournalOverview(
    Map<String, dynamic> input,
  ) async {
    if (!signedIn) {
      throw StateError('Войдите в аккаунт в разделе «Ещё → Синхронизация».');
    }
    try {
      final response = await client!.functions
          .invoke(
            'journal-ai',
            body: input,
            queryParameters: const {'forceFunctionRegion': 'eu-west-1'},
          )
          .timeout(const Duration(seconds: 65));
      return JournalAiResult.fromJson(response.data);
    } on FunctionException catch (e) {
      if (e.status == 400 || e.status == 413) {
        throw const AiRequestFailure(
          'Не удалось проверить сводку. Сократите вопрос или выберите меньше разделов.',
        );
      }
      throw AiRequestFailure(aiServerErrorMessage(e.status, e.details));
    } on TimeoutException {
      throw const AiRequestFailure(
        'ИИ не успел ответить. Локальные данные не изменены; попробуйте ещё раз.',
      );
    }
  }

  Future<DiaryAiResult> analyzeDiary({
    required DiaryAiSnapshot snapshot,
    required String question,
    required bool replaceKnownMicros,
  }) async {
    if (!signedIn)
      throw StateError(
        'Для анализа ИИ войдите в аккаунт в разделе «Ещё → Синхронизация».',
      );
    final body = snapshot.request(
      question,
      replaceKnownMicros: replaceKnownMicros,
    );
    try {
      final response = await client!.functions
          .invoke(
            'food-ai',
            body: body,
            queryParameters: const {'forceFunctionRegion': 'eu-west-1'},
          )
          .timeout(const Duration(seconds: 65));
      return validateDiaryAiResult(
        response.data,
        snapshot,
        replaceKnownMicros: replaceKnownMicros,
      );
    } on FunctionException catch (e) {
      throw AiRequestFailure(aiServerErrorMessage(e.status, e.details));
    } on TimeoutException {
      throw const AiRequestFailure(
        'ИИ не успел ответить. Запрос остался на экране, дневник не изменён.',
      );
    }
  }

  Future<Map<String, dynamic>> parseWorkout(String description) async {
    if (!signedIn)
      throw StateError(
        'Для ИИ войдите в аккаунт в разделе «Ещё → Синхронизация».',
      );
    final text = description.trim();
    if (text.isEmpty || text.length > 4000)
      throw ArgumentError('Введите описание тренировки до 4000 символов.');
    try {
      final response = await client!.functions
          .invoke(
            'workout-ai',
            body: {'text': text},
            queryParameters: const {'forceFunctionRegion': 'eu-west-1'},
          )
          .timeout(const Duration(seconds: 65));
      return validateWorkoutDraft(response.data);
    } on FunctionException catch (e) {
      if (e.status == 400)
        throw const AiRequestFailure(
          'Не удалось прочитать тренировку. Уточните описание.',
        );
      throw AiRequestFailure(aiServerErrorMessage(e.status, e.details));
    } on TimeoutException {
      throw const AiRequestFailure(
        'ИИ не успел ответить. Описание осталось на экране; попробуйте позже.',
      );
    }
  }

  Future<List<Json>> parseSupplements({
    String text = '',
    Uint8List? image,
    String mime = 'image/jpeg',
  }) async {
    if (!signedIn)
      throw StateError(
        'Для AI нужен вход в аккаунт. Ручной ввод работает без входа.',
      );
    try {
      final response = await client!.functions
          .invoke(
            'food-ai',
            queryParameters: const {'forceFunctionRegion': 'eu-west-1'},
            body: buildAiSupplementRequest(
              text: text,
              image: image,
              mime: mime,
            ),
          )
          .timeout(const Duration(seconds: 65));
      final data = response.data;
      if (data is! Map)
        throw const FormatException('Некорректный ответ AI. Повторите запрос.');
      return validateAiSupplements(data['items']);
    } on FunctionException catch (e) {
      throw AiRequestFailure(aiServerErrorMessage(e.status, e.details));
    } on TimeoutException {
      throw const AiRequestFailure(
        'AI не успел ответить. Описание и фото остаются на экране.',
      );
    }
  }

  Future<List<Json>> parseFood({
    String text = '',
    Uint8List? image,
    String mime = 'image/jpeg',
    String mode = 'food',
    List<Json>? previousItems,
  }) async {
    if (!signedIn)
      throw StateError('Для AI нужен настроенный сервер и вход в аккаунт');
    if (text.trim().isEmpty && image == null)
      throw ArgumentError('Добавьте описание или фото');
    if (image != null && image.length > 4 * 1024 * 1024)
      throw ArgumentError('Фото должно быть меньше 4 МБ');
    try {
      final response = await client!.functions
          .invoke(
            'food-ai',
            queryParameters: const {'forceFunctionRegion': 'eu-west-1'},
            body: buildAiFoodRequest(
              text: text,
              image: image,
              mime: mime,
              mode: mode,
              previousItems: previousItems,
            ),
          )
          .timeout(const Duration(seconds: 65));
      final data = response.data;
      if (data is! Map)
        throw const FormatException('Некорректный ответ AI. Повторите запрос.');
      return validateAiItems(data['items']);
    } on FunctionException catch (e) {
      throw AiRequestFailure(aiServerErrorMessage(e.status, e.details));
    } on TimeoutException {
      throw const AiRequestFailure(
        'AI не успел ответить. Ваше описание и фото остаются на экране. Попробуйте позже.',
      );
    }
  }
}
