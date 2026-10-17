import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass_theme.dart';
import '../../services/ai/ai_model.dart';
import '../../services/ai/ai_model_catalog.dart';
import '../../services/ai/model_downloader.dart';
import '../../services/ai/model_importer.dart';
import '../../services/device_info_service.dart';

/// AI 模型管理页面。
///
/// 列出全部预设模型 + 用户自行导入的模型。
/// 卡片可展开查看评分详情与设备推荐。
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
  final Set<String> _expanded = {};
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
          // 目录存在不放行，必须包含至少一个 .onnx 才认为已下载
          final files = await entry.list().toList();
          if (files.any((f) =>
              f.path.toLowerCase().endsWith('.onnx') && f is File)) {
            ids.add(entry.path.split(Platform.pathSeparator).last);
          }
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
    final expanded = _expanded.contains(model.id);
    final tooHeavy = DeviceInfoService.instance.isTooHeavy(model.minRamGB);
    final ramGB = DeviceInfoService.instance.ramGB;
    final ramLabel = ramGB > 0 ? '本机 ${ramGB.toStringAsFixed(1)} GB' : '本机 RAM 未知';

    return Card(
      color: Colors.white.withOpacity(0.6),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusMd)),
      child: InkWell(
        borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
        onTap: () {
          setState(() {
            expanded ? _expanded.remove(model.id) : _expanded.add(model.id);
          });
        },
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 顶行：名称 + 操作按钮 + 展开箭头 ──
                Row(
                  children: [
                    // 能力图标
                    _capIcon(model),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(model.displayName,
                                    style: const TextStyle(
                                        color: GlassTheme.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                              ),
                              if (isReady) ...[
                                const SizedBox(width: 6),
                                _badge('已下载', GlassTheme.accentTeal),
                              ],
                              if (tooHeavy) ...[
                                const SizedBox(width: 6),
                                _badge('内存不足', GlassTheme.accentPink),
                              ],
                              if (!tooHeavy && !isReady) ...[
                                const SizedBox(width: 6),
                                _badge(_recommendLabel(model, ramGB),
                                    GlassTheme.accentPurple),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Text(model.sizeLabel,
                                  style: const TextStyle(
                                      color: GlassTheme.textTertiary,
                                      fontSize: 12)),
                              const SizedBox(width: 8),
                              Text(model.license,
                                  style: const TextStyle(
                                      color: GlassTheme.textTertiary,
                                      fontSize: 12)),
                              const SizedBox(width: 8),
                              _langChip(model),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _buildActionButton(
                      modelId: model.id,
                      isReady: isReady,
                      isDownloading: isDownloading,
                      progress: p,
                      error: error,
                      onDownload: () => _startDownload(model),
                      onDelete: () => _deleteModel(model.id),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.keyboard_arrow_down,
                          size: 20, color: GlassTheme.textTertiary),
                    ),
                  ],
                ),

                // ── 展开面板：评分 + 设备推荐 + 备注 ──
                if (expanded) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Color(0x1A000000)),
                  const SizedBox(height: 12),

                  // 评分行
                  Row(
                    children: [
                      _metricColumn('速度', model.speedRating, Icons.speed),
                      const SizedBox(width: 24),
                      _metricColumn(
                          '质量', model.qualityRating, Icons.auto_awesome),
                      const SizedBox(width: 24),
                      _metricColumn(
                          '体积', _sizeToStars(model.sizeMB), Icons.storage),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 设备推荐
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (tooHeavy
                              ? GlassTheme.accentPink
                              : GlassTheme.accentTeal)
                          .withOpacity(0.08),
                      borderRadius:
                          BorderRadius.circular(GlassTheme.radiusSm),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          tooHeavy ? Icons.warning_amber : Icons.check_circle,
                          size: 16,
                          color: tooHeavy
                              ? GlassTheme.accentPink
                              : GlassTheme.accentTeal,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tooHeavy
                                ? '需要 ≥${model.minRamGB.toStringAsFixed(0)} GB RAM，$ramLabel，不推荐'
                                : '$ramLabel，可以流畅运行',
                            style: TextStyle(
                              color: tooHeavy
                                  ? GlassTheme.accentPink
                                  : GlassTheme.accentTeal,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 备注
                  Text(model.notes,
                      style: const TextStyle(
                          color: GlassTheme.textSecondary,
                          fontSize: 12,
                          height: 1.5)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUserModelCard(String modelId) {
    return Card(
      color: Colors.white.withOpacity(0.6),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusMd)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: GlassTheme.accentPurple.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.folder_outlined,
                  size: 18, color: GlassTheme.accentPurple),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(modelId,
                      style: const TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const Text('用户导入',
                      style: TextStyle(
                          color: GlassTheme.textTertiary, fontSize: 12)),
                ],
              ),
            ),
            _smallButton('删除',
                color: GlassTheme.textTertiary,
                onTap: () => _deleteModel(modelId)),
          ],
        ),
      ),
    );
  }

  // ── 展开面板元素 ──

  Widget _metricColumn(String label, int score, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: GlassTheme.textTertiary),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    color: GlassTheme.textTertiary, fontSize: 11)),
          ],
        ),
        const SizedBox(height: 4),
        _starRow(score),
      ],
    );
  }

  Widget _starRow(int score) {
    return Row(
      children: List.generate(5, (i) {
        final filled = i < score;
        return Icon(
          filled ? Icons.star : Icons.star_border,
          size: 14,
          color: filled ? const Color(0xFFFFB600) : const Color(0xFFDDDDDD),
        );
      }),
    );
  }

  int _sizeToStars(int sizeMB) {
    if (sizeMB <= 20) return 5;
    if (sizeMB <= 100) return 4;
    if (sizeMB <= 300) return 3;
    if (sizeMB <= 800) return 2;
    return 1;
  }

  String _recommendLabel(AiModel model, double ramGB) {
    if (ramGB <= 0) return '';
    if (model.minRamGB <= 2 && ramGB >= 6) return '推荐';
    if (model.tier == ModelTier.balanced && ramGB >= 6) return '推荐';
    if (model.tier == ModelTier.light && ramGB >= 4) return '适用';
    return '';
  }

  // ── 卡片头部元素 ──

  Widget _capIcon(AiModel model) {
    IconData icon;
    switch (model.kind) {
      case ModelKind.asr:
        icon = Icons.mic;
        break;
      case ModelKind.vad:
        icon = Icons.graphic_eq;
        break;
      case ModelKind.llm:
        icon = Icons.psychology;
        break;
      case ModelKind.nmt:
        icon = Icons.translate;
        break;
      case ModelKind.ocr:
        icon = Icons.text_fields;
        break;
      case ModelKind.embedding:
        icon = Icons.search;
        break;
      case ModelKind.vision:
        icon = Icons.image;
        break;
      case ModelKind.tts:
        icon = Icons.volume_up;
        break;
      case ModelKind.punctuation:
        icon = Icons.format_quote;
        break;
      case ModelKind.keywordSpotting:
        icon = Icons.hearing;
        break;
      case ModelKind.speakerDiarization:
        icon = Icons.group_work;
        break;
      case ModelKind.speechEnhancement:
        icon = Icons.noise_control_off;
        break;
    }
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
          color: GlassTheme.accentPurple.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, size: 18, color: GlassTheme.accentPurple),
    );
  }

  Widget _langChip(AiModel model) {
    if (model.languages.isEmpty) return const SizedBox.shrink();
    final labels = model.languages.take(3).map((l) => l.toUpperCase()).join('/');
    return Text(labels,
        style: const TextStyle(
            color: GlassTheme.textTertiary,
            fontSize: 10,
            fontFamily: 'monospace'));
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(4)),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w600)),
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
}