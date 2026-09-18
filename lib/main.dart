import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/lk_client.dart';
import 'api/store.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'services/anonymous_telemetry.dart';
import 'services/app_motion.dart';
import 'services/reader_volume_keys.dart';

final _rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void _showSessionExpiredNotice() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final messenger = _rootScaffoldMessengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        snackBarAnimationStyle: AppMotion.style(messenger.context),
        SnackBar(
          content: const Text('登录状态已失效，已自动退出，请重新登录'),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LKStore.load();
  LKClient.sessionExpiredHandler = LKStore.clear;
  LKClient.sessionExpiredRev.addListener(_showSessionExpiredNotice);
  PaintingBinding.instance.imageCache.maximumSizeBytes = 128 * 1024 * 1024;
  runApp(const LKApp());
  unawaited(LKClient.shared.warmErrorCodeHints());
  // 统计请求独立于界面初始化：网络异常不会影响应用正常打开。
  unawaited(AnonymousTelemetry.reportFirstActivation());
}

class LKApp extends StatelessWidget {
  const LKApp({super.key});

  ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF5C6BC0), brightness: brightness);
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      pageTransitionsTheme: AppMotion.disabled
          ? AppMotion.noPageTransitions
          : const PageTransitionsTheme(),
      splashFactory: AppMotion.disabled ? NoSplash.splashFactory : null,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF121316) : const Color(0xFFF6F7FB),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xFF1B1C21) : Colors.white,
        foregroundColor: isDark ? Colors.white : const Color(0xFF263238),
        systemOverlayStyle: isDark
            ? const SystemUiOverlayStyle(
                statusBarColor: Color(0xFF1B1C21),
                statusBarIconBrightness: Brightness.light,
                statusBarBrightness: Brightness.dark,
              )
            : const SystemUiOverlayStyle(
                statusBarColor: Colors.white,
                statusBarIconBrightness: Brightness.dark,
                statusBarBrightness: Brightness.light,
              ),
        titleTextStyle: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : const Color(0xFF263238)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        color: isDark ? const Color(0xFF1E2025) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF2A2C33) : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF1B1C21) : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        labelTextStyle: WidgetStatePropertyAll(TextStyle(
            fontSize: 12,
            color: isDark ? Colors.grey.shade400 : Colors.grey.shade700)),
        height: 64,
      ),
      dividerTheme: DividerThemeData(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
      listTileTheme: ListTileThemeData(
        tileColor: isDark ? const Color(0xFF1E2025) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 注意:Size.fromHeight 会构造无限宽度,导致 Row 内布局崩溃
          minimumSize: const Size(64, 44),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 44),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        LKStore.themeMode,
        LKStore.dataSaverMode,
        LKStore.animationsEnabled
      ]),
      builder: (context, _) => MaterialApp(
        scaffoldMessengerKey: _rootScaffoldMessengerKey,
        title: 'Yomiru',
        debugShowCheckedModeBanner: false,
        navigatorObservers: [readerRouteObserver],
        themeAnimationDuration:
            AppMotion.disabled ? Duration.zero : kThemeAnimationDuration,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: LKStore.themeMode.value,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              disableAnimations: AppMotion.disabled ||
                  MediaQuery.disableAnimationsOf(context)),
          child: _SystemUIBridge(child: child),
        ),
        home: const HomePage(),
        routes: {
          '/login': (_) => const LoginPage(),
        },
      ),
    );
  }
}

/// 直接通过 SystemChrome 设置系统状态栏(Android 16 上 AnnotatedRegion 不可靠)
class _SystemUIBridge extends StatefulWidget {
  final Widget? child;
  const _SystemUIBridge({this.child});

  @override
  State<_SystemUIBridge> createState() => _SystemUIBridgeState();
}

class _SystemUIBridgeState extends State<_SystemUIBridge>
    with WidgetsBindingObserver {
  static const _phoneOrientations = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ];
  static const _largeScreenOrientations = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];
  List<DeviceOrientation>? _appliedOrientations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LKStore.landscapeEnabled.addListener(_updateOrientations);
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateOrientations();
    });
  }

  void _updateOrientations() {
    final orientations = (LKStore.landscapeEnabled.value ||
            MediaQuery.sizeOf(context).shortestSide >= 600)
        ? _largeScreenOrientations
        : _phoneOrientations;
    if (identical(_appliedOrientations, orientations)) return;
    _appliedOrientations = orientations;
    SystemChrome.setPreferredOrientations(orientations);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LKStore.landscapeEnabled.removeListener(_updateOrientations);
    SystemChrome.setPreferredOrientations(_phoneOrientations);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateOrientations();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(isDark
        ? SystemUiOverlayStyle(
            statusBarColor: Theme.of(context).scaffoldBackgroundColor,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarColor: const Color(0xFF1B1C21),
            systemNavigationBarIconBrightness: Brightness.light,
          )
        : SystemUiOverlayStyle(
            statusBarColor: Theme.of(context).scaffoldBackgroundColor,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
          ));
  }

  @override
  Widget build(BuildContext context) => widget.child ?? const SizedBox.shrink();
}
