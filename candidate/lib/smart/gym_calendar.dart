import 'dart:convert';

import 'gym_models.dart';
import 'local_store.dart';

/// Minimal immutable display snapshot. Never exposes the mutable GymSession
/// or its notes, set details, timer and other private fields to other views.
class GymCalendarItem {
  final String id, title;
  final DateTime startedAt;
  final bool completed;
  final int setCount, cardioCount;

  GymCalendarItem(GymSession session)
    : id = session.id,
      title = session.title,
      startedAt = session.startedAt,
      completed = session.completed,
      setCount = session.setCount,
      cardioCount = session.cardio.length;
}

/// Read-only projection of the existing gym documents. No new storage, no
/// network and no modification of sessions. Corrupt documents are reported,
/// not silently turned into an empty day.
class GymCalendarIndex {
  final List<GymCalendarItem> sessions;
  final int unreadable;

  GymCalendarIndex._(List<GymCalendarItem> sessions, this.unreadable)
    : sessions = List.unmodifiable(sessions);

  /// The existing session model stores an instant, not the original timezone.
  /// Group by its start date in the current device timezone, consistent with
  /// the existing training overview. A cross-midnight session appears once.
  List<GymCalendarItem> forDate(DateTime date) => List.unmodifiable(
    sessions.where((s) {
      final start = s.startedAt.toLocal();
      return start.year == date.year &&
          start.month == date.month &&
          start.day == date.day;
    }),
  );
}

GymCalendarIndex indexGymSessions(Map<String, Object?> documents) {
  final sessions = <GymCalendarItem>[];
  var unreadable = 0;
  for (final entry in documents.entries) {
    if (!entry.key.startsWith(gymSessionPrefix) || entry.value == null)
      continue;
    try {
      validateGymDocument(entry.key, entry.value);
      final raw = jsonDecode(entry.value! as String);
      sessions.add(
        GymCalendarItem(
          GymSession.fromJson(Map<String, dynamic>.from(raw as Map)),
        ),
      );
    } catch (_) {
      // Date and details are unknown; it would be misleading to say that
      // there are certainly no sessions on any particular date.
      unreadable++;
    }
  }
  sessions.sort((a, b) {
    final date = b.startedAt.compareTo(a.startedAt);
    return date != 0 ? date : a.id.compareTo(b.id);
  });
  return GymCalendarIndex._(sessions, unreadable);
}

class _CachedGymCalendar {
  final Map<String, Object?> documents;
  final GymCalendarIndex index;
  _CachedGymCalendar(this.documents, this.index);
}

// A weak per-store cache avoids reparsing every gym session when unrelated
// water/food UI changes. Comparing the raw strings also catches sync, import
// and delete operations that do not use writeGymDocument. No disk copy is made.
final Expando<_CachedGymCalendar> _calendarCache = Expando();

GymCalendarIndex readGymCalendar(LocalPreferences store) {
  final documents = <String, Object?>{
    for (final key in store.getKeys())
      if (key.startsWith(gymSessionPrefix)) key: store.get(key),
  };
  final cached = _calendarCache[store];
  if (cached != null &&
      cached.documents.length == documents.length &&
      documents.entries.every(
        (entry) =>
            cached.documents.containsKey(entry.key) &&
            cached.documents[entry.key] == entry.value,
      )) {
    return cached.index;
  }
  final index = indexGymSessions(documents);
  _calendarCache[store] = _CachedGymCalendar(documents, index);
  return index;
}
