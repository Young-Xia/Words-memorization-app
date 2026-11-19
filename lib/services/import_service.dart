import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

class ImportRow {
  const ImportRow({
    required this.word,
    this.meaning,
    this.frequency,
    this.senseKey,
  });

  final String word;
  final String? meaning;
  final int? frequency;
  final String? senseKey;
}

class ImportPreview {
  const ImportPreview({required this.rows, required this.warnings});

  final List<ImportRow> rows;
  final List<String> warnings;
}

/// Parses content only. The caller previews rows before updating persisted data.
class ImportService {
  ImportPreview parse(String filename, List<int> bytes) {
    final extension = filename.split('.').last.toLowerCase();
    try {
      switch (extension) {
        case 'txt':
          final text = _decode(bytes);
          return _rows(
            const LineSplitter()
                .convert(text)
                .map((line) => line.split('\t'))
                .toList(),
          );
        case 'csv':
          return _rows(_csv(_decode(bytes)));
        case 'docx':
          return _rows(_docx(bytes));
        default:
          throw const FormatException('仅支持 TXT、CSV 和 DOCX 文件。');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('文件无法解析，请检查文件内容和格式。');
    }
  }

  String _decode(List<int> bytes) {
    final text = utf8.decode(bytes);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }

  static const _headers = {
    'word': 'word',
    '单词': 'word',
    '英文': 'word',
    'meaning': 'meaning',
    '释义': 'meaning',
    '意思': 'meaning',
    'frequency': 'frequency',
    '考频': 'frequency',
    '频次': 'frequency',
    'sensekey': 'senseKey',
    'sense_key': 'senseKey',
    '词义编号': 'senseKey',
  };

  ImportPreview _rows(List<List<String>> records) {
    final rows = <ImportRow>[];
    final warnings = <String>[];
    Map<String, int> columns = {
      'word': 0,
      'meaning': 1,
      'frequency': 2,
      'senseKey': 3,
    };
    var first = true;
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      if (record.every((value) => value.trim().isEmpty)) continue;
      if (first) {
        first = false;
        final mapped = record
            .map((cell) => _headers[cell.trim().toLowerCase()])
            .toList();
        if (mapped.contains('word')) {
          columns = {};
          for (var c = 0; c < mapped.length; c++) {
            final key = mapped[c];
            if (key != null) columns[key] = c;
          }
          continue;
        }
      }
      String? value(String key) {
        final column = columns[key];
        if (column == null || column >= record.length) return null;
        final result = record[column].trim();
        return result.isEmpty ? null : result;
      }

      final word = value('word');
      if (word == null) {
        warnings.add('第 ${index + 1} 条缺少单词，已跳过。');
        continue;
      }
      final rawFrequency = value('frequency');
      var frequency = rawFrequency == null ? null : int.tryParse(rawFrequency);
      if (rawFrequency != null && (frequency == null || frequency < 0)) {
        warnings.add('第 ${index + 1} 条「$word」考频无效，已留空。');
        frequency = null;
      }
      rows.add(
        ImportRow(
          word: word.toLowerCase(),
          meaning: value('meaning'),
          frequency: frequency,
          senseKey: value('senseKey'),
        ),
      );
    }
    return ImportPreview(
      rows: List.unmodifiable(rows),
      warnings: List.unmodifiable(warnings),
    );
  }

  List<List<String>> _csv(String text) {
    final records = <List<String>>[];
    var record = <String>[];
    var field = StringBuffer();
    var quoted = false;
    var closedQuote = false;
    void finishField() {
      record.add(field.toString());
      field = StringBuffer();
      closedQuote = false;
    }

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
            closedQuote = true;
          }
        } else {
          field.write(char);
        }
      } else if (char == ',') {
        finishField();
      } else if (char == '\n' || char == '\r') {
        finishField();
        records.add(record);
        record = [];
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      } else if (char == '"') {
        if (field.isNotEmpty || closedQuote) {
          throw const FormatException('CSV 引号位置无效。');
        }
        quoted = true;
      } else {
        if (closedQuote) {
          if (char == ' ' || char == '\t') continue;
          throw const FormatException('CSV 引号后存在无效内容。');
        }
        field.write(char);
      }
    }
    if (quoted) throw const FormatException('CSV 引号未闭合。');
    if (field.isNotEmpty || record.isNotEmpty || closedQuote) {
      finishField();
      records.add(record);
    }
    return records;
  }

  List<List<String>> _docx(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final file = archive.findFile('word/document.xml');
    if (file == null) throw const FormatException('DOCX 缺少正文。');
    final document = XmlDocument.parse(utf8.decode(file.content as List<int>));
    final bodies = document.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'body',
    );
    if (bodies.isEmpty) throw const FormatException('DOCX 缺少正文。');
    final records = <List<String>>[];
    // Read body blocks once, so table paragraphs are not imported a second time.
    for (final block in bodies.first.childElements) {
      if (block.name.local == 'p') {
        final paragraph = _paragraph(block);
        for (final line in const LineSplitter().convert(paragraph)) {
          records.add(line.split('\t'));
        }
      } else if (block.name.local == 'tbl') {
        for (final row in block.childElements.where(
          (e) => e.name.local == 'tr',
        )) {
          records.add(
            row.childElements.where((e) => e.name.local == 'tc').map((cell) {
              return cell.childElements
                  .where((e) => e.name.local == 'p')
                  .map(_paragraph)
                  .join('\n');
            }).toList(),
          );
        }
      }
    }
    return records;
  }

  String _paragraph(XmlElement paragraph) {
    final result = StringBuffer();
    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      switch (element.name.local) {
        case 't':
          result.write(element.innerText);
        case 'tab':
          result.write('\t');
        case 'br':
        case 'cr':
          result.write('\n');
      }
    }
    return result.toString();
  }
}
