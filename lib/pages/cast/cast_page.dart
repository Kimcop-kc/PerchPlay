import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../models/cast_device_model.dart';
import '../../providers/cast_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/common/app_page_header.dart';

/// 投屏页面 — iOS 27 玻璃质感
class CastPage extends ConsumerStatefulWidget {
  const CastPage({super.key});

  @override
  ConsumerState<CastPage> createState() => _CastPageState();
}

class _CastPageState extends ConsumerState<CastPage>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;

  /// 提前缓存 notifier：dispose 阶段访问 ref 会抛异常，
  /// 一旦抛出后面的 dispose 就都不会执行（原来动画控制器会永久泄漏，
  /// repeat(reverse: true) 一直跑 = 持续发热）
  late final CastNotifier _castNotifier;

  @override
  void initState() {
    super.initState();
    _castNotifier = ref.read(castProvider.notifier);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    Future.microtask(() => _castNotifier.startDiscovery());
  }

  @override
  void dispose() {
    // 控制器优先释放，随后再动 provider（不依赖 ref）
    _pulseController.dispose();
    try {
      _castNotifier.stopDiscovery();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    final isLarge = AppBreakpoints.isLargeScreen(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        // 与首页一致：内容铺到屏幕底，避免导航栏下方出现空白层
        bottom: false,
        child: Column(
          children: [
            if (castState.errorMessage != null)
              _buildErrorBanner(castState.errorMessage!),
            Expanded(
              child: isLarge
                  ? _buildTabletLayout(castState)
                  : _buildMobileLayout(castState),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: GlassTheme.accentPink.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
        border: Border.all(
            color: GlassTheme.accentPink.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: GlassTheme.accentPink, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    color: GlassTheme.textPrimary, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // ═══════════════ 手机 ═══════════════

  Widget _buildMobileLayout(CastState state) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      switchInCurve: GlassCurves.iosDecelerate,
      switchOutCurve: Curves.easeIn,
      child: state.isConnected && state.activeDevice != null
          ? _buildConnectedPanel(state)
          // 没有设备时不显示顶部扫描条，整块内容居中（含扫描状态与重新搜索）
          : state.devices.isEmpty
              ? _buildEmptyDeviceList(state)
              : Column(
                  children: [
                    _buildScanHeader(state),
                    Expanded(child: _buildDeviceList(state)),
                  ],
                ),
    );
  }

  // ═══════════════ 平板双栏 ═══════════════

  Widget _buildTabletLayout(CastState state) {
    return Row(
      children: [
        SizedBox(
          width: 340,
          child: Column(
            children: [
              _buildTabletTitle(),
              _buildScanHeader(state),
              Expanded(child: _buildDeviceList(state)),
            ],
          ),
        ),
        const VerticalDivider(width: 0.5, color: Color(0x14000000)),
        Expanded(
          child: state.isConnected && state.activeDevice != null
              ? _buildConnectedPanel(state)
              : _buildEmptyDetail(),
        ),
      ],
    );
  }

  Widget _buildTabletTitle() {
    // 平板侧栏 340px 用紧凑标题；手机全宽用 AppPageHeader 大标题
    final isLarge = AppBreakpoints.isLargeScreen(context);
    if (isLarge) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(
          '投屏',
          style: TextStyle(
            color: GlassTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return const AppPageHeader(
      title: '投屏',
      subtitle: '搜索并连接局域网设备',
      asSliver: false,
      childGap: 8,
    );
  }

  // ═══════════════ 扫描头 ═══════════════

  Widget _buildScanHeader(CastState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: GlassCard(
        radius: GlassTheme.radiusSm,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        tint: GlassTheme.tintPurple,
        child: Row(
          children: [
            GlassAnimatedBuilder(
              listenable: _pulseController,
              builder: (_, child) => Icon(
                Icons.sensors_rounded,
                color: state.isDiscovering
                    ? GlassTheme.accentPurple
                        .withValues(alpha: 0.4 + _pulseController.value * 0.6)
                    : GlassTheme.textTertiary,
                size: 20,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              state.isDiscovering ? '扫描中...' : '就绪',
              style: TextStyle(
                color: state.isDiscovering
                    ? GlassTheme.accentPurple
                    : GlassTheme.textTertiary,
                fontSize: 12,
              ),
            ),
            const Spacer(),
            GlassButton(
              icon: Icons.refresh_rounded,
              compact: true,
              ghost: true,
              foregroundColor: GlassTheme.textTertiary,
              onTap: () => ref.read(castProvider.notifier).refresh(),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════ 设备列表 ═══════════════

  /// 无设备时的居中空状态（扫描状态 + 重新搜索）
  Widget _buildEmptyDeviceList(CastState state) {
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.isDiscovering)
              const SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                    strokeWidth: 3, color: GlassTheme.accentPurple),
              )
            else
              const Icon(Icons.cast_rounded,
                  size: 48, color: GlassTheme.textTertiary),
            const SizedBox(height: 14),
            Text(
              state.isDiscovering ? '正在搜索投屏设备…' : '未发现投屏设备',
              style: const TextStyle(
                  color: GlassTheme.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 6),
            const Text('请确保设备与手机在同一 Wi-Fi 网络',
                textAlign: TextAlign.center,
                style: TextStyle(color: GlassTheme.textTertiary, fontSize: 12)),
            const SizedBox(height: 18),
            GlassButton.outlined(
              icon: Icons.refresh_rounded,
              label: '重新搜索',
              foregroundColor: GlassTheme.accentPurple,
              onTap: () => ref.read(castProvider.notifier).refresh(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceList(CastState state) {
    if (state.devices.isEmpty) {
      return Center(
        child: GlassPanel(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cast_rounded,
                  size: 48, color: GlassTheme.textTertiary),
              const SizedBox(height: 12),
              Text(
                state.isDiscovering ? '搜索中...' : '未发现投屏设备',
                style: const TextStyle(color: GlassTheme.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 6),
              const Text('请确保设备在同一 Wi-Fi 网络',
                  style:
                      TextStyle(color: GlassTheme.textTertiary, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    final dlna =
        state.devices.where((d) => d.protocol == CastProtocol.dlna).toList();
    final chromecast = state.devices
        .where((d) => d.protocol == CastProtocol.chromecast)
        .toList();
    final airplay =
        state.devices.where((d) => d.protocol == CastProtocol.airplay).toList();
    final others = state.devices
        .where((d) =>
            d.protocol == CastProtocol.unknown ||
            d.protocol == CastProtocol.miracast)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, GlassTheme.navBarOverlay),
      children: [
        if (dlna.isNotEmpty) ...[
          _sectionHeader('DLNA / UPnP'),
          ...dlna.map((d) => _deviceTile(state, d)),
        ],
        if (chromecast.isNotEmpty) ...[
          _sectionHeader('Chromecast'),
          ...chromecast.map((d) => _deviceTile(state, d)),
        ],
        if (airplay.isNotEmpty) ...[
          _sectionHeader('AirPlay'),
          ...airplay.map((d) => _deviceTile(state, d)),
        ],
        if (others.isNotEmpty) ...[
          _sectionHeader('其他设备'),
          ...others.map((d) => _deviceTile(state, d)),
        ],
      ],
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
      child: Text(title,
          style: const TextStyle(
              color: GlassTheme.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)),
    );
  }

  Widget _deviceTile(CastState state, CastDevice device) {
    final isActive = state.activeDevice?.id == device.id;
    final isConnecting = device.status == CastDeviceStatus.connecting;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassCard(
        radius: GlassTheme.radiusSm,
        padding: const EdgeInsets.all(12),
        selected: isActive,
        tint: isActive ? GlassTheme.tintPurple : GlassTheme.tintWhite,
        onTap: () {
          if (!isActive) ref.read(castProvider.notifier).connect(device);
        },
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    (isActive
                            ? GlassTheme.accentPurple
                            : Colors.black.withValues(alpha: 0.08))
                        .withValues(alpha: 0.2),
                    (isActive
                            ? GlassTheme.accentPurple
                            : Colors.black.withValues(alpha: 0.04))
                        .withValues(alpha: 0.06),
                  ],
                ),
                borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
              ),
              child: Icon(_protocolIcon(device.protocol),
                  color: isActive
                      ? GlassTheme.accentPurple
                      : GlassTheme.textSecondary,
                  size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: GlassTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 2),
                  Text('${device.protocol.name.toUpperCase()} · ${device.host}',
                      style: const TextStyle(
                          color: GlassTheme.textTertiary, fontSize: 11)),
                ],
              ),
            ),
            if (isConnecting)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: GlassTheme.accentPurple),
              )
            else if (isActive)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      GlassTheme.accentPurple.withValues(alpha: 0.2),
                      GlassTheme.accentTeal.withValues(alpha: 0.1),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
                ),
                child: const Text('已连接',
                    style: TextStyle(
                        color: GlassTheme.accentPurple,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  // ═══════════════ 已连接面板 ═══════════════

  Widget _buildConnectedPanel(CastState state) {
    final device = state.activeDevice!;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 大图标
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  GlassTheme.accentPurple.withValues(alpha: 0.2),
                  GlassTheme.accentTeal.withValues(alpha: 0.08),
                ],
              ),
              border: Border.all(
                color: GlassTheme.accentPurple.withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: GlassTheme.accentPurple.withValues(alpha: 0.2),
                  blurRadius: 20,
                ),
              ],
            ),
            child: Icon(_protocolIcon(device.protocol),
                size: 40, color: GlassTheme.accentPurple),
          ),
          const SizedBox(height: 20),
          Text(device.name,
              style: const TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('${device.protocol.name.toUpperCase()} · ${device.host}',
              style: const TextStyle(
                  color: GlassTheme.textTertiary, fontSize: 13)),
          const SizedBox(height: 30),
          // 控制按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _controlButton(
                icon: state.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                label: state.isPlaying ? '暂停' : '播放',
                onTap: state.isPlaying
                    ? () => ref.read(castProvider.notifier).pause()
                    : () => ref.read(castProvider.notifier).resume(),
              ),
              const SizedBox(width: 20),
              _controlButton(
                icon: Icons.stop_rounded,
                label: '停止',
                onTap: () => ref.read(castProvider.notifier).stop(),
              ),
              const SizedBox(width: 20),
              _controlButton(
                icon: Icons.link_off_rounded,
                label: '断开',
                color: GlassTheme.accentPink,
                onTap: () => ref.read(castProvider.notifier).disconnect(),
              ),
            ],
          ),
          const SizedBox(height: 30),
          // ── 音量 + 进度（M05 音量接口的 UI 入口，闭环「视频→投屏→音量」）──
          _buildRemoteControls(state),
          const SizedBox(height: 20),
          // 提示
          GlassPanel(
            radius: GlassTheme.radiusSm,
            padding: const EdgeInsets.all(14),
            child: Text(
              '在播放器页面点击投屏按钮即可将当前视频投射到 ${device.name}',
              style: const TextStyle(
                  color: GlassTheme.textTertiary, fontSize: 13, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  /// 投屏遥控：音量滑条 + 进度拖动。
  Widget _buildRemoteControls(CastState state) {
    // 进度目标只作为本地提示态，拖动结束才下发 Seek（避免每帧都打 SOAP）
    return GlassPanel(
      radius: GlassTheme.radiusSm,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.volume_down_rounded,
                  color: GlassTheme.textTertiary, size: 20),
              Expanded(
                child: Slider(
                  value: state.volume.toDouble().clamp(0, 100),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${state.volume}',
                  onChanged: (v) {
                    // 拖动过程只更新本地显示，不逐帧发命令
                    ref.read(castProvider.notifier).setVolume(v.round());
                  },
                ),
              ),
              const Icon(Icons.volume_up_rounded,
                  color: GlassTheme.textTertiary, size: 20),
            ],
          ),
          const SizedBox(height: 4),
          // 进度条：DLNA 没有查询当前位置的标准可靠接口，这里做成
          // 「快退/快进」步进按钮，避免假进度条误导用户。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _miniButton(
                icon: Icons.replay_10_rounded,
                label: '-10s',
                onTap: () => _seekRelative(-10),
              ),
              const SizedBox(width: 12),
              _miniButton(
                icon: Icons.forward_10_rounded,
                label: '+10s',
                onTap: () => _seekRelative(10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 相对快进/快退：从本地记录的位置偏移后下发 Seek。
  void _seekRelative(int deltaSeconds) {
    final cast = ref.read(castProvider);
    final cur = cast.seekPosition;
    final target = (cur + deltaSeconds).clamp(0, 24 * 3600);
    ref.read(castProvider.notifier).seek(target);
    // 本地同步进度提示（无真实当前位置源时用「已下发目标」代替）
    _safeSyncSeek(target);
  }

  void _safeSyncSeek(int target) {
    try {
      ref.read(castProvider.notifier).setSeekPosition(target);
    } catch (_) {}
  }

  Widget _miniButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GlassButton(
      icon: icon,
      label: label,
      compact: true,
      ghost: true,
      height: 32,
      onTap: onTap,
    );
  }

  Widget _buildEmptyDetail() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cast_connected_rounded,
              size: 48, color: GlassTheme.textTertiary),
          SizedBox(height: 12),
          Text('选择左侧设备开始投屏',
              style: TextStyle(color: GlassTheme.textSecondary, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = GlassTheme.accentPurple,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: GlassCurves.iosDecelerate,
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0.18),
                  color.withValues(alpha: 0.06)
                ],
              ),
              border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style:
                const TextStyle(color: GlassTheme.textTertiary, fontSize: 11)),
      ],
    );
  }

  IconData _protocolIcon(CastProtocol protocol) {
    switch (protocol) {
      case CastProtocol.dlna:
        return Icons.tv_rounded;
      case CastProtocol.chromecast:
        return Icons.cast_rounded;
      case CastProtocol.airplay:
        return Icons.phone_iphone_rounded;
      case CastProtocol.miracast:
        return Icons.screen_share_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }
}
