import 'package:flutter_test/flutter_test.dart';

import 'package:wordsmemory/domain/review.dart';

void main() {
  final start = DateTime(2026, 10, 20, 9);

  test('three spaced successful checks master a sense', () {
    var state = ReviewScheduler.markLearned(const ReviewState(), start);
    expect(state.dueAt, start.add(const Duration(days: 1)));
    state = ReviewScheduler.recordCheck(state, true, state.dueAt!);
    expect(state.stage, 1);
    expect(state.dueAt, start.add(const Duration(days: 4)));
    state = ReviewScheduler.recordCheck(state, true, state.dueAt!);
    expect(state.stage, 2);
    expect(state.dueAt, start.add(const Duration(days: 11)));
    state = ReviewScheduler.recordCheck(state, true, state.dueAt!);
    expect(state.mastered, isTrue);
    expect(state.dueAt, start.add(const Duration(days: 25)));
  });

  test('early answers and same-day repeats cannot promote progress', () {
    final state = ReviewScheduler.markLearned(const ReviewState(), start);
    expect(ReviewScheduler.recordCheck(state, true, start), same(state));
    final checked = ReviewScheduler.recordCheck(state, true, state.dueAt!);
    final malformedDue = checked.copyWith(dueAt: checked.lastCheckAt!);
    expect(
      ReviewScheduler.recordCheck(
        malformedDue,
        true,
        checked.lastCheckAt!.add(const Duration(hours: 2)),
      ),
      same(malformedDue),
    );
  });

  test('late checks keep progress and a wrong answer retreats one stage', () {
    final late = ReviewState(stage: 2, learned: true, dueAt: start);
    final passed = ReviewScheduler.recordCheck(
      late,
      true,
      start.add(const Duration(days: 10)),
    );
    expect(passed.stage, 3);
    final wrong = ReviewScheduler.recordCheck(passed, false, passed.dueAt!);
    expect(wrong.stage, 2);
    expect(wrong.dueAt, passed.dueAt!.add(const Duration(days: 1)));
  });

  test('successful practice cannot promote or erase learned history', () {
    final state = ReviewScheduler.markLearned(const ReviewState(), start);
    expect(ReviewScheduler.practice(state, true, start), same(state));
    expect(
      ReviewScheduler.markLearned(state, start.add(const Duration(days: 9))),
      same(state),
    );
    expect(
      ReviewScheduler.recordCheck(const ReviewState(), true, start).stage,
      0,
    );
  });

  test(
    'early mistakes demote mastered progress without same-day promotion',
    () {
      final state = ReviewState(
        stage: 3,
        learned: true,
        dueAt: start.add(const Duration(days: 20)),
      );
      final wrong = ReviewScheduler.recordCheck(state, false, start);
      expect(wrong.stage, 2);
      expect(wrong.dueAt, start.add(const Duration(days: 1)));
      expect(
        ReviewScheduler.practice(
          wrong,
          false,
          start.add(const Duration(minutes: 10)),
        ),
        same(wrong),
      );
      expect(
        ReviewScheduler.recordCheck(
          wrong,
          true,
          start.add(const Duration(minutes: 10)),
        ),
        same(wrong),
      );
    },
  );

  test(
    'wrong practice retreats once and does not postpone an imminent check',
    () {
      final state = ReviewState(
        stage: 2,
        learned: true,
        dueAt: start.add(const Duration(hours: 3)),
      );
      final wrong = ReviewScheduler.practice(state, false, start);
      expect(wrong.stage, 1);
      expect(wrong.dueAt, state.dueAt);
      expect(
        ReviewScheduler.recordCheck(wrong, true, wrong.dueAt!),
        same(wrong),
      );
    },
  );

  test('a same-day extra check cannot change the completed formal check', () {
    final state = ReviewState(stage: 2, learned: true, dueAt: start);
    final passed = ReviewScheduler.recordCheck(state, true, start);
    final failed = ReviewScheduler.recordCheck(
      passed,
      false,
      start.add(const Duration(hours: 1)),
    );
    expect(failed, same(passed));
  });

  test(
    'stage zero failures stay zero and mastered checks extend to thirty days',
    () {
      final state = ReviewState(learned: true, dueAt: start);
      expect(ReviewScheduler.recordCheck(state, false, start).stage, 0);
      final mastered = ReviewState(stage: 3, learned: true, dueAt: start);
      final checked = ReviewScheduler.recordCheck(mastered, true, start);
      expect(checked.stage, 3);
      expect(checked.dueAt, start.add(const Duration(days: 30)));
    },
  );
}
