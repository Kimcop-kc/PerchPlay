import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass_theme.dart';
import '../../models/scrape_result.dart';
import '../../providers/scrape_provider.dart';
import '../glass/glass_button.dart';
import '../glass/glass_panel.dart';

/// TMDB 海报（带加载中/失败兜底）
///
/// 用 Flutter 自带的 ImageCache 就够了：海报数量有限、尺寸固定，
/// 不引入额外的磁盘缓存依赖。
class ScrapedPoster extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? fallback;

  const ScrapedPoster({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => fallback ?? const SizedBox.shrink(),
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height,
          color: Colors.black.withValues(alpha: 0.05),
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: GlassTheme.textTertiary),
            ),
          ),
        );
      },
    );
  }
}

/// 视频详情里的「影片信息」区块
///
/// 之前刮削拿到的海报/简介/评分**没有任何界面展示**，
/// 用户既看不到匹配结果、也无从发现匹配错了。
class ScrapeInfoSection extends ConsumerWidget {
  final String videoPath;

  /// 手动匹配时预填的搜索词（一般是清洗后的片名）
  final String? initialQuery;

  const ScrapeInfoSection({
    super.key,
    required this.videoPath,
    this.initialQuery,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(scrapeProvider.select((s) => s.isEnabled));
    final result = ref.watch(scrapeResultProvider(videoPath));

    if (!enabled && result == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result != null) _buildMatched(context, ref, result),
        if (result != null) const SizedBox(height: 12),
        _buildMatchButton(context, ref, hasResult: result != null),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildMatched(BuildContext context, WidgetRef ref, ScrapeResult r) {
    final poster = r.posterUrl;
    return GlassPanel(
      radius: GlassTheme.radiusLg,
      opacity: GlassTheme.glassLight,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
            child: poster != null
                ? ScrapedPoster(url: poster, width: 76, height: 114)
                : Container(
                    width: 76,
                    height: 114,
                    color: Colors.black.withValues(alpha: 0.06),
                    child: const Icon(Icons.movie_rounded,
                        color: GlassTheme.textTertiary),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  style: const TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (r.originalTitle != null &&
                    r.originalTitle!.isNotEmpty &&
                    r.originalTitle != r.title) ...[
                  const SizedBox(height: 2),
                  Text(r.originalTitle!,
                      style: const TextStyle(
                          color: GlassTheme.textTertiary, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (r.year != null) _chip('${r.year}'),
                    _chip(r.type == ScrapeType.tv ? '剧集' : '电影'),
                    if (r.rating != null && r.rating! > 0)
                      _chip('★ ${r.rating!.toStringAsFixed(1)}'),
                    for (final g in r.genres.take(3)) _chip(g),
                  ],
                ),
                if (r.overview != null && r.overview!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    r.overview!,
                    style: const TextStyle(
                        color: GlassTheme.textSecondary,
                        fontSize: 12,
                        height: 1.35),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: GlassTheme.accentPurple.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
      ),
      child: Text(text,
          style: const TextStyle(color: GlassTheme.accentPurple, fontSize: 11)),
    );
  }

  Widget _buildMatchButton(BuildContext context, WidgetRef ref,
      {required bool hasResult}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => showManualMatchSheet(
          context,
          ref,
          videoPath: videoPath,
          initialQuery: initialQuery,
        ),
        icon: Icon(hasResult ? Icons.edit_rounded : Icons.search_rounded,
            size: 16),
        label: Text(hasResult ? '匹配不对？手动修改' : '手动匹配影片信息',
            style: const TextStyle(fontSize: 13)),
        style: TextButton.styleFrom(
          foregroundColor: GlassTheme.accentPurple,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

/// 手动匹配弹窗：搜片名 → 从候选里选正确的 → 写入缓存
Future<void> showManualMatchSheet(
  BuildContext context,
  WidgetRef ref, {
  required String videoPath,
  String? initialQuery,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ManualMatchSheet(
      videoPath: videoPath,
      initialQuery: initialQuery ?? '',
    ),
  );
}

class _ManualMatchSheet extends ConsumerStatefulWidget {
  final String videoPath;
  final String initialQuery;

  const _ManualMatchSheet({
    required this.videoPath,
    required this.initialQuery,
  });

  @override
  ConsumerState<_ManualMatchSheet> createState() => _ManualMatchSheetState();
}

class _ManualMatchSheetState extends ConsumerState<_ManualMatchSheet> {
  late final TextEditingController _controller;
  List<ScrapeResult> _results = const [];
  bool _searching = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final list = await ref.read(scrapeProvider.notifier).search(q);
    if (!mounted) return;
    setState(() {
      _results = list;
      _searching = false;
      _searched = true;
    });
  }

  Future<void> _pick(ScrapeResult r) async {
    await ref.read(scrapeProvider.notifier).bindResult(widget.videoPath, r);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(scrapeProvider.select((s) => s.isEnabled));
    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      decoration: const BoxDecoration(
        color: Color(0xF7FFFFFF),
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusXl)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 20 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('手动匹配',
              style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('搜不到就换个关键词（试试原名或英文名）',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 12)),
          const SizedBox(height: 12),
          if (!enabled)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('刮削未启用：请先在「设置 → 影片刮削」里填 TMDB API Key',
                  style:
                      TextStyle(color: GlassTheme.textSecondary, fontSize: 13)),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: GlassPanel(
                    radius: GlassTheme.radiusFull,
                    opacity: GlassTheme.glassLight,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      style: const TextStyle(
                          color: GlassTheme.textPrimary, fontSize: 14),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '输入片名',
                        hintStyle: TextStyle(
                            color: GlassTheme.textTertiary, fontSize: 14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GlassButton.filled(
                  label: '搜索',
                  onTap: _search,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_searching)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                    child: CircularProgressIndicator(
                        color: GlassTheme.accentPurple)),
              )
            else if (_searched && _results.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('没搜到，换个关键词试试',
                      style: TextStyle(
                          color: GlassTheme.textSecondary, fontSize: 13)),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => _buildRow(_results[i]),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildRow(ScrapeResult r) {
    final poster = r.posterThumbUrl;
    return InkWell(
      onTap: () => _pick(r),
      borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
      child: GlassPanel(
        radius: GlassTheme.radiusMd,
        opacity: GlassTheme.glassLight,
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: poster != null
                  ? ScrapedPoster(url: poster, width: 48, height: 72)
                  : Container(
                      width: 48,
                      height: 72,
                      color: Colors.black.withValues(alpha: 0.06),
                      child: const Icon(Icons.movie_rounded,
                          size: 20, color: GlassTheme.textTertiary),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title,
                      style: const TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (r.year != null) '${r.year}',
                      r.type == ScrapeType.tv ? '剧集' : '电影',
                      if (r.rating != null && r.rating! > 0)
                        '★ ${r.rating!.toStringAsFixed(1)}',
                    ].join(' · '),
                    style: const TextStyle(
                        color: GlassTheme.textTertiary, fontSize: 12),
                  ),
                  if (r.overview != null && r.overview!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(r.overview!,
                        style: const TextStyle(
                            color: GlassTheme.textSecondary, fontSize: 11),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: GlassTheme.textTertiary),
          ],
        ),
      ),
    );
  }
}
