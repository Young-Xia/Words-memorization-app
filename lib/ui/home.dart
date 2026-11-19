import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../data/store.dart';
import 'consolidation_icon.dart';
import '../domain/review.dart';
import '../domain/quiz.dart';
import '../services/import_service.dart';
import '../services/desktop_service.dart';

class HomePage extends StatefulWidget {
  final AppStore store;
  final DesktopService? desktop;
  const HomePage({super.key, required this.store, this.desktop});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> books = [], rows = [];
  String? bookId;
  bool showingBook = false;
  int page = 0, card = 0;
  bool revealed = false, busy = true;
  String search = '', exam = '全部考试', sort = '字母';
  int minFrequency = 0;
  List<QuizQuestion> questions = [];
  int questionIndex = 0, score = 0;
  int? answer;
  String quizScope = 'all';
  String quizTitle = '已学综合';
  bool submitting = false;
  final Set<int> practiceIndices = {};
  final List<String> studyRetry = [];
  final limit = TextEditingController(text: '10');

  AppStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    guard(loadSession);
  }

  @override
  void dispose() {
    limit.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final nextBooks = await store.books();
    var nextRows = await store.entries(bookId: bookId);
    if (bookId == null && exam != '全部考试') {
      final ids = nextBooks
          .where((b) => b['exam'] == exam)
          .map((b) => b['id'])
          .toSet();
      final groups = await Future.wait(
        ids.map((id) => store.entries(bookId: id as String)),
      );
      final seen = <String>{};
      nextRows = groups
          .expand((g) => g)
          .where((r) => seen.add(r['senseId'] as String))
          .toList();
    }
    if (!mounted) return;
    setState(() {
      books = nextBooks;
      rows = nextRows;
      busy = false;
    });
  }

  Future<void> loadSession() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/session.json');
    if (await file.exists()) {
      try {
        final data = jsonDecode(await file.readAsString()) as Map;
        final available = await store.books();
        final savedBook = data['bookId'];
        bookId = available.any((b) => b['id'] == savedBook)
            ? savedBook as String
            : null;
        card = (data['card'] as int? ?? 0).clamp(0, 1000000);
        widget.desktop?.notifications = data['notifications'] != false;
      } catch (_) {
        /* Recover by using the default view. */
      }
    }
    await reload();
    unawaited(widget.desktop?.checkDue() ?? Future<void>.value());
  }

  Future<void> persistSession() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await File('${dir.path}/session.json').writeAsString(
        jsonEncode({
          'bookId': bookId,
          'card': card,
          'notifications': widget.desktop?.notifications ?? false,
        }),
      );
    } catch (error) {
      message('学习记录已保存，但界面位置未保存：$error');
    }
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      message('操作未完成：$error');
    }
  }

  ReviewState progress(Map<String, dynamic> row) => ReviewState(
    stage: row['stage'] as int? ?? 0,
    learned: row['learned'] == 1,
    dueAt: DateTime.tryParse(row['dueAt'] as String? ?? ''),
    lastCheckAt: DateTime.tryParse(row['lastCheckAt'] as String? ?? ''),
  );
  bool isDue(Map<String, dynamic> row) =>
      progress(row).learned &&
      progress(row).dueAt != null &&
      !progress(row).dueAt!.isAfter(DateTime.now());
  String meaning(Map<String, dynamic> row) =>
      (row['customMeaning'] as String?)?.trim().isNotEmpty == true
      ? row['customMeaning'] as String
      : row['meaning'] as String? ?? '';
  List<Map<String, dynamic>> get filtered {
    final list = rows
        .where(
          (r) =>
              '${r['word']} ${meaning(r)}'.toLowerCase().contains(
                search.toLowerCase(),
              ) &&
              (minFrequency == 0 ||
                  (r['frequency'] as int? ?? -1) >= minFrequency),
        )
        .toList();
    list.sort(
      (a, b) => sort == '考频'
          ? (b['frequency'] as int? ?? -1).compareTo(
              a['frequency'] as int? ?? -1,
            )
          : (a['word'] as String).compareTo(b['word'] as String),
    );
    return list;
  }

  List<Map<String, dynamic>> get studyCards {
    final base = filtered.where((r) => meaning(r).isNotEmpty).toList();
    return [
      ...base,
      ...studyRetry.expand((id) => base.where((r) => r['senseId'] == id)),
    ];
  }

  bool needsConsolidation(Map<String, dynamic> row) =>
      progress(row).learned && !progress(row).mastered;

  Future<void> rateStudy(String rating) async {
    if (submitting || !revealed || studyCards.isEmpty) return;
    final list = studyCards;
    final i = card.clamp(0, list.length - 1);
    final r = list[i];
    setState(() => submitting = true);
    try {
      var next = ReviewScheduler.markLearned(progress(r), DateTime.now());
      if (rating == '不认识') {
        next = ReviewScheduler.practice(next, false, DateTime.now());
      }
      await store.saveReview(
        r['senseId'] as String,
        next,
        kind: 'self:$rating',
        correct: null,
      );
      if (rating != '认识' && !studyRetry.contains(r['senseId'])) {
        studyRetry.add(r['senseId'] as String);
      }
      await reload();
      if (!mounted) return;
      setState(() {
        card = i + 1 < studyCards.length ? i + 1 : 0;
        revealed = false;
      });
      await persistSession();
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  void continueQuiz() {
    if (submitting || answer == null) return;
    setState(() {
      questionIndex++;
      answer = null;
    });
  }

  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    final focus = FocusManager.instance.primaryFocus;
    final editing =
        focus?.context != null &&
        (focus!.context!.widget is EditableText ||
            focus.context!.findAncestorWidgetOfExactType<EditableText>() !=
                null);
    if (busy ||
        submitting ||
        editing ||
        ModalRoute.of(context)?.isCurrent != true ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final number = switch (key) {
      LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 0,
      LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 1,
      LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 2,
      LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 3,
      _ => -1,
    };
    final letter = [
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyD,
    ].indexOf(key);
    if (page == 1 && studyCards.isNotEmpty) {
      if (key == LogicalKeyboardKey.space && !revealed) {
        setState(() => revealed = true);
      } else if (number >= 0 && number < 3 && revealed) {
        unawaited(guard(() => rateStudy(['不认识', '模糊', '认识'][number])));
      } else if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        setState(() {
          card = (card + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1)).clamp(
            0,
            studyCards.length - 1,
          );
          revealed = false;
        });
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (page == 2 && questions.isNotEmpty && questionIndex < questions.length) {
      final q = questions[questionIndex];
      final index = number >= 0 ? number : letter;
      if (answer == null && index >= 0 && index < q.options.length) {
        unawaited(guard(() => submit(q, index)));
      } else if (answer != null &&
          (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.space)) {
        continueQuiz();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final due = rows.where(isDue).length;
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width > 1100;
    return Focus(
      autofocus: true,
      onKeyEvent: handleKey,
      child: Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: wide,
              minExtendedWidth: 204,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      Icons.auto_stories_rounded,
                      size: 24,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
              ),
              selectedIndex: page,
              onDestinationSelected: busy || submitting
                  ? null
                  : (value) => setState(() {
                      page = value;
                      if (value == 0) showingBook = false;
                      revealed = false;
                    }),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.library_books_outlined),
                  label: Text('词表与单词'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.style_outlined),
                  label: Text('开始背诵'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.fact_check_outlined),
                  label: Text('考核与复习'),
                ),
                NavigationRailDestination(
                  icon: ConsolidationIcon(
                    key: ValueKey('consolidation-nav-icon'),
                  ),
                  selectedIcon: ConsolidationIcon(filled: true),
                  label: Text('需要巩固'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_backup_restore),
                  label: Text('备份与设置'),
                ),
              ],
            ),
            Expanded(
              child: busy || (page == 0 && submitting)
                  ? const Center(child: CircularProgressIndicator())
                  : Padding(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 40 : 24,
                        28,
                        wide ? 40 : 24,
                        24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '词间',
                                  style: theme.textTheme.headlineLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w400,
                                        letterSpacing: 1.2,
                                      ),
                                ),
                              ),
                              Chip(
                                avatar: const Icon(Icons.schedule, size: 18),
                                label: Text('待复习 $due'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          const Divider(height: 1),
                          const SizedBox(height: 16),
                          if (page > 0 && page < 4) ...[
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                DropdownButton<String>(
                                  value: exam,
                                  items:
                                      {
                                            '全部考试',
                                            ...books.map(
                                              (b) => b['exam'] as String,
                                            ),
                                          }
                                          .map(
                                            (s) => DropdownMenuItem(
                                              value: s,
                                              child: Text(s),
                                            ),
                                          )
                                          .toList(),
                                  onChanged: submitting
                                      ? null
                                      : (s) {
                                          setState(() {
                                            exam = s!;
                                            bookId = null;
                                            questions = [];
                                            card = 0;
                                            revealed = false;
                                          });
                                          guard(reload);
                                        },
                                ),
                                DropdownButton<String>(
                                  value: bookId ?? '',
                                  items: [
                                    const DropdownMenuItem(
                                      value: '',
                                      child: Text('所有词表 · 综合'),
                                    ),
                                    ...books
                                        .where(
                                          (b) =>
                                              exam == '全部考试' ||
                                              b['exam'] == exam,
                                        )
                                        .map(
                                          (b) => DropdownMenuItem(
                                            value: b['id'] as String,
                                            child: Text(b['name'] as String),
                                          ),
                                        ),
                                  ],
                                  onChanged: submitting
                                      ? null
                                      : (s) {
                                          setState(() {
                                            bookId = s == '' ? null : s;
                                            card = 0;
                                            revealed = false;
                                            questions = [];
                                          });
                                          guard(reload);
                                        },
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                          ],
                          Expanded(
                            child: switch (page) {
                              0 => showingBook ? library() : bookDirectory(),
                              1 => study(),
                              2 => quiz(),
                              3 => consolidation(),
                              _ => settings(),
                            },
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget bookDirectory() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '我的词表',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          FilledButton.icon(
            onPressed: submitting ? null : () => guard(createBook),
            icon: const Icon(Icons.add),
            label: const Text('新建词表'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Expanded(
        child: books.isEmpty
            ? const Center(child: Text('还没有词表。新建词表后即可添加或导入单词。'))
            : ListView.separated(
                itemCount: books.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  if (index == books.length) {
                    return ListTile(
                      leading: const Icon(Icons.library_books_outlined),
                      title: const Text('所有词表 · 综合'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: submitting
                          ? null
                          : () => guard(() => openBook(null)),
                    );
                  }
                  final book = books[index];
                  final name = book['name'] as String;
                  final examLabel = (book['exam'] as String).isEmpty
                      ? '自定义'
                      : book['exam'];
                  return Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('$examLabel · ${book['count']} 条'),
                      onTap: submitting
                          ? null
                          : () => guard(() => openBook(book['id'] as String)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '重命名',
                            onPressed: submitting
                                ? null
                                : () => guard(() => renameBook(book)),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: '删除词表',
                            onPressed: submitting
                                ? null
                                : () => guard(() => deleteBook(book)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Widget library() {
    final title =
        books.where((book) => book['id'] == bookId).firstOrNull?['name']
            as String? ??
        '所有词表 · 综合';
    final visibleRows = filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() => showingBook = false),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回词表目录'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 230,
              child: TextField(
                decoration: const InputDecoration(
                  labelText: '搜索单词或释义',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (s) => setState(() => search = s),
              ),
            ),
            DropdownButton<String>(
              value: sort,
              items: ['字母', '考频']
                  .map((s) => DropdownMenuItem(value: s, child: Text('按$s排序')))
                  .toList(),
              onChanged: (s) => setState(() => sort = s!),
            ),
            DropdownButton<int>(
              value: minFrequency,
              items: [0, 1, 5, 10, 20]
                  .map(
                    (n) => DropdownMenuItem(
                      value: n,
                      child: Text(n == 0 ? '全部考频' : '考频 ≥ $n'),
                    ),
                  )
                  .toList(),
              onChanged: (n) => setState(() => minFrequency = n!),
            ),
            if (bookId != null) ...[
              FilledButton.tonalIcon(
                onPressed: () => guard(importFile),
                icon: const Icon(Icons.upload_file),
                label: const Text('导入文件'),
              ),
              FilledButton.icon(
                onPressed: () => guard(addWord),
                icon: const Icon(Icons.add),
                label: const Text('添加单词'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        if (bookId == null)
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('综合视图按词义去重。', style: TextStyle(color: Colors.black54)),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: visibleRows.isEmpty
              ? Center(
                  child: Text(
                    rows.isEmpty && bookId != null
                        ? '这本词表还是空的，可以导入文件或添加单词。'
                        : '没有匹配的单词。',
                  ),
                )
              : ListView.separated(
                  itemCount: visibleRows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final r = visibleRows[index];
                    final p = progress(r);
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 9,
                        horizontal: 12,
                      ),
                      title: Text(
                        r['word'] as String,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '${meaning(r).isEmpty ? '释义待补充' : meaning(r)}\n考频：${r['frequency'] ?? '未提供'}${r['example'] == null ? '' : ' · ${r['example']}'}',
                      ),
                      isThreeLine: true,
                      trailing: Chip(
                        label: Text(
                          !p.learned
                              ? '未学习'
                              : p.mastered
                              ? '已掌握'
                              : '巩固 ${p.stage}/3',
                        ),
                      ),
                      onTap: bookId == null
                          ? null
                          : () => guard(() => editMeaning(r)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget study() {
    final list = studyCards;
    if (list.isEmpty) {
      return const Center(child: Text('还没有可背诵的词义。请先添加释义，或选择内置示例词表。'));
    }
    final i = card.clamp(0, list.length - 1);
    final r = list[i];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          children: [
            Text(
              '词义 ${i + 1} / ${list.length} · ${progress(r).mastered ? '已掌握' : '学习与巩固'}',
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: (i + 1) / list.length),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Card(
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          const SizedBox(height: 20),
                          Text(
                            r['word'] as String,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          const SizedBox(height: 22),
                          if (r['example'] != null)
                            Text(
                              r['example'] as String,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 18),
                            ),
                          const SizedBox(height: 32),
                          if (!revealed)
                            FilledButton(
                              onPressed: () => setState(() => revealed = true),
                              child: const Text('想一想，再揭晓释义'),
                            ),
                          if (revealed) ...[
                            Text(
                              meaning(r),
                              style: const TextStyle(fontSize: 27),
                            ),
                            if (r['customMeaning'] != null &&
                                r['meaning'] != r['customMeaning'])
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text('词典补充：${r['meaning']}'),
                              ),
                            const SizedBox(height: 28),
                            Wrap(
                              spacing: 12,
                              children: ['不认识', '模糊', '认识']
                                  .map(
                                    (s) => OutlinedButton(
                                      onPressed: submitting
                                          ? null
                                          : () => guard(() => rateStudy(s)),
                                      child: Text(s),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: submitting || i == 0
                      ? null
                      : () => setState(() {
                          card = i - 1;
                          revealed = false;
                        }),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('上一个'),
                ),
                const Flexible(
                  child: Text(
                    '空格揭晓 · 1 不认识 / 2 模糊 / 3 认识 · ← → 翻页',
                    textAlign: TextAlign.center,
                  ),
                ),
                TextButton.icon(
                  onPressed: submitting || i == list.length - 1
                      ? null
                      : () => setState(() {
                          card = i + 1;
                          revealed = false;
                        }),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('下一个'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  QuizCandidate candidate(Map<String, dynamic> r) => QuizCandidate(
    senseId: r['senseId'] as String,
    word: r['word'] as String,
    meaning: meaning(r),
    example: r['example'] as String?,
    learned: r['learned'] == 1,
    requiresContext: r['requiresContext'] == 1,
  );
  Future<void> startQuiz({String? scope, String? senseId}) async {
    if (submitting) return;
    final count = senseId != null ? 1 : int.tryParse(limit.text);
    if (count == null || count < 1 || count > 200) {
      message('题量请输入 1～200。');
      return;
    }
    final selectedScope =
        scope ?? (quizScope == 'reinforce' ? 'all' : quizScope);
    setState(() => submitting = true);
    try {
      final dictionary = await store.dictionary();
      if (!mounted) return;
      final pool = rows
          .where(
            (r) =>
                (senseId == null || r['senseId'] == senseId) &&
                (selectedScope == 'due'
                    ? isDue(r)
                    : selectedScope == 'reinforce'
                    ? needsConsolidation(r)
                    : true),
          )
          .toList();
      final built = QuizBuilder.build(
        pool.map(candidate).toList(),
        dictionary.map(candidate).toList(),
        limit: count,
      );
      setState(() {
        page = 2;
        quizScope = selectedScope;
        quizTitle = senseId != null
            ? '单词专项测试'
            : selectedScope == 'due'
            ? '到期复习'
            : selectedScope == 'reinforce'
            ? '巩固练习'
            : '已学综合';
        questions = built;
        questionIndex = 0;
        score = 0;
        answer = null;
        retried.clear();
        practiceIndices.clear();
      });
      if (built.length < count) {
        message('本次可出 ${built.length} 题：只考已学词义，并跳过缺少语境或可靠选项的题目。');
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Widget reviewEntry(
    String title,
    String description,
    String scope,
    IconData icon,
    int count,
  ) => SizedBox(
    width: 270,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              '$title · $count',
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: submitting || count == 0
                  ? null
                  : () => guard(() => startQuiz(scope: scope)),
              child: Text('开始$title'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget reviewWord(Map<String, dynamic> row) {
    final state = progress(row);
    final due = state.dueAt?.toLocal();
    final canTest =
        meaning(row).isNotEmpty &&
        (row['requiresContext'] != 1 ||
            (row['example'] as String? ?? '').trim().isNotEmpty);
    return Card(
      child: ListTile(
        title: Text(
          row['word'] as String,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '巩固 ${state.stage}/3 · ${isDue(row)
              ? '已到复习时间'
              : due == null
              ? '尚未安排'
              : '下次 ${due.month}/${due.day} ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}'}'
          '${canTest ? '' : ' · 请先在词表补充释义或例句'}',
        ),
        trailing: TextButton.icon(
          onPressed: submitting || !canTest
              ? null
              : () => guard(
                  () => startQuiz(
                    scope: 'all',
                    senseId: row['senseId'] as String,
                  ),
                ),
          icon: const Icon(Icons.play_arrow),
          label: const Text('测试此词'),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> get consolidationRows {
    final list = rows.where(needsConsolidation).toList();
    list.sort((a, b) {
      final aDue = progress(a).dueAt;
      final bDue = progress(b).dueAt;
      if (aDue == null) return bDue == null ? 0 : 1;
      if (bDue == null) return -1;
      return aDue.compareTo(bDue);
    });
    return list;
  }

  Widget consolidation() {
    final list = consolidationRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            ConsolidationIcon(filled: true, size: 28),
            SizedBox(width: 10),
            Text(
              '需要巩固',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('已学习但尚未通过三轮间隔考核的词义会自动进入这里，掌握后自动移出。提前测试属于练习。'),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            Chip(label: Text('待巩固 ${list.length}')),
            Chip(label: Text('其中到期 ${list.where(isDue).length}')),
            FilledButton.icon(
              onPressed: submitting || list.isEmpty
                  ? null
                  : () => guard(() => startQuiz(scope: 'reinforce')),
              icon: const Icon(Icons.play_arrow),
              label: const Text('开始巩固测试'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('当前范围没有待巩固词义。先去背诵并完成自评，单词会自动加入。'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => reviewWord(list[i]),
                ),
        ),
      ],
    );
  }

  Widget quiz() {
    if (questions.isEmpty) {
      return ListView(
        children: [
          const Text(
            '在间隔中，确认自己还记得',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            '正式检查：约 1 天 → 再隔 3 天 → 再隔 7 天。通过三次后掌握。\n提前练习会保存答题记录，但不晋级；漏学不清零。',
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              reviewEntry(
                '到期复习',
                '按计划检查记忆，答对后推进巩固阶段。',
                'due',
                Icons.schedule,
                rows.where(isDue).length,
              ),
              reviewEntry(
                '已学综合',
                '从当前范围内所有已学词义抽题。',
                'all',
                Icons.fact_check_outlined,
                rows.where((r) => progress(r).learned).length,
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 200,
            child: TextField(
              controller: limit,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '题量（建议 ${rows.where(isDue).length.clamp(5, 20)}）',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Wrap(
              spacing: 8,
              children: [
                for (final scope in ['all', 'due'])
                  ChoiceChip(
                    label: Text(
                      {
                        'all': '已学综合',
                        'due': '到期复习',
                        'reinforce': '巩固练习',
                      }[scope]!,
                    ),
                    selected:
                        (quizScope == 'reinforce' ? 'all' : quizScope) == scope,
                    onSelected: submitting
                        ? null
                        : (_) => setState(() => quizScope = scope),
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: submitting ? null : () => guard(() => startQuiz()),
              icon: const Icon(Icons.play_arrow),
              label: const Text('开始考核'),
            ),
          ),
        ],
      );
    }
    if (questionIndex >= questions.length) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.task_alt, size: 64, color: Color(0xff3d4a5c)),
            const SizedBox(height: 24),
            Text(
              '本轮答对 $score / ${questions.length}',
              style: const TextStyle(fontSize: 28),
            ),
            const SizedBox(height: 12),
            const Text('错题已在本轮后面追加一次练习；练习不计入正式晋级。'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => setState(() => questions = []),
              child: const Text('返回考核设置'),
            ),
          ],
        ),
      );
    }
    final q = questions[questionIndex];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$quizTitle · 第 ${questionIndex + 1} / ${questions.length} 题',
                  ),
                ),
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => setState(() => questions = []),
                  child: const Text('返回复习首页'),
                ),
              ],
            ),
            const Text('1–4 / A–D 选择并提交 · Enter / 空格继续'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: questionIndex / questions.length),
            const SizedBox(height: 28),
            Text(
              q.target.word,
              style: const TextStyle(fontSize: 42, fontWeight: FontWeight.bold),
            ),
            if (q.target.example != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  q.target.example!,
                  style: const TextStyle(fontSize: 19),
                ),
              ),
            const Text('请选择这里的中文意思'),
            const SizedBox(height: 20),
            ...List.generate(
              q.options.length,
              (i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(20),
                    disabledBackgroundColor: answer == null
                        ? null
                        : i == q.correctIndex
                        ? const Color(0xffdce9e3)
                        : answer == i
                        ? const Color(0xfff3e2e2)
                        : null,
                    disabledForegroundColor: answer == null
                        ? null
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                  onPressed: answer != null || submitting
                      ? null
                      : () => guard(() => submit(q, i)),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${i + 1} / ${String.fromCharCode(65 + i)}. ${q.options[i]}',
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
              ),
            ),
            if (answer != null) ...[
              Text(
                answer == q.correctIndex
                    ? '回答正确，已记录。'
                    : '正确答案：${q.options[q.correctIndex]}',
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: continueQuiz, child: const Text('继续')),
            ],
          ],
        ),
      ),
    );
  }

  final Set<String> retried = {};
  Future<void> submit(QuizQuestion q, int index) async {
    if (submitting || answer != null) return;
    setState(() => submitting = true);
    try {
      final correct = index == q.correctIndex;
      final current = rows.firstWhere((r) => r['senseId'] == q.target.senseId);
      final now = DateTime.now();
      final isPractice = practiceIndices.contains(questionIndex);
      final next = isPractice
          ? ReviewScheduler.practice(progress(current), correct, now)
          : ReviewScheduler.recordCheck(progress(current), correct, now);
      await store.saveReview(
        q.target.senseId,
        next,
        kind: isPractice ? 'retry' : 'quiz',
        correct: correct,
      );
      if (!correct && retried.add(q.target.senseId)) {
        practiceIndices.add(questions.length);
        questions = [...questions, q];
      }
      await reload();
      if (mounted) {
        setState(() {
          answer = index;
          if (correct) score++;
        });
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Widget settings() => ListView(
    children: [
      const Text(
        '把进步，妥善保存',
        style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      const Text('完整备份包含全部词表、自定义释义、学习记录及复习时间。恢复将替换当前内容，恢复前自动生成安全备份。'),
      const SizedBox(height: 24),
      Wrap(
        spacing: 16,
        children: [
          FilledButton.icon(
            onPressed: () => guard(exportBackup),
            icon: const Icon(Icons.download),
            label: const Text('导出完整备份'),
          ),
          OutlinedButton.icon(
            onPressed: () => guard(restore),
            icon: const Icon(Icons.restore),
            label: const Text('导入恢复'),
          ),
        ],
      ),
      const Divider(height: 48),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('系统复习通知'),
        subtitle: const Text('关闭窗口后在托盘运行；彻底退出后停止提醒。到期提醒最多每天一次。'),
        value: widget.desktop?.notifications ?? false,
        onChanged: widget.desktop?.ready == true
            ? (v) {
                setState(() => widget.desktop!.notifications = v);
                unawaited(persistSession());
              }
            : null,
      ),
      if (widget.desktop?.warning != null) Text(widget.desktop!.warning!),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: widget.desktop?.ready == true
              ? () => guard(() => widget.desktop!.checkDue(test: true))
              : null,
          child: const Text('测试系统通知'),
        ),
      ),
      const Divider(height: 48),
      const Text(
        '内置词表为原创示例，用于体验完整学习流程，不代表正式考试词表或官方考频。\n多义词通过语境区分；导入新词义不会继承其他词义的进度。\n应用数据保存在当前用户的应用支持目录中。',
      ),
    ],
  );

  Future<List<String>?> fields(
    String title,
    List<String> labels, {
    List<String>? values,
  }) async {
    final controllers = List.generate(
      labels.length,
      (i) => TextEditingController(text: values?[i] ?? ''),
    );
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                labels.length,
                (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextField(
                    controller: controllers[i],
                    autofocus: i == 0,
                    decoration: InputDecoration(labelText: labels[i]),
                  ),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              controllers.map((c) => c.text.trim()).toList(),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Controllers are owned by the dialog route until its exit animation ends.
    Future<void>.delayed(const Duration(seconds: 1), () {
      for (final c in controllers) {
        c.dispose();
      }
    });
    return result;
  }

  Future<void> createBook() async {
    final v = await fields('新建词表', ['词表名称', '考试类别（可不填）']);
    if (v == null) return;
    if (v[0].isEmpty) {
      message('请填写词表名称。');
      return;
    }
    await updateLibrary(() async {
      final id = await store.createBook(v[0], v[1].isEmpty ? '自定义' : v[1]);
      if (mounted) selectLibraryBook(id);
    });
  }

  void selectLibraryBook(String? id) {
    setState(() {
      if (bookId != id || exam != '全部考试') {
        card = 0;
        questions = [];
      }
      bookId = id;
      exam = '全部考试';
      revealed = false;
      search = '';
      minFrequency = 0;
      showingBook = true;
    });
  }

  Future<void> openBook(String? id) =>
      updateLibrary(() async => selectLibraryBook(id));

  Future<void> updateLibrary(Future<void> Function() change) async {
    if (!mounted || submitting) return;
    setState(() => submitting = true);
    try {
      await change();
      if (mounted) await reload();
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Future<void> renameBook(Map<String, dynamic> book) async {
    final values = await fields(
      '重命名词表',
      ['词表名称'],
      values: [book['name'] as String],
    );
    if (values == null) return;
    await updateLibrary(
      () => store.renameBook(book['id'] as String, values.single),
    );
  }

  Future<void> deleteBook(Map<String, dynamic> book) async {
    final name = book['name'] as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除词表？'),
        content: Text('将删除「$name」及其中的 ${book['count']} 条词条。其他词表和学习记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = book['id'] as String;
    await updateLibrary(() async {
      await store.deleteBook(id);
      if (!mounted) return;
      if (bookId == id ||
          (exam != '全部考试' &&
              !books.any(
                (other) => other['id'] != id && other['exam'] == exam,
              ))) {
        setState(() {
          exam = '全部考试';
          bookId = null;
          card = 0;
          revealed = false;
          questions = [];
        });
      }
    });
  }

  Future<void> addWord() async {
    final v = await fields('添加单词', ['英文单词', '自定义释义', '考频（可不填）']);
    if (v == null) return;
    if (v[0].isEmpty) {
      message('英文单词不能为空。');
      return;
    }
    final frequency = int.tryParse(v[2]);
    if (v[2].isNotEmpty && (frequency == null || frequency < 0)) {
      message('考频应为非负整数。');
      return;
    }
    await store.importRows(bookId!, [
      ImportRow(
        word: v[0],
        meaning: v[1].isEmpty ? null : v[1],
        frequency: frequency,
      ),
    ]);
    await reload();
  }

  Future<void> editMeaning(Map<String, dynamic> row) async {
    final v = await fields(
      '修改本词表的释义',
      ['自定义释义（留空使用词典）', '该词义的英文例句（跨词表共用）'],
      values: [
        row['customMeaning'] as String? ?? '',
        row['example'] as String? ?? '',
      ],
    );
    if (v == null) return;
    await store.setCustomMeaning(bookId!, row['senseId'] as String, v[0]);
    await store.setExample(row['senseId'] as String, v[1]);
    await reload();
  }

  Future<void> importFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'csv', 'docx'],
      withData: true,
    );
    if (picked == null) return;
    final file = picked.files.single;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    final preview = ImportService().parse(file.name, bytes);
    final existing = rows
        .map((r) => (r['word'] as String).toLowerCase())
        .toSet();
    final repeats = preview.rows
        .where((r) => existing.contains(r.word.toLowerCase()))
        .length;
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入预览'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '有效 ${preview.rows.length} 条 · 同名单词 $repeats 条（按词义更新或新增）\n学习进度保留，空字段不覆盖。',
                ),
                const SizedBox(height: 12),
                ...preview.rows
                    .take(20)
                    .map(
                      (r) => Text(
                        '${r.word} · ${r.meaning ?? '待补充'} · ${r.frequency ?? '无考频'}',
                      ),
                    ),
                if (preview.rows.length > 20) const Text('……仅预览前 20 条'),
                ...preview.warnings.map(
                  (w) =>
                      Text(w, style: const TextStyle(color: Colors.deepOrange)),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: preview.rows.isEmpty
                ? null
                : () => Navigator.pop(ctx, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await store.importRows(bookId!, preview.rows);
    await reload();
    message('已导入 ${preview.rows.length} 条。');
  }

  Future<void> exportBackup() async {
    final data = await store.exportBackup();
    final saved = await FilePicker.platform.saveFile(
      dialogTitle: '导出完整备份',
      fileName:
          'words-${DateTime.now().millisecondsSinceEpoch}.wordsmemory.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: Uint8List.fromList(utf8.encode(data)),
    );
    if (saved != null) message('备份已导出：$saved');
  }

  Future<void> restore() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null) return;
    final file = picked.files.single;
    final data = utf8.decode(
      file.bytes ?? await File(file.path!).readAsBytes(),
    );
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复完整备份？'),
        content: const Text('这会替换当前全部词表和学习记录。恢复前自动保存当前数据的安全备份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final dir = await getApplicationSupportDirectory();
    final safety = File(
      '${dir.path}/before-restore-${DateTime.now().millisecondsSinceEpoch}.wordsmemory.json',
    );
    await safety.writeAsString(await store.exportBackup(), flush: true);
    await store.restoreBackup(data);
    setState(() {
      bookId = null;
      showingBook = false;
      exam = '全部考试';
      questions = [];
      card = 0;
    });
    await reload();
    message('恢复完成。恢复前备份：${safety.path}');
  }
}
