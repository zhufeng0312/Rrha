import 'dart:convert';

import '../../data/models/bili_session.dart';
import '../utils/logger.dart';
import 'secure_store.dart';

/// B 站账号凭据的存取。
///
/// **这一层存在的唯一理由**：把「凭据只能进系统钥匙串」这条约定收敛到
/// 一个文件里，而不是让设置页、provider、网络层各自去 `write('sessdata', …)`。
/// 约定见 HANDOVER §8。
///
/// 因此这里：
/// - 所有读写都必须经过 [SecureStore]（Android Keystore / iOS Keychain）；
/// - **绝不**触碰 SharedPreferences、文件缓存；
/// - 日志只允许出现键名、长度与操作结果，**永不**出现凭据值。
class BiliCredentialStore {
  BiliCredentialStore({required SecureStore secure}) : _secure = secure;

  final SecureStore _secure;

  /// 键名带版本号：将来凭据结构变了可以并存，而不是互相覆盖出玄学问题。
  static const String sessionKey = 'bili_session_v1';

  /// 写入钥匙串。**只在这里**把会话序列化成字符串。
  Future<void> save(BiliSession session) async {
    final raw = jsonEncode(session.toJson());
    await _secure.write(sessionKey, raw);
    // 只报长度，不报内容。
    Log.d('BiliCredentialStore', '凭据已写入钥匙串（${raw.length} 字节）');
  }

  /// 读取凭据。任何形式的损坏都返回 `null`（＝未登录），绝不抛异常。
  Future<BiliSession?> load() async {
    final raw = await _secure.read(sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final session = BiliSession.fromJson(jsonDecode(raw));
      if (session == null) {
        Log.w('BiliCredentialStore', '钥匙串里的凭据不完整，按未登录处理');
        return null;
      }
      if (!session.isUsable) {
        Log.w('BiliCredentialStore', '钥匙串里的凭据不可用，按未登录处理');
        return null;
      }
      return session;
    } catch (e) {
      Log.w('BiliCredentialStore', '钥匙串凭据解析失败，按未登录处理：$e');
      return null;
    }
  }

  /// 是否存在一份可用的凭据（供设置页展示状态，不回显内容）。
  Future<bool> has() async => (await load()) != null;

  Future<void> clear() async {
    await _secure.delete(sessionKey);
    Log.d('BiliCredentialStore', '凭据已从钥匙串删除');
  }
}
