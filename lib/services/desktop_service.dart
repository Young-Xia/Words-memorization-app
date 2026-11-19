import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../data/store.dart';

class DesktopService with TrayListener, WindowListener {
  final AppStore store;
  Timer? _timer;
  DateTime? _lastNotice;
  File? _noticeFile;
  bool _checking = false;
  bool notifications = true;
  bool ready = false;
  String? warning;
  VoidCallback? onOpenReview;
  DesktopService(this.store);

  Future<void> init() async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(900, 650));
    await windowManager.setTitle('词间 · WordsMemory');
    try {
      final directory = await getApplicationSupportDirectory();
      _noticeFile = File('${directory.path}/last-notice.txt');
      if (await _noticeFile!.exists()) {
        _lastNotice = DateTime.tryParse(await _noticeFile!.readAsString());
      }
      await localNotifier.setup(
        appName: 'WordsMemory',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('词间 · 在托盘继续提醒复习');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '打开词间'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '彻底退出'),
          ],
        ),
      );
      trayManager.addListener(this);
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
      ready = true;
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => checkDue());
    } catch (error) {
      warning = '系统提醒或托盘初始化失败，仍可在软件内查看待复习任务。$error';
    }
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> openReview() async {
    onOpenReview?.call();
    await show();
  }

  Future<void> checkDue({bool test = false}) async {
    if (!ready || !notifications || _checking) return;
    _checking = true;
    try {
      await _showDueNotice(test: test);
    } catch (error) {
      warning = '暂时无法发送复习通知：$error';
    } finally {
      _checking = false;
    }
  }

  Future<void> _showDueNotice({required bool test}) async {
    final now = DateTime.now();
    if (!test &&
        _lastNotice != null &&
        now.difference(_lastNotice!).inHours < 24) {
      return;
    }
    final entries = await store.entries();
    final count = entries
        .where(
          (r) =>
              r['learned'] == 1 &&
              r['dueAt'] != null &&
              !DateTime.parse(r['dueAt'] as String).isAfter(now),
        )
        .length;
    if (count == 0 && !test) return;
    final notice = LocalNotification(
      title: '词间 · 复习提醒',
      body: test ? '系统通知已连接。点击此通知进入考核与复习。' : '有 $count 个词义等待复习。点击此通知进入考核与复习。',
    );
    notice.onClick = openReview;
    await notice.show();
    if (!test) {
      _lastNotice = now;
      await _noticeFile?.writeAsString(now.toIso8601String(), flush: true);
    }
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') show();
    if (menuItem.key == 'exit') quit();
  }

  Future<void> quit() async {
    ready = false;
    _timer?.cancel();
    await trayManager.destroy();
    await store.close();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}
