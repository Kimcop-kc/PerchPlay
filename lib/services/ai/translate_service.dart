import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../app_settings_service.dart';
import 'local_translate_backend.dart';

/// 翻译后端类型。
enum TranslateBackend {
  /// Google 免费 gtx 接口（无需 Key，走 translate.googleapis.com）
  google,

  /// OpenAI 兼容的 LLM 接口（用户自配 Key：DeepSeek/OpenAI/智谱/SiliconFlow）
  llm,

  /// 本地 Opus-MT ONNX（onnxruntime 直接加载本地下载的模型，无需联网）
  local,
}

/// 翻译服务：把 ASR 识别出的中文转成外文字幕（双语第二行）。
///
/// ## 为什么同时做「网络 + 本地」两个后端
/// NovaPlayer 反编译出来就是双路径：免费 Google gtx 兜底 + 用户自配 LLM Key
/// 提升质量。本服务对齐这个设计，并额外预留「本地 Opus-MT」后端 —— 一旦
/// Flutter SDK 升级到 onnx_translation 可用的版本，只需补 [TranslateBackend.local]
/// 分支，调用方无需改动。
///
/// ## 语言代码
/// [targetLang] 用 ISO 639-1（`en` / `ja` / `ko` / `fr` …）。中文是 ASR 的
/// 识别结果，固定作为源语言，所以这里**不暴露 srcLang**，减少误用。
class TranslateService {
  TranslateService({
    this.backend = TranslateBackend.google,
    this.targetLang = 'en',
    this.llmBaseUrl = 'https://api.deepseek.com/v1/chat/completions',
    this.llmApiKey = '',
    this.llmModel = 'deepseek-chat',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 当前后端。
  TranslateBackend backend;

  /// 目标语言（ISO 639-1）。
  String targetLang;

  /// LLM 后端的 OpenAI 兼容 base URL。
  String llmBaseUrl;

  /// LLM 后端的 API Key（空 = 未配置，退回 Google）。
  String llmApiKey;

  /// LLM 后端的模型名。
  String llmModel;

  /// 本地 Opus-MT 后端（懒初始化，仅在后端切到 local 时创建）。
  LocalTranslateBackend? _local;

  /// 本地模型目录（由调用方在切 local 前设置）。
  String? localModelDir;

  /// 释放底层 HTTP client + 本地模型。
  void dispose() {
    _client.close();
    _local?.dispose();
    _local = null;
  }

  /// 从持久化设置里加载后端相关配置，覆盖本实例字段。
  ///
  /// 设置统一收敛在 [AppSettingsService.instance]，由设置页写入；调用方在
  /// 需要翻译（切字幕）前调一次，让后端 / 目标语言跟随用户的选择。
  void loadFromSettings() {
    final s = AppSettingsService.instance;
    final sBackend = s.translateBackend;
    if (sBackend == 'llm') {
      backend = TranslateBackend.llm;
    } else if (sBackend == 'local') {
      backend = TranslateBackend.local;
    } else {
      // 未知值 / 默认：一律落到免费的 Google
      backend = TranslateBackend.google;
    }
    llmApiKey = s.llmApiKey;
    llmBaseUrl = s.llmBaseUrl;
    llmModel = s.llmModel;
    targetLang = s.translateTargetLang;
  }

  /// 本地离线翻译是否可用。
  ///
  /// 只有后端切到 local 且已配置模型目录时才可用；其它后端一律不可用。
  bool get isLocalReady =>
      backend == TranslateBackend.local &&
      localModelDir != null &&
      localModelDir!.isNotEmpty;

  /// 当前后端的可读中文标签（设置页 / 状态栏展示用）。
  ///
  /// llm 但未配 Key 时实际会回退 Google（见 [translate]），标签也如实提示。
  String get backendLabel {
    switch (backend) {
      case TranslateBackend.google:
        return 'Google 免费翻译';
      case TranslateBackend.llm:
        if (llmApiKey.trim().isEmpty) {
          return 'LLM 未配置 Key';
        }
        return '自配 LLM 翻译';
      case TranslateBackend.local:
        return '本地离线翻译';
    }
  }

  /// 翻译一段文本。
  ///
  /// [sourceLang] 传给 LLM 后端以避免翻反方向（google / local 不需要，它们
  /// 自己判断源语言）。默认 `auto`。
  ///
  /// 返回 null 表示「翻译失败 / 后端未就绪」。调用方收到 null 时应静默降级
  /// 为「只显示中文单语」，而不是报错中断字幕流。
  Future<String?> translate(String text, {String sourceLang = 'auto'}) async {
    final src = text.trim();
    if (src.isEmpty) return null;

    switch (backend) {
      case TranslateBackend.google:
        return _translateGoogle(src);
      case TranslateBackend.llm:
        if (llmApiKey.trim().isEmpty) {
          debugPrint('[Translate] LLM Key 未配置，翻译不可用');
          return null;
        }
        return _translateLlm(src, sourceLang: sourceLang);
      case TranslateBackend.local:
        return _translateLocal(src);
    }
  }

  /// 本地 Opus-MT 翻译（懒加载模型）。
  ///
  /// 当前只支持 zh↔en（opus-mt-zh-en）。
  /// 目标语言/模型加载不匹配时报告明确错误，不回退到网络翻译
  /// （离线模式的硬边界：禁止任何网络回退）。
  Future<String?> _translateLocal(String text) async {
    final dir = localModelDir;
    if (dir == null || dir.isEmpty) {
      debugPrint('[Translate] 本地翻译未配置模型目录');
      return null;
    }
    // Opus-MT zh-en 只能翻英文
    if (targetLang != 'en') {
      debugPrint('[Translate] 本地模型仅支持中→英，目标语言$targetLang不可用');
      return null;
    }
    _local ??= LocalTranslateBackend();
    if (!_local!.isLoaded) {
      final ok = await _local!.loadModel(dir);
      if (!ok) {
        debugPrint('[Translate] 本地模型加载失败，离线翻译不可用');
        return null;
      }
    }
    return _local!.translate(text);
  }

  /// Google 免费 gtx 接口（NovaPlayer 同款）。
  ///
  /// URL：`https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh&tl=$targetLang&dt=t&q=$text`
  Future<String?> _translateGoogle(String text) async {
    try {
      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single'
        '?client=gtx&sl=auto&tl=$targetLang&dt=t&q=${Uri.encodeQueryComponent(text)}',
      );
      final resp = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;

      // 返回形如 [[["译文","原文",...],...],...]
      final decoded = jsonDecode(resp.body);
      if (decoded is! List || decoded.isEmpty) return null;
      final segments = decoded[0];
      if (segments is! List) return null;

      final out = StringBuffer();
      for (final seg in segments) {
        if (seg is List && seg.isNotEmpty) {
          final translated = seg[0];
          if (translated is String && translated.isNotEmpty) {
            out.write(translated);
          }
        }
      }
      return out.isEmpty ? null : out.toString();
    } catch (e) {
      debugPrint('[Translate] Google 翻译失败: $e');
      return null;
    }
  }

  /// OpenAI 兼容 chat completions 后端。
  ///
  /// [sourceLang] 告诉 LLM 源语言（避免翻反方向），默认 `auto` 不指明。
  Future<String?> _translateLlm(String text,
      {String sourceLang = 'auto'}) async {
    final srcName = sourceLang == 'auto' ? '' : _langName(sourceLang);
    try {
      final uri = Uri.parse(llmBaseUrl);
      final resp = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $llmApiKey',
            },
            body: jsonEncode({
              'model': llmModel,
              'messages': [
                {
                  'role': 'system',
                  'content': '你是专业的字幕翻译引擎。只输出译文本身，不要任何解释、引号或多余内容。',
                },
                {
                  'role': 'user',
                  'content': srcName.isNotEmpty
                      ? '把下面的${srcName}字幕翻译成${_langName(targetLang)}：\n$text'
                      : '把下面的字幕翻译成${_langName(targetLang)}：\n$text',
                },
              ],
              'temperature': 0.3,
              'max_tokens': 2000,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;

      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final message = choices[0]['message'];
      final content = (message is Map) ? message['content'] : null;
      if (content is! String) return null;
      return content.trim().isEmpty ? null : content.trim();
    } catch (e) {
      debugPrint('[Translate] LLM 翻译失败: $e');
      return null;
    }
  }

  /// ISO 639-1 → 中文名（LLM prompt 里用）。
  static String _langName(String code) {
    const map = <String, String>{
      'en': '英文',
      'ja': '日文',
      'ko': '韩文',
      'fr': '法文',
      'de': '德文',
      'es': '西班牙文',
      'ru': '俄文',
      'pt': '葡萄牙文',
      'it': '意大利文',
      'ar': '阿拉伯文',
      'hi': '印地文',
      'th': '泰文',
      'vi': '越南文',
      'yue': '粤语（繁体）',
    };
    return map[code] ?? code.toUpperCase();
  }
}

/// 可选的翻译目标语言（UI 下拉选项）。
///
/// 保持少量高频语种，避免列表过长；用户有其它需求可自行扩展。
const List<String> aiSubtitleTargetLanguages = <String>[
  'en',
  'ja',
  'ko',
  'fr',
  'de',
  'es',
  'ru',
  'yue',
];
