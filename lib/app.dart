import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/services/settings_service.dart';
import 'features/browser/browser_screen.dart';

/// 全局深色模式状态（设置页修改后通知 App 重建）。
final ValueNotifier<bool> darkModeNotifier = ValueNotifier<bool>(false);

/// 未来浏览器 — 应用根组件（全中文界面，支持深色模式）。
class NewWebApp extends StatefulWidget {
  const NewWebApp({super.key});

  @override
  State<NewWebApp> createState() => _NewWebAppState();
}

class _NewWebAppState extends State<NewWebApp> {
  @override
  void initState() {
    super.initState();
    darkModeNotifier.addListener(_onThemeChanged);
    // 启动时读取深色模式设置
    SettingsService.instance.isDarkModeEnabled().then((value) {
      darkModeNotifier.value = value;
    });
  }

  @override
  void dispose() {
    darkModeNotifier.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3B82F6),
        brightness: brightness,
      ),
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF5F6F8),
      appBarTheme: AppBarTheme(
        backgroundColor:
            isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF5F6F8),
        foregroundColor: isDark ? Colors.white : const Color(0xFF1F2937),
        elevation: 0,
      ),
      cardColor: isDark ? const Color(0xFF2C2C2E) : Colors.white,
      dividerColor: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E7EB),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '未来浏览器',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: darkModeNotifier.value ? ThemeMode.dark : ThemeMode.light,
      // 100% 汉化
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
      locale: const Locale('zh'),
      home: const BrowserScreen(),
    );
  }
}
