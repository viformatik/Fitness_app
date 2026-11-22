import 'dart:convert';

import 'gym_models.dart';
import 'local_store.dart';

/// Equality here means only the same spelling, ignoring case and whitespace.
/// It is not evidence that two exercises used identical technique/equipment.
/// In particular, different names and е/ё are not silently merged.
String exerciseHistoryKey(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// An immutable, deliberately minimal snapshot of an actual recorded set.
/// Notes, profile details and other private session fields are not copied.
class ExerciseHistorySet {
  final int index;
  final DateTime recordedAt;
  final int? reps, seconds, rir;
  final double? weightKg;
  final String pullupMode;
  final bool isPullup, isTest;

  ExerciseHistorySet(GymSet set)
    : index = set.index,
      recordedAt = set.recordedAt,
      reps = set.reps,
      seconds = set.seconds,
      rir = set.rir,
      weightKg = set.weightKg,
      pullupMode = set.pullupMode,
      isPullup = set.isPullup,
      isTest = set.isTest;
}

/// One real session, not an inferred workout or a recommendation.
class ExerciseHistorySession {
  final String id, title;
  final DateTime startedAt;
  final bool completed, listedInSession;
  final List<ExerciseHistorySet> sets;

  ExerciseHistorySession._({
    required this.id,
    required this.title,
    required this.startedAt,
    required this.completed,
    required this.listedInSession,
    required List<ExerciseHistorySet> sets,
  }) : sets = List.unmodifiable(sets);
}

class ExerciseHistoryItem {
  final String key, name;
  final List<ExerciseHistorySession> sessions;
  final int recordedSets, sessionsWithSets;

  ExerciseHistoryItem._({
    required this.key,
    required this.name,
    required List<ExerciseHistorySession> sessions,
  }) : sessions = List.unmodifiable(sessions),
       recordedSets = sessions.fold(
         0,
         (sum, session) => sum + session.sets.length,
       ),
       sessionsWithSets = sessions
           .where((session) => session.sets.isNotEmpty)
           .length;
}

class ExerciseHistoryIndex {
  final Map<String, ExerciseHistoryItem> byName;
  final int unreadable;

  ExerciseHistoryIndex._(
    Map<String, ExerciseHistoryItem> items,
    this.unreadable,
  ) : byName = Map.unmodifiable(items);

  ExerciseHistoryItem? forName(String name) => byName[exerciseHistoryKey(name)];
}

class _SessionCollector {
  String name;
  DateTime lastSeen;
  bool listed = false;
  final List<ExerciseHistorySet> sets = [];
  _SessionCollector(this.name, this.lastSeen);

  void observeName(String value, DateTime when) {
    if (when.isAfter(lastSeen) ||
        (when.isAtSameMomentAs(lastSeen) && value.compareTo(name) < 0)) {
      name = value;
      lastSeen = when;
    }
  }
}

class _ItemCollector {
  final String key;
  String name;
  DateTime lastSeen;
  final List<ExerciseHistorySession> sessions = [];
  _ItemCollector(this.key, this.name, this.lastSeen);

  void observeName(String value, DateTime when) {
    final clean = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (when.isAfter(lastSeen) ||
        (when.isAtSameMomentAs(lastSeen) && clean.compareTo(name) < 0)) {
      name = clean;
      lastSeen = when;
    }
  }
}

/// Build a read-only index exclusively from existing gym session documents.
/// The saved set's exerciseName, not today's mutable exercise name, controls
/// its history. A listed exercise without sets is explicitly not a completed
/// set. Invalid documents are counted without changing or silently erasing them.
ExerciseHistoryIndex indexExerciseHistory(Map<String, Object?> documents) {
  final items = <String, _ItemCollector>{};
  var unreadable = 0;
  final entries = documents.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final document in entries) {
    if (!document.key.startsWith(gymSessionPrefix) || document.value == null) {
      continue;
    }
    try {
      validateGymDocument(document.key, document.value);
      final raw = jsonDecode(document.value! as String);
      final session = GymSession.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      final perSession = <String, _SessionCollector>{};

      _SessionCollector group(String name, DateTime observedAt) {
        final key = exerciseHistoryKey(name);
        final clean = name.trim().replaceAll(RegExp(r'\s+'), ' ');
        final data = perSession.putIfAbsent(
          key,
          () => _SessionCollector(clean, observedAt),
        );
        data.observeName(clean, observedAt);
        return data;
      }

      for (final block in session.blocks) {
        for (final exercise in block.exercises) {
          // An exercise may have been replaced after a set was recorded.
          group(exercise.name, session.startedAt).listed = true;
          for (final set in exercise.sets) {
            group(
              set.exerciseName,
              set.recordedAt,
            ).sets.add(ExerciseHistorySet(set));
          }
        }
      }
      // Finish the complete document before exposing any of its rows. A bad
      // session must not leak a partially built item into the other histories.
      final projections = <String, ExerciseHistorySession>{};
      for (final entry in perSession.entries) {
        final data = entry.value;
        data.sets.sort((a, b) {
          final time = a.recordedAt.compareTo(b.recordedAt);
          return time != 0 ? time : a.index.compareTo(b.index);
        });
        projections[entry.key] = ExerciseHistorySession._(
          id: session.id,
          title: session.title,
          startedAt: session.startedAt,
          completed: session.completed,
          listedInSession: data.listed,
          sets: data.sets,
        );
      }
      for (final entry in perSession.entries) {
        final data = entry.value;
        final item = items.putIfAbsent(
          entry.key,
          () => _ItemCollector(entry.key, data.name, data.lastSeen),
        );
        item.observeName(data.name, data.lastSeen);
        item.sessions.add(projections[entry.key]!);
      }
    } catch (_) {
      unreadable++;
    }
  }

  final result = <String, ExerciseHistoryItem>{};
  for (final item in items.values) {
    item.sessions.sort((a, b) {
      final date = b.startedAt.compareTo(a.startedAt);
      return date != 0 ? date : a.id.compareTo(b.id);
    });
    result[item.key] = ExerciseHistoryItem._(
      key: item.key,
      name: item.name,
      sessions: item.sessions,
    );
  }
  return ExerciseHistoryIndex._(result, unreadable);
}

class _CachedExerciseHistory {
  final Map<String, Object?> documents;
  final ExerciseHistoryIndex index;
  _CachedExerciseHistory(this.documents, this.index);
}

// Keep the last projection only. Raw document comparisons catch writes through
// sync/import/removal as well as the gym editor when the provider rebuilds.
final Expando<_CachedExerciseHistory> _exerciseHistoryCache = Expando();

ExerciseHistoryIndex readExerciseHistory(LocalPreferences store) {
  final documents = <String, Object?>{
    for (final key in store.getKeys())
      if (key.startsWith(gymSessionPrefix)) key: store.get(key),
  };
  final cached = _exerciseHistoryCache[store];
  if (cached != null &&
      cached.documents.length == documents.length &&
      documents.entries.every(
        (entry) =>
            cached.documents.containsKey(entry.key) &&
            cached.documents[entry.key] == entry.value,
      )) {
    return cached.index;
  }
  final index = indexExerciseHistory(documents);
  _exerciseHistoryCache[store] = _CachedExerciseHistory(documents, index);
  return index;
}
