import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:wordsmemory/domain/quiz.dart';

QuizCandidate candidate(
  String id,
  String word,
  String meaning, {
  bool learned = false,
  bool context = false,
  String? example,
}) => QuizCandidate(
  senseId: id,
  word: word,
  meaning: meaning,
  learned: learned,
  requiresContext: context,
  example: example,
);

void main() {
  final dictionary = [
    candidate('dog', 'dog', '狗'),
    candidate('cat', 'cat', '猫'),
    candidate('tree', 'tree', '树'),
    candidate('flower', 'flower', '花'),
  ];

  test('only learned, contextualized, distinct senses become targets', () {
    final pool = [
      candidate('a', 'apple', '苹果', learned: true),
      candidate('a', 'apple', '苹果', learned: true),
      candidate('b', 'bank', '银行', learned: true, context: true),
      candidate('c', 'cold', '冷'),
      candidate(
        'd',
        'bat',
        '球棒',
        learned: true,
        context: true,
        example: 'He swung the bat.',
      ),
    ];
    final questions = QuizBuilder.build(pool, dictionary, random: Random(1));
    expect(questions.map((q) => q.target.senseId).toSet(), {'a', 'd'});
    for (final q in questions) {
      expect(q.options[q.correctIndex], q.target.meaning);
      expect(q.options.length, 4);
    }
  });

  test(
    'other senses of the same word and overlapping aliases are excluded',
    () {
      final target = candidate('bank1', 'bank', '银行', learned: true);
      final questions = QuizBuilder.build(
        [target],
        [
          candidate('bank2', ' BANK ', '河岸'),
          candidate('finance', 'finance', '银行；金融机构'),
          ...dictionary,
        ],
        random: Random(8),
      );
      final options = questions.single.options;
      expect(options, isNot(contains('河岸')));
      expect(options, isNot(contains('银行；金融机构')));
    },
  );

  test('duplicate and overlapping distractors cannot both appear', () {
    final questions = QuizBuilder.build(
      [candidate('a', 'apple', '苹果', learned: true)],
      [
        candidate('b', 'b', 'Dog'),
        candidate('c', 'c', ' dog '),
        candidate('d', 'd', 'DOG；狗'),
      ],
      random: Random(3),
    );
    expect(questions.single.options.length, 2);
  });

  test(
    'reduces to two options but skips questions with no safe distractor',
    () {
      final target = candidate('a', 'apple', '苹果', learned: true);
      expect(
        QuizBuilder.build([target], [dictionary.first]).single.options.length,
        2,
      );
      expect(QuizBuilder.build([target], []), isEmpty);
      expect(QuizBuilder.build([target], dictionary, limit: 0), isEmpty);
    },
  );

  test('limit caps the number of questions', () {
    final pool = [
      candidate('a', 'apple', '苹果', learned: true),
      candidate('b', 'bread', '面包', learned: true),
    ];
    expect(QuizBuilder.build(pool, dictionary, limit: 1).length, 1);
  });
}
