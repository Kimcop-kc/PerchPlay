import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/constants/app_constants.dart';
import '../../core/responsive/breakpoints.dart';
import '../../services/device_info_service.dart';
import '../../services/rom_optimization_service.dart';
import '../../services/ipad_optimization_service.dart';
import '../../services/app_settings_service.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/safe_glass.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _settings = AppSettingsService.instance;

  @override
  void initState() {
    super.initState();
    _settings.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final device = DeviceInfoService.instance;
    final isLarge = AppBreakpoints.isLargeScreen(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            _buildHeader(),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: isLarge ? 40 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionHeader('播放'),
                    _buildPlaybackSettings(),
                    const SizedBox(height: 24),
                    _sectionHeader('界面'),
                    _buildUISettings(),
                    const SizedBox(height: 24),
                    if (device.brand.isChineseBrand)
                      _buildChineseRomOptimization(context, device),
                    if (device.isIPad)
                      _buildIPadFeatures(context),
                    const SizedBox(height: 24),
                    _sectionHeader('关于'),
                    _buildAbout(),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final topPad = MediaQuery.of(context).padding.top + 24;
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, topPad, 20, 20),
        child: const Text('设置',
            style: TextStyle(
                color: GlassTheme.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(title.toUpperCase(),
          style: const TextStyle(
              color: GlassTheme.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)),
    );
  }

  Widget _buildPlaybackSettings() {
    return GlassCard(
      radius: GlassTheme.radiusMd,
      tint: GlassTheme.tintPurple,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _settingRow(
            Icons.speed_rounded,
            '默认播放速度',
            trailing: Text('${_settings.defaultSpeed}x',
                style: const TextStyle(
                    color: GlassTheme.accentPurple,
                    fontWeight: FontWeight.w600)),
            onTap: () => _showSpeedPicker(),
          ),
          _divider(),
          _settingRow(
            Icons.fast_forward_rounded,
            '快进/快退秒数',
            trailing: Text('${_settings.skipSeconds}s',
                style: const TextStyle(color: GlassTheme.textTertiary)),
            onTap: () => _showSkipPicker(),
          ),
          _divider(),
          _settingSwitch(
            Icons.skip_next_rounded,
            '自动播放下一个',
            _settings.autoPlayNext,
            (v) => _settings.setAutoPlayNext(v).then((_) {
              if (mounted) setState(() {});
            }),
          ),
          _divider(),
          _settingSwitch(
            Icons.headphones_rounded,
            '后台播放',
            _settings.backgroundPlay,
            (v) => _settings.setBackgroundPlay(v).then((_) {
              if (mounted) setState(() {});
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildUISettings() {
    return GlassCard(
      radius: GlassTheme.radiusMd,
      tint: GlassTheme.tintTeal,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _settingRow(
            Icons.palette_rounded,
            '主题风格',
            trailing: _unsupportedTag('浅色玻璃'),
            onTap: () => _showComingSoon('主题风格'),
          ),
          _divider(),
          _settingRow(
            Icons.text_fields_rounded,
            '字幕样式',
            trailing: _unsupportedTag(null),
            onTap: () => _showComingSoon('字幕样式'),
          ),
          _divider(),
          _settingRow(
            Icons.language_rounded,
            '界面语言',
            trailing: _unsupportedTag('中文'),
            onTap: () => _showComingSoon('界面语言'),
          ),
        ],
      ),
    );
  }

  /// 未实现功能的禁用标签
  Widget _unsupportedTag(String? currentValue) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (currentValue != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(currentValue,
                style: const TextStyle(color: GlassTheme.textTertiary)),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.06),
            borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
          ),
          child: const Text('暂未支持',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 11)),
        ),
      ],
    );
  }

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('「$feature」暂未支持，敬请期待'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildChineseRomOptimization(
      BuildContext context, DeviceInfoService device) {
    final rom = RomOptimizationService.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('系统优化 (${device.brand.displayName})'),
        GlassCard(
          radius: GlassTheme.radiusMd,
          tint: const Color(0x14FF6B9D),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.battery_saver_rounded,
                      color: GlassTheme.accentPink, size: 18),
                  const SizedBox(width: 8),
                  const Text('电池优化白名单',
                      style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              Text(rom.batteryGuide,
                  style: const TextStyle(
                      color: GlassTheme.textSecondary, fontSize: 12, height: 1.4)),
              const SizedBox(height: 12),
              GlassButton.outlined(
                label: '去设置',
                height: 34,
                foregroundColor: GlassTheme.accentPink,
                onTap: () => rom.openBatterySettings(),
              ),
              const SizedBox(height: 12),
              if (device.brand.isXiaomi) ...[
                Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded,
                        color: GlassTheme.accentPink, size: 18),
                    const SizedBox(width: 8),
                    const Text('自启动管理',
                        style: TextStyle(
                            color: GlassTheme.textPrimary,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(rom.autoStartGuide,
                    style: const TextStyle(
                        color: GlassTheme.textSecondary, fontSize: 12, height: 1.4)),
                const SizedBox(height: 12),
                GlassButton.outlined(
                  label: '开启自启动',
                  height: 34,
                  foregroundColor: GlassTheme.accentPink,
                  onTap: () => rom.openAutoStartSettings(),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIPadFeatures(BuildContext context) {
    final iPad = IPadOptimizationService.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('iPad Pro 特性'),
        GlassCard(
          radius: GlassTheme.radiusMd,
          tint: GlassTheme.tintWhite,
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _ipadFeatureRow(
                  Icons.auto_awesome_mosaic_rounded, '台前调度 (Stage Manager)',
                  '已适配分屏/侧拉/全屏'),
              const SizedBox(height: 10),
              _ipadFeatureRow(
                  Icons.refresh_rounded, '120Hz ProMotion',
                  '流畅动画已锁定'),
              const SizedBox(height: 10),
              _ipadFeatureRow(
                  Icons.keyboard_rounded, '妙控键盘快捷键',
                  '空格/方向键/F/S/R/P/M 等'),
              const SizedBox(height: 10),
              _ipadFeatureRow(
                  Icons.edit_rounded, 'Apple Pencil 悬停',
                  'M2 芯片专属'),
              if (iPad.supportXDR)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _ipadFeatureRow(Icons.hdr_on_rounded, 'XDR HDR',
                      'Liquid Retina XDR'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ipadFeatureRow(IconData icon, String label, String detail) {
    return Row(
      children: [
        Icon(icon, size: 18, color: GlassTheme.accentTeal),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: GlassTheme.textPrimary, fontSize: 14)),
              Text(detail,
                  style: const TextStyle(
                      color: GlassTheme.textTertiary, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAbout() {
    return GlassCard(
      radius: GlassTheme.radiusMd,
      tint: GlassTheme.tintWhite,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  GlassTheme.accentPurple,
                  GlassTheme.accentTeal,
                ],
              ),
              borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
              boxShadow: [
                BoxShadow(
                  color: GlassTheme.accentPurple.withOpacity(0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(Icons.play_arrow_rounded,
                color: Colors.white, size: 28),
          ),
          const SizedBox(height: 12),
          const Text('VidFlow',
              style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('v${AppConstants.appVersion}',
              style: const TextStyle(color: GlassTheme.textTertiary, fontSize: 12)),
          const SizedBox(height: 6),
          Text(
            '${DeviceInfoService.instance.brand.displayName} · '
            '${DeviceInfoService.instance.isIPad ? "iPad" : "Phone"}',
            style: const TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ─── Setting Row Helpers ───

  Widget _settingRow(IconData icon, String title,
      {Widget? trailing, VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon, color: GlassTheme.textSecondary, size: 20),
      title: Text(title,
          style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 15)),
      trailing: trailing,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    );
  }

  Widget _settingSwitch(
      IconData icon, String title, bool value, ValueChanged<bool> onChanged) {
    return ListTile(
      leading: Icon(icon, color: GlassTheme.textSecondary, size: 20),
      title: Text(title,
          style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 15)),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: GlassTheme.accentPurple,
        inactiveThumbColor: GlassTheme.textTertiary,
        inactiveTrackColor: Colors.black.withOpacity(0.08),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    );
  }

  Widget _divider() {
    return Divider(
        height: 1, indent: 52, color: Colors.black.withOpacity(0.06));
  }

  void _showSpeedPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _pickerSheet(
        title: '播放速度',
        items: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
        current: _settings.defaultSpeed,
        onSelect: (v) => _settings.setDefaultSpeed(v).then((_) {
          if (mounted) setState(() {});
        }),
        format: (v) => '${v}x',
      ),
    );
  }

  void _showSkipPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _pickerSheet(
        title: '跳转秒数',
        items: [5, 10, 15, 30, 60],
        current: _settings.skipSeconds.toDouble(),
        onSelect: (v) => _settings.setSkipSeconds(v.toInt()).then((_) {
          if (mounted) setState(() {});
        }),
        format: (v) => '${v.toInt()}s',
      ),
    );
  }

  Widget _pickerSheet({
    required String title,
    required List<double> items,
    required double current,
    required void Function(double) onSelect,
    required String Function(double) format,
  }) {
    return ClipRRect(
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusXl)),
      child: SafeBackdropFilter(
        blurSigma: 24,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withOpacity(0.8),
                Colors.white.withOpacity(0.5),
              ],
            ),
            border: Border(
              top: BorderSide(color: Colors.black.withOpacity(0.06), width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: Colors.black.withOpacity(0.15),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(title,
                  style: const TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              ...items.map((v) {
                final isActive = v == current;
                return GlassButton(
                  label: format(v),
                  width: double.infinity,
                  height: 44,
                  ghost: true,
                  filled: false,
                  foregroundColor: isActive
                      ? GlassTheme.accentPurple
                      : GlassTheme.textPrimary,
                  onTap: () {
                    onSelect(v);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
