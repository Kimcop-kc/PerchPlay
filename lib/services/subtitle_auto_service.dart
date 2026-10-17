import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'app_settings_service.dart';
import 'subtitle_matcher.dart';
import 'subtitle_service.dart';

/// 打开视频时「自动挂同名字幕 / 恢复上次选择」的 IO 层
///
/// 为什么单独一个服务：列目录、判文件是否存在、读写 SharedPreferences 记忆
/// 都是 IO，塞进播放器 notifier 里会让 loadVideo 越来越难读；而真正的决策
/// （候选怎么排序、选哪条）全在 [Subtitles] / [SubtitleMemory] 这两个纯逻辑里。
/// 两层分开后，决策规则可以直接单测，不用起播放器。
class SubtitleAutoService {
  SubtitleAutoService._();
  static final instance = SubtitleAutoService._();

  /// 这次打开这个视频该不该自动挂字幕、挂哪条
  ///
  /// 找不到任何同名字幕 / 记忆里是「关掉字幕」时返回不挂的结论，
  /// 调用方只管照着 `path` 做，不需要自己再判断。
  Future<SubtitlePick> resolve(String videoPath) async {
    final candidates = await findCandidates(videoPath);
    final remembered = AppSettingsService.instance.subtitleMemoryFor(videoPath);
    final pick = Subtitles.pick(
      candidates,
      remembered,
      // 记忆里的文件可能已经被用户删了：这里查真实文件系统，
      // 文件不在就忽略记忆、回落到自动挑选（需求里的「删了就忽略记忆」）。
      exists: (path) => File(path).existsSync(),
    );

    // 记忆确实生效时顺手刷新「最近使用」时间。
    // 淘汰是按最近使用来的，如果只在「手动改选」时更新时间，常看的片子会被
    // 后来选过字幕的其它片子挤出 300 条上限，明明一直在看却丢了记忆。
    if (remembered != null &&
        (pick.kind == SubtitlePickKind.rememberedFile ||
            pick.kind == SubtitlePickKind.rememberedOff)) {
      await AppSettingsService.instance
          .rememberSubtitle(videoPath, remembered.subtitlePath);
    }
    return pick;
  }

  /// 视频同目录下的同名字幕候选（已排好序）
  Future<List<SubtitleCandidate>> findCandidates(String videoPath) async {
    try {
      // 复用现有的目录列举（扩展名过滤、异常兜底都在里面），
      // 这里只要文件名，同名判断交给纯函数
      final files =
          await SubtitleService.listSubtitleFilesInDir(p.dirname(videoPath));
      return Subtitles.findCandidates(
        videoPath,
        files.map((f) => p.basename(f.path)),
      );
    } catch (e) {
      // 目录不存在 / 权限不足：当作没有字幕，不影响播放
      debugPrint('[SubtitleAuto] 列出同目录字幕失败: $e');
      return const <SubtitleCandidate>[];
    }
  }

  /// 记住某个视频上次选的字幕；[subtitlePath] 为 null 表示用户关掉了字幕
  Future<void> remember(String videoPath, String? subtitlePath) =>
      AppSettingsService.instance.rememberSubtitle(videoPath, subtitlePath);
}
