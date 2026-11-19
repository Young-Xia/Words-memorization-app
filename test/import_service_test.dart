import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wordsmemory/services/import_service.dart';

void main() {
  final service = ImportService();

  test('TXT preserves absent frequency and independent sense keys', () {
    final preview = service.parse(
      'words.TXT',
      utf8.encode(
        '\uFEFFword\tmeaning\tfrequency\tsenseKey\r\n'
        ' Bank \t银行\t12\tbank.money\r\n'
        'bank\t河岸\t\tbank.river\r\n',
      ),
    );
    expect(preview.rows.map((r) => r.word), ['bank', 'bank']);
    expect(preview.rows.map((r) => r.senseKey), ['bank.money', 'bank.river']);
    expect(preview.rows.map((r) => r.frequency), [12, null]);
    expect(preview.warnings, isEmpty);
  });

  test(
    'CSV supports reordered Chinese headers, commas, quotes and newlines',
    () {
      final preview = service.parse(
        'words.csv',
        utf8.encode(
          '释义,考频,单词,词义编号\r\n'
          '"说，\n并说""你好""",0,say,say.speak\r\n',
        ),
      );
      expect(preview.rows.single.word, 'say');
      expect(preview.rows.single.meaning, '说，\n并说"你好"');
      expect(preview.rows.single.frequency, 0);
      expect(preview.rows.single.senseKey, 'say.speak');
    },
  );

  test(
    'missing words are skipped and invalid frequency is warned, never zeroed',
    () {
      final preview = service.parse(
        'words.csv',
        utf8.encode(
          'word,meaning,frequency\n,无单词,5\napple,苹果,-1\npear,梨,no\norange,橙子,\n',
        ),
      );
      expect(preview.rows.map((r) => r.word), ['apple', 'pear', 'orange']);
      expect(preview.rows.every((r) => r.frequency == null), isTrue);
      expect(preview.warnings, hasLength(3));
    },
  );

  test(
    'DOCX imports paragraphs and table rows once, including multi-run text',
    () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:r><w:t>apple</w:t><w:tab/><w:t>苹果</w:t></w:r></w:p>
<w:tbl><w:tr>
<w:tc><w:p><w:r><w:t>ba</w:t></w:r><w:r><w:t>nk</w:t></w:r></w:p></w:tc>
<w:tc><w:p><w:r><w:t>银行</w:t></w:r></w:p><w:p><w:r><w:t>金融机构</w:t></w:r></w:p></w:tc>
<w:tc><w:p><w:r><w:t>8</w:t></w:r></w:p></w:tc>
</w:tr></w:tbl>
</w:body></w:document>''';
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'word/document.xml',
            utf8.encode(xml).length,
            utf8.encode(xml),
          ),
        );
      final preview = service.parse('words.docx', ZipEncoder().encode(archive));
      expect(preview.rows, hasLength(2));
      expect(preview.rows.last.word, 'bank');
      expect(preview.rows.last.meaning, '银行\n金融机构');
      expect(preview.rows.last.frequency, 8);
    },
  );

  test(
    'malformed inputs reject instead of silently accepting corrupt data',
    () {
      expect(
        () =>
            service.parse('words.csv', utf8.encode('word,meaning\n"apple,苹果')),
        throwsFormatException,
      );
      expect(
        () => service.parse('words.csv', utf8.encode('"apple"oops,苹果')),
        throwsFormatException,
      );
      expect(() => service.parse('words.txt', [0xff]), throwsFormatException);
      expect(
        () => service.parse('words.docx', [1, 2, 3]),
        throwsFormatException,
      );
      expect(() => service.parse('words.doc', []), throwsFormatException);
    },
  );
}
