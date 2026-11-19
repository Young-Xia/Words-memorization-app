import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/store.dart';
import 'services/desktop_service.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final store = AppStore.open(File('${dir.path}/wordsmemory.db'));
    await store.init();
    final desktop = DesktopService(store);
    await desktop.init();
    runApp(WordsApp(store: store, desktop: desktop));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SelectableText('启动失败，请检查数据目录或开发环境。\n$error')),
        ),
      ),
    );
  }
}

class WordsApp extends StatelessWidget {
  final AppStore store;
  final DesktopService? desktop;
  const WordsApp({super.key, required this.store, this.desktop});

  @override
  Widget build(BuildContext context) {
    const slate = Color(0xff3d4a5c);
    const paper = Color(0xfffaf9f7);
    const sage = Color(0xffdce9e3);
    const border = BorderSide(color: Color(0xffdedfdf));
    final scheme = ColorScheme.fromSeed(seedColor: slate).copyWith(
      primary: slate,
      onPrimary: paper,
      secondaryContainer: sage,
      onSecondaryContainer: slate,
      surface: paper,
      onSurface: slate,
      onSurfaceVariant: const Color(0xff606b79),
      outline: const Color(0xff818a95),
      outlineVariant: border.color,
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: border,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '词间 · WordsMemory',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: paper,
        fontFamily: 'Microsoft YaHei',
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xfff0ede8),
          indicatorColor: sage,
          selectedIconTheme: IconThemeData(color: slate),
          selectedLabelTextStyle: TextStyle(
            color: slate,
            fontFamily: 'Microsoft YaHei',
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xfffffefd),
          elevation: 1,
          shadowColor: const Color(0x183d4a5c),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: border,
          ),
        ),
        chipTheme: const ChipThemeData(
          backgroundColor: sage,
          side: BorderSide.none,
          shape: StadiumBorder(),
          labelStyle: TextStyle(color: slate, fontFamily: 'Microsoft YaHei'),
          iconTheme: IconThemeData(color: slate),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xfffffefd),
          border: inputBorder,
          enabledBorder: inputBorder,
          focusedBorder: inputBorder.copyWith(
            borderSide: const BorderSide(color: slate),
          ),
        ),
      ),
      home: HomePage(store: store, desktop: desktop),
    );
  }
}
