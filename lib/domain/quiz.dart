import 'dart:math';

class QuizCandidate {
  final String senseId;
  final String word;
  final String meaning;
  final String? example;
  final bool learned;
  final bool requiresContext;

  const QuizCandidate({
    required this.senseId,
    required this.word,
    required this.meaning,
    this.example,
    this.learned = false,
    this.requiresContext = false,
  });
}

class QuizQuestion {
  final QuizCandidate target;
  final List<String> options;
  final int correctIndex;

  QuizQuestion({
    required this.target,
    required List<String> options,
    required this.correctIndex,
  }) : options = List.unmodifiable(options);
}

class QuizBuilder {
  const QuizBuilder._();

  static List<QuizQuestion> build(
    List<QuizCandidate> pool,
    List<QuizCandidate> dictionary, {
    int limit = 10,
    Random? random,
  }) {
    if (limit <= 0) return const [];
    final rng = random ?? Random();
    final seen = <String>{};
    final targets =
        pool
            .where(
              (candidate) =>
                  candidate.learned &&
                  candidate.meaning.trim().isNotEmpty &&
                  (!candidate.requiresContext ||
                      (candidate.example?.trim().isNotEmpty ?? false)) &&
                  seen.add(candidate.senseId),
            )
            .toList()
          ..shuffle(rng);
    final all = [...pool, ...dictionary];
    final questions = <QuizQuestion>[];

    for (final target in targets) {
      final validAliases = <String>{};
      for (final candidate in all) {
        if (_normalize(candidate.word) == _normalize(target.word)) {
          validAliases.addAll(_aliases(candidate.meaning));
        }
      }
      final usedAliases = {...validAliases};
      final distractors = [...all]..shuffle(rng);
      final options = <String>[target.meaning.trim()];
      for (final candidate in distractors) {
        final aliases = _aliases(candidate.meaning);
        if (aliases.isEmpty || aliases.any(usedAliases.contains)) continue;
        if (_normalize(candidate.word) == _normalize(target.word)) continue;
        options.add(candidate.meaning.trim());
        usedAliases.addAll(aliases);
        if (options.length == 4) break;
      }
      if (options.length < 2) continue;
      options.shuffle(rng);
      questions.add(
        QuizQuestion(
          target: target,
          options: options,
          correctIndex: options.indexOf(target.meaning.trim()),
        ),
      );
      if (questions.length == limit) break;
    }
    return List.unmodifiable(questions);
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static Set<String> _aliases(String value) => value
      .split(RegExp(r'[;；、/|,，]'))
      .map(_normalize)
      .where((part) => part.isNotEmpty)
      .toSet();
}
