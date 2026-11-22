import 'gym_exercise_history.dart';

/// One actual saved set, selected for an explicitly approximate calculation.
/// This projection deliberately does not copy training notes or personal data.
class ExerciseEstimateSet {
  final String sessionId, sessionTitle;
  final DateTime sessionStartedAt, recordedAt;
  final bool sessionCompleted;
  final int setIndex, reps;
  final double weightKg, estimatedOneRepMaxKg;

  const ExerciseEstimateSet({
    required this.sessionId,
    required this.sessionTitle,
    required this.sessionStartedAt,
    required this.recordedAt,
    required this.sessionCompleted,
    required this.setIndex,
    required this.reps,
    required this.weightKg,
    required this.estimatedOneRepMaxKg,
  });
}

/// A read-only comparison of at most two distinct sessions. Missing previous
/// information stays null, never zero. Values are rounded only by the UI.
class ExerciseProgressEstimate {
  final ExerciseEstimateSet? latest, previous;
  final int qualifyingSets, excludedSets, qualifyingSessions;
  final bool latestOrderUnclear, previousOrderUnclear;

  const ExerciseProgressEstimate({
    required this.latest,
    required this.previous,
    required this.qualifyingSets,
    required this.excludedSets,
    required this.qualifyingSessions,
    required this.latestOrderUnclear,
    required this.previousOrderUnclear,
  });

  double? get percentageChange {
    final now = latest, before = previous;
    if (now == null || before == null || before.estimatedOneRepMaxKg <= 0) {
      return null;
    }
    return (now.estimatedOneRepMaxKg / before.estimatedOneRepMaxKg - 1) * 100;
  }
}

/// Epley: external load × (1 + reps / 30), calculated from saved values only.
///
/// Include 2–10 reps, positive external load, no timed set, no technical test
/// and no pull-up-specific mode. This is not a measurement, strength advice or
/// a prediction of a safe load. A caller must tell the user that the formula
/// only makes sense when the recorded load is the total relevant resistance
/// and equipment, technique and effort are comparable. The user must opt in.
ExerciseProgressEstimate estimateExerciseProgress(ExerciseHistoryItem? item) {
  var qualifyingSets = 0;
  var excludedSets = 0;
  final sessions = <ExerciseEstimateSet>[];

  for (final session in item?.sessions ?? const <ExerciseHistorySession>[]) {
    ExerciseEstimateSet? best;
    for (final set in session.sets) {
      final reps = set.reps;
      final weight = set.weightKg;
      if (reps == null ||
          reps < 2 ||
          reps > 10 ||
          weight == null ||
          !weight.isFinite ||
          weight <= 0 ||
          set.seconds != null ||
          set.isPullup ||
          set.isTest ||
          set.pullupMode != 'unknown') {
        excludedSets++;
        continue;
      }
      final estimate = weight * (1 + reps / 30);
      if (!estimate.isFinite || estimate <= 0) {
        excludedSets++;
        continue;
      }
      qualifyingSets++;
      final candidate = ExerciseEstimateSet(
        sessionId: session.id,
        sessionTitle: session.title,
        sessionStartedAt: session.startedAt,
        sessionCompleted: session.completed,
        recordedAt: set.recordedAt,
        setIndex: set.index,
        reps: reps,
        weightKg: weight,
        estimatedOneRepMaxKg: estimate,
      );
      // Stable tie-break: use the most recently recorded tied set, then its
      // number. No inference is made from a missing value or unrecorded set.
      if (best == null ||
          candidate.estimatedOneRepMaxKg > best.estimatedOneRepMaxKg ||
          (candidate.estimatedOneRepMaxKg == best.estimatedOneRepMaxKg &&
              (candidate.recordedAt.isAfter(best.recordedAt) ||
                  (candidate.recordedAt.isAtSameMomentAs(best.recordedAt) &&
                      candidate.setIndex > best.setIndex)))) {
        best = candidate;
      }
    }
    if (best != null) sessions.add(best);
  }

  sessions.sort((a, b) {
    final date = b.sessionStartedAt.compareTo(a.sessionStartedAt);
    return date != 0 ? date : a.sessionId.compareTo(b.sessionId);
  });
  // Equal session start times do not establish which session came first.
  // Do not use an arbitrary identifier as evidence of chronological progress.
  final latestOrderUnclear =
      sessions.length > 1 &&
      sessions[0].sessionStartedAt.isAtSameMomentAs(
        sessions[1].sessionStartedAt,
      );
  final previousOrderUnclear =
      !latestOrderUnclear &&
      sessions.length > 2 &&
      sessions[1].sessionStartedAt.isAtSameMomentAs(
        sessions[2].sessionStartedAt,
      );
  return ExerciseProgressEstimate(
    latest: sessions.isNotEmpty && !latestOrderUnclear ? sessions.first : null,
    previous:
        sessions.length > 1 && !latestOrderUnclear && !previousOrderUnclear
        ? sessions[1]
        : null,
    qualifyingSets: qualifyingSets,
    excludedSets: excludedSets,
    qualifyingSessions: sessions.length,
    latestOrderUnclear: latestOrderUnclear,
    previousOrderUnclear: previousOrderUnclear,
  );
}
