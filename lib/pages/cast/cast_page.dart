import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../models/cast_device_model.dart';
import '../../providers/cast_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';

/// 投屏页面 — iOS 27 玻璃质感
class CastPage extends ConsumerStatefulWidget {
  const CastPage({super.key});

  @override
  ConsumerState<CastPage> createState() => _CastPageState();
}

class _CastPageState extends ConsumerState<CastPage>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    Future.microtask(
        () => ref.read(castProvider.notifier).startDiscovery());
  }

  @override
  void dispose() {
    ref.read(castProvider.notifier).stopDiscovery();
    _pulseController.dispose();
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
        color: GlassTheme.accentPink.withOpacity(0.12),
        borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
        border: Border.all(
            color: GlassTheme.accentPink.withOpacity(0.3), width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: GlassTheme.accentPink, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 13)),
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
    final topPad = MediaQuery.of(context).padding.top + 20;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, topPad, 20, 8),
      child: const Align(
        alignment: Alignment.centerLeft,
        child: Text('投屏',
            style: TextStyle(
                color: GlassTheme.textPrimary,
                fontSize: 26,
                fontWeight: FontWeight.w800)),
      ),
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
                        .withOpacity(0.4 + _pulseController.value * 0.6)
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

  Widget _buildDeviceList(CastState state) {
    if (state.devices.isEmpty) {
      return Center(
        child: GlassPanel(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cast_rounded, size: 48, color: GlassTheme.textTertiary),
              const SizedBox(height: 12),
              Text(
                state.isDiscovering ? '搜索中...' : '未发现投屏设备',
                style: TextStyle(color: GlassTheme.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 6),
              const Text('请确保设备在同一 Wi-Fi 网络',
                  style: TextStyle(color: GlassTheme.textTertiary, fontSize: 12)),
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
    final airplay = state.devices
        .where((d) => d.protocol == CastProtocol.airplay)
        .toList();
    final others = state.devices
        .where((d) =>
            d.protocol == CastProtocol.unknown ||
            d.protocol == CastProtocol.miracast)
        .toList();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
                            : Colors.black.withOpacity(0.08))
                        .withOpacity(0.2),
                    (isActive
                            ? GlassTheme.accentPurple
                            : Colors.black.withOpacity(0.04))
                        .withOpacity(0.06),
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
                  Text(
                      '${device.protocol.name.toUpperCase()} · ${device.host}',
                      style:
                          const TextStyle(color: GlassTheme.textTertiary, fontSize: 11)),
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
                      GlassTheme.accentPurple.withOpacity(0.2),
                      GlassTheme.accentTeal.withOpacity(0.1),
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
                  GlassTheme.accentPurple.withOpacity(0.2),
                  GlassTheme.accentTeal.withOpacity(0.08),
                ],
              ),
              border: Border.all(
                color: GlassTheme.accentPurple.withOpacity(0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: GlassTheme.accentPurple.withOpacity(0.2),
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
              style: const TextStyle(color: GlassTheme.textTertiary, fontSize: 13)),
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

  Widget _buildEmptyDetail() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cast_connected_rounded, size: 48, color: GlassTheme.textTertiary),
          const SizedBox(height: 12),
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
                colors: [color.withOpacity(0.18), color.withOpacity(0.06)],
              ),
              border: Border.all(color: color.withOpacity(0.3), width: 1),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: GlassTheme.textTertiary, fontSize: 11)),
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
