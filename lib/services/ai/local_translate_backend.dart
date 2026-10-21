import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:onnxruntime/onnxruntime.dart';

/// 本地 Opus-MT（MarianMT）翻译后端。
///
/// 把 Hugging Face 的 Helsinki-NLP/opus-mt-zh-en（或任意 MarianMT）导出成
/// ONNX 后，放到本地目录，运行时用 onnxruntime 直接加载推理，无需联网。
///
/// ## 为什么不用现成的 `onnx_translation` 包
/// `onnx_translation`（pub.dev，0.1.2）已经实现了同样的 MarianMT 推理循环，
/// 但它的 [OnnxModel.init] 只支持 `rootBundle.load()` —— 模型必须打包进
/// Flutter assets 才能加载。而本项目遵循「模型运行时下载到本地目录、不打包
/// 进 APK」的架构，两者冲突。
///
/// 因此这里**复用 onnx_translation 的核心算法**（tokenize / softmax greedy
/// decode / detokenize），仅把「`rootBundle.load` 读 assets」改成
/// 「`File.readAsBytes` 读本地目录」，从而无缝对接本项目的 `ModelDownloader`
/// 下载到 `ai_models/opus-mt-zh-en/` 的模型文件。
///
/// ## 需要的模型文件（Opus-MT 导出后）
/// - `encoder_model.onnx`
/// - `decoder_model.onnx`
/// - `vocab.json`
/// - `tokenizer_config.json`（可选，缺省用默认 pad/unk/eos）
/// - `generation_config.json`（可选）
///
/// ## 关于模型下载地址
/// Hugging Face 的 `Helsinki-NLP/opus-mt-zh-en` 仓库有 `onnx/` 子目录（含
/// encoder/decoder ONNX 与 tokenizer JSON），但需要经 `transformers` +
/// `optimum` 导出成标准命名。`ai_model_catalog.dart` 里的 url 需要指向真实
/// 可下载的 ONNX 文件（当前是 `.invalid` 占位，需补真实 URL 后才能真正下载）。
class LocalTranslateBackend {
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;
  Map<String, int> _vocab = {};
  Map<int, String> _reverseVocab = {};

  int _eosTokenId = 0;
  int _padTokenId = 0;
  int _unkTokenId = 1;

  final RegExp _specialTokenRegex = RegExp(r'<[^>]+>');

  bool get isLoaded => _encoderSession != null && _decoderSession != null;

  /// 从本地模型目录加载 Opus-MT ONNX。
  Future<bool> loadModel(String modelDir) async {
    dispose();

    final d = Directory(modelDir);
    if (!d.existsSync()) {
      debugPrint('[LocalTranslate] 模型目录不存在: $modelDir');
      return false;
    }

    final files = d.listSync().whereType<File>().toList();
    final map = <String, File>{};
    for (final f in files) {
      map[f.path.split(Platform.pathSeparator).last] = f;
    }

    final enc = map['encoder_model.onnx'];
    final dec = map['decoder_model.onnx'];
    final vocabFile = map['vocab.json'];
    if (enc == null || dec == null || vocabFile == null) {
      debugPrint(
        '[LocalTranslate] 缺模型文件（需要 encoder_model.onnx / '
        'decoder_model.onnx / vocab.json）',
      );
      return false;
    }

    try {
      OrtEnv.instance.init();

      // 词表
      final vocabStr = await vocabFile.readAsString();
      final vocabJson = jsonDecode(vocabStr) as Map<String, dynamic>;
      _vocab = vocabJson.map((k, v) => MapEntry(k, (v as num).toInt()));
      _reverseVocab = Map.fromEntries(
        _vocab.entries.map((e) => MapEntry(e.value, e.key)),
      );

      // 特殊 token id
      _eosTokenId = _reverseVocab.entries
          .firstWhere(
            (e) => e.value == '</s>',
            orElse: () => MapEntry(0, '</s>'),
          )
          .key;
      _unkTokenId = _reverseVocab.entries
          .firstWhere(
            (e) => e.value == '<unk>',
            orElse: () => MapEntry(1, '<unk>'),
          )
          .key;
      _padTokenId = _vocab['<pad>'] ?? _eosTokenId;

      // tokenizer_config（可选，覆盖 pad/unk）
      final tcfg = map['tokenizer_config.json'];
      if (tcfg != null) {
        try {
          final tc =
              jsonDecode(await tcfg.readAsString()) as Map<String, dynamic>;
          if (tc.containsKey('pad_token')) {
            final tok = tc['pad_token'] as String;
            if (_vocab.containsKey(tok)) _padTokenId = _vocab[tok]!;
          }
          if (tc.containsKey('unk_token')) {
            final tok = tc['unk_token'] as String;
            if (_vocab.containsKey(tok)) _unkTokenId = _vocab[tok]!;
          }
        } catch (_) {}
      }

      // 加载 ONNX session（从文件，符合「下载到本地」架构）
      final opts = OrtSessionOptions();
      _encoderSession = OrtSession.fromFile(enc, opts);
      _decoderSession = OrtSession.fromFile(dec, opts);
      opts.release();

      debugPrint('[LocalTranslate] 模型加载成功: $modelDir');
      return true;
    } catch (e) {
      debugPrint('[LocalTranslate] 加载失败: $e');
      dispose();
      return false;
    }
  }

  /// 中→外文翻译（greedy decode）。
  ///
  /// 返回 null 表示失败/未加载。
  Future<String?> translate(String text) async {
    if (!isLoaded) return null;
    if (text.trim().isEmpty) return null;

    try {
      final inputIds = _tokenize(text);
      final seqLen = inputIds.length;
      final attentionMask = List<int>.filled(seqLen, 1);

      final inputTensor = OrtValueTensor.createTensorWithDataList(inputIds, [
        1,
        seqLen,
      ]);
      final attentionMaskTensor = OrtValueTensor.createTensorWithDataList(
        attentionMask,
        [1, seqLen],
      );

      final encoderOutputs = await _encoderSession!.runAsync(OrtRunOptions(), {
        'input_ids': inputTensor,
        'attention_mask': attentionMaskTensor,
      });
      final encoderHiddenStates = encoderOutputs![0];
      if (encoderHiddenStates == null) return null;

      final decoderInputIds = <int>[_padTokenId];
      final generatedIds = <int>[];

      for (int step = 0; step < 100; step++) {
        final decInputTensor = OrtValueTensor.createTensorWithDataList(
          decoderInputIds,
          [1, decoderInputIds.length],
        );

        final decoderOutputs = await _decoderSession!.runAsync(
          OrtRunOptions(),
          {
            'input_ids': decInputTensor,
            'encoder_hidden_states': encoderHiddenStates,
            'encoder_attention_mask': attentionMaskTensor,
          },
        );

        final logitsTensor = decoderOutputs![0];
        if (logitsTensor == null || logitsTensor.value == null) break;

        final raw = logitsTensor.value as List<dynamic>;
        final lastStepLogits = (raw[0] as List<dynamic>).last as List<dynamic>;
        final logits =
            lastStepLogits.map((e) => (e as num).toDouble()).toList();
        final probs = _softmax(logits);

        int nextToken = 0;
        double best = double.negativeInfinity;
        for (int i = 0; i < probs.length; i++) {
          if (probs[i] > best) {
            best = probs[i];
            nextToken = i;
          }
        }

        generatedIds.add(nextToken);
        if (nextToken == _eosTokenId) break;
        decoderInputIds.add(nextToken);
      }

      return _detokenize(generatedIds);
    } catch (e) {
      debugPrint('[LocalTranslate] 翻译失败: $e');
      return null;
    }
  }

  void dispose() {
    try {
      _encoderSession?.release();
    } catch (_) {}
    try {
      _decoderSession?.release();
    } catch (_) {}
    _encoderSession = null;
    _decoderSession = null;
    _vocab = {};
    _reverseVocab = {};
  }

  // ── 以下算法复用 onnx_translation 的 tokenize/softmax/detokenize ──

  List<int> _tokenize(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return [_eosTokenId];

    final tokenIds = <int>[];
    final tokens = _vocab.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    int pos = 0;
    while (pos < normalized.length) {
      final match = _specialTokenRegex.matchAsPrefix(normalized, pos);
      if (match != null) {
        final specialTok = match.group(0)!;
        if (_vocab.containsKey(specialTok)) {
          tokenIds.add(_vocab[specialTok]!);
          pos += specialTok.length;
          while (pos < normalized.length && normalized[pos] == ' ') pos++;
          continue;
        }
      }

      bool matched = false;
      for (final tok in tokens) {
        if (tok.length > normalized.length - pos) continue;
        final substr = normalized.substring(pos, pos + tok.length);
        if (substr == tok) {
          tokenIds.add(_vocab[tok]!);
          pos += tok.length;
          matched = true;
          break;
        }
        if (tok.startsWith('▁')) {
          final plainTok = tok.substring(1);
          if ((pos == 0 || normalized[pos - 1] == ' ') &&
              normalized.substring(pos, pos + plainTok.length) == plainTok) {
            tokenIds.add(_vocab[tok]!);
            pos += plainTok.length;
            matched = true;
            break;
          }
        }
      }
      if (!matched) {
        tokenIds.add(_unkTokenId);
        pos += 1;
      } else {
        while (pos < normalized.length && normalized[pos] == ' ') pos++;
      }
    }
    tokenIds.add(_eosTokenId);
    return tokenIds;
  }

  List<double> _softmax(List<double> logits) {
    final maxValue = logits.reduce(max);
    final exps = logits.map((l) => exp(l - maxValue)).toList();
    final sumExp = exps.fold<double>(0.0, (a, b) => a + b);
    return exps.map((e) => e / sumExp).toList();
  }

  bool _isPunctuation(String token) {
    const punctuations = {
      '.',
      ',',
      '!',
      '?',
      ':',
      ';',
      '-',
      '—',
      '(',
      ')',
      '[',
      ']',
      '"',
      "'",
    };
    return punctuations.contains(token);
  }

  String _detokenize(List<int> tokenIds) {
    final tokens = tokenIds.map((id) => _reverseVocab[id] ?? '<unk>').toList();
    final buffer = StringBuffer();
    for (final tok in tokens) {
      if (tok == '</s>') continue;
      if (tok.startsWith('<') && tok.endsWith('>')) {
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(tok);
        continue;
      }
      if (tok.startsWith('▁')) {
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(tok.substring(1));
      } else if (_isPunctuation(tok)) {
        buffer.write(tok);
      } else {
        buffer.write(tok);
      }
    }
    return buffer.toString().trim();
  }
}
