import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:crypto/crypto.dart' show sha256;
import 'package:encrypt/encrypt.dart' as enc;

/// 本地敏感信息（API Key 等）的 AES 加密工具。
///
/// ## 为什么这样做
/// API Key 如果明文存进 SharedPreferences，任何能读取应用沙盒的工具
/// （root 设备、备份恢复、调试）都能直接看到。这里用 AES-256 加密后再存，
/// 至少不是明文。
///
/// ## 诚实说明（安全边界）
/// 纯 Dart 的 [encrypt] 做 AES，密钥仍派生自本地固定的盐 + 设备信息，
/// 下一轮启动要能重新解出同一密钥，所以密钥**必须**能在本地重建。
/// 这比明文好，但**不是**系统级安全：
///  - 不是 `flutter_secure_storage` 那种放系统 Keychain/Keystore 的方案；
///  - root 设备上，硬拿密钥去解仍有可能。
/// 对「用户自配的第三方 API Key」这个场景已经够用（比明文大幅提升），
/// 若要更高安全等级，后续可换 flutter_secure_storage（需新增原生插件）。
class KeyEncryption {
  KeyEncryption._();

  /// 从固定盐 + 任意设备指纹派生 32 字节 AES 密钥。
  ///
  /// [deviceFingerprint] 传入设备相关字符串（如设备型号 + Android ID），
  /// 让同一份 SharedPreferences 数据换设备后解不开，降低拿到备份文件就能
  /// 解密的可能。
  static enc.Key _deriveKey(String deviceFingerprint) {
    // 固定盐：写死在代码里，避免和密钥本身一起存在 SharedPreferences
    const salt = 'perchplay.key.salt.v1';
    final digest = sha256.convert(utf8.encode('$salt|$deviceFingerprint'));
    return enc.Key(Uint8List.fromList(digest.bytes));
  }

  /// 加密明文，返回 base64 字符串（可安全存进 SharedPreferences）。
  static String encrypt(String plaintext, {String deviceFingerprint = ''}) {
    if (plaintext.isEmpty) return '';
    final key = _deriveKey(deviceFingerprint);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    // iv 与密文一起存，因为 iv 不需要保密，但解密时必须用它
    return '${iv.base64}:${encrypted.base64}';
  }

  /// 解密（上一方法返回的 base64 字符串），失败返回 null。
  static String? decrypt(String encoded, {String deviceFingerprint = ''}) {
    if (encoded.isEmpty) return null;
    try {
      final parts = encoded.split(':');
      if (parts.length != 2) return null;
      final key = _deriveKey(deviceFingerprint);
      final iv = enc.IV.fromBase64(parts[0]);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      return encrypter.decrypt64(parts[1], iv: iv);
    } catch (_) {
      return null; // 解密失败（密钥不符 / 数据损坏）→ 返回 null，调用方回退默认
    }
  }
}