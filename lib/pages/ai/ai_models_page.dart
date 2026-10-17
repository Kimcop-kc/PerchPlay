import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass_theme.dart';
import '../../services/ai/ai_model.dart';
import '../../services/ai/ai_model_catalog.dart';
import '../../services/ai/model_downloader.dart';
import '../../services/ai/model_importer.dart';

/// AI 模型管理页面。
///
/// 列出全部 18 个预设模型 + 用户自行导入的模型。
/// 支持下载 / 导入 / 删除。
class AiModelsPage extends ConsumerStatefulWidget {
  const AiModelsPage({super.key});

  @override
  ConsumerState<AiModelsPage> createState() => _AiModelsPageState();
}

class _AiModelsPageState extends ConsumerState<AiModelsPage> {
  final _downloader = ModelDownloader();
  final _importer = ModelImporter();
  final Map<String, double> _progress = {};
  final Map<String, String> _errors = {};
  final Set<String> _downloaded = {};
  bool _checking = true;
  String? _importingModelId;

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
          ids.add(entry.path.split(Platform.pathSeparator).last);
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

  Future<void> _deleteModel(String modelId) async {
    final dir = await ModelDownloader.modelsDir();
    final modelDir = Directory('${dir.path}/$modelId');
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
      await _refreshStatus();
    }
  }

  // ── 导入 ──

  Future<void> _startImport() async {
    final id = await _showImportDialog();
    if (id == null) return;

    setState(() => _importingModelId = id);
    try {
      final count = await _importer.import(modelId: id);
      await _refreshStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('成功导入 $count 个文件 → $id'),
          backgroundColor: GlassTheme.accentTeal,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导入失败：$e'),
          backgroundColor: GlassTheme.accentPink,
        ),
      );
    } finally {
      if (mounted) setState(() => _importingModelId = null);
    }
  }

  Future<String?> _showImportDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor:
            GlassTheme.surfaceWhite,
        title: const Text('导入模型',
            style: TextStyle(
                color: GlassTheme.textPrimary, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '给模型起个名字（用作存储目录名）',
              style:
                  TextStyle(color: GlassTheme.textTertiary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '例如：my-whisper-model',
                hintStyle: const TextStyle(
                    color: GlassTheme.textTertiary, fontSize: 14),
                filled: true,
                fillColor: Colors.black.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(GlassTheme.radiusSm),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(
                  color: GlassTheme.textPrimary, fontSize: 15),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: GlassTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              final id = controller.text.trim();
              if (id.isNotEmpty) Navigator.pop(ctx, id);
            },
            child: const Text('选择文件',
                style: TextStyle(
                    color: GlassTheme.accentPurple,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── 非 catalog 用户模型条目 ──

  /// 返回用户手动导入的模型 id（不在 catalog 中的）
  List<String> _userModelIds() {
    final catalogIds =
        AiModelCatalog.all.map((m) => m.id).toSet();
    return _downloaded.where((id) => !catalogIds.contains(id)).toList()
      ..sort();
  }

  @override
  void dispose() {
    _downloader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userIds = _userModelIds();

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
            else ...[
              // ── 预设模型 ──
              SliverToBoxAdapter(
                child: _sectionHeader('预设模型'),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _buildModelCard(AiModelCatalog.all[index]),
                  childCount: AiModelCatalog.all.length,
                ),
              ),
              // ── 用户自行导入 ──
              if (userIds.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _sectionHeader('自行导入'),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _buildUserModelCard(userIds[index]),
                    childCount: userIds.length,
                  ),
                ),
              ],
              const SliverToBoxAdapter(
                child:
                    SizedBox(height: GlassTheme.navBarOverlay),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(title,
          style: const TextStyle(
              color: GlassTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildHeader() {
    final topPad = MediaQuery.of(context).padding.top + 24;
    final isImporting = _importingModelId != null;
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
            const Expanded(
              child: Text('AI 模型管理',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
            ),
            if (isImporting)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: GlassTheme.accentPurple)),
              ),
            _buildGlobalStatus(),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: isImporting ? null : _startImport,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: GlassTheme.accentPurple.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open,
                        size: 14,
                        color: isImporting
                            ? GlassTheme.textTertiary
                            : GlassTheme.accentPurple),
                    const SizedBox(width: 4),
                    Text('导入',
                        style: TextStyle(
                            color: isImporting
                                ? GlassTheme.textTertiary
                                : GlassTheme.accentPurple,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalStatus() {
    if (_importingModelId != null) {
      return Text('导入中…',
          style: const TextStyle(
              color: GlassTheme.accentPurple, fontSize: 13));
    }
    final downloading = _progress.values.where((p) => p < 1).length;
    if (downloading > 0) {
      return Text('$downloading 个下载中…',
          style: const TextStyle(
              color: GlassTheme.accentPurple, fontSize: 13));
    }
    if (_downloaded.isNotEmpty) {
      return Text('${_downloaded.length} 个已就绪',
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

    return _modelCard(
      title: model.displayName,
      subtitle: '约 ${model.sizeLabel} · ${model.license}',
      modelId: model.id,
      isReady: isReady,
      isDownloading: isDownloading,
      progress: p,
      error: error,
      tags: [
        _capLabel(model),
        _tierLabel(model.tier),
        model.notes,
      ],
      onDownload: () => _startDownload(model),
      onDelete: () => _deleteModel(model.id),
    );
  }

  Widget _buildUserModelCard(String modelId) {
    return _modelCard(
      title: modelId,
      subtitle: '用户导入',
      modelId: modelId,
      isReady: true,
      isDownloading: false,
      progress: 0,
      error: null,
      tags: const ['自定义', '', ''],
      onDownload: null,
      onDelete: () => _deleteModel(modelId),
    );
  }

  // ── 通用模型卡片 ──

  Widget _modelCard({
    required String title,
    required String subtitle,
    required String modelId,
    required bool isReady,
    required bool isDownloading,
    required double progress,
    String? error,
    List<String> tags = const [],
    VoidCallback? onDownload,
    VoidCallback? onDelete,
  }) {
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
                      Text(title,
                          style: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(subtitle,
                          style: const TextStyle(
                              color: GlassTheme.textTertiary,
                              fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildActionButton(
                  modelId: modelId,
                  isReady: isReady,
                  isDownloading: isDownloading,
                  progress: progress,
                  error: error,
                  onDownload: onDownload,
                  onDelete: onDelete,
                ),
              ],
            ),
            if (tags.any((t) => t.isNotEmpty)) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  _tag(tags[0], GlassTheme.accentPurple),
                  if (tags.length > 1 && tags[1].isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _tag(tags[1], const Color(0xFF34C759)),
                  ],
                  if (tags.length > 2 && tags[2].isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _tag(tags[2], const Color(0xFFFF9500)),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String modelId,
    required bool isReady,
    required bool isDownloading,
    required double progress,
    String? error,
    VoidCallback? onDownload,
    VoidCallback? onDelete,
  }) {
    if (error != null) {
      return _smallButton(
        '重试',
        color: GlassTheme.accentPink,
        onTap: onDownload,
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
              value: progress > 0 ? progress : null,
              strokeWidth: 2.5,
              color: GlassTheme.accentPurple,
            ),
            Text('${(progress * 100).toInt()}%',
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
        onTap: onDelete,
      );
    }
    return _smallButton(
      '下载',
      color: GlassTheme.accentPurple,
      onTap: onDownload,
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
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w500)),
    );
  }

  // ── 内联标签 ──

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