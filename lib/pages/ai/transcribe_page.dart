import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/theme/glass_theme.dart';
import '../../services/ai/ai_model.dart';
import '../../services/ai/ai_model_catalog.dart';
import '../../services/ai/model_downloader.dart';
import '../../services/ai/punct_service.dart';
import '../../services/ai/speech_service.dart';
import '../../services/ai/tts_service.dart';

/// 语音转写页面。
///
/// 流程：选模型 → 选 WAV 文件 → 加载模型 → 转写 → 标点恢复 → 展示结果。
/// 结果页支持 TTS 朗读。
class TranscribePage extends StatefulWidget {
  const TranscribePage({super.key});

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

enum _Step { selectModel, selectAudio, transcribing, done }

class _TranscribePageState extends State<TranscribePage> {
  final _speech = SpeechService();
  final _punct = PunctService();
  final _tts = TtsService();
  final _downloader = ModelDownloader();

  _Step _step = _Step.selectModel;

  /// 用户选中的模型 id
  String? _modelId;

  /// 用户选中的 WAV 文件路径
  String? _wavPath;

  /// 转写结果（原始）
  String? _rawResult;

  /// 标点后结果
  String? _result;

  /// 错误信息
  String? _error;

  /// TTS 是否正在合成
  bool _ttsBusy = false;

  /// 已下载的模型 id → AiModel（仅 ASR 类）
  List<AiModel> _availableModels = [];
  bool _scanning = true;

  /// 下载进度
  final Map<String, double> _dlProgress = {};

  @override
  void initState() {
    super.initState();
    _scanModels();
  }

  Future<void> _scanModels() async {
    final dir = await ModelDownloader.modelsDir();
    final downloaded = <String>{};
    if (await dir.exists()) {
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is Directory) {
          final files = await entry.list().toList();
          if (files.any((f) =>
              f.path.toLowerCase().endsWith('.onnx') && f is File)) {
            downloaded.add(entry.path.split(Platform.pathSeparator).last);
          }
        }
      }
    }
    final models = AiModelCatalog.all.where((m) {
      return m.capabilities.contains(AiCapability.asr) ||
          m.capabilities.contains(AiCapability.asrStreaming);
    }).where((m) => downloaded.contains(m.id)).toList();

    if (!mounted) return;
    setState(() {
      _availableModels = models;
      _scanning = false;
    });
  }

  @override
  void dispose() {
    _speech.dispose();
    _punct.dispose();
    _tts.dispose();
    _downloader.dispose();
    super.dispose();
  }

  // ── 步骤 1：选模型 ──

  Future<void> _pickModel(AiModel model) async {
    final dir = await ModelDownloader.modelsDir();
    final modelDir = '${dir.path}${Platform.pathSeparator}${model.id}';

    // 先校验本地 MANIFEST（如果有），损坏就直接清理避免 SpeechService 崩溃
    final corrupted = await ModelDownloader.verifyModel(modelDir);
    if (corrupted.isNotEmpty) {
      debugPrint('[TranscribePage] 校验失败: $modelDir → $corrupted');
      try {
        final broken = Directory(modelDir);
        if (await broken.exists()) {
          await broken.delete(recursive: true);
        }
        await _scanModels();
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('模型已损坏（$corrupted），已自动删除。请重新下载'),
          backgroundColor: GlassTheme.accentPink,
        ),
      );
      return;
    }

    // SpeechService.loadModel 自动扫描目录找 .onnx + tokens.txt
    _speech.loadModel(modelDir);
    if (!_speech.isLoaded) {
      // 模型损坏 → 自动删除目录以免下次再次崩溃
      debugPrint('[TranscribePage] 模型加载失败，自动删除: $modelDir');
      try {
        final broken = Directory(modelDir);
        if (await broken.exists()) {
          await broken.delete(recursive: true);
        }
        await _scanModels();
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('模型已损坏，已自动删除。请重新下载'),
          backgroundColor: GlassTheme.accentPink,
        ),
      );
      return;
    }

    setState(() {
      _modelId = model.id;
      _error = null;
      _step = _Step.selectAudio;
    });
  }

  // ── 步骤 2：选 WAV 文件 ──

  Future<void> _pickWav() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'm4a', 'aac', 'ogg', 'flac'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    // TODO(P2): 非 WAV 文件需要用 ffmpeg 转码。当前硬限制 WAV。
    if (!path.toLowerCase().endsWith('.wav')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('暂不支持非 WAV 格式（需要 FFmpeg 转码，P2 待做）'),
          backgroundColor: Color(0xFFFF9500),
        ),
      );
      return;
    }

    setState(() {
      _wavPath = path;
      _result = null;
      _error = null;
      _step = _Step.transcribing;
    });

    await _runTranscribe();
  }

  // ── 步骤 3：转写 ──

  Future<void> _runTranscribe() async {
    final wav = _wavPath;
    if (wav == null) return;

    try {
      // 1. ASR 转写
      final text = await _speech.transcribeFile(wav);
      if (!mounted) return;

      final raw = (text == null || text.isEmpty) ? '(未识别到语音内容)' : text;
      String display = raw;

      // 2. 标点恢复（如果标点模型已下载）
      if (raw != '(未识别到语音内容)') {
        final pDir = await _resolvePunctModelDir();
        if (pDir != null) {
          _punct.loadModel(pDir);
          if (_punct.isLoaded) {
            display = _punct.restore(raw);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _step = _Step.done;
        _rawResult = raw;
        _result = display;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.done;
        _rawResult = null;
        _result = null;
        _error = '转写失败: $e';
      });
    }
  }

  // ── 重来 ──

  void _reset() {
    setState(() {
      _step = _Step.selectModel;
      _wavPath = null;
      _rawResult = null;
      _result = null;
      _error = null;
    });
  }

  // ── 下载缺失模型 ──

  Future<void> _downloadModel(AiModel model) async {
    setState(() => _dlProgress[model.id] = 0);
    try {
      await _downloader.download(
        model: model,
        preferredSource: DownloadSource.huggingface,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _dlProgress[model.id] = p);
        },
      );
      await _scanModels();
      if (!mounted) return;
      setState(() => _dlProgress.remove(model.id));
    } catch (e) {
      if (!mounted) return;
      setState(() => _dlProgress.remove(model.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('下载失败: $e'),
          backgroundColor: GlassTheme.accentPink,
        ),
      );
    }
  }

  /// 查找标点模型目录。
  Future<String?> _resolvePunctModelDir() async {
    final dir = await ModelDownloader.modelsDir();
    final d = Directory('${dir.path}${Platform.pathSeparator}punct-ct-transformer');
    if (!await d.exists()) return null;
    final hasOnnx = await d.list().any((e) =>
        e is File && e.path.toLowerCase().endsWith('.onnx'));
    return hasOnnx ? d.path : null;
  }

  /// 查找 TTS 模型目录（按优先级：中文 > 英文 > 粤语）。
  Future<String?> _resolveTtsModelDir() async {
    final dir = await ModelDownloader.modelsDir();
    for (final id in ['vits-zh', 'vits-en', 'vits-yue']) {
      final d = Directory('${dir.path}${Platform.pathSeparator}$id');
      if (!await d.exists()) continue;
      final hasOnnx = await d.list().any((e) =>
          e is File && e.path.toLowerCase().endsWith('.onnx'));
      if (hasOnnx) return d.path;
    }
    return null;
  }

  /// TTS 朗读当前转写结果。
  Future<void> _speakResult() async {
    final text = _result;
    if (text == null || text.isEmpty) return;
    if (_ttsBusy) return;

    final ttsDir = await _resolveTtsModelDir();
    if (ttsDir == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先下载 TTS 模型（VITS-中文/英文/粤语）'),
          backgroundColor: Color(0xFFFF9500),
        ),
      );
      return;
    }

    setState(() => _ttsBusy = true);
    try {
      _tts.loadModel(ttsDir);
      final audio = _tts.synthesize(text, speed: 1.0);
      if (audio == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('TTS 合成失败'),
            backgroundColor: GlassTheme.accentPink,
          ),
        );
        return;
      }

      // 写临时 WAV 文件
      final tmpDir = await getTemporaryDirectory();
      final wavFile = File(
          '${tmpDir.path}${Platform.pathSeparator}tts_${DateTime.now().millisecondsSinceEpoch}.wav');
      sherpa.writeWave(
        filename: wavFile.path,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('朗读已生成: ${wavFile.path}'),
          backgroundColor: GlassTheme.accentTeal,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _ttsBusy = false);
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top + 24;
    return Scaffold(
      backgroundColor: GlassTheme.bg,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, topPad, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAppBar(),
              const SizedBox(height: 24),
              // 步骤指示器
              _buildStepper(),
              const SizedBox(height: 24),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: const Icon(Icons.arrow_back_ios,
              size: 20, color: GlassTheme.textSecondary),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('语音转写',
              style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800)),
        ),
        if (_step != _Step.selectModel)
          TextButton(
            onPressed: _reset,
            child: const Text('重来',
                style: TextStyle(
                    color: GlassTheme.accentPurple,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Widget _buildStepper() {
    return Row(
      children: [
        _stepDot(1, '选模型'),
        _stepLine(1),
        _stepDot(2, '选音频'),
        _stepLine(2),
        _stepDot(3, '转写'),
      ],
    );
  }

  Widget _stepDot(int n, String label) {
    final active = _step.index + 1 >= n;
    final current = _step.index + 1 == n;
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: current
                ? GlassTheme.accentPurple
                : active
                    ? GlassTheme.accentTeal
                    : Colors.grey.withOpacity(0.2),
          ),
          child: Center(
            child: _step == _Step.transcribing && n == 3
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text('$n',
                    style: TextStyle(
                        color:
                            active ? Colors.white : GlassTheme.textTertiary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                color: current
                    ? GlassTheme.accentPurple
                    : active
                        ? GlassTheme.accentTeal
                        : GlassTheme.textTertiary,
                fontSize: 11,
                fontWeight: current ? FontWeight.w600 : FontWeight.w400)),
      ],
    );
  }

  Widget _stepLine(int from) {
    final active = _step.index >= from;
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 18),
        color: active
            ? GlassTheme.accentTeal.withOpacity(0.5)
            : Colors.grey.withOpacity(0.15),
      ),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case _Step.selectModel:
        return _buildModelPicker();
      case _Step.selectAudio:
        return _buildAudioPicker();
      case _Step.transcribing:
        return _buildTranscribing();
      case _Step.done:
        return _buildResult();
    }
  }

  // ── 模型选择 ──

  Widget _buildModelPicker() {
    if (_scanning) {
      return const Center(
        child: CircularProgressIndicator(
            strokeWidth: 2, color: GlassTheme.accentPurple),
      );
    }

    // 所有 ASR 模型（不管下载与否），让用户看到全貌
    final allAsr = AiModelCatalog.all
        .where((m) =>
            m.capabilities.contains(AiCapability.asr) ||
            m.capabilities.contains(AiCapability.asrStreaming))
        .toList();

    final downloadedIds =
        _availableModels.map((m) => m.id).toSet();

    return ListView.builder(
      itemCount: allAsr.length,
      itemBuilder: (context, index) {
        final model = allAsr[index];
        final isReady = downloadedIds.contains(model.id);
        final downloading = _dlProgress.containsKey(model.id);
        final progress = _dlProgress[model.id] ?? 0;

        return Card(
          color: Colors.white.withOpacity(0.6),
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GlassTheme.radiusMd)),
          child: InkWell(
            borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
            onTap: isReady ? () => _pickModel(model) : null,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(
                    isReady ? Icons.check_circle : Icons.cloud_download,
                    color: isReady
                        ? GlassTheme.accentTeal
                        : GlassTheme.textTertiary,
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(model.displayName,
                            style: const TextStyle(
                                color: GlassTheme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          '${model.sizeLabel} · ${model.languages.join("/")} · ${model.license}',
                          style: const TextStyle(
                              color: GlassTheme.textTertiary,
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (downloading)
                    SizedBox(
                      width: 60,
                      height: 28,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: progress > 0 ? progress : null,
                            strokeWidth: 2,
                            color: GlassTheme.accentPurple,
                          ),
                          Text('${(progress * 100).toInt()}%',
                              style: const TextStyle(
                                  color: GlassTheme.accentPurple,
                                  fontSize: 11)),
                        ],
                      ),
                    )
                  else if (!isReady)
                    GestureDetector(
                      onTap: () => _downloadModel(model),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: GlassTheme.accentPurple.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('下载',
                            style: TextStyle(
                                color: GlassTheme.accentPurple,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ),
                    )
                  else if (isReady)
                    const Icon(Icons.chevron_right,
                        color: GlassTheme.textTertiary, size: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── 音频选择 ──

  Widget _buildAudioPicker() {
    final model = AiModelCatalog.all.firstWhere(
      (m) => m.id == _modelId,
      orElse: () => AiModelCatalog.all.first,
    );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic,
              size: 64,
              color: GlassTheme.accentPurple.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('已选择：${model.displayName}',
              style: const TextStyle(
                  color: GlassTheme.textSecondary, fontSize: 14)),
          const SizedBox(height: 8),
          const Text('请选择要转写的 WAV 音频文件',
              style: TextStyle(
                  color: GlassTheme.textTertiary, fontSize: 13)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _pickWav,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 32, vertical: 14),
              decoration: BoxDecoration(
                color: GlassTheme.accentPurple,
                borderRadius:
                    BorderRadius.circular(GlassTheme.radiusSm),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.audio_file,
                      color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('选择音频文件',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('支持 WAV 格式 · MP3/M4A 等格式将在后续版本支持',
              style: TextStyle(
                  color: GlassTheme.textTertiary.withOpacity(0.6),
                  fontSize: 11)),
        ],
      ),
    );
  }

  // ── 转写中 ──

  Widget _buildTranscribing() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
                strokeWidth: 3, color: GlassTheme.accentPurple),
          ),
          const SizedBox(height: 20),
          const Text('正在转写…',
              style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            _wavPath != null
                ? _wavPath!.split(Platform.pathSeparator).last
                : '',
            style: const TextStyle(
                color: GlassTheme.textTertiary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── 结果 ──

  Widget _buildResult() {
    final hasError = _error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 状态标签
        Row(
          children: [
            Icon(
              hasError ? Icons.error : Icons.check_circle,
              size: 20,
              color: hasError
                  ? GlassTheme.accentPink
                  : GlassTheme.accentTeal,
            ),
            const SizedBox(width: 8),
            Text(
              hasError ? '转写出错' : '转写完成',
              style: TextStyle(
                  color: hasError
                      ? GlassTheme.accentPink
                      : GlassTheme.accentTeal,
                  fontSize: 16,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 结果文本
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.7),
              borderRadius:
                  BorderRadius.circular(GlassTheme.radiusMd),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                hasError ? _error! : (_result ?? ''),
                style: TextStyle(
                  color: hasError
                      ? GlassTheme.accentPink
                      : GlassTheme.textPrimary,
                  fontSize: 15,
                  height: 1.6,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 操作按钮
        Row(
          children: [
            Expanded(
              child: _outlineButton('重新选择文件', _pickWav),
            ),
            const SizedBox(width: 12),
            if (!hasError)
              Expanded(
                child: _ttsBusy
                    ? const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: GlassTheme.accentPurple),
                        ),
                      )
                    : _outlineButton('朗读结果', _speakResult),
              ),
          ],
        ),
      ],
    );
  }

  Widget _outlineButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: GlassTheme.accentPurple.withOpacity(0.3),
          ),
          borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
        ),
        child: Center(
          child: Text(label,
              style: const TextStyle(
                  color: GlassTheme.accentPurple,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}