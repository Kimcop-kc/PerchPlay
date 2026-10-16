import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/theme/glass_theme.dart';
import '../../models/video_model.dart';
import '../../providers/player_provider.dart';

/// 后台播放悬浮小窗
///
/// 显示视频实时画面 + 标题，点击返回播放器；
/// 按住向左/右滑出屏幕边缘即可关闭小窗并停止播放。
///
/// 注意：这个组件原来写在首页内部，所以只有「首页」tab 能看到它 ——
/// 切到文件夹/列表/历史/NAS/设置就"没有在播一样"。现在它挂在
/// AdaptiveScaffold 的外壳 Stack 上，属于所有 tab 共用的那一层。
class MiniPlayer extends StatefulWidget {
  final VideoModel video;
  final PlayerState playerState;
  final VoidCallback onTap;
  final VoidCallback onClose;

  /// 小窗实际占用的高度（卡片 56 + 底部间距 8），不含浮在导航栏之上的那段间隙。
  ///
  /// 外壳按这个值给页面内容补底部留白，否则小窗会盖住各页最后一行；
  /// 写在这里而不是外壳里，是为了让"小窗多高"只有一个来源，
  /// 改小窗尺寸时留白自动跟着变，不会漏改。
  static const double height = 64;

  const MiniPlayer({
    super.key,
    required this.video,
    required this.playerState,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<MiniPlayer> createState() => MiniPlayerState();
}

class MiniPlayerState extends State<MiniPlayer> {
  // 横向偏移（用于滑出动画）
  double _dx = 0;
  bool _dismissing = false;

  @override
  void didUpdateWidget(covariant MiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了视频必须重新显示：否则上一个视频关闭动画留下的 _dismissing=true
    // 会让新的小窗"存在但透明"，表现为"回到首页小窗没弹出来"
    if (oldWidget.video.id != widget.video.id) {
      _dismissing = false;
      _dx = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 视频画面 + 标题横向小长方形卡片
    return GestureDetector(
      onTap: widget.onTap,
      onHorizontalDragUpdate: (details) {
        setState(() => _dx += details.delta.dx);
      },
      onHorizontalDragEnd: (details) {
        final width = MediaQuery.of(context).size.width;
        // 滑出超过屏幕 1/3 则关闭
        if (_dx.abs() > width / 3) {
          _dismiss();
        } else {
          // 回弹
          setState(() => _dx = 0);
        }
      },
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: Opacity(
          opacity: _dismissing ? 0 : 1,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            height: 56,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
              border: Border.all(
                color: Colors.white.withOpacity(0.5),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                // 视频画面（横向小长方形）
                SizedBox(
                  width: 96,
                  height: 56,
                  child: Video(
                    controller: widget.playerState.videoController!,
                    fit: BoxFit.cover,
                    controls: NoVideoControls,
                  ),
                ),
                // 标题 + 关闭按钮
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.video.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // 关闭按钮
                        GestureDetector(
                          onTap: widget.onClose,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: GlassTheme.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _dismiss() {
    setState(() => _dismissing = true);
    // 动画完成后触发关闭
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) widget.onClose();
    });
  }
}
