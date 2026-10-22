/// 全局「正在播放视频」标志。
///
/// 为什么单独做一个静态标志而不是让缩略图/刮削 provider 直接 watch
/// playerProvider：
/// - 缩略图/刮削是后台任务，跑在自己的 async 循环里，不适合每轮都去
///   read 一个 Riverpod provider（会有生命周期和重建耦合）；
/// - 播放状态只有「在播 / 不在播」两个值，用一个 volatile 静态 bool
///   足够，player_provider 在 playing 流变化时更新它。
///
/// 用途：播放视频时暂停缩略图解码、TMDB 刮削等吃 CPU/网络的低优先级
/// 后台任务，把资源让给播放器，避免「播着播着突然卡一下」。
class PlaybackBusy {
  PlaybackBusy._();

  /// 当前是否正在播放视频（播放中 = true，暂停/停止 = false）。
  static bool playing = false;
}
