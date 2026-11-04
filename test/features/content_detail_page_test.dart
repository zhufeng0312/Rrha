import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/video_ref.dart';
import 'package:rrha/features/comments/comment_section.dart';
import 'package:rrha/features/player/inline_video_player.dart';
import 'package:rrha/features/player/player_adapter.dart';
import 'package:rrha/features/timeline/content_detail_page.dart';

/// 微博视频详情页：**视频页内自动播 + 评论在同一页**。
///
/// 用户原话：「我需要点击视频的时候进的是视频详情页，能看到评论的那种。」
/// 这一组测试钉住三件事：
/// 1. 微博视频进详情页后，视频区是**真的播放器**（不是静态封面）；
/// 2. 无直链时不渲染播放器（走封面兜底），且**不会**再压一层详情页；
/// 3. 评论组件确实在页面上（微博评论走 hotflow，`oid = mid`）。
///
/// ⚠️ 单测里**绝不能**让 libmpv 起真播放器（测试环境没有 native 库）。
/// 所以 `InlineVideoPlayer` 留了 `playerFactory` 注入点，这里统一注入假实现。
class _FakePlayer implements RrhaPlayer {
  bool _playing = false;
  bool disposed = false;

  /// 记录调用，供交互测试断言（双击暂停、长按 2x、拖动 seek）。
  final List<String> calls = <String>[];
  final List<double> speeds = <double>[];
  final List<Duration> seeks = <Duration>[];

  /// **必须是广播 + 状态变化时主动推送**。
  ///
  /// 早先这里用 `Stream<bool>.value(_playing)`，它只在订阅那一刻发一次，
  /// 之后 `play()` 不会再推 → 界面永远停在「未播放」，控制栏一直显示 ▶。
  /// 真实播放器会推状态，假实现必须同构，否则测出来的行为跟真机不一样。
  final StreamController<bool> _playingCtl =
      StreamController<bool>.broadcast();

  void _emit() {
    if (!_playingCtl.isClosed) _playingCtl.add(_playing);
  }

  @override
  Widget buildView(BuildContext context) => const SizedBox.expand();

  @override
  Stream<Duration> get positionStream => Stream<Duration>.empty();

  @override
  Stream<bool> get playingStream => _playingCtl.stream;

  @override
  Stream<Duration> get durationStream => Stream<Duration>.empty();

  @override
  Stream<void> get completedStream => const Stream<void>.empty();

  @override
  Stream<String> get errorStream => const Stream<String>.empty();

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => const Duration(seconds: 26);

  @override
  bool get isPlaying => _playing;

  @override
  double get aspectRatio => 16 / 9;

  @override
  double get speed => 1.0;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> play() async {
    _playing = true;
    calls.add('play');
    _emit();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    calls.add('pause');
    _emit();
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    calls.add('seek');
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {
    speeds.add(speed);
    calls.add('setSpeed');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _playingCtl.close();
  }
}

ContentItem _weiboVideo({String? directVideoUrl}) => ContentItem(
      id: 'w1',
      platform: Platform.weibo,
      kind: ContentKind.video,
      sourceId: 'weibo:1',
      authorName: '作者',
      title: '标题',
      summary: '正文',
      images: const <String>[],
      link: 'https://m.weibo.cn/status/5259410951377781',
      videoRef: VideoRef(
        directVideoUrl: directVideoUrl,
        coverUrl: 'https://wx4.sinaimg.cn/orj480/x.jpg',
        sourceUrl: 'https://m.weibo.cn/status/5259410951377781',
        duration: const Duration(seconds: 26),
        isVertical: true,
      ),
      publishedAt: DateTime.now().toUtc(),
      fetchedAt: DateTime.now().toUtc(),
    );

void main() {
  Future<void> pumpDetail(WidgetTester tester, ContentItem item) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ContentDetailPage(item: item),
        ),
      ),
    );
    // 不 pumpAndSettle：详情页里的评论组件会发起网络请求（离线必然失败），
    // settle 会一直等。只要首帧结构就够断言。
    await tester.pump();
  }

  /// 滚到详情页底部。
  ///
  /// 为什么必须滚：详情页是 `ListView`，评论区在正文/视频下面，
  /// **首帧根本不会构建**（懒加载）。不滚就断言 `CommentSection` 存在，
  /// 会得到「Found 0 widgets」——那是测试的错，不是产品的错。
  Future<void> scrollToComments(WidgetTester tester) async {
    await tester.dragUntilVisible(
      find.byType(CommentSection),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pump();
  }

  group('微博视频详情页', () {
    testWidgets('有直链 → 视频区是 InlineVideoPlayer（不是静态封面）',
        (WidgetTester tester) async {
      await pumpDetail(
        tester,
        _weiboVideo(directVideoUrl: 'https://f.video.weibocdn.com/x.mp4'),
      );

      // 核心断言：详情页里**嵌着播放器**，而不是一张要去别处点的封面。
      expect(find.byType(InlineVideoPlayer), findsOneWidget);
    });

    testWidgets('解析出的 mid 被交给微博评论区（oid 正确）',
        (WidgetTester tester) async {
      await pumpDetail(
        tester,
        _weiboVideo(directVideoUrl: 'https://f.video.weibocdn.com/x.mp4'),
      );
      await scrollToComments(tester);

      // 评论要和视频**在同一页**，否则用户看完还得返回去。
      final Finder section = find.byType(CommentSection);
      expect(section, findsOneWidget);
      final CommentSection widget = tester.widget<CommentSection>(section);
      expect(widget.platform, Platform.weibo);
      expect(widget.oid, '5259410951377781');
      // 微博侧 type 固定 0（hotflow 只认 id/mid）。
      expect(widget.type, 0);
    });

    testWidgets('无直链 → 不渲染播放器（走封面兜底）', (WidgetTester tester) async {
      await pumpDetail(tester, _weiboVideo());
      await scrollToComments(tester);

      // 没有可播地址就不要起播放器：那只会多一次必然失败的初始化。
      expect(find.byType(InlineVideoPlayer), findsNothing);
      // 评论区仍在。
      expect(find.byType(CommentSection), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('InlineVideoPlayer 自身', () {
    testWidgets('进入即自动播放，销毁时释放播放器', (WidgetTester tester) async {
      final _FakePlayer fake = _FakePlayer();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineVideoPlayer(
              url: 'https://f.video.weibocdn.com/x.mp4',
              referer: 'https://weibo.com/',
              playerFactory: () => fake,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.isPlaying, isTrue, reason: '进详情页就该自动播，不该再点一次');

      // 换成别的页面 → 触发 dispose。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pump();
      expect(fake.disposed, isTrue, reason: '离开详情页必须释放解码器');
    });

    testWidgets('初始化失败时显示可读错误与重试，不崩', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineVideoPlayer(
              url: 'https://x.invalid/v.mp4',
              playerFactory: () => _ThrowingPlayer(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('视频播放失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  /// 交互规格对齐 B 站播放页（`docs/HANDOVER.md` §7.23）。
  ///
  /// 用户明确要求：「下边有控制栏可以控制，可以双击播放，双击暂停，
  /// 长按快进等功能」。这一组逐条钉住。
  ///
  /// **不含弹幕**：用户已明确「微博视频不需要弹幕功能」，所以这里也断言
  /// 不存在弹幕开关 —— 防止后续「顺手对齐 B 站」把它加回来。
  group('InlineVideoPlayer 交互（对齐 B 站）', () {
    Future<_FakePlayer> pumpPlayer(WidgetTester tester) async {
      final _FakePlayer fake = _FakePlayer();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineVideoPlayer(
              url: 'https://f.video.weibocdn.com/x.mp4',
              referer: 'https://weibo.com/',
              hintDuration: const Duration(seconds: 26),
              playerFactory: () => fake,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return fake;
    }

    testWidgets('底部控制栏存在：播放/暂停 + 进度条 + 时间 + 全屏',
        (WidgetTester tester) async {
      await pumpPlayer(tester);

      expect(find.byType(Slider), findsOneWidget, reason: '进度条');
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget, reason: '全屏');
      // 自动播放中 → 按钮显示「暂停」。
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      // 时间：00:00 / 00:26（hintDuration 兜底，因为假播放器 duration=26s）。
      expect(find.textContaining('/ 00:26'), findsOneWidget);
    });

    testWidgets('点控制栏按钮能暂停 / 再播放', (WidgetTester tester) async {
      final _FakePlayer fake = await pumpPlayer(tester);

      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      expect(fake.calls.contains('pause'), isTrue);

      // 暂停后按钮变回「播放」。
      await tester.pump();
      final Finder playBtn = find.byIcon(Icons.play_arrow_rounded);
      expect(playBtn, findsWidgets);
      await tester.tap(playBtn.first);
      await tester.pump();
      expect(fake.calls.where((String c) => c == 'play').length, greaterThan(1));
    });

    testWidgets('双击画面 = 播放/暂停（用户明确要求）',
        (WidgetTester tester) async {
      final _FakePlayer fake = await pumpPlayer(tester);
      final int before = fake.calls.length;

      // 双击画面中央（避开底部控制栏与中央的暂停图标）。
      final Finder surface = find.byType(InlineVideoPlayer);
      await tester.tap(surface, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(surface, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));

      // 双击触发 togglePlay → 因为当前在播，应该调 pause。
      expect(fake.calls.length, greaterThan(before));
      expect(fake.calls.contains('pause'), isTrue);
    });

    testWidgets('长按 2.0x 快进，松手回到 1.0x',
        (WidgetTester tester) async {
      final _FakePlayer fake = await pumpPlayer(tester);

      final Finder surface = find.byType(InlineVideoPlayer);
      final TestGesture g = await tester.startGesture(
        tester.getCenter(surface),
      );
      await tester.pump(const Duration(milliseconds: 700)); // 超过长按阈值
      expect(fake.speeds, contains(2.0), reason: '长按要 2x 快进');
      expect(find.textContaining('快进中'), findsOneWidget);

      await g.up();
      await tester.pump();
      expect(fake.speeds.last, 1.0, reason: '松手必须还原，不能永久 2x');
      expect(find.textContaining('快进中'), findsNothing);
    });

    testWidgets('单击画面切换控制栏显隐', (WidgetTester tester) async {
      await pumpPlayer(tester);
      expect(find.byType(Slider), findsOneWidget);

      final Finder surface = find.byType(InlineVideoPlayer);
      await tester.tap(surface, warnIfMissed: false);
      // 等过双击判定窗口，让单击生效。
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Slider), findsNothing, reason: '单击应隐藏控制栏');
    });

    testWidgets('没有任何弹幕入口（用户明确要求不要弹幕）',
        (WidgetTester tester) async {
      await pumpPlayer(tester);

      // 弹幕相关图标一个都不该出现。
      expect(find.byIcon(Icons.subtitles_rounded), findsNothing);
      expect(find.byIcon(Icons.subtitles_off_rounded), findsNothing);
      expect(find.textContaining('弹幕'), findsNothing);
    });

    testWidgets('点控制栏按钮不会同时把控制栏藏起来（真机回归）',
        (WidgetTester tester) async {
      // 真机踩到的坑：点暂停按钮时，按钮的 InkWell 与下面画面手势层的
      // `onTap`（切换控制栏）同时进入手势竞技场，于是「视频暂停了，
      // 控制栏也一起消失」，用户想调进度还得再点一次画面。
      // 修法是给控制栏套一层注册了 `onTap` 的 GestureDetector 抢占事件。
      final _FakePlayer fake = await pumpPlayer(tester);

      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.calls.contains('pause'), isTrue);
      // 暂停后控制栏必须仍在（能继续操作进度条）。
      expect(
        find.byType(Slider),
        findsOneWidget,
        reason: '点控制栏按钮不该把控制栏一起藏掉',
      );
    });
  });
}

/// 初始化就抛异常的假播放器：验证「失败要显示出来，而不是静默黑屏」。
class _ThrowingPlayer implements RrhaPlayer {
  @override
  Widget buildView(BuildContext context) => const SizedBox.expand();

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Stream<bool> get playingStream => const Stream<bool>.empty();

  @override
  Stream<Duration> get durationStream => const Stream<Duration>.empty();

  @override
  Stream<void> get completedStream => const Stream<void>.empty();

  @override
  Stream<String> get errorStream => const Stream<String>.empty();

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => Duration.zero;

  @override
  bool get isPlaying => false;

  @override
  double get aspectRatio => 16 / 9;

  @override
  double get speed => 1.0;

  @override
  Future<void> initialize() async => throw StateError('decode failed');

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {}
}
