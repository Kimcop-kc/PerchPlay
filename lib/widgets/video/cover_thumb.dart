import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass_theme.dart';
import '../../models/video_model.dart';
import '../../providers/scrape_provider.dart';
import '../scrape/scrape_widgets.dart';

/// 视频封面：优先刮削海报，没有则用本地缩略图，都没有就是统一占位
///
/// 写成公共组件是为了让「首页卡片 / 播放列表 / 列表详情」三处用同一套回退
/// 规则。回退必须存在的原因：缩略图文件在系统清缓存后会消失，但数据库里的
/// 路径还在，这时直接 `Image.file` 只会渲染成**一片空白**。
class CoverThumb extends ConsumerWidget {
  final VideoModel video;
  final double width;
  final double height;
  final double radius;

  /// 占位图标大小（列表小图要小一点）
  final double iconSize;

  /// 缩略图解码宽度：不限制的话会按原分辨率解码，列表滚动时明显掉帧
  final int cacheWidth;

  const CoverThumb({
    super.key,
    required this.video,
    required this.width,
    required this.height,
    this.radius = 6,
    this.iconSize = 20,
    this.cacheWidth = 240,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posterUrl =
        ref.watch(scrapeProvider.select((s) => s.results[video.path]?.posterUrl));
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: posterUrl != null
            ? ScrapedPoster(
                url: posterUrl,
                fit: BoxFit.cover,
                fallback: _localThumb(),
              )
            : _localThumb(),
      ),
    );
  }

  Widget _localThumb() {
    final path = video.thumbnailPath;
    if (path.isEmpty || !File(path).existsSync()) {
      return _placeholder();
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() => Container(
        color: Colors.black.withOpacity(0.08),
        child: Center(
          child: Icon(Icons.movie_rounded,
              color: GlassTheme.textTertiary, size: iconSize),
        ),
      );
}
