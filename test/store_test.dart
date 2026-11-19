import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmemory/data/store.dart';
import 'package:wordsmemory/services/import_service.dart';
import 'package:wordsmemory/domain/review.dart';

void main() {
  late AppStore store;
  setUp(() async {
    store = AppStore.memory();
    await store.init();
  });
  tearDown(() async {
    await store.close();
  });

  test('renaming and deleting a book preserve shared review data', () async {
    final book = await store.createBook('练习', '六级');
    const word = ImportRow(word: 'apple', meaning: '苹果', frequency: 5);
    await store.importRows(book, [word]);
    final entry = (await store.entries(bookId: book)).single;
    await store.saveReview(
      entry['senseId'] as String,
      const ReviewState(learned: true, stage: 1),
      kind: 'check',
      correct: true,
    );
    await store.renameBook(book, '  六级练习  ');
    expect((await store.books()).singleWhere((b) => b['id'] == book), {
      'id': book,
      'name': '六级练习',
      'exam': '六级',
      'count': 1,
    });
    expect((await store.entries(bookId: book)).single['frequency'], 5);

    await store.deleteBook(book);
    expect((await store.books()).any((b) => b['id'] == book), isFalse);
    expect(await store.entries(bookId: book), isEmpty);
    final shared = (await store.entries(
      bookId: 'sample-0',
    )).singleWhere((row) => row['word'] == 'apple');
    expect(shared['stage'], 1);
  });

  test('an empty book directory stays empty when reopened', () async {
    final directory = await Directory.systemTemp.createTemp(
      'wordsmemory-empty-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/wordsmemory.db');
    final first = AppStore.open(file);
    try {
      await first.init();
      for (final book in await first.books()) {
        await first.deleteBook(book['id'] as String);
      }
    } finally {
      await first.close();
    }
    final reopened = AppStore.open(file);
    try {
      await reopened.init();
      expect(await reopened.books(), isEmpty);
      expect(await reopened.entries(), isEmpty);
    } finally {
      await reopened.close();
    }
  });

  test(
    'exact senses share progress across books while imports preserve it',
    () async {
      final first = await store.createBook('我的词表', '');
      final second = await store.createBook('另一个词表', '');
      await store.importRows(first, [
        const ImportRow(word: 'apple', meaning: '苹果', frequency: 8),
      ]);
      final id =
          (await store.entries(bookId: first)).single['senseId'] as String;
      final due = DateTime(2026, 10, 25);
      await store.saveReview(
        id,
        ReviewState(
          stage: 2,
          dueAt: due,
          lastCheckAt: DateTime(2026, 10, 22),
          learned: true,
        ),
        kind: 'check',
        correct: true,
      );
      await store.importRows(second, [
        const ImportRow(word: 'APPLE', meaning: '苹果'),
      ]);
      await store.importRows(first, [
        const ImportRow(word: 'apple', frequency: 12),
      ]);
      final entry = (await store.entries(bookId: first)).single;
      final shared = (await store.entries(bookId: second)).single;
      expect(entry['frequency'], 12);
      expect(entry['stage'], 2);
      expect(entry['dueAt'], due.toIso8601String());
      expect(shared['senseId'], id);
      expect(shared['stage'], 2);
      expect(shared['frequency'], isNull);
      await store.setCustomMeaning(first, id, '我的苹果释义');
      await store.importRows(first, [const ImportRow(word: 'apple')]);
      expect(
        (await store.entries(bookId: first)).single['customMeaning'],
        '我的苹果释义',
      );
      expect(
        (await store.entries(bookId: second)).single['customMeaning'],
        '苹果',
      );
    },
  );

  test(
    'editing an example updates only its shared sense and survives backup',
    () async {
      final first = await store.createBook('例句甲', '');
      final second = await store.createBook('例句乙', '');
      const row = ImportRow(word: 'bank', meaning: '银行', senseKey: 'my-bank');
      await store.importRows(first, [row]);
      await store.importRows(second, [row]);
      final id =
          (await store.entries(bookId: first)).single['senseId'] as String;
      expect((await store.entries(bookId: first)).single['requiresContext'], 1);
      await store.setExample(id, '  I visited the bank to open an account.  ');
      expect(
        (await store.entries(bookId: second)).single['example'],
        'I visited the bank to open an account.',
      );
      final river = (await store.dictionary()).singleWhere(
        (r) => r['word'] == 'bank' && r['meaning'] == '河岸',
      );
      expect(river['example'], 'We sat on the grassy bank beside the river.');
      final backup = await store.exportBackup();
      await store.setExample(id, '');
      await store.restoreBackup(backup);
      expect(
        (await store.entries(bookId: first)).single['example'],
        'I visited the bank to open an account.',
      );
      await expectLater(
        store.setExample('missing', 'An example.'),
        throwsFormatException,
      );
    },
  );

  test(
    'changed wording without a sense key cannot overwrite an existing sense',
    () async {
      final book = await store.createBook('保守合并', '');
      await store.importRows(book, [
        const ImportRow(word: 'bank', meaning: '金融机构'),
      ]);
      final id =
          (await store.entries(bookId: book)).single['senseId'] as String;
      await store.saveReview(
        id,
        const ReviewState(stage: 1, learned: true),
        kind: 'learn',
        correct: null,
      );
      await store.importRows(book, [
        const ImportRow(word: 'bank', meaning: '银行；金融机构'),
      ]);
      final rows = await store.entries(bookId: book);
      expect(rows.length, 2);
      expect(rows.singleWhere((r) => r['senseId'] == id)['stage'], 1);
      expect(rows.singleWhere((r) => r['senseId'] != id)['stage'], 0);
    },
  );

  test(
    'blank updates preserve metadata and ambiguous words remain pending',
    () async {
      final book = await store.createBook('导入', '');
      await store.importRows(book, [
        const ImportRow(word: 'apple', frequency: 9),
        const ImportRow(word: 'bank'),
      ]);
      await store.importRows(book, [const ImportRow(word: 'apple')]);
      final rows = await store.entries(bookId: book);
      expect(rows.singleWhere((row) => row['word'] == 'apple')['frequency'], 9);
      expect(rows.singleWhere((row) => row['word'] == 'bank')['meaning'], '');
      final banks = (await store.dictionary()).where(
        (row) => row['word'] == 'bank',
      );
      expect(banks.length, 2);
    },
  );

  test(
    'explicit sense keys link wording without changing another book',
    () async {
      final first = await store.createBook('甲', '');
      final second = await store.createBook('乙', '');
      await store.importRows(first, [
        const ImportRow(
          word: 'bank',
          meaning: '银行',
          senseKey: 'financial-bank',
        ),
      ]);
      await store.importRows(second, [
        const ImportRow(
          word: 'bank',
          meaning: '银行；金融机构',
          senseKey: 'financial-bank',
        ),
      ]);
      final a = (await store.entries(bookId: first)).single;
      final b = (await store.entries(bookId: second)).single;
      expect(a['senseId'], b['senseId']);
      expect(a['customMeaning'], '银行');
      expect(b['customMeaning'], '银行；金融机构');
      await expectLater(
        store.importRows(second, [
          const ImportRow(word: 'river', senseKey: 'financial-bank'),
        ]),
        throwsFormatException,
      );
    },
  );

  test(
    'backup round trips all data and rejects broken references atomically',
    () async {
      final book = await store.createBook('恢复测试', '自定义');
      await store.importRows(book, [
        const ImportRow(word: 'newword', meaning: '自定义词义', frequency: 2),
      ]);
      final id =
          (await store.entries(bookId: book)).single['senseId'] as String;
      await store.saveReview(
        id,
        ReviewState(stage: 1, learned: true, dueAt: DateTime(2026, 10, 23)),
        kind: 'learn',
        correct: null,
      );
      final backup = await store.exportBackup();
      await store.createBook('恢复后应消失', '');
      await store.restoreBackup(backup);
      final restored =
          jsonDecode(await store.exportBackup()) as Map<String, dynamic>;
      final original = jsonDecode(backup) as Map<String, dynamic>;
      for (final table in ['books', 'senses', 'entries', 'reviews', 'events']) {
        expect(restored[table], original[table]);
      }
      final invalid = jsonDecode(backup) as Map<String, dynamic>;
      (invalid['entries'] as List).first['sense_id'] = 'missing';
      await expectLater(
        store.restoreBackup(jsonEncode(invalid)),
        throwsFormatException,
      );
      final badDate = jsonDecode(backup) as Map<String, dynamic>;
      (badDate['reviews'] as List).first['due_at'] = '2026-02-31T00:00:00.000';
      await expectLater(
        store.restoreBackup(jsonEncode(badDate)),
        throwsFormatException,
      );
      final badVersion = jsonDecode(backup) as Map<String, dynamic>;
      badVersion['version'] = 2;
      await expectLater(
        store.restoreBackup(jsonEncode(badVersion)),
        throwsFormatException,
      );
      expect((await store.entries(bookId: book)).single['stage'], 1);
      expect(
        (await store.books()).any((row) => row['name'] == '恢复后应消失'),
        isFalse,
      );
    },
  );
}
