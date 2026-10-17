import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass_theme.dart';
import '../../services/ai/ai_model.dart';
import '../../services/ai/ai_model_catalog.dart';
import '../../services/ai/model_downloader.dart';

/// AI 模型管理页面。
///
/// 列出全部 18 个模型，显示名称、体积、能力标签、评分。
/// 用户可点击下载 / 切换 / 删除每个模型。
class AiModelsPage extends ConsumerStatefulWidget {
  const AiModelsPage({super.key});

  @override
  ConsumerState<AiModelsPage> createState() => _AiModelsPageState();
}

class _AiModelsPageState extends ConsumerState<AiModelsPage> {
  final _downloader = ModelDownloader();
  /// modelId → 0.0~1.0 的下载进度（null 表示不在下载中）
  final Map<String, double> _progress = {};
  /// modelId → error 字符串
  final Map<String, String> _errors = {};
  /// 已下载的模型 id 集合（检查 modelDir 是否存在）
  final Set<String> _downloaded = {};
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final dir = await ModelDownloader.modelsDir();
    final ids = <String>{};
    if (await dir.exists()) {
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is Directory) {
          final name = entry.path.split(Platform.pathSeparator).last;
          ids.add(name);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _downloaded
        ..clear()
        ..addAll(ids);
      _checking = false;
    });
  }

  Future<void> _startDownload(AiModel model) async {
    setState(() {
      _progress[model.id] = 0;
      _errors.remove(model.id);
    });
    try {
      await _downloader.download(
        model: model,
        preferredSource: DownloadSource.huggingface,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress[model.id] = p);
        },
      );
      await _refreshStatus();
      setState(() => _progress.remove(model.id));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress.remove(model.id);
        _errors[model.id] = e.toString();
      });
    }
  }

  Future<void> _deleteModel(AiModel model) async {
    final dir = await ModelDownloader.modelsDir();
    final modelDir = Directory('${dir.path}/${model.id}');
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
      await _refreshStatus();
    }
  }

  @override
  void dispose() {
    _downloader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GlassTheme.bg,
      body: SafeArea(
        top: false,
        bottom: false,
        child: CustomScrollView(
          slivers: [
            _buildHeader(),
            if (_checking)
              const SliverToBoxAdapter(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: GlassTheme.accentPurple),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final model = AiModelCatalog.all[index];
                    return _buildModelCard(model);
                  },
                  childCount: AiModelCatalog.all.length,
                ),
              ),
            const SliverToBoxAdapter(
              child: SizedBox(height: GlassTheme.navBarOverlay),
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
        padding: EdgeInsets.fromLTRB(20, topPad, 20, 12),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: const Icon(Icons.arrow_back_ios,
                  size: 20, color: GlassTheme.textSecondary),
            ),
            const SizedBox(width: 12),
            const Text('AI 模型管理',
                style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            _buildGlobalStatus(),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalStatus() {
    final downloading = _progress.values.where((p) => p < 1).length;
    if (downloading > 0) {
      return Text('$downloading 个下载中…',
          style: const TextStyle(
              color: GlassTheme.accentPurple, fontSize: 13));
    }
    final total = _downloaded.length;
    if (total > 0) {
      return Text('$total 个已就绪',
          style: const TextStyle(
              color: GlassTheme.accentTeal, fontSize: 13));
    }
    return const Text('尚未下载模型',
        style: TextStyle(color: GlassTheme.textTertiary, fontSize: 13));
  }

  Widget _buildModelCard(AiModel model) {
    final isReady = _downloaded.contains(model.id);
    final isDownloading = _progress.containsKey(model.id);
    final p = _progress[model.id] ?? 0;
    final error = _errors[model.id];
    final desc = '${model.displayName} · 约 ${model.sizeLabel} · ${model.license}';

    return Card(
      color: Colors.white.withOpacity(0.6),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusMd)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.displayName,
                          style: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(desc,
                          style: const TextStyle(
                              color: GlassTheme.textTertiary,
                              fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildActionButton(model, isReady, isDownloading,
                    p, error),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _tag(_capLabel(model), GlassTheme.accentPurple),
                const SizedBox(width: 6),
                _tag(_tierLabel(model.tier),
                    const Color(0xFF34C759)),
                const SizedBox(width: 6),
                _tag(model.notes,
                    const Color(0xFFFF9500)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(
    AiModel model,
    bool isReady,
    bool isDownloading,
    double p,
    String? error,
  ) {
    if (error != null) {
      return _smallButton(
        '重试',
        color: GlassTheme.accentPink,
        onTap: () => _startDownload(model),
      );
    }
    if (isDownloading) {
      return SizedBox(
        width: 80,
        height: 32,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: p > 0 ? p : null,
              strokeWidth: 2.5,
              color: GlassTheme.accentPurple,
            ),
            Text('${(p * 100).toInt()}%',
                style: const TextStyle(
                    color: GlassTheme.accentPurple,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }
    if (isReady) {
      return _smallButton(
        '删除',
        color: GlassTheme.textTertiary,
        onTap: () => _deleteModel(model),
      );
    }
    return _smallButton(
      '下载',
      color: GlassTheme.accentPurple,
      onTap: () => _startDownload(model),
    );
  }

  Widget _smallButton(String label,
      {required Color color, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _tag(String text, Color color) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w500)),
    );
  }

  // ── 内联标签 helper（避免跨文件静态方法分析器问题） ──

  static String _capLabel(AiModel model) {
    if (model.capabilities.isEmpty) return '';
    const names = <AiCapability, String>{
      AiCapability.vad: 'VAD',
      AiCapability.asr: '语音识别',
      AiCapability.asrStreaming: '流式识别',
      AiCapability.translate: '翻译',
      AiCapability.classify: '分类',
      AiCapability.ocr: 'OCR',
      AiCapability.embed: '语义搜索',
      AiCapability.frameScore: '选帧',
    };
    return names[model.capabilities.first] ?? '';
  }

  static String _tierLabel(ModelTier tier) {
    switch (tier) {
      case ModelTier.light:
        return '轻量';
      case ModelTier.balanced:
        return '均衡';
      case ModelTier.highQuality:
        return '高质量';
      case ModelTier.multilingual:
        return '多语言';
    }
  }
}