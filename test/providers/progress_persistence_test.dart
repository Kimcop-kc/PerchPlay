import 'package:flutter_test/flutter_test.dart';

/// 播放进度保存与恢复回归测试（P1-5 缺陷修复）
///
/// 验证：
/// 1. 远程路径跳过进度保存
/// 2. 近结尾自动清零
/// 3. pendingResume 与 loadToken 守卫逻辑

/// 模拟 isRemotePath 检查
bool isRemotePath(String path) {
  final p = path.toLowerCase();
  return p.startsWith('http://') ||
      p.startsWith('https://') ||
      p.startsWith('smb://') ||
      p.startsWith('ftp://') ||
      p.startsWith('webdav://');
}

/// 模拟 _persistProgress 核心逻辑
Duration? computePersistPosition({
  required Duration position,
  required Duration duration,
  required bool isRemote,
}) {
  if (isRemote) return null; // 网络源不写库
  final ms = position.inMilliseconds;
  if (ms <= 0) return null;

  // 长视频且距结尾 <3 秒 → 保存 0（视为看完）
  if (duration.inMilliseconds > 30000 &&
      (duration - position).inMilliseconds < 3000) {
    return Duration.zero;
  }
  return position;
}

/// 模拟 _pendingResume 钳位逻辑
Duration clampResume(int resumeMs, Duration duration) {
  final clamped = resumeMs.clamp(0, duration.inMilliseconds);
  return Duration(milliseconds: clamped);
}

/// 模拟 _loadToken + _pendingResumeLoadId 守卫
class LoadGuard {
  int _loadToken = 0;
  int _pendingResumeLoadId = 0;

  int get loadToken => _loadToken;

  void loadVideo() => ++_loadToken;

  void setPendingResume(Duration d) {
    _pendingResumeLoadId = _loadToken;
  }

  bool isPendingValid(int currentLoadToken) =>
      _pendingResumeLoadId == currentLoadToken;
}

void main() {
  group('远程路径检测（跳过进度保存）', () {
    test('HTTP/HTTPS/SMB/FTP/WebDAV 识别为远程', () {
      expect(isRemotePath('http://192.168.1.1/video.mp4'), true);
      expect(isRemotePath('https://nas.local/media.mp4'), true);
      expect(isRemotePath('smb://server/share/file.mkv'), true);
      expect(isRemotePath('ftp://server/video.mp4'), true);
      expect(isRemotePath('webdav://server/share'), true);
    });

    test('本地路径不误判为远程', () {
      expect(isRemotePath('/storage/emulated/0/video.mp4'), false);
      expect(isRemotePath('file:///data/media/0/file.mp4'), false);
      expect(isRemotePath('content://com.android.providers'), false);
    });
  });

  group('进度保存 — 近结尾自动清零', () {
    test('长视频距结尾 <3s → 保存 0（看完）', () {
      final result = computePersistPosition(
        position: const Duration(minutes: 119, seconds: 58),
        duration: const Duration(minutes: 120),
        isRemote: false,
      );
      expect(result, Duration.zero);
    });

    test('短视频（≤30s）近结尾不自动清零', () {
      final result = computePersistPosition(
        position: const Duration(seconds: 28),
        duration: const Duration(seconds: 30),
        isRemote: false,
      );
      expect(result, const Duration(seconds: 28));
    });

    test('远程源不写库', () {
      final result = computePersistPosition(
        position: const Duration(minutes: 30),
        duration: const Duration(minutes: 60),
        isRemote: true,
      );
      expect(result, isNull);
    });
  });

  group('pendingResume 钳位 + loadToken 守卫', () {
    test('resume > duration → 钳位到 duration', () {
      final result = clampResume(999999, const Duration(minutes: 10));
      expect(result, const Duration(minutes: 10));
    });

    test('resume < 0 → 钳位到 0', () {
      final result = clampResume(-5000, const Duration(minutes: 10));
      expect(result, Duration.zero);
    });

    test('正常 resume → 不钳位', () {
      final result = clampResume(30000, const Duration(minutes: 10));
      expect(result, const Duration(seconds: 30));
    });

    test('loadToken 守卫：旧 pending 不匹配当前 token', () {
      final guard = LoadGuard();
      guard.loadVideo(); // token = 1
      guard.setPendingResume(const Duration(seconds: 10)); // pends on 1

      guard.loadVideo(); // token = 2（切集）

      // 旧 pending 的 loadId=1，当前 loadToken=2 —— 不匹配，丢弃
      expect(guard.isPendingValid(guard.loadToken), false);
    });

    test('loadToken 守卫：同 token 下的 pending 有效', () {
      final guard = LoadGuard();
      guard.loadVideo(); // token = 1
      guard.setPendingResume(const Duration(seconds: 10)); // pends on 1
      expect(guard.isPendingValid(1), true);
    });
  });
}
