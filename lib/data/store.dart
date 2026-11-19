import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../services/import_service.dart';
import '../domain/review.dart';

class _Database extends GeneratedDatabase {
  _Database(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in _schema) {
        await customStatement(sql);
      }
      const names = ['日常基础 · 示例词表', '学习与工作 · 示例词表', '多义词 · 示例词表'];
      for (var i = 0; i < names.length; i++) {
        await customStatement('INSERT INTO books VALUES (?,?,?)', [
          'sample-$i',
          names[i],
          '示例',
        ]);
      }
      for (final row in _seed) {
        final word = row[0] as String;
        final meaning = row[1] as String;
        final id = AppStore._senseId(word, meaning);
        await customStatement('INSERT INTO senses VALUES (?,?,?,?,?)', [
          id,
          word,
          meaning,
          row[2],
          row[3],
        ]);
        await customStatement('INSERT INTO entries VALUES (?,?,NULL,NULL)', [
          'sample-${row[4]}',
          id,
        ]);
      }
    },
  );
}

const _schema = [
  'CREATE TABLE books (id TEXT PRIMARY KEY, name TEXT NOT NULL, exam TEXT NOT NULL)',
  'CREATE TABLE senses (id TEXT PRIMARY KEY, word TEXT NOT NULL, meaning TEXT NOT NULL, example TEXT NOT NULL, requires_context INTEGER NOT NULL)',
  'CREATE TABLE entries (book_id TEXT NOT NULL REFERENCES books(id), sense_id TEXT NOT NULL REFERENCES senses(id), custom_meaning TEXT, frequency INTEGER, PRIMARY KEY(book_id,sense_id))',
  'CREATE TABLE reviews (sense_id TEXT PRIMARY KEY REFERENCES senses(id), stage INTEGER NOT NULL, due_at TEXT, last_check_at TEXT, learned INTEGER NOT NULL)',
  'CREATE TABLE events (id TEXT PRIMARY KEY, sense_id TEXT NOT NULL REFERENCES senses(id), kind TEXT NOT NULL, correct INTEGER, at TEXT NOT NULL)',
];

/// The database owns shared sense progress; entries own book-specific metadata.
class AppStore {
  AppStore._(this._db);
  factory AppStore.open(File file) =>
      AppStore._(_Database(NativeDatabase(file)));
  factory AppStore.memory() => AppStore._(_Database(NativeDatabase.memory()));
  final _Database _db;
  int _counter = 0;
  String _id(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
  static String _normal(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static String _senseId(String word, String meaning) =>
      'sense:${base64Url.encode(utf8.encode('${_normal(word)}\u0000${_normal(meaning)}'))}';

  Future<List<Map<String, dynamic>>> _query(
    String sql, [
    List<Variable> variables = const [],
  ]) async => (await _db.customSelect(sql, variables: variables).get())
      .map((row) => Map<String, dynamic>.from(row.data))
      .toList();

  Future<void> init() async {
    await _db.customStatement('PRAGMA foreign_keys = ON');
  }

  Future<List<Map<String, dynamic>>> books() => _query(
    'SELECT b.*, COUNT(e.sense_id) AS count FROM books b LEFT JOIN entries e ON e.book_id=b.id GROUP BY b.id ORDER BY b.rowid',
  );

  Future<List<Map<String, dynamic>>> entries({String? bookId}) async {
    final rows = await _query(
      '''SELECT s.id AS senseId, s.word, s.meaning,
      e.book_id AS bookId, e.custom_meaning AS customMeaning, e.frequency,
      s.example, s.requires_context AS requiresContext,
      COALESCE(r.stage,0) AS stage, r.due_at AS dueAt,
      r.last_check_at AS lastCheckAt, COALESCE(r.learned,0) AS learned
      FROM entries e JOIN senses s ON s.id=e.sense_id
      LEFT JOIN reviews r ON r.sense_id=s.id
      ${bookId == null ? '' : 'WHERE e.book_id=?'}
      ORDER BY e.frequency IS NULL, e.frequency DESC, s.word, s.id, e.rowid''',
      bookId == null ? [] : [Variable<String>(bookId)],
    );
    if (bookId != null) return rows;
    final seen = <String>{};
    return rows.where((row) => seen.add(row['senseId'] as String)).toList();
  }

  Future<List<Map<String, dynamic>>> dictionary() => _query(
    'SELECT id AS senseId, word, meaning, example, requires_context AS requiresContext FROM senses WHERE meaning<>\'\' ORDER BY word,id',
  );

  Future<String> createBook(String name, String exam) async {
    if (name.trim().isEmpty) throw const FormatException('词表名称不能为空。');
    final id = _id('book');
    await _db.customStatement('INSERT INTO books VALUES (?,?,?)', [
      id,
      name.trim(),
      exam.trim(),
    ]);
    return id;
  }

  Future<void> renameBook(String bookId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const FormatException('词表名称不能为空。');
    final changed = await _db.customUpdate(
      'UPDATE books SET name=? WHERE id=?',
      variables: [Variable<String>(trimmed), Variable<String>(bookId)],
    );
    if (changed == 0) throw const FormatException('词表不存在。');
  }

  Future<void> deleteBook(String bookId) => _db.transaction(() async {
    // Senses, reviews and events can belong to other books or be used on reimport.
    await _db.customStatement('DELETE FROM entries WHERE book_id=?', [bookId]);
    await _db.customStatement('DELETE FROM books WHERE id=?', [bookId]);
  });

  Future<void> importRows(String bookId, List<ImportRow> rows) async {
    await _db.transaction(() async {
      if ((await _query('SELECT id FROM books WHERE id=?', [
        Variable<String>(bookId),
      ])).isEmpty) {
        throw const FormatException('词表不存在。');
      }
      for (final row in rows) {
        final word = _normal(row.word);
        if (word.isEmpty || (row.frequency != null && row.frequency! < 0)) {
          throw const FormatException('单词或考频无效。');
        }
        var meaning = row.meaning?.trim();
        if (meaning?.isEmpty ?? false) meaning = null;
        final key = row.senseKey?.trim();
        String id;
        if (key != null && key.isNotEmpty) {
          id = 'key:${_normal(key)}';
        } else if (meaning != null) {
          id = _senseId(word, meaning);
        } else {
          final local = await _query(
            'SELECT s.id,s.meaning FROM senses s JOIN entries e ON e.sense_id=s.id WHERE e.book_id=? AND s.word=?',
            [Variable<String>(bookId), Variable<String>(word)],
          );
          final matches = local.length == 1
              ? local
              : await _query(
                  'SELECT id,meaning FROM senses WHERE word=? AND meaning<>\'\'',
                  [Variable<String>(word)],
                );
          if (matches.length == 1) {
            id = matches.single['id'] as String;
            meaning = matches.single['meaning'] as String;
          } else {
            id = _senseId(word, '');
          }
        }
        final existing = await _query(
          'SELECT word,meaning FROM senses WHERE id=?',
          [Variable<String>(id)],
        );
        if (existing.isNotEmpty && existing.single['word'] != word) {
          throw const FormatException('词义编号不能关联不同单词。');
        }
        if (existing.isEmpty) {
          await _db.customStatement('INSERT INTO senses VALUES (?,?,?,?,?)', [
            id,
            word,
            meaning ?? '',
            '',
            0,
          ]);
        } else if (existing.single['meaning'] == '' && meaning != null) {
          await _db.customStatement('UPDATE senses SET meaning=? WHERE id=?', [
            meaning,
            id,
          ]);
        }
        await _db.customStatement(
          '''UPDATE senses SET requires_context=1
          WHERE word=? AND (SELECT COUNT(DISTINCT meaning) FROM senses WHERE word=? AND meaning<>'')>1''',
          [word, word],
        );
        await _db.customStatement(
          'INSERT OR IGNORE INTO entries VALUES (?,?,NULL,NULL)',
          [bookId, id],
        );
        // Canonical meanings stay stable; imported wording belongs to this book.
        if (row.meaning?.trim().isNotEmpty ?? false) {
          await _db.customStatement(
            'UPDATE entries SET custom_meaning=? WHERE book_id=? AND sense_id=?',
            [meaning, bookId, id],
          );
        }
        if (row.frequency != null) {
          await _db.customStatement(
            'UPDATE entries SET frequency=? WHERE book_id=? AND sense_id=?',
            [row.frequency, bookId, id],
          );
        }
        await _db.customStatement('INSERT INTO events VALUES (?,?,?,NULL,?)', [
          _id('event'),
          id,
          'import',
          DateTime.now().toUtc().toIso8601String(),
        ]);
      }
    });
  }

  Future<void> setCustomMeaning(String bookId, String senseId, String text) =>
      _db.customStatement(
        'UPDATE entries SET custom_meaning=? WHERE book_id=? AND sense_id=?',
        [text.trim().isEmpty ? null : text.trim(), bookId, senseId],
      );

  /// A reliable example describes this shared sense in every linked book.
  Future<void> setExample(String senseId, String example) async {
    await _db.transaction(() async {
      if ((await _query('SELECT id FROM senses WHERE id=?', [
        Variable<String>(senseId),
      ])).isEmpty) {
        throw const FormatException('词义不存在。');
      }
      await _db.customStatement('UPDATE senses SET example=? WHERE id=?', [
        example.trim(),
        senseId,
      ]);
      await _db.customStatement('INSERT INTO events VALUES (?,?,?,NULL,?)', [
        _id('event'),
        senseId,
        'example_edit',
        DateTime.now().toUtc().toIso8601String(),
      ]);
    });
  }

  Future<void> saveReview(
    String senseId,
    ReviewState state, {
    required String kind,
    required bool? correct,
  }) async {
    await _db.transaction(() async {
      await _db.customStatement(
        'INSERT OR REPLACE INTO reviews VALUES (?,?,?,?,?)',
        [
          senseId,
          state.stage,
          state.dueAt?.toIso8601String(),
          state.lastCheckAt?.toIso8601String(),
          state.learned ? 1 : 0,
        ],
      );
      await _db.customStatement('INSERT INTO events VALUES (?,?,?,?,?)', [
        _id('event'),
        senseId,
        kind,
        correct == null ? null : (correct ? 1 : 0),
        DateTime.now().toUtc().toIso8601String(),
      ]);
    });
  }

  static const _tables = ['books', 'senses', 'entries', 'reviews', 'events'];
  Future<String> exportBackup() async => _db.transaction(() async {
    final data = <String, dynamic>{
      'format': 'wordsmemory-backup',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
    };
    for (final table in _tables) {
      data[table] = await _query('SELECT * FROM $table ORDER BY rowid');
    }
    return const JsonEncoder.withIndent('  ').convert(data);
  });

  Future<void> restoreBackup(String json) async {
    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      data = decoded;
      _validateBackup(data);
    } catch (_) {
      throw const FormatException('备份文件无效或版本不受支持，当前数据未修改。');
    }
    await _db.transaction(() async {
      for (final table in _tables.reversed) {
        await _db.customStatement('DELETE FROM $table');
      }
      for (final table in _tables) {
        for (final raw in data[table] as List) {
          final row = raw as Map<String, dynamic>;
          final columns = _columns[table]!;
          await _db.customStatement(
            'INSERT INTO $table (${columns.join(',')}) VALUES (${List.filled(columns.length, '?').join(',')})',
            columns.map((column) => row[column]).toList(),
          );
        }
      }
    });
  }

  Future<void> close() => _db.close();
}

const _columns = {
  'books': ['id', 'name', 'exam'],
  'senses': ['id', 'word', 'meaning', 'example', 'requires_context'],
  'entries': ['book_id', 'sense_id', 'custom_meaning', 'frequency'],
  'reviews': ['sense_id', 'stage', 'due_at', 'last_check_at', 'learned'],
  'events': ['id', 'sense_id', 'kind', 'correct', 'at'],
};

void _validateBackup(Map<String, dynamic> data) {
  void require(bool valid) {
    if (!valid) throw const FormatException();
  }

  require(data['format'] == 'wordsmemory-backup' && data['version'] == 1);
  const keys = ['format', 'version', 'exportedAt', ...AppStore._tables];
  require(data.length == keys.length && keys.every(data.containsKey));
  require(_validBackupDate(data['exportedAt']));
  final ids = <String, Set<String>>{};
  for (final table in AppStore._tables) {
    require(data[table] is List);
    final seen = <String>{};
    ids[table] = seen;
    for (final raw in data[table] as List) {
      require(raw is Map<String, dynamic>);
      final row = raw as Map<String, dynamic>;
      require(
        row.length == _columns[table]!.length &&
            _columns[table]!.every(row.containsKey),
      );
      final primary = table == 'entries'
          ? '${row['book_id']}\u0000${row['sense_id']}'
          : row[table == 'reviews' ? 'sense_id' : 'id'];
      require(primary is String && primary.isNotEmpty && seen.add(primary));
      for (final column in _columns[table]!) {
        final value = row[column];
        if (['requires_context', 'learned', 'correct'].contains(column)) {
          require(
            (column == 'correct' && value == null) ||
                (value is int && (value == 0 || value == 1)),
          );
        } else if (column == 'frequency' || column == 'stage') {
          require(
            (column == 'frequency' && value == null) ||
                (value is int &&
                    value >= 0 &&
                    (column != 'stage' || value <= 3)),
          );
        } else if (column == 'due_at' ||
            column == 'last_check_at' ||
            column == 'at') {
          require((column != 'at' && value == null) || _validBackupDate(value));
        } else if (column == 'custom_meaning') {
          require(value == null || value is String);
        } else {
          require(value is String);
          if ([
            'id',
            'book_id',
            'sense_id',
            'word',
            'name',
            'kind',
          ].contains(column)) {
            require((value as String).trim().isNotEmpty);
          }
        }
      }
    }
  }
  for (final row in data['entries'] as List) {
    require(
      ids['books']!.contains(row['book_id']) &&
          ids['senses']!.contains(row['sense_id']),
    );
  }
  for (final table in ['reviews', 'events']) {
    for (final row in data[table] as List) {
      require(ids['senses']!.contains(row['sense_id']));
    }
  }
}

// Accept the exact ISO representation written by Dart, rejecting date overflow
// such as February 31, which DateTime.tryParse otherwise silently normalizes.
bool _validBackupDate(Object? value) =>
    value is String && DateTime.tryParse(value)?.toIso8601String() == value;

// Original demonstration material, not an official examination vocabulary list.
const _seed = <List<Object>>[
  ['apple', '苹果', 'She put an apple in her bag.', 0, 0],
  ['water', '水', 'Please bring a glass of water.', 0, 0],
  ['friend', '朋友', 'My friend lives near the park.', 0, 0],
  ['travel', '旅行', 'We travel by train in summer.', 0, 0],
  ['quiet', '安静的', 'The room became quiet.', 0, 0],
  ['bright', '明亮的', 'The kitchen is bright in the morning.', 0, 0],
  ['garden', '花园', 'We grow herbs in the garden.', 0, 0],
  ['prepare', '准备', 'I prepare my lunch before work.', 0, 1],
  ['improve', '改善；提高', 'Practice can improve your reading.', 0, 1],
  ['research', '研究', 'Their research focuses on clean energy.', 0, 1],
  ['schedule', '日程安排', 'Check the schedule before the meeting.', 0, 1],
  ['project', '项目', 'Our project starts next week.', 0, 1],
  ['measure', '测量', 'They measure the length of the desk.', 0, 1],
  ['evidence', '证据', 'The report includes useful evidence.', 0, 1],
  ['bank', '银行', 'I deposited my savings at the bank.', 1, 2],
  ['bank', '河岸', 'We sat on the grassy bank beside the river.', 1, 2],
  ['light', '光线', 'Sunlight filled the room with light.', 1, 2],
  ['light', '轻的', 'This empty suitcase is very light.', 1, 2],
  ['present', '礼物', 'She wrapped a birthday present.', 1, 2],
  ['present', '出席的', 'All ten students were present today.', 1, 2],
  ['spring', '春天', 'Flowers return in spring.', 1, 2],
  ['spring', '泉水；泉', 'Fresh water flows from the spring.', 1, 2],
];
