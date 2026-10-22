import '../../models/online_subtitle.dart';
import '../../models/video_model.dart';
import '../app_settings_service.dart';
import 'online_subtitle_service.dart';
import 'subtitle_matcher_online.dart';
import 'subtitle_source.dart';

/// 在线字幕自动加载结果。
enum AutoLoadAction {
  /// 什么都不做（开关关闭 / 无可用源 / 无匹配）。
  none,

  /// 找到高置信度结果，按设置自动下载并应用。
  autoApply,

  /// 找到低置信度结果，提示用户确认。
  prompt,
}

/// 在线字幕自动加载决策服务。
///
/// 打开视频时调用，按设置决定：
/// - 开关关闭 → none
/// - 无可用源（无 API Key）→ none
/// - 搜索到高置信度（≥0.75）且开启自动下载/应用 → autoApply
/// - 搜索到低置信度 → prompt（不静默应用）
class SubtitleAutoLoader {
  SubtitleAutoLoader._();

  static final SubtitleAutoLoader instance = SubtitleAutoLoader._();

  final _service = OnlineSubtitleService.instance;

  /// 已处理过的视频（防重复自动加载）。
  final Set<String> _processed = {};

  /// 正在处理的视频（防并发重复任务）。
  final Set<String> _inFlight = {};

  /// 自动加载决策：搜索 + 评分 + 判断动作。
  ///
  /// 返回 (action, 最佳结果)。autoApply 时结果非空。
  Future<(AutoLoadAction, OnlineSubtitle?)> evaluate(VideoModel video) async {
    final settings = AppSettingsService.instance;

    // 开关关闭或已处理过
    if (!settings.subtitleOnlineSearch) {
      return (AutoLoadAction.none, null);
    }
    if (_processed.contains(video.id)) {
      return (AutoLoadAction.none, null);
    }

    // 无可用源（未配置 API Key）
    if (!_service.hasAvailableSource) {
      return (AutoLoadAction.none, null);
    }

    // 防重复并发
    if (_inFlight.contains(video.id)) {
      return (AutoLoadAction.none, null);
    }
    _inFlight.add(video.id);

    try {
      final query = SubtitleQuery(
        fileName: video.path,
        title: video.name,
        languageCode: settings.subtitleDefaultLang,
      );

      final results = await _service.search(query, videoFileName: video.path);
      _processed.add(video.id);

      if (results.isEmpty) return (AutoLoadAction.none, null);

      final best = results.first; // 已按评分降序
      final score = best.matchScore ?? 0;

      if (score >= SubtitleMatcher.highConfidence) {
        if (settings.subtitleAutoDownload) {
          return (AutoLoadAction.autoApply, best);
        }
        // 高分但未开启自动下载 → 提示用户
        return (AutoLoadAction.prompt, best);
      }
      if (score >= SubtitleMatcher.lowConfidence) {
        return (AutoLoadAction.prompt, best);
      }
      return (AutoLoadAction.none, null);
    } finally {
      _inFlight.remove(video.id);
    }
  }

  /// 清除某视频的处理标记（切换影片后重新评估）。
  void reset(String videoId) {
    _processed.remove(videoId);
  }

  /// 清空所有状态（测试/释放）。
  void clear() {
    _processed.clear();
    _inFlight.clear();
  }
}
