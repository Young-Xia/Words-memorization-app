import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wordsmemory/data/store.dart';
import 'package:wordsmemory/main.dart';
import 'package:wordsmemory/domain/review.dart';
import 'package:wordsmemory/services/desktop_service.dart';

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _Desktop extends DesktopService {
  _Desktop(super.store);

  int showCount = 0;

  @override
  Future<void> show() async => showCount++;
}

void main() {
  testWidgets('clicking the system review notification opens the review page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wordsmemory-notification-'),
    ))!;
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final store = AppStore.memory();
    await tester.runAsync(store.init);
    final desktop = _Desktop(store);
    const channel = MethodChannel('local_notifier');
    final messenger = tester.binding.defaultBinaryMessenger;
    String? notificationId;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setup') return true;
      if (call.method == 'notify') {
        notificationId = call.arguments['identifier'] as String;
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      PathProviderPlatform.instance = original;
      await tester.runAsync(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
    });

    await tester.pumpWidget(WordsApp(store: store, desktop: desktop));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的词表'), findsOneWidget);

    await localNotifier.setup(appName: 'WordsMemory');
    desktop.ready = true;
    await tester.runAsync(() => desktop.checkDue(test: true));
    expect(notificationId, isNotNull);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onLocalNotificationClick', {
          'notificationId': notificationId,
        }),
      ),
      null,
    );
    await tester.pumpAndSettle();

    expect(desktop.showCount, 1);
    expect(find.text('到期复习'), findsOneWidget);
    expect(find.text('我的词表'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('book directory opens, renames, and confirms deletion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wordsmemory-library-'),
    ))!;
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final store = AppStore.memory();
    await tester.runAsync(store.init);
    addTearDown(() async {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      PathProviderPlatform.instance = original;
      await tester.runAsync(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
    });

    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(WordsApp(store: store));
    await settle();
    final name = find.text('日常基础 · 示例词表');
    final tile = find.ancestor(of: name, matching: find.byType(ListTile));
    expect(find.text('我的词表'), findsOneWidget);
    expect(find.text('搜索单词或释义'), findsNothing);
    await tester.tap(name);
    await settle();
    expect(find.text('搜索单词或释义'), findsOneWidget);
    expect(find.text('apple'), findsOneWidget);
    await tester.tap(find.text('返回词表目录'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: tile, matching: find.byTooltip('重命名')),
    );
    await tester.pumpAndSettle();
    expect(find.text('重命名词表'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '我的日常词表');
    await tester.tap(find.text('保存'));
    await settle();
    final renamed = find.text('我的日常词表');
    expect(name, findsNothing);
    expect(renamed, findsOneWidget);

    final delete = find.descendant(
      of: find.ancestor(of: renamed, matching: find.byType(ListTile)),
      matching: find.byTooltip('删除词表'),
    );
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('删除词表？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(renamed, findsOneWidget);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await settle();
    expect(renamed, findsNothing);
    expect(find.text('学习与工作 · 示例词表'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.style_outlined));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('study reveal and rating unlock learned-only quiz', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wordsmemory-ui-'),
    ))!;
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final store = AppStore.memory();
    await tester.runAsync(store.init);
    addTearDown(() async {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      PathProviderPlatform.instance = original;
      await tester.runAsync(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
    });
    const preview = bool.fromEnvironment('PREVIEW');
    final boundaryKey = GlobalKey();
    if (preview) {
      await tester.runAsync(() async {
        final loader = FontLoader('Microsoft YaHei');
        loader.addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
        await loader.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          File(
            '.tools/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
        await icons.load();
      });
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: WordsApp(store: store),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(find.text('词间'), findsOneWidget);
    Future<void> capture(String path) async {
      if (!preview) return;
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('docs/ui-preview.png');
    await tester.tap(find.text('开始背诵'));
    await tester.pumpAndSettle();
    // A rating before reveal must do nothing. Holding space must not rate a word.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, '认识'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad2);
    // Rapid input while the database is saving must not submit another rating.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final learnedRows = (await tester.runAsync(store.entries))!;
    expect(learnedRows.where((e) => e['learned'] == 1).length, 1);
    final backup = (await tester.runAsync(store.exportBackup))!;
    expect('self:模糊'.allMatches(backup).length, 1);
    expect(backup.contains('self:认识'), isFalse);
    for (
      var attempt = 0;
      attempt < 40 &&
          tester
                  .widget<NavigationRail>(find.byType(NavigationRail))
                  .onDestinationSelected ==
              null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(
      tester
          .widget<NavigationRail>(find.byType(NavigationRail))
          .onDestinationSelected,
      isNotNull,
    );
    await tester.tap(find.text('考核与复习'));
    await tester.pumpAndSettle();
    expect(find.text('开始巩固练习'), findsNothing);
    expect(find.text('待巩固单词 · 快速测试'), findsNothing);
    expect(find.text('查看全部'), findsNothing);
    await capture('docs/review-preview.png');
    // Numeric shortcuts must leave the quiz length text field editable.
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '1');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(find.text('请选择这里的中文意思'), findsNothing);
    await tester.enterText(find.byType(TextField), '10');
    await tester.tap(find.byKey(const ValueKey('consolidation-nav-icon')));
    await tester.pumpAndSettle();
    expect(find.text('待巩固 1'), findsOneWidget);
    await capture('docs/consolidation-preview.png');
    final learnedWord =
        learnedRows.firstWhere((e) => e['learned'] == 1)['word'] as String;
    expect(find.text(learnedWord), findsOneWidget);
    await tester.tap(find.text('测试此词'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('请选择这里的中文意思'), findsOneWidget);
    expect(find.text(learnedWord), findsOneWidget);
    expect(find.textContaining('单词专项测试'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad1);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('继续'), findsOneWidget);
    final afterAnswer = (await tester.runAsync(store.exportBackup))!;
    // A number shortcut after submission must not record another answer.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    final afterExtraKey = (await tester.runAsync(store.exportBackup))!;
    expect(
      jsonDecode(afterExtraKey)['events'],
      jsonDecode(afterAnswer)['events'],
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'consolidation excludes mastered and due quiz excludes future words',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('wordsmemory-scope-'),
      ))!;
      final original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      final store = AppStore.memory();
      await tester.runAsync(() async {
        await store.init();
        final rows = await store.entries();
        for (final word in ['apple', 'water', 'friend']) {
          final row = rows.firstWhere((r) => r['word'] == word);
          await store.saveReview(
            row['senseId'] as String,
            ReviewState(
              learned: true,
              stage: word == 'water' ? 3 : 0,
              dueAt: DateTime.now().add(
                Duration(days: word == 'apple' ? -1 : 5),
              ),
            ),
            kind: 'self:认识',
            correct: null,
          );
        }
      });
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        PathProviderPlatform.instance = original;
        await tester.runAsync(() async {
          await store.close();
          await directory.delete(recursive: true);
        });
      });
      await tester.pumpWidget(WordsApp(store: store));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('consolidation-nav-icon')));
      await tester.pumpAndSettle();
      expect(find.text('待巩固 2'), findsOneWidget);
      expect(find.text('其中到期 1'), findsOneWidget);
      expect(find.text('water'), findsNothing);
      expect(find.text('apple'), findsOneWidget);
      expect(find.text('friend'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fact_check_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始到期复习'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('apple'), findsOneWidget);
      expect(find.text('到期复习 · 第 1 / 1 题'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('继续'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('继续'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
