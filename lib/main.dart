import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'core/cache/image_cache_store.dart';
import 'core/net/dio_provider.dart';
import 'core/storage/prefs.dart';
import 'core/theme/app_colors.dart';
import 'providers.dart';
import 'widgets/cached_image.dart';
import 'widgets/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // DASH 通道（media_kit / libmpv）要求在使用前完成原生初始化。
  // 它只注册插件与库路径，开销很小，不拖慢冷启动。
  MediaKit.ensureInitialized();

  // 冷启动路径上只 await 这两件事：SharedPreferences 读取很快，
  // 图片缓存的索引也只是一个 JSON（几十 KB 量级）。
  //
  // 图片索引**必须**在首帧前读进内存：`CachedImage` 靠同步的
  // `lookup(url)` 才能在 build 里直接拿到磁盘文件 —— 这是「滚回不闪灰」的前提。
  // 缓存目录本身仍是惰性的，不受影响。
  final prefs = await Prefs.create();

  // ⚠️ 这里**必须**注入一个 Dio。
  // `ImageCacheStore` 只有在拿到 Dio 时才会真的去下载图片；
  // 忘了注入的话缓存目录会被建出来、索引也写了，但里面永远是空的 ——
  // 现象是「图片每次都联网、磁盘命中率恒为 0」，极难从界面反推
  // （真机上就是这样撞见的：`image_cache/` 建好了，`index.json` 只有 26 字节）。
  final imageCache = ImageCacheStore(dio: DioFactory.createBiliDio());
  await imageCache.ensureReady();

  runApp(
    ProviderScope(
      overrides: <Override>[
        prefsProvider.overrideWithValue(prefs),
        imageCacheStoreProvider.overrideWithValue(imageCache),
      ],
      child: ImageCacheScope(
        cache: imageCache,
        child: const _LoginBootstrap(child: RrhaApp()),
      ),
    ),
  );
}

/// 首帧之后触发的「非关键初始化」。
///
/// 登录态要从系统钥匙串读（异步，可能几十毫秒），放进冷启动路径会拖慢首帧，
/// 所以放在首帧之后异步恢复；恢复完成后 `biliClientProvider` 会自动带上 Cookie。
/// 这也是 HOT 路径上唯一被推迟的事情。
class _LoginBootstrap extends ConsumerStatefulWidget {
  const _LoginBootstrap({required this.child});

  final Widget child;

  @override
  ConsumerState<_LoginBootstrap> createState() => _LoginBootstrapState();
}

class _LoginBootstrapState extends ConsumerState<_LoginBootstrap> {
  @override
  void initState() {
    super.initState();
    // 故意不 await：让钥匙串读取自己在后台完成，不阻塞首帧。
    //
    // 但**恢复完成后必须补刷一次时间线**：首帧那一刻登录态还没读出来，
    // 首轮刷新会跑在「看起来还没登录」的时机，B 站订阅会被判成
    // 「需要先登录」并一直挂在那儿 —— 这正是真机上出现过的现象。
    ref.read(biliLoginProvider.notifier).restore().then((_) {
      if (!mounted) return;
      ref.read(timelineProvider.notifier).refresh(silent: true);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class RrhaApp extends StatelessWidget {
  const RrhaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rrha',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      // 刻意**不提供** darkTheme：本项目只做亮色（对标 B 站动态页）。
      // 留一个几乎一样的 darkTheme 只会让人误以为支持夜间模式。
      themeMode: ThemeMode.light,
      home: const HomeShell(),
    );
  }

  /// 亮色主题。
  ///
  /// 底色与文字色统一取自 [AppColors]：深色主题时代这里写死了 `0xFF121212` /
  /// `0xFF1A1A1A`，切亮色时散落的硬编码就变成「白底白字」。
  ThemeData _buildTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.biliBlue,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.page,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.page,
        foregroundColor: AppColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        labelTextStyle: const WidgetStatePropertyAll<TextStyle?>(
          TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
      // 刻意不设置 cardTheme：`CardTheme` / `CardThemeData` 在不同 Flutter
      // 版本间类型不兼容，卡片样式交由组件内部自绘，避免版本地狱。
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}
