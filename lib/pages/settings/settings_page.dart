import 'dart:async';
import 'dart:io' show File, Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/system/system_ui_policy.dart';
import '../../services/device_info_service.dart';
import '../../services/log_service.dart';
import '../../services/rom_optimization_service.dart';
import '../../services/ipad_optimization_service.dart';
import '../../services/app_settings_service.dart';
import '../../services/hdr_output_mode.dart';
import '../../services/storage_manager.dart';
import '../../services/library_prune_service.dart';
import '../../services/update_service.dart';
import '../../services/app_version.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/ui_settings_provider.dart';
import '../../providers/scrape_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/safe_glass.dart';
import '../../widgets/common/app_page_header.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _settings = AppSettingsService.instance;
  late final TextEditingController _tmdbController;

  @override
  void initState() {
    super.initState();
    _tmdbController = TextEditingController(text: _settings.tmdbApiKey);
    _settings.ensureLoaded().then((_) {
      // ensureLoaded 可能从 SharedPreferences 读到比 init 时的默认值更新的 apiKey
      if (mounted && _tmdbController.text != _settings.tmdbApiKey) {
        _tmdbController.text = _settings.tmdbApiKey;
        setState(() {});
      } else if (mounted) {
        setState(() {});
      }
      // 清理隐藏名单里已不存在的僵尸路径，避免「已隐藏的视频（N 个）」虚高
      _pruneHiddenVideos();
    });
  }

  /// 清理隐藏名单里磁盘上已不存在的路径（后台执行，不阻塞设置页）。
  ///
  /// 注意：网络来源（smb/http/云盘/UNC）的路径**必须跳过** ——
  /// `File().existsSync()` 对它们恒为 false，会把合法的隐藏项误删，
  /// 导致下次扫描又把视频写回影库（用户以为「隐藏失效」）。
  Future<void> _pruneHiddenVideos() async {
    try {
      final removed = await _settings.pruneMissingHiddenVideos(
        (path) async {
          if (LibraryPruneService.isRemotePath(path)) return true; // 视为存在
          return File(path).existsSync();
        },
      );
      if (removed > 0 && mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _tmdbController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final device = DeviceInfoService.instance;
    final isLarge = AppBreakpoints.isLargeScreen(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        // 与首页一致：内容铺到屏幕底，避免导航栏下方出现空白层
        bottom: false,
        child: CustomScrollView(
          slivers: [
            _buildHeader(),
            SliverToBoxAdapter(
              child: Center(
                // 平板限宽：内容最大 720px，避免设置卡片铺满整个平板宽度
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: isLarge ? 40 : 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionHeader('播放'),
                        _buildPlaybackSettings(),
                        const SizedBox(height: 24),
                        _sectionHeader('刮削 (TMDB)'),
                        _buildScrapeSettings(),
                        const SizedBox(height: 24),
                        _sectionHeader('界面'),
                        _buildUISettings(),
                        const SizedBox(height: 24),
                        _sectionHeader('影库'),
                        _buildLibrarySettings(),
                        const SizedBox(height: 24),
                        _sectionHeader('存储与缓存'),
                        _buildStorageSettings(),
                        const SizedBox(height: 24),
                        if (device.brand.isChineseBrand)
                          _buildChineseRomOptimization(context, device),
                        if (device.isIPad) _buildIPadFeatures(context),
                        const SizedBox(height: 24),
                        _sectionHeader('关于'),
                        _buildAbout(),
                        const SizedBox(height: GlassTheme.navBarOverlay),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    // 与所有 tab 页统一：同一个留白/字号规格，切 tab 不跳
    return const AppPageHeader(
      title: '设置',
      subtitle: '播放、字幕、存储与外观',
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
            Icons.touch_app_rounded,
            '长按倍速',
            trailing: Text('${_settings.longPressSpeed}x',
                style: const TextStyle(
                    color: GlassTheme.accentPurple,
                    fontWeight: FontWeight.w600)),
            onTap: () => _showLongPressSpeedPicker(),
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
          _divider(),
          // 解码方式：硬解（省电、4K 流畅）/ 软解（兼容花屏、黑屏的机型）
          _settingSwitch(
            Icons.memory_rounded,
            '硬件解码',
            _settings.hardwareDecoding,
            (v) => _settings.setHardwareDecoding(v).then((_) {
              // 立即对当前播放器生效
              ref.read(playerProvider.notifier).applyDecodingMode();
              if (mounted) setState(() {});
            }),
          ),
          // 硬件解码的说明小字，紧跟在其下方
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '遇到花屏 / 黑屏 / 无法播放时，可关闭硬件解码改用软件解码',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
            ),
          ),
          _divider(),
          _settingRow(
            Icons.screen_rotation_rounded,
            '打开视频方向',
            trailing: Text(_playerOrientationLabel(_settings.playerOrientation),
                style: const TextStyle(
                    color: GlassTheme.accentPurple,
                    fontWeight: FontWeight.w600)),
            onTap: () => _showPlayerOrientationPicker(),
          ),
          _divider(),
          // HDR 输出模式：走 gpu-next + hdr-toys，需要自建 libmpv
          _settingRow(
            Icons.hdr_strong_rounded,
            'HDR 输出模式',
            trailing: Text(
                HdrOutputModeX.fromId(_settings.hdrOutputMode).shortLabel,
                style: const TextStyle(
                    color: GlassTheme.accentPurple,
                    fontWeight: FontWeight.w600)),
            onTap: () => _showHdrOutputModePicker(),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '非「关闭」档会改用 GPU-Next 渲染管线做 HDR 直通，'
              '需要安装带 libplacebo 的构建版本；切换会重建渲染器，画面闪一下是正常的',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  /// 选择 HDR 输出模式。
  ///
  /// 切换会经 `PlayerNotifier.setHdrOutputMode` 重建 VideoController
  /// （vo 从 gpu 换成 gpu-next），因此会短暂黑屏 —— 选项说明里已写明。
  void _showHdrOutputModePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _hdrOutputModeSheet(
        current: _settings.hdrOutputMode,
        onSelect: (id) async {
          final mode = HdrOutputModeX.fromId(id);
          if (mounted) setState(() {});
          await ref.read(playerProvider.notifier).setHdrOutputMode(mode);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Widget _hdrOutputModeSheet({
    required String current,
    required Future<void> Function(String) onSelect,
  }) {
    final bottomInset =
        SystemUiPolicy.bottomSheetInset(MediaQuery.of(context)) + 96;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
          top: Radius.circular(GlassTheme.radiusXl)),
      child: SafeBackdropFilter(
        blurSigma: 24,
        child: Container(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset),
          decoration: const BoxDecoration(
            color: GlassTheme.bgRaised,
            borderRadius: BorderRadius.vertical(
                top: Radius.circular(GlassTheme.radiusXl)),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: GlassTheme.textTertiary.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: Text('HDR 输出模式',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
                for (final m in HdrOutputMode.values)
                  _hdrOptionTile(
                    mode: m,
                    selected: m.id == current,
                    onTap: () async {
                      Navigator.of(context).pop();
                      await onSelect(m.id);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hdrOptionTile({
    required HdrOutputMode mode,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? GlassTheme.accentPurple.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
              border: Border.all(
                color: selected
                    ? GlassTheme.accentPurple.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mode.label,
                          style: TextStyle(
                              color: selected
                                  ? GlassTheme.accentPurple
                                  : GlassTheme.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(mode.description,
                          style: const TextStyle(
                              color: GlassTheme.textTertiary, fontSize: 11)),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_circle_rounded,
                      color: GlassTheme.accentPurple, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 影库维护：隐藏名单的恢复入口
  ///
  /// 「仅从影库移除（保留文件）」会把路径记进隐藏名单（否则下次扫描又写回来），
  /// 没有这个入口，用户误点一次就永远找不回来了 —— 这是可逆性的唯一出口。
  Widget _buildLibrarySettings() {
    final hiddenCount = _settings.hiddenVideoCount;
    return GlassCard(
      radius: GlassTheme.radiusMd,
      tint: GlassTheme.tintPink,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _settingRow(
            Icons.visibility_off_rounded,
            '已隐藏的视频（$hiddenCount 个）',
            trailing: hiddenCount == 0
                ? const Text('无',
                    style:
                        TextStyle(color: GlassTheme.textTertiary, fontSize: 13))
                : GlassButton.outlined(
                    label: '全部恢复',
                    height: 32,
                    foregroundColor: GlassTheme.accentTeal,
                    onTap: _restoreHiddenVideos,
                  ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '「仅从影库移除（保留文件）」的视频记在这里。'
              '恢复后会立即重扫，把它们放回影库。',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreHiddenVideos() async {
    final count = _settings.hiddenVideoCount;
    await _settings.restoreHiddenVideos();
    if (!mounted) return;
    setState(() {});
    // 立刻重扫：用户点「全部恢复」就是想看到它们回来，不该再等下次冷启动。
    // 不 await —— 扫描要遍历目录，设置页不能被它卡住。
    unawaited(ref.read(libraryProvider.notifier).scan());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已恢复 $count 个视频，正在重新扫描影库'),
        duration: const Duration(seconds: 3),
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
            trailing: const Icon(Icons.chevron_right,
                color: GlassTheme.textTertiary, size: 20),
            onTap: () => _showSubtitleStyleSheet(context),
          ),
          _divider(),
          _settingRow(
            Icons.language_rounded,
            '界面语言',
            trailing: _unsupportedTag('中文'),
            onTap: () => _showComingSoon('界面语言'),
          ),
          _divider(),
          // 液态玻璃实时模糊：默认开启（观感核心）。
          // 低端机 / 发烫时关掉可省电，属于用户自选，不是性能优化的手段。
          _settingSwitch(
            Icons.blur_on_rounded,
            '液态玻璃实时模糊',
            ref.watch(glassBlurProvider),
            (v) {
              // 立即生效（provider）+ 持久化（设置服务）
              ref.read(glassBlurProvider.notifier).state = v;
              _settings.setGlassBlur(v);
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '只影响是否对背后内容做实时模糊，导航栏外观不变。'
              '关闭可省电、防止低端机发烫。',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
            ),
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
            color: Colors.black.withValues(alpha: 0.06),
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
              const Row(
                children: [
                  Icon(Icons.battery_saver_rounded,
                      color: GlassTheme.accentPink, size: 18),
                  SizedBox(width: 8),
                  Text('电池优化白名单',
                      style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              Text(rom.batteryGuide,
                  style: const TextStyle(
                      color: GlassTheme.textSecondary,
                      fontSize: 12,
                      height: 1.4)),
              const SizedBox(height: 12),
              GlassButton.outlined(
                label: '去设置',
                height: 34,
                foregroundColor: GlassTheme.accentPink,
                onTap: () => rom.openBatterySettings(),
              ),
              const SizedBox(height: 12),
              if (device.brand.isXiaomi) ...[
                const Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded,
                        color: GlassTheme.accentPink, size: 18),
                    SizedBox(width: 8),
                    Text('自启动管理',
                        style: TextStyle(
                            color: GlassTheme.textPrimary,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(rom.autoStartGuide,
                    style: const TextStyle(
                        color: GlassTheme.textSecondary,
                        fontSize: 12,
                        height: 1.4)),
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
              _ipadFeatureRow(Icons.auto_awesome_mosaic_rounded,
                  '台前调度 (Stage Manager)', '已适配分屏/侧拉/全屏'),
              const SizedBox(height: 10),
              _ipadFeatureRow(
                  Icons.refresh_rounded, '120Hz ProMotion', '流畅动画已锁定'),
              const SizedBox(height: 10),
              _ipadFeatureRow(
                  Icons.keyboard_rounded, '妙控键盘快捷键', '空格/方向键/F/S/R/P/M 等'),
              const SizedBox(height: 10),
              _ipadFeatureRow(Icons.edit_rounded, 'Apple Pencil 悬停', 'M2 芯片专属'),
              if (iPad.supportXDR)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _ipadFeatureRow(
                      Icons.hdr_on_rounded, 'XDR HDR', 'Liquid Retina XDR'),
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

  Widget _buildScrapeSettings() {
    final apiKey = _settings.tmdbApiKey;
    final isEnabled = apiKey.isNotEmpty;
    return GlassCard(
      radius: GlassTheme.radiusMd,
      tint: const Color(0x1400D474),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.movie_filter_rounded,
                  color: GlassTheme.accentTeal, size: 20),
              const SizedBox(width: 8),
              const Text('TMDB 刮削',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              if (isEnabled)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: GlassTheme.accentTeal.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
                  ),
                  child: const Text('已启用',
                      style: TextStyle(
                          color: GlassTheme.accentTeal,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
                  ),
                  child: const Text('未启用',
                      style: TextStyle(
                          color: GlassTheme.textTertiary, fontSize: 11)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '扫描视频后自动匹配 TMDB 海报、简介、评分。\n'
            '去 themoviedb.org 免费申请即可拿到凭证。\n'
            '「API 密钥 (v3 auth)」和「API 读访问令牌」都支持，粘哪个都能用。',
            style: TextStyle(
                color: GlassTheme.textSecondary, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tmdbController,
                  obscureText: true,
                  obscuringCharacter: '\u2022',
                  style: const TextStyle(
                      fontSize: 13, color: GlassTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: isEnabled
                        ? '\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022'
                        : '粘贴 TMDB API Key 或 读访问令牌',
                    hintStyle: const TextStyle(
                        fontSize: 12, color: GlassTheme.textTertiary),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                      borderSide: BorderSide(
                          color: Colors.black.withValues(alpha: 0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                      borderSide: BorderSide(
                          color: Colors.black.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                      borderSide:
                          const BorderSide(color: GlassTheme.accentTeal),
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.5),
                  ),
                  onChanged: (v) {
                    _settings.setTmdbApiKey(v.trim());
                    if (v.trim().isNotEmpty) {
                      ref.read(scrapeProvider.notifier).enable(v.trim());
                    } else {
                      ref.read(scrapeProvider.notifier).disable();
                    }
                    if (mounted) setState(() {});
                  },
                ),
              ),
              if (apiKey.isNotEmpty) ...[
                const SizedBox(width: 8),
                GlassButton.outlined(
                  label: '清除',
                  height: 36,
                  foregroundColor: GlassTheme.accentPink,
                  onTap: () {
                    _settings.setTmdbApiKey('');
                    _tmdbController.clear();
                    ref.read(scrapeProvider.notifier).disable();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 存储与缓存：展示各类数据占用并可清理。
  Widget _buildStorageSettings() {
    return GlassCard(
      radius: GlassTheme.radiusMd,
      tint: GlassTheme.tintWhite,
      padding: const EdgeInsets.all(12),
      child: FutureBuilder<List<StorageItem>>(
        future: StorageManager.instance.scan(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GlassTheme.accentPurple,
                  ),
                ),
              ),
            );
          }
          final items = snapshot.data ?? const <StorageItem>[];
          if (items.isEmpty) {
            return const Text('暂无缓存数据',
                style: TextStyle(color: GlassTheme.textTertiary, fontSize: 13));
          }
          return Column(
            children: [
              for (final item in items) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    item.canClear
                        ? Icons.folder_open_rounded
                        : Icons.storage_rounded,
                    color: item.canClear
                        ? GlassTheme.accentTeal
                        : GlassTheme.textTertiary,
                    size: 20,
                  ),
                  title: Text(
                    item.label,
                    style: const TextStyle(
                        color: GlassTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    item.description,
                    style: const TextStyle(
                        color: GlassTheme.textTertiary, fontSize: 11),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        StorageManager.instance.formatSize(item.sizeBytes),
                        style: const TextStyle(
                            color: GlassTheme.textSecondary, fontSize: 13),
                      ),
                      if (item.canClear) ...[
                        const SizedBox(width: 8),
                        GlassButton.outlined(
                          label: '清理',
                          height: 30,
                          foregroundColor: GlassTheme.accentPink,
                          onTap: () => _confirmClearStorage(item),
                        ),
                      ],
                    ],
                  ),
                ),
                if (item != items.last)
                  const Divider(height: 1, color: Color(0x1A000000)),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmClearStorage(StorageItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GlassTheme.bg.withValues(alpha: 0.95),
        title: Text('清理「${item.label}」？'),
        content: Text(
          '将释放 ${StorageManager.instance.formatSize(item.sizeBytes)}。\n${item.description}',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: GlassTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理',
                style: TextStyle(color: GlassTheme.accentPink)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await StorageManager.instance.clearItem(item.id);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已清理「${item.label}」'),
          backgroundColor: GlassTheme.accentTeal,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 「字幕样式」面板：字号 / 位置 / 背景 / 颜色 / 字体 / 对齐 / 双语样式。
  void _showSubtitleStyleSheet(BuildContext context) {
    final s = AppSettingsService.instance;

    // 状态放在 Sheet 外：每次 setState 重建时不会把用户的改动冲掉
    double fontSize = s.subtitleFontSize;
    double position = s.subtitlePosition;
    double bgOpacity = s.subtitleBgOpacity;
    int textColor = s.subtitleTextColorValue;
    bool stroke = s.subtitleStroke;
    double secScale = s.subtitleSecondaryScale;
    bool secDim = s.subtitleSecondaryDim;
    String fontFamily = s.subtitleFontFamily;
    int fontWeightIdx = s.subtitleFontWeight;
    double lineSpacing = s.subtitleLineSpacing;
    double lineHeight = s.subtitleLineHeight;
    double bgRadius = s.subtitleBgRadius;
    int bgColor = s.subtitleBgColorValue;
    bool showBg = s.subtitleShowBg;
    String align = s.subtitleAlign;
    bool useAssPos = s.subtitleUseAssPosition;

    const colorOptions = <(int, String, Color)>[
      (0xFFFFFFFF, '白色', Colors.white),
      (0xFFFFEB3B, '黄色', Color(0xFFFFEB3B)),
      (0xFF80DEEA, '青色', Color(0xFF80DEEA)),
      (0xFFFFB74D, '橙色', Color(0xFFFFB74D)),
      (0xFF81C784, '绿色', Color(0xFF81C784)),
    ];

    // 内置字体（Android/iOS 系统自带的通用中英文字体族）
    const fontOptions = <(String, String)>[
      ('system', '系统默认'),
      ('sans-serif', '无衬线'),
      ('sans-serif-medium', '无衬线中等'),
      ('sans-serif-condensed', '窄体'),
      ('serif', '衬线'),
      ('monospace', '等宽'),
      ('Noto Sans CJK SC', '思源黑体'),
      ('Noto Serif CJK SC', '思源宋体'),
    ];

    // 背景色选项
    const bgColorOptions = <(int, String, Color)>[
      (0xFF000000, '黑色', Colors.black),
      (0xFF1A1A2E, '深蓝黑', Color(0xFF1A1A2E)),
      (0xFF2D2D2D, '深灰', Color(0xFF2D2D2D)),
    ];

    // 字体粗细选项
    const weightOptions = <(int, String, FontWeight)>[
      (3, '细', FontWeight.w300),
      (4, '常规', FontWeight.w400),
      (5, '中等', FontWeight.w500),
      (6, '半粗', FontWeight.w600),
      (7, '粗', FontWeight.w700),
    ];

    // 对齐选项
    const alignOptions = <(String, String, IconData)>[
      ('start', '左对齐', Icons.format_align_left_rounded),
      ('center', '居中', Icons.format_align_center_rounded),
      ('end', '右对齐', Icons.format_align_right_rounded),
    ];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          void persist() {
            // 一次批量写入：16 个参数 1 次 SP batch + 1 次 JSON flush，
            // 代替原来 16 次独立 setter（每次 openWrite + setXxx）。
            s.batchSetSubtitleStyle(
              fontSize: fontSize,
              position: position,
              bgOpacity: bgOpacity,
              textColor: textColor,
              stroke: stroke,
              secScale: secScale,
              secDim: secDim,
              fontFamily: fontFamily,
              fontWeightIdx: fontWeightIdx,
              lineSpacing: lineSpacing,
              lineHeight: lineHeight,
              bgRadius: bgRadius,
              bgColor: bgColor,
              showBg: showBg,
              align: align,
              useAssPos: useAssPos,
            );
            // 通知播放页重建：字幕浮层读的是同步 getter，
            // 不重建就会出现「改了设置但正在播的视频没反应」。
            try {
              ref.read(subtitleSettingsTickProvider.notifier).state++;
            } catch (_) {}
          }

          final previewSize = fontSize > 0 ? fontSize : 16.0;

          // 半屏弹出：约束高度 50%，超出滚动
          //
          // 底部留白必须用 bottomSheetInset 而不是 padding.bottom：
          // Android 8/9 走 manual 模式时 padding.bottom 是 0，
          // 而 bottomSheet 仍覆盖整个物理屏幕，会被导航栏压住。
          final safeBottom =
              SystemUiPolicy.bottomSheetInset(MediaQuery.of(sheetCtx));
          return ClipRRect(
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(GlassTheme.radiusXl)),
            child: SafeBackdropFilter(
              blurSigma: 24,
              child: Container(
                padding: EdgeInsets.fromLTRB(20, 16, 20, safeBottom + 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.85),
                      Colors.white.withValues(alpha: 0.55),
                    ],
                  ),
                  border: Border(
                    top: BorderSide(
                        color: Colors.black.withValues(alpha: 0.06),
                        width: 0.5),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: SingleChildScrollView(
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
                              color: Colors.black.withValues(alpha: 0.15),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Icon(Icons.text_fields_rounded,
                                color: GlassTheme.accentPurple, size: 20),
                            const SizedBox(width: 8),
                            const Text('字幕样式',
                                style: TextStyle(
                                    color: GlassTheme.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700)),
                            const Spacer(),
                            TextButton(
                              onPressed: () {
                                setSheetState(() {
                                  fontSize = 0;
                                  position = 0.12;
                                  bgOpacity = 0.62;
                                  textColor = 0xFFFFFFFF;
                                  stroke = true;
                                  secScale = 0.82;
                                  secDim = true;
                                  fontFamily = 'system';
                                  fontWeightIdx = 5;
                                  lineSpacing = 3;
                                  lineHeight = 1.35;
                                  bgRadius = 4;
                                  bgColor = 0xFF000000;
                                  showBg = true;
                                  align = 'center';
                                  useAssPos = true;
                                });
                                persist();
                              },
                              child: const Text('恢复默认',
                                  style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // ── 实时预览 ──
                        Container(
                          height: 96,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment(
                            0,
                            // 预览里位置映射到 -1~1，便于直观感受
                            position <= 0 ? 0.85 : (0.85 - position * 2.6),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _previewLine(
                                '字幕预览效果',
                                previewSize,
                                Color(textColor),
                                stroke,
                                showBg ? bgOpacity : 0,
                                fontFamily,
                                fontWeightIdx,
                                lineHeight,
                                bgRadius,
                                Color(bgColor),
                              ),
                              if (secScale > 0)
                                _previewLine(
                                  'Bilingual preview',
                                  previewSize * secScale,
                                  secDim
                                      ? Color(textColor).withValues(alpha: 0.72)
                                      : Color(textColor),
                                  stroke,
                                  showBg ? bgOpacity : 0,
                                  fontFamily,
                                  fontWeightIdx,
                                  lineHeight,
                                  bgRadius,
                                  Color(bgColor),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        _sliderRow(
                          '字号',
                          fontSize <= 0 ? '自动' : fontSize.toStringAsFixed(0),
                          fontSize <= 0 ? 16 : fontSize,
                          14,
                          30,
                          (v) {
                            setSheetState(() => fontSize = v);
                            persist();
                          },
                        ),
                        _sliderRow(
                          '垂直位置',
                          position <= 0.02
                              ? '贴底'
                              : '${(position * 100).round()}%',
                          position,
                          0,
                          0.5,
                          (v) {
                            setSheetState(() => position = v);
                            persist();
                          },
                        ),
                        _sliderRow(
                          '背景透明度',
                          '${(bgOpacity * 100).round()}%',
                          bgOpacity,
                          0,
                          1,
                          (v) {
                            setSheetState(() => bgOpacity = v);
                            persist();
                          },
                        ),
                        _sliderRow(
                          '译文比例',
                          '${(secScale * 100).round()}%',
                          secScale,
                          0.5,
                          1.0,
                          (v) {
                            setSheetState(() => secScale = v);
                            persist();
                          },
                        ),

                        const SizedBox(height: 6),
                        const Text('文字颜色',
                            style: TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (final (argb, name, c) in colorOptions)
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Tooltip(
                                  message: name,
                                  child: GestureDetector(
                                    onTap: () {
                                      setSheetState(() => textColor = argb);
                                      persist();
                                    },
                                    child: Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: c,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: textColor == argb
                                              ? GlassTheme.accentPurple
                                              : Colors.white24,
                                          width: textColor == argb ? 3 : 1,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('文字描边',
                              style: TextStyle(
                                  color: GlassTheme.textPrimary, fontSize: 14)),
                          subtitle: const Text('复杂画面上更清晰',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 11)),
                          value: stroke,
                          activeThumbColor: GlassTheme.accentPurple,
                          onChanged: (v) {
                            setSheetState(() => stroke = v);
                            persist();
                          },
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('译文弱化',
                              style: TextStyle(
                                  color: GlassTheme.textPrimary, fontSize: 14)),
                          subtitle: const Text('双语时译文用灰色，突出原文',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 11)),
                          value: secDim,
                          activeThumbColor: GlassTheme.accentPurple,
                          onChanged: (v) {
                            setSheetState(() => secDim = v);
                            persist();
                          },
                        ),

                        const SizedBox(height: 10),
                        const Text('字体',
                            style: TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        // 字体族选择
                        SizedBox(
                          height: 40,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final (key, label) in fontOptions)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(label,
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontFamily:
                                                key == 'system' ? null : key)),
                                    selected: fontFamily == key,
                                    onSelected: (_) {
                                      setSheetState(() => fontFamily = key);
                                      persist();
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text('字重',
                            style: TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (final (idx, label, w) in weightOptions)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(label,
                                      style: TextStyle(
                                          fontSize: 12, fontWeight: w)),
                                  selected: fontWeightIdx == idx,
                                  onSelected: (_) {
                                    setSheetState(() => fontWeightIdx = idx);
                                    persist();
                                  },
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text('对齐',
                            style: TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (final (key, label, icon) in alignOptions)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  avatar: Icon(icon, size: 16),
                                  label: Text(label,
                                      style: const TextStyle(fontSize: 12)),
                                  selected: align == key,
                                  onSelected: (_) {
                                    setSheetState(() => align = key);
                                    persist();
                                  },
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        _sliderRow(
                          '行间距',
                          lineSpacing.toStringAsFixed(0),
                          lineSpacing,
                          0,
                          12,
                          (v) {
                            setSheetState(() => lineSpacing = v);
                            persist();
                          },
                        ),
                        _sliderRow(
                          '行高',
                          lineHeight.toStringAsFixed(2),
                          lineHeight,
                          1.0,
                          1.8,
                          (v) {
                            setSheetState(() => lineHeight = v);
                            persist();
                          },
                        ),
                        _sliderRow(
                          '背景圆角',
                          bgRadius.toStringAsFixed(0),
                          bgRadius,
                          0,
                          12,
                          (v) {
                            setSheetState(() => bgRadius = v);
                            persist();
                          },
                        ),

                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('显示黑底',
                              style: TextStyle(
                                  color: GlassTheme.textPrimary, fontSize: 14)),
                          subtitle: const Text('关闭后字幕无背景色',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 11)),
                          value: showBg,
                          activeThumbColor: GlassTheme.accentPurple,
                          onChanged: (v) {
                            setSheetState(() => showBg = v);
                            persist();
                          },
                        ),
                        if (showBg) ...[
                          const SizedBox(height: 6),
                          const Text('背景色',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              for (final (argb, name, c) in bgColorOptions)
                                Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: Tooltip(
                                    message: name,
                                    child: GestureDetector(
                                      onTap: () {
                                        setSheetState(() => bgColor = argb);
                                        persist();
                                      },
                                      child: Container(
                                        width: 30,
                                        height: 30,
                                        decoration: BoxDecoration(
                                          color: c,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: bgColor == argb
                                                ? GlassTheme.accentPurple
                                                : Colors.white24,
                                            width: bgColor == argb ? 3 : 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('应用 ASS 定位',
                              style: TextStyle(
                                  color: GlassTheme.textPrimary, fontSize: 14)),
                          subtitle: const Text('按 ASS 字幕的垂直位置与对齐渲染',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 11)),
                          value: useAssPos,
                          activeThumbColor: GlassTheme.accentPurple,
                          onChanged: (v) {
                            setSheetState(() => useAssPos = v);
                            persist();
                          },
                        ),

                        const SizedBox(height: 6),
                        const Divider(height: 1, color: Colors.white12),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 字幕预览里的一行（带黑底，和实际渲染一致）
  Widget _previewLine(
    String text,
    double size,
    Color color,
    bool stroke,
    double bg,
    String fontFamily,
    int fontWeightIdx,
    double lineHeight,
    double bgRadius,
    Color bgColor,
  ) {
    const weights = <int, FontWeight>{
      3: FontWeight.w300,
      4: FontWeight.w400,
      5: FontWeight.w500,
      6: FontWeight.w600,
      7: FontWeight.w700,
      8: FontWeight.w800,
    };
    final family =
        (fontFamily.isEmpty || fontFamily == 'system') ? null : fontFamily;
    final weight = weights[fontWeightIdx] ?? FontWeight.w500;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor.withValues(alpha: bg.clamp(0.0, 1.0)),
          borderRadius: BorderRadius.circular(bgRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: size,
              fontWeight: weight,
              height: lineHeight,
              fontFamily: family,
              shadows: stroke
                  ? const [
                      Shadow(
                          color: Colors.black87,
                          blurRadius: 3,
                          offset: Offset(1, 1)),
                      Shadow(
                          color: Colors.black87,
                          blurRadius: 3,
                          offset: Offset(-1, -1)),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sliderRow(
    String label,
    String value,
    double current,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(
                    color: GlassTheme.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(value,
                style: const TextStyle(
                    color: GlassTheme.accentPurple,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        SliderTheme(
          data: const SliderThemeData(
            trackHeight: 3,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: current.clamp(min, max),
            min: min,
            max: max,
            activeColor: GlassTheme.accentPurple,
            inactiveColor: Colors.white24,
            onChanged: onChanged,
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
          // 真正的应用图标（深色底 + 栖木横线 + 播放三角）
          ClipRRect(
            borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
            child: Image.asset(
              'assets/branding/perchplay_icon_1024.png',
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 64,
                height: 64,
                color: GlassTheme.accentPurple,
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 30),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('PerchPlay',
              style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('v${AppVersion.display}',
              style: const TextStyle(
                  color: GlassTheme.textTertiary, fontSize: 12)),
          const SizedBox(height: 16),
          // 检查更新
          GlassButton.outlined(
            icon: Icons.system_update_rounded,
            label: '检查更新',
            width: double.infinity,
            height: 40,
            foregroundColor: GlassTheme.accentPurple,
            onTap: _checkForUpdate,
          ),
          const SizedBox(height: 10),
          // 诊断日志：出问题时一键复制发给开发者
          GlassButton.outlined(
            icon: Icons.bug_report_rounded,
            label: '诊断日志',
            width: double.infinity,
            height: 40,
            foregroundColor: GlassTheme.accentTeal,
            onTap: _showDiagnosticsSheet,
          ),
        ],
      ),
    );
  }

  /// 诊断日志面板：查看 / 复制 / 清空 / 分享。
  ///
  /// 设计目标是「用户不需要懂技术，出问题时能一键把有用信息发出来」，
  /// 所以面板里同时提供三个动作：
  ///  - 复制全文（粘到微信/邮件最快）
  ///  - 分享文件（长日志更适合当附件）
  ///  - 只看最近若干条（手机屏幕小，全文翻不动）
  Future<void> _showDiagnosticsSheet() async {
    final svc = LogService.instance;
    final device = DeviceInfoService.instance;
    // 设备信息用 brand/capabilities 拼（DeviceInfoService 没有 model getter）
    final devInfo = '品牌: ${device.brand.name} · '
        'RAM: ${device.ramGB.toStringAsFixed(1)}GB · '
        '手势导航: ${device.capabilities.isGestureNavigation}';
    final report = await svc.buildReport(
      appVersion: 'v${AppVersion.display}',
      extraInfo: devInfo,
    );

    if (!mounted) return;
    // 底部安全边距。
    //
    // 用「实测导航栏高度」与 48dp 的较大值作为**保底**；
    // 外层再套 SafeArea(bottom:true) 做**二次保险** —— 两处都做不是浪费：
    //  - SafeArea 依赖 MediaQuery.padding，低版本 manual 模式下可能是 0
    //  - 我们自己的实测值在个别 ROM 上也可能偏小（用户小米报 20dp）
    // 取两者中生效的那个，比赌单一来源可靠。
    final mq = MediaQuery.of(context);
    final navInset = SystemUiPolicy.bottomSheetInset(mq);
    final safeBottom = navInset > 56 ? navInset : 56.0;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        // 高度 = min(屏高 * 0.82, 屏高 - 安全区)。
        //
        // 为什么减安全区：`showModalBottomSheet` 贴屏幕物理底边，
        // 如果高度取 82%，面板底边就在最底部，按钮必然落进导航栏区域。
        // 减掉安全区后，整个面板上移，按钮自然在导航栏之上。
        // 这是比「在面板内加 padding」更稳的解法 —— padding 只是把内容
        // 往上推，面板本身的底边仍在导航栏下面。
        height: (MediaQuery.of(ctx).size.height * 0.82)
            .clamp(0.0, MediaQuery.of(ctx).size.height - safeBottom - 24),
        decoration: const BoxDecoration(
          color: Color(0xFFF7F7FA),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // 注意：padding 不放在这一层。
        // Container 的 padding 会挤压内部 Column，配合 Expanded 会让
        // 底部按钮紧贴 padding 边缘、没有可呼吸的余量。改为下面
        // 用 Column 末尾的固定高度 SizedBox 来保证安全区。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 标题 + 说明（带水平边距）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.bug_report_rounded,
                      color: GlassTheme.accentTeal, size: 20),
                  const SizedBox(width: 8),
                  const Text('诊断日志',
                      style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${svc.count} 条',
                      style: const TextStyle(
                          color: GlassTheme.textTertiary, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '遇到问题时点「复制全部」发给我，能快速定位原因。'
                '日志只在本机保存，不会上传。',
                style: TextStyle(
                    color: GlassTheme.textTertiary, fontSize: 11, height: 1.4),
              ),
            ),
            const SizedBox(height: 12),
            // 日志正文
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: Colors.black.withValues(alpha: 0.06)),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      report,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        height: 1.45,
                        color: Color(0xFF2C2C2E),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 按钮行（带水平边距）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: GlassButton.filled(
                      icon: Icons.copy_rounded,
                      label: '复制全部',
                      height: 46,
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(text: report));
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          _showSnack('已复制，直接粘贴发给我即可');
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 清空：复现问题前先清空，日志只保留本次操作
                  Expanded(
                    child: GlassButton.outlined(
                      icon: Icons.delete_sweep_rounded,
                      label: '清空',
                      height: 46,
                      foregroundColor: GlassTheme.textTertiary,
                      onTap: () {
                        svc.clear();
                        svc.log('[日志] 已由用户清空');
                        Navigator.pop(ctx);
                        _showSnack('已清空，请复现问题后再来看');
                      },
                    ),
                  ),
                ],
              ),
            ),
            // 底部安全区：**固定高度**占位，不依赖 padding。
            //
            // 原来把安全区算进 Container 的 padding，但 Container 高度是
            // 屏高的百分比，减去 padding 后 Expanded 仍会吃满，按钮就贴在
            // padding 下沿 —— 视觉上还是被导航栏压住（用户反馈 20dp 的
            // 导航栏高度也确实太小）。改成这里显式留一个 SizedBox，
            // 高度取 max(实测导航栏, 48)，保证按钮上下都有余量。
            SizedBox(height: safeBottom),
          ],
        ),
      ),
    );
  }

  /// 轻量提示（设置页内多处复用）。
  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  /// 检查更新：查询 GitHub 最新 release，有新版则引导下载安装。
  Future<void> _checkForUpdate() async {
    final messenger = ScaffoldMessenger.of(context);
    final svc = UpdateService.instance;

    // 先提示检查中
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在检查更新…'),
        duration: Duration(seconds: 1),
      ),
    );

    final info = await svc.checkForUpdate();
    if (!mounted) return;

    if (!info.hasUpdate) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已是最新版本'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // 有新版本：弹确认框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GlassTheme.bg,
        title: const Text('发现新版本',
            style: TextStyle(color: GlassTheme.textPrimary, fontSize: 17)),
        content: Text(
          '当前 v${AppVersion.display}\n最新 v${info.latestVersion}\n\n是否立即下载并安装？',
          style: const TextStyle(
              color: GlassTheme.textSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: GlassTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载',
                style: TextStyle(color: GlassTheme.accentPurple)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // ── iOS：应用无法自安装 IPA ──
    //
    // iOS 沙盒限制决定了 App 不能像 Android 那样下载安装包后调系统安装器。
    // 这里把 Release 链接复制到剪贴板并提示，用户可在 Safari 打开下载 IPA
    // 后用 AltStore / SideStore 等工具安装。
    // （不引入 url_launcher 新依赖，避免多一个 iOS pod 和潜在兼容问题。）
    if (!kIsWeb && Platform.isIOS) {
      const releaseUrl = 'https://github.com/Kimcop-kc/PerchPlay/releases/latest';
      try {
        await Clipboard.setData(const ClipboardData(text: releaseUrl));
      } catch (e) {
        debugPrint('[Update] 复制下载链接失败: $e');
      }
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('下载链接已复制，请在 Safari 打开下载 IPA，'
              '再用 AltStore 等工具安装'),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    // 下载（带进度提示）
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在下载更新包…'),
        duration: Duration(seconds: 1),
      ),
    );

    final path = await svc.downloadApk(info.downloadUrl);
    if (!mounted) return;

    if (path == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('下载失败，请检查网络后重试'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    // 触发系统安装器
    final ok = await svc.installApk(path);
    if (!mounted) return;

    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('无法调起安装器，请手动安装'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  // ─── Setting Row Helpers ───

  Widget _settingRow(IconData icon, String title,
      {Widget? trailing, VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon, color: GlassTheme.textSecondary, size: 20),
      // 必须限制为单行 + 省略号。
      //
      // ListTile 的 title 在 trailing 占宽之后会被压缩，而 Text 默认允许
      // 任意换行——中文没有空格，压缩到「每行一个字」时就变成了竖排文字，
      // 典型受害者是「已隐藏的视频（12 个）」+「全部恢复」按钮这一行。
      title: Text(
        title,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 15),
      ),
      trailing: trailing,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    );
  }

  Widget _settingSwitch(
      IconData icon, String title, bool value, ValueChanged<bool> onChanged) {
    return ListTile(
      leading: Icon(icon, color: GlassTheme.textSecondary, size: 20),
      // 同上：单行 + 省略，避免长标题被从右侧压缩成竖排
      title: Text(
        title,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 15),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: GlassTheme.accentPurple,
        inactiveThumbColor: GlassTheme.textTertiary,
        inactiveTrackColor: Colors.black.withValues(alpha: 0.08),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    );
  }

  Widget _divider() {
    return Divider(
        height: 1, indent: 52, color: Colors.black.withValues(alpha: 0.06));
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

  void _showLongPressSpeedPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _pickerSheet(
        title: '长按倍速',
        subtitle: '播放时按住画面即可以此速度播放，松手恢复',
        items: [1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0],
        current: _settings.longPressSpeed,
        onSelect: (v) => _settings.setLongPressSpeed(v).then((_) {
          if (mounted) setState(() {});
        }),
        format: (v) => '${v}x',
      ),
    );
  }

  void _showSkipPicker() {
    // 无极滑动选择快进/快退秒数（1-60 秒连续可调）
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _sliderSheet(
        title: '快进/快退秒数',
        min: 1,
        max: 60,
        divisions: 59,
        current: _settings.skipSeconds.toDouble(),
        format: (v) => '${v.toInt()} 秒',
        onChanged: (v) {
          _settings.setSkipSeconds(v.toInt());
        },
      ),
    );
  }

  String _playerOrientationLabel(String v) {
    switch (v) {
      case 'landscape':
        return '横屏';
      case 'portrait':
        return '竖屏';
      case 'auto':
      default:
        return '自动';
    }
  }

  void _showPlayerOrientationPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _orientationSheet(
        current: _settings.playerOrientation,
        onSelect: (v) => _settings.setPlayerOrientation(v).then((_) {
          if (mounted) setState(() {});
        }),
      ),
    );
  }

  Widget _orientationSheet({
    required String current,
    required void Function(String) onSelect,
  }) {
    // 同 _pickerSheet：低版本 padding.bottom 为 0，必须用 bottomSheetInset
    final bottomInset =
        SystemUiPolicy.bottomSheetInset(MediaQuery.of(context)) + 96;
    const options = <(String, String, String)>[
      ('auto', '自动', '跟随手机当前方向，可自由旋转'),
      ('landscape', '横屏', '打开视频即横屏全屏'),
      ('portrait', '竖屏', '打开视频即竖屏'),
    ];
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
          top: Radius.circular(GlassTheme.radiusXl)),
      child: SafeBackdropFilter(
        blurSigma: 24,
        child: Container(
          padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.8),
                Colors.white.withValues(alpha: 0.5),
              ],
            ),
            border: Border(
              top: BorderSide(
                  color: Colors.black.withValues(alpha: 0.06), width: 0.5),
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
                    color: Colors.black.withValues(alpha: 0.15),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('打开视频方向',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              for (final (key, label, desc) in options)
                GlassButton(
                  label: '$label · $desc',
                  width: double.infinity,
                  height: 52,
                  ghost: true,
                  filled: false,
                  foregroundColor: current == key
                      ? GlassTheme.accentPurple
                      : GlassTheme.textPrimary,
                  onTap: () {
                    onSelect(key);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sliderSheet({
    required String title,
    required double min,
    required double max,
    required int divisions,
    required double current,
    required String Function(double) format,
    required void Function(double) onChanged,
  }) {
    return StatefulBuilder(
      builder: (ctx, setSheetState) {
        double value = current;
        // 避让悬浮玻璃导航栏 + 底部系统栏
        // 同 _pickerSheet：低版本 padding.bottom 为 0，必须用 bottomSheetInset
        final bottomInset =
            SystemUiPolicy.bottomSheetInset(MediaQuery.of(ctx)) + 96;
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(GlassTheme.radiusXl)),
          child: SafeBackdropFilter(
            blurSigma: 24,
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 24, 24, bottomInset),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.85),
                    Colors.white.withValues(alpha: 0.55),
                  ],
                ),
                border: Border(
                  top: BorderSide(
                      color: Colors.black.withValues(alpha: 0.06), width: 0.5),
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
                        color: Colors.black.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      Text(
                        format(value),
                        style: const TextStyle(
                            color: GlassTheme.accentPurple,
                            fontSize: 18,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 无极滑动条：拖拽时只更新本地显示，松手才持久化
                  Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    activeColor: GlassTheme.accentPurple,
                    inactiveColor: Colors.black.withValues(alpha: 0.08),
                    onChanged: (v) {
                      setSheetState(() => value = v);
                    },
                    onChangeEnd: (v) {
                      onChanged(v);
                    },
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${min.toInt()}s',
                          style: const TextStyle(
                              color: GlassTheme.textTertiary, fontSize: 12)),
                      Text('${max.toInt()}s',
                          style: const TextStyle(
                              color: GlassTheme.textTertiary, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pickerSheet({
    required String title,
    String? subtitle,
    required List<double> items,
    required double current,
    required void Function(double) onSelect,
    required String Function(double) format,
  }) {
    // 避让悬浮玻璃导航栏 + 底部系统栏。
    //
    // 底部系统栏用 bottomSheetInset 而非 padding.bottom：
    // Android 8/9 是 manual 模式，padding.bottom == 0，但 bottomSheet
    // 覆盖整个物理屏幕，不加就会让最后几个选项被导航栏压住且点不到。
    final safeBottom = SystemUiPolicy.bottomSheetInset(MediaQuery.of(context));
    final bottomInset = safeBottom + 96;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
          top: Radius.circular(GlassTheme.radiusXl)),
      child: SafeBackdropFilter(
        blurSigma: 24,
        child: Container(
          padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.8),
                Colors.white.withValues(alpha: 0.5),
              ],
            ),
            border: Border(
              top: BorderSide(
                  color: Colors.black.withValues(alpha: 0.06), width: 0.5),
            ),
          ),
          child: SingleChildScrollView(
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
                      color: Colors.black.withValues(alpha: 0.15),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(title,
                    style: const TextStyle(
                        color: GlassTheme.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(subtitle,
                        style: const TextStyle(
                            color: GlassTheme.textTertiary, fontSize: 13)),
                  ),
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
      ),
    );
  }
}
