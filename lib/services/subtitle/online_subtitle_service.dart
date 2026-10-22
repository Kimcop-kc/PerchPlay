import '../../models/online_subtitle.dart';
import '../../models/subtitle_model.dart';
import '../app_settings_service.dart';
import 'opensubtitles_source.dart';
import 'subtitle_aggregator.dart';
import 'subtitle_downloader.dart';
import 'subtitle_matcher_online.dart';
import 'subtitle_source.dart';

/// 在线字幕服务的统一编排入口。
///
/// 连接：设置（API Key）→ 字幕源 → 聚合器 → 匹配评分 → 下载器。
/// UI 层只和这个服务打交道，不直接碰各个底层组件。
class OnlineSubtitleService {
  OnlineSubtitleService._();

  static final OnlineSubtitleService instance = OnlineSubtitleService._();

  final _aggregator = SubtitleAggregator.instance;
  final _downloader = SubtitleDownloader.instance;

  bool _sourcesReady = false;

  /// 确保字幕源已按当前设置初始化。
  void _ensureSources() {
    if (_sourcesReady) return;
    final settings = AppSettingsService.instance;

    // 重建源：OpenSubtitles 用用户配置的 API Key
    _aggregator.clearSources();
    final key = settings.subtitleOpenSubtitlesKey;
    if (key.isNotEmpty) {
      _aggregator.addSource(OpenSubtitlesSource(apiKey: key));
    }
    _sourcesReady = true;
  }

  /// 当前是否有可用的字幕源（有 API Key 且服务可用）。
  bool get hasAvailableSource {
    _ensureSources();
    return _aggregator.availableSources.isNotEmpty;
  }

  /// 在线搜索开关是否开启。
  bool get isEnabled => AppSettingsService.instance.subtitleOnlineSearch;

  /// 搜索在线字幕，返回带匹配评分的结果。
  ///
  /// [query] 查询条件，[videoFileName] 当前视频文件名（用于版本匹配）。
  Future<List<OnlineSubtitle>> search(
    SubtitleQuery query, {
    String? videoFileName,
  }) async {
    _ensureSources();
    final result = await _aggregator.search(query);

    // 计算匹配评分
    final scored = result.results.map((s) {
      final score = SubtitleMatcher.score(query, s);
      return s.copyWith(
        matchScore: score.score,
        matchReason: score.reasons.join('、'),
      );
    }).toList();

    // 按评分排序（聚合器已按初步排序，这里用精确评分重排）
    scored.sort((a, b) => (b.matchScore ?? 0).compareTo(a.matchScore ?? 0));
    return scored;
  }

  /// 下载字幕并转成本地模型。
  Future<SubtitleModel> download(OnlineSubtitle subtitle) async {
    _ensureSources();
    // 找到对应的源
    SubtitleSource? source;
    for (final s in _aggregator.availableSources) {
      if (s.sourceId == subtitle.source) {
        source = s;
        break;
      }
    }
    if (source == null) {
      throw const SubtitleServiceException(
        SubtitleErrorType.unknown,
        '字幕源不可用',
      );
    }
    final result = await _downloader.download(source, subtitle);
    return result.toSubtitleModel();
  }

  /// 取消当前搜索。
  void cancel() => _aggregator.cancel();

  /// 释放资源。
  void dispose() {
    _sourcesReady = false;
    _aggregator.dispose();
  }
}
