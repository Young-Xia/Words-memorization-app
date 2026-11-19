/// Progress belongs to a sense, rather than to a word or a word list.
class ReviewState {
  final int stage;
  final DateTime? dueAt;
  final DateTime? lastCheckAt;
  final bool learned;

  const ReviewState({
    this.stage = 0,
    this.dueAt,
    this.lastCheckAt,
    this.learned = false,
  }) : assert(stage >= 0 && stage <= 3);

  bool get mastered => stage == 3;

  ReviewState copyWith({
    int? stage,
    DateTime? dueAt,
    DateTime? lastCheckAt,
    bool? learned,
  }) => ReviewState(
    stage: stage ?? this.stage,
    dueAt: dueAt ?? this.dueAt,
    lastCheckAt: lastCheckAt ?? this.lastCheckAt,
    learned: learned ?? this.learned,
  );
}

class ReviewScheduler {
  const ReviewScheduler._();

  static ReviewState markLearned(ReviewState state, DateTime now) {
    if (state.learned) return state;
    return state.copyWith(
      learned: true,
      dueAt: now.add(const Duration(days: 1)),
    );
  }

  /// An early answer is practice, not a formal check. Late checks keep progress.
  static ReviewState recordCheck(
    ReviewState state,
    bool correct,
    DateTime now,
  ) {
    if (!state.learned) return state;
    // Discovering a forgotten sense matters even before its scheduled check.
    if (!correct) return _recordMistake(state, now);
    if (state.dueAt == null || now.isBefore(state.dueAt!)) {
      return state;
    }
    final previous = state.lastCheckAt;
    if (previous != null && _sameDay(previous, now)) return state;

    final nextStage = state.stage < 3 ? state.stage + 1 : 3;
    final days = state.stage == 3 ? 30 : [3, 7, 14][state.stage];
    return state.copyWith(
      stage: nextStage,
      lastCheckAt: now,
      dueAt: now.add(Duration(days: days)),
    );
  }

  /// Correct practice cannot promote progress. Once a sense was checked today,
  /// its same-day retry queue cannot retreat or promote it again.
  static ReviewState practice(ReviewState state, bool correct, DateTime now) {
    if (correct || !state.learned) return state;
    final previous = state.lastCheckAt;
    if (previous != null && _sameDay(previous, now)) return state;
    return _recordMistake(state, now);
  }

  static ReviewState _recordMistake(ReviewState state, DateTime now) {
    final previous = state.lastCheckAt;
    if (previous != null && _sameDay(previous, now)) return state;
    final tomorrow = now.add(const Duration(days: 1));
    // Preserve an already imminent check rather than postponing it. An overdue
    // failed check gets tomorrow as its next independent retrieval attempt.
    final due = state.dueAt;
    return state.copyWith(
      stage: state.stage > 0 ? state.stage - 1 : 0,
      lastCheckAt: now,
      dueAt: due != null && due.isAfter(now) && due.isBefore(tomorrow)
          ? due
          : tomorrow,
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
