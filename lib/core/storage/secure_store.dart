import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/logger.dart';

/// 系统钥匙串（Android Keystore）封装。
///
/// 本轮原型**不使用任何账号凭证**，因此这里只提供能力与契约：
/// 若后续允许用户粘贴 Cookie / Token，必须经由此类写入钥匙串，
/// 严禁落到 SharedPreferences、日志或代码里。
///
/// 注意：B 站的 `buvid3` 是匿名设备指纹（非账号凭证），按需求约定
/// 不放在钥匙串，而是跟随网络层请求头，且可在设置页关闭。
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e, st) {
      Log.e('SecureStore', '写入钥匙串失败 key=$key', e, st);
      rethrow;
    }
  }

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      Log.w('SecureStore', '读取钥匙串失败 key=$key: $e');
      return null;
    }
  }

  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      Log.w('SecureStore', '删除钥匙串条目失败 key=$key: $e');
    }
  }

  Future<void> clear() async {
    try {
      await _storage.deleteAll();
    } catch (e) {
      Log.w('SecureStore', '清空钥匙串失败: $e');
    }
  }

  /// 当前是否存有某类凭证（用于设置页展示状态，绝不回显内容）。
  Future<bool> has(String key) async => (await read(key))?.isNotEmpty ?? false;
}
