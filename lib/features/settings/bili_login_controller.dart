import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/app_error.dart';
import '../../core/storage/bili_credential_store.dart';
import '../../core/utils/logger.dart';
import '../../data/bili/bili_login.dart';
import '../../data/models/bili_session.dart';

/// 登录界面的阶段。
enum LoginPhase {
  /// 未开始（也用于「已登出」）。
  idle,

  /// 正在申请二维码。
  loadingQr,

  /// 二维码已就绪，等待扫码（`86101`）。
  waiting,

  /// 已扫码，等待手机端确认（`86090`）。
  scanned,

  /// 已拿到凭据，正在向 `/nav` 确认身份并落库。
  confirming,

  /// 登录完成。
  success,

  /// 二维码过期（180 秒）或服务端判定过期（`86038`）。
  expired,

  /// 失败（生成二维码失败、确认身份失败等）。
  failed,
}

/// 登录状态。
class LoginState {
  const LoginState({
    this.phase = LoginPhase.idle,
    this.ticket,
    this.session,
    this.error,
    this.hint,
  });

  final LoginPhase phase;

  /// 当前二维码。阶段进入 [LoginPhase.success] / [LoginPhase.expired] 后不再使用。
  final QrCodeTicket? ticket;

  /// 已登录的凭据（**只在内存里传，界面只允许读 uname / maskedSummary**）。
  final BiliSession? session;

  /// 失败原因（已转成带中文文案的 [AppError]）。
  final AppError? error;

  /// 服务端给的状态文案（如「已扫码，请在手机上确认」）。
  final String? hint;

  bool get isLoggedIn => session != null;

  /// 是否正在等待扫码（这两种阶段都该继续轮询）。
  bool get awaitingScan =>
      phase == LoginPhase.waiting || phase == LoginPhase.scanned;

  /// 是否处于「进行中」，用于禁用按钮 / 显示进度圈。
  bool get busy =>
      phase == LoginPhase.loadingQr ||
      phase == LoginPhase.confirming ||
      awaitingScan;

  LoginState copyWith({
    LoginPhase? phase,
    QrCodeTicket? ticket,
    BiliSession? session,
    AppError? error,
    String? hint,
    bool clearError = false,
    bool clearHint = false,
  }) =>
      LoginState(
        phase: phase ?? this.phase,
        ticket: ticket ?? this.ticket,
        session: session ?? this.session,
        error: clearError ? null : (error ?? this.error),
        hint: clearHint ? null : (hint ?? this.hint),
      );
}

/// 扫码登录的状态机。
///
/// 生命周期约定：
/// - [restore] 在 App 启动/进入设置页时调用，把钥匙串里的凭据捞回内存；
/// - [start] 申请二维码并开始轮询，[cancel] 收尾（关掉登录界面时务必调用）；
/// - 凭据**只在 [_finish] 里落库一次**，且只经 [BiliCredentialStore]。
class BiliLoginController extends StateNotifier<LoginState> {
  BiliLoginController({
    required BiliLoginClient client,
    required BiliCredentialStore store,
  })  : _client = client,
        _store = store,
        super(const LoginState());

  final BiliLoginClient _client;
  final BiliCredentialStore _store;

  Timer? _timer;
  DateTime? _deadline;

  /// 上一拍还没回来时置位，避免慢网络下请求堆叠。
  bool _inFlight = false;

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// 从钥匙串恢复登录态（App 启动时调用一次即可）。
  Future<void> restore() async {
    final session = await _store.load();
    if (!mounted) return;
    if (session == null) {
      state = const LoginState();
      return;
    }
    Log.d('BiliLogin', '已从钥匙串恢复登录态（uid=${session.dedeUserId}）');
    state = LoginState(phase: LoginPhase.success, session: session);
  }

  /// 申请二维码并开始轮询。
  Future<void> start() async {
    cancel();
    state = const LoginState(phase: LoginPhase.loadingQr);
    try {
      final ticket = await _client.generate();
      if (!mounted) return;
      _deadline = DateTime.now().add(BiliLoginClient.ticketTtl);
      state = LoginState(phase: LoginPhase.waiting, ticket: ticket);
      _timer = Timer.periodic(BiliLoginClient.pollInterval, (_) => _tick());
    } on AppError catch (e) {
      if (!mounted) return;
      state = LoginState(phase: LoginPhase.failed, error: e);
    } catch (e) {
      if (!mounted) return;
      state = LoginState(
        phase: LoginPhase.failed,
        error: AppError(AppErrorKind.unknown, '申请二维码失败：$e'),
      );
    }
  }

  /// 停止轮询（保留当前状态，供界面展示「已取消」）。
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    _inFlight = false;
  }

  /// 回到未登录的初始态（不动钥匙串）。
  void reset() {
    cancel();
    state = const LoginState();
  }

  /// 退出登录：先清钥匙串，再清内存态。
  ///
  /// 顺序很重要 —— 万一清钥匙串失败，界面不会骗用户说「已退出」。
  Future<void> logout() async {
    cancel();
    await _store.clear();
    if (!mounted) return;
    state = const LoginState();
  }

  // ------------------------------------------------------------ 轮询

  Future<void> _tick() async {
    final ticket = state.ticket;
    if (ticket == null) {
      cancel();
      return;
    }
    if (_inFlight) return;

    final deadline = _deadline;
    if (deadline != null && DateTime.now().isAfter(deadline)) {
      cancel();
      if (mounted) {
        state = LoginState(phase: LoginPhase.expired, ticket: ticket);
      }
      return;
    }

    _inFlight = true;
    try {
      final result = await _client.poll(ticket.key);
      if (!mounted) return;

      switch (result.state) {
        case QrPollState.waiting:
          state = state.copyWith(
            phase: LoginPhase.waiting,
            hint: result.message,
          );
          break;

        case QrPollState.scanned:
          state = state.copyWith(
            phase: LoginPhase.scanned,
            hint: result.message,
          );
          break;

        case QrPollState.expired:
          cancel();
          state = LoginState(phase: LoginPhase.expired, ticket: ticket);
          break;

        case QrPollState.success:
          cancel();
          state = state.copyWith(phase: LoginPhase.confirming);
          await _finish(result.session);
          break;

        case QrPollState.unknown:
          // 网络抖动或未知状态码：不改阶段，只更新提示，下一拍继续。
          state = state.copyWith(
            hint: result.message,
            clearError: true,
          );
          break;
      }
    } finally {
      _inFlight = false;
    }
  }

  /// 确认身份并落库。**凭据只在写在这里。**
  Future<void> _finish(BiliSession? session) async {
    if (session == null) {
      if (!mounted) return;
      state = state.copyWith(
        phase: LoginPhase.failed,
        error: const AppError(
          AppErrorKind.auth,
          '登录响应里没有凭据，请重新扫码',
          retryable: true,
        ),
      );
      return;
    }

    try {
      final confirmed = await _client.confirm(session);
      await _store.save(confirmed);
      if (!mounted) return;
      state = LoginState(phase: LoginPhase.success, session: confirmed);
    } on AppError catch (e) {
      if (!mounted) return;
      state = LoginState(phase: LoginPhase.failed, error: e);
    } catch (e) {
      if (!mounted) return;
      state = LoginState(
        phase: LoginPhase.failed,
        error: AppError(AppErrorKind.unknown, '登录收尾失败：$e'),
      );
    }
  }
}
