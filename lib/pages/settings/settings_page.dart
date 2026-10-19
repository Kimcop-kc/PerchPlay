import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/constants/app_constants.dart';
import '../../core/responsive/breakpoints.dart';
import '../../services/device_info_service.dart';
import '../../services/rom_optimization_service.dart';
import '../../services/ipad_optimization_service.dart';
import '../../services/app_settings_service.dart';
import '../../services/storage_manager.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/ui_settings_provider.dart';
import '../../providers/scrape_provider.dart';
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
    });
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
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: isLarge ? 40 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionHeader('播放'),
                    _buildPlaybackSettings(),
                    const SizedBox(height: 24),
                    _sectionHeader('刮削 (TMDB)'),
                    _buildScrapeSettings(),
                    const SizedBox(height: 24),
                    _sectionHeader('AI 模型'),
                    _buildAiModelsEntry(context),
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
                    if (device.isIPad)
                      _buildIPadFeatures(context),
                    const SizedBox(height: 24),
                    _sectionHeader('关于'),
                    _buildAbout(),
                    const SizedBox(height: GlassTheme.navBarOverlay),
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
          _divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '遇到花屏 / 黑屏 / 无法播放时，可关闭硬件解码改用软件解码',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
            ),
          ),
        ],
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
                    style: TextStyle(
                        color: GlassTheme.textTertiary, fontSize: 13))
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
          ),          const Padding(
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: GlassTheme.accentTeal.withOpacity(0.12),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
                  ),
                  child: const Text('未启用',
                      style: TextStyle(
                          color: GlassTheme.textTertiary,
                          fontSize: 11)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '扫描视频后自动匹配 TMDB 海报、简介、评分。\n'
            '去 themoviedb.org 免费申请即可拿到凭证。\n'
            '「API 密钥 (v3 auth)」和「API 读访问令牌」都支持，粘哪个都能用。',
            style: TextStyle(color: GlassTheme.textSecondary, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tmdbController,
                  obscureText: true,
                  obscuringCharacter: '\u2022',
                  style: const TextStyle(fontSize: 13, color: GlassTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: isEnabled ? '\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022' : '粘贴 TMDB API Key 或 读访问令牌',
                    hintStyle: const TextStyle(fontSize: 12, color: GlassTheme.textTertiary),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                      borderSide: BorderSide(color: Colors.black.withOpacity(0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                      borderSide: BorderSide(color: Colors.black.withOpacity(0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                      borderSide: const BorderSide(color: GlassTheme.accentTeal),
                    ),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.5),
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

  Widget _buildAiModelsEntry(BuildContext context) {
    return Column(
      children: [
        GlassCard(
          radius: GlassTheme.radiusMd,
          tint: GlassTheme.tintWhite,
          padding: const EdgeInsets.all(0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
            child: ListTile(
              leading: const Icon(Icons.memory,
                  color: GlassTheme.accentPurple, size: 22),
              title: const Text('AI 模型管理',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500)),
              subtitle: const Text('下载、切换、删除语音识别与翻译模型',
                  style: TextStyle(
                      color: GlassTheme.textTertiary, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right,
                  color: GlassTheme.textTertiary, size: 20),
              onTap: () {
                GoRouter.of(context).pushNamed('aiModels');
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        GlassCard(
          radius: GlassTheme.radiusMd,
          tint: GlassTheme.tintWhite,
          padding: const EdgeInsets.all(0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
            child: ListTile(
              leading: const Icon(Icons.translate,
                  color: GlassTheme.accentPink, size: 22),
              title: const Text('AI 翻译设置',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500)),
              subtitle: const Text('翻译后端、LLM Key 与目标语言',
                  style: TextStyle(
                      color: GlassTheme.textTertiary, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right,
                  color: GlassTheme.textTertiary, size: 20),
              onTap: () => _showTranslateSettings(context),
            ),
          ),
        ),
      ],
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
                style: TextStyle(
                    color: GlassTheme.textTertiary, fontSize: 13));
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
        backgroundColor: GlassTheme.bg.withOpacity(0.95),
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

  /// 「AI 翻译设置」弹窗：翻译后端 / LLM Key / 目标语言
  ///
  /// 关键：可选值（backend / targetLang）和三个 TextEditingController
  /// **必须放在 StatefulBuilder 的 builder 之外**。
  /// 之前它们写在 builder 内部，每次 setDialogState 触发重建都会重新
  /// 执行一遍 `String backend = _settings.translateBackend;`，把用户刚点
  /// 的选项又覆盖回已保存的旧值 —— 表现就是「点了其他选项没反应/跳回去」。
  void _showTranslateSettings(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom + 24;

    // ── 对话框状态（生命周期 = 整个弹窗，不随重建重置）──
    String backend = _settings.translateBackend;
    String targetLang = _settings.translateTargetLang;
    final keyCtrl = TextEditingController(text: _settings.llmApiKey);
    final urlCtrl = TextEditingController(text: _settings.llmBaseUrl);
    final modelCtrl = TextEditingController(text: _settings.llmModel);

    const backendOptions = <(String, String, IconData)>[
      ('google', 'Google 免费', Icons.public_rounded),
      ('llm', 'LLM 自配 Key', Icons.key_rounded),
      ('local', '本地离线', Icons.offline_pin_rounded),
    ];

    const langOptions = <(String, String)>[
      ('en', 'en (英文)'),
      ('ja', 'ja (日文)'),
      ('ko', 'ko (韩文)'),
      ('fr', 'fr (法文)'),
      ('de', 'de (德文)'),
      ('es', 'es (西班牙文)'),
      ('ru', 'ru (俄文)'),
      ('yue', 'yue (粤语)'),
    ];

    Future<void> persist() async {
      await _settings.setTranslateBackend(backend);
      await _settings.setLlmApiKey(keyCtrl.text.trim());
      await _settings.setLlmBaseUrl(urlCtrl.text.trim());
      await _settings.setLlmModel(modelCtrl.text.trim());
      await _settings.setTranslateTargetLang(targetLang);
    }

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20),
            child: ClipRRect(
              borderRadius:
                  BorderRadius.circular(GlassTheme.radiusLg),
              child: SafeBackdropFilter(
                blurSigma: 24,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 520),
                  padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.88),
                        Colors.white.withOpacity(0.6),
                      ],
                    ),
                    border: Border.all(
                        color: Colors.white.withOpacity(0.4), width: 0.8),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.translate,
                                color: GlassTheme.accentPink, size: 22),
                            const SizedBox(width: 8),
                            const Text('AI 翻译设置',
                                style: TextStyle(
                                    color: GlassTheme.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // 翻译后端单选
                        const Text('翻译后端',
                            style: TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        for (final (value, label, icon) in backendOptions)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: GlassCard(
                              radius: GlassTheme.radiusMd,
                              tint: backend == value
                                  ? GlassTheme.tintPink
                                  : GlassTheme.tintWhite,
                              padding: const EdgeInsets.all(0),
                              enableHover: false,
                              onTap: () =>
                                  setDialogState(() => backend = value),
                              child: ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(GlassTheme.radiusMd),
                                child: ListTile(
                                  dense: true,
                                  leading: Icon(icon,
                                      color: backend == value
                                          ? GlassTheme.accentPink
                                          : GlassTheme.textSecondary,
                                      size: 20),
                                  title: Text(label,
                                      style: TextStyle(
                                          color: GlassTheme.textPrimary,
                                          fontSize: 14,
                                          fontWeight: backend == value
                                              ? FontWeight.w600
                                              : FontWeight.w400)),
                                  trailing: Icon(
                                    backend == value
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    color: backend == value
                                        ? GlassTheme.accentPink
                                        : GlassTheme.textTertiary,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // LLM 专属字段
                        if (backend == 'llm') ...[
                          const SizedBox(height: 4),
                          const Text('API Key',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: keyCtrl,
                                  obscureText: true,
                                  obscuringCharacter: '\u2022',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: GlassTheme.textPrimary),
                                  decoration: _translateInputDecoration(
                                      '粘贴 LLM API Key'),
                                  onChanged: (_) =>
                                      setDialogState(() {}),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (keyCtrl.text.isNotEmpty)
                                GlassButton.outlined(
                                  label: '清除',
                                  height: 42,
                                  foregroundColor: GlassTheme.accentPink,
                                  onTap: () =>
                                      setDialogState(() => keyCtrl.clear()),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text('Base URL',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: urlCtrl,
                            keyboardType: TextInputType.url,
                            style: const TextStyle(
                                fontSize: 13, color: GlassTheme.textPrimary),
                            decoration: _translateInputDecoration(
                                'OpenAI 兼容 chat/completions 地址'),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                          const SizedBox(height: 12),
                          const Text('Model',
                              style: TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: modelCtrl,
                            style: const TextStyle(
                                fontSize: 13, color: GlassTheme.textPrimary),
                            decoration:
                                _translateInputDecoration('模型名称'),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ],

                        const SizedBox(height: 16),
                        const Text('目标语言',
                            style: TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Container(
                          height: 44,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.5),
                            borderRadius:
                                BorderRadius.circular(GlassTheme.radiusSm),
                            border: Border.all(
                                color: Colors.black.withOpacity(0.1)),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: targetLang,
                              isExpanded: true,
                              icon: const Icon(Icons.keyboard_arrow_down,
                                  color: GlassTheme.textTertiary),
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: GlassTheme.textPrimary),
                              items: [
                                for (final (code, label) in langOptions)
                                  DropdownMenuItem<String>(
                                    value: code,
                                    child: Text(label),
                                  ),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setDialogState(
                                    () => targetLang = v);
                              },
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: GlassButton.outlined(
                                label: '取消',
                                height: 46,
                                foregroundColor: GlassTheme.textSecondary,
                                onTap: () => Navigator.pop(dialogCtx),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: GlassButton.filled(
                                label: '保存',
                                height: 46,
                                onTap: () async {
                                  final navigator =
                                      Navigator.of(dialogCtx);
                                  await persist();
                                  if (mounted) setState(() {});
                                  navigator.pop();
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ).then((_) {
      // 弹窗关闭后释放 controller，避免长会话里累积
      keyCtrl.dispose();
      urlCtrl.dispose();
      modelCtrl.dispose();
    });
  }

  InputDecoration _translateInputDecoration(String hintText) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(
          fontSize: 12, color: GlassTheme.textTertiary),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
        borderSide: BorderSide(color: Colors.black.withOpacity(0.1)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
        borderSide: BorderSide(color: Colors.black.withOpacity(0.1)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
        borderSide: const BorderSide(color: GlassTheme.accentPink),
      ),
      filled: true,
      fillColor: Colors.white.withOpacity(0.5),
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
          Text('v${AppConstants.appVersion}',
              style: const TextStyle(color: GlassTheme.textTertiary, fontSize: 12)),
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
        // 避让悬浮玻璃导航栏 + 底部安全区
        final bottomInset = MediaQuery.of(ctx).padding.bottom + 96;
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
                    Colors.white.withOpacity(0.85),
                    Colors.white.withOpacity(0.55),
                  ],
                ),
                border: Border(
                  top: BorderSide(
                      color: Colors.black.withOpacity(0.06), width: 0.5),
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
                  // 无极滑动条
                  Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    activeColor: GlassTheme.accentPurple,
                    inactiveColor: Colors.black.withOpacity(0.08),
                    onChanged: (v) {
                      setSheetState(() => value = v);
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
    // 避让悬浮玻璃导航栏 + 底部安全区
    final bottomInset = MediaQuery.of(context).padding.bottom + 96;
    return ClipRRect(
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusXl)),
      child: SafeBackdropFilter(
        blurSigma: 24,
        child: Container(
          padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset),
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
    );
  }
}
