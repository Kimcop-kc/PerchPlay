import 'package:flutter/material.dart';

import '../../models/online_subtitle.dart';
import '../../models/video_model.dart';
import '../../services/subtitle/online_subtitle_service.dart';
import '../../services/subtitle/subtitle_source.dart';
import '../glass/glass_button.dart';
import '../glass/glass_card.dart';
import '../../core/theme/glass_theme.dart';

/// 在线字幕搜索面板。
///
/// 嵌入播放器字幕面板使用。展示：
/// - 搜索状态（加载/空/部分失败/全部失败）
/// - 搜索结果列表（来源/语言/格式/匹配分）
/// - 下载按钮和进度
/// - 下载后回调加载到播放器
class OnlineSubtitlePanel extends StatefulWidget {
  /// 当前视频（用于构造查询条件）。
  final VideoModel? video;

  /// 下载成功后的回调（把本地字幕加载到播放器）。
  final Future<void> Function(OnlineSubtitle subtitle) onDownloaded;

  const OnlineSubtitlePanel({
    super.key,
    required this.video,
    required this.onDownloaded,
  });

  @override
  State<OnlineSubtitlePanel> createState() => _OnlineSubtitlePanelState();
}

class _OnlineSubtitlePanelState extends State<OnlineSubtitlePanel> {
  final _service = OnlineSubtitleService.instance;

  bool _loading = false;
  bool _searched = false;
  List<OnlineSubtitle> _results = [];
  String? _error;

  /// 正在下载的字幕 id（防重复提交）。
  String? _downloadingId;

  /// 已下载的字幕 id 集合。
  final Set<String> _downloadedIds = {};

  /// 搜索关键词（默认影片名，可手动改）。
  late final TextEditingController _queryCtrl;

  /// 语言筛选（null=不限）。
  String? _langFilter;

  @override
  void initState() {
    super.initState();
    _queryCtrl = TextEditingController(
      text: widget.video?.name ?? '',
    );
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  SubtitleQuery _buildQuery() {
    final video = widget.video;
    return SubtitleQuery(
      fileName: video?.path,
      title: video?.name ?? _queryCtrl.text,
      year: video == null ? null : null, // 年份从文件名/刮削信息提取（暂不支持）
      languageCode: _langFilter,
    );
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _searched = true;
      _error = null;
    });
    try {
      final results = await _service.search(
        _buildQuery(),
        videoFileName: widget.video?.path,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _download(OnlineSubtitle subtitle) async {
    if (_downloadingId != null) return; // 防重复提交
    setState(() => _downloadingId = subtitle.id);
    try {
      await widget.onDownloaded(subtitle);
      if (!mounted) return;
      setState(() {
        _downloadedIds.add(subtitle.id);
        _downloadingId = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadingId = null;
        _error = '下载失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 搜索栏
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _queryCtrl,
                style: const TextStyle(
                    color: GlassTheme.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: '搜索关键词',
                  hintStyle: const TextStyle(
                      color: GlassTheme.textTertiary, fontSize: 13),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                    borderSide:
                        BorderSide(color: Colors.black.withValues(alpha: 0.1)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GlassButton(
              icon: Icons.search_rounded,
              compact: true,
              height: 38,
              foregroundColor: GlassTheme.accentPurple,
              onTap: _loading ? null : _search,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 语言筛选
        Wrap(
          spacing: 6,
          children: [
            for (final lang in const [
              (null, '全部'),
              ('zh', '中文'),
              ('en', '英文'),
              ('ja', '日文'),
              ('ko', '韩文'),
            ])
              ChoiceChip(
                label: Text(lang.$2, style: const TextStyle(fontSize: 12)),
                selected: _langFilter == lang.$1,
                onSelected: (_) {
                  setState(() => _langFilter = lang.$1);
                  _search();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),

        // 状态
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: GlassTheme.accentPurple),
            ),
          )
        else if (_error != null && _results.isEmpty)
          _buildError(_error!)
        else if (_searched && _results.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('未找到匹配的字幕',
                  style:
                      TextStyle(color: GlassTheme.textTertiary, fontSize: 14)),
            ),
          )
        else if (_results.isNotEmpty)
          ..._results.map((s) => _buildResultTile(s)),
      ],
    );
  }

  Widget _buildError(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text('搜索失败',
                style: TextStyle(color: GlassTheme.accentPink, fontSize: 14)),
            const SizedBox(height: 6),
            Text(msg,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: GlassTheme.textTertiary, fontSize: 12)),
            const SizedBox(height: 12),
            GlassButton.outlined(
              label: '重试',
              height: 36,
              foregroundColor: GlassTheme.accentPurple,
              onTap: _search,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultTile(OnlineSubtitle s) {
    final downloading = _downloadingId == s.id;
    final downloaded = _downloadedIds.contains(s.id) || s.isDownloaded;

    return GlassCard(
      radius: GlassTheme.radiusSm,
      tint: GlassTheme.tintWhite,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: GlassTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (s.matchScore != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${(s.matchScore! * 100).round()}%',
                        style: TextStyle(
                          color: s.matchScore! >= 0.75
                              ? GlassTheme.accentTeal
                              : GlassTheme.textTertiary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    s.source,
                    s.languageName,
                    s.format.toUpperCase(),
                    if (s.releaseGroup != null) s.releaseGroup!,
                    if (s.isHearingImpaired) 'SDH',
                  ].join(' · '),
                  style: const TextStyle(
                      color: GlassTheme.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (downloaded)
            const Icon(Icons.check_circle_rounded,
                color: GlassTheme.accentTeal, size: 20)
          else
            GlassButton.outlined(
              icon: downloading
                  ? Icons.hourglass_empty_rounded
                  : Icons.download_rounded,
              label: downloading ? '下载中' : '下载',
              height: 32,
              foregroundColor: GlassTheme.accentPurple,
              onTap: downloading ? null : () => _download(s),
            ),
        ],
      ),
    );
  }
}
