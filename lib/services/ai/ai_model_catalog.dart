/// 端侧 AI 模型清单（33 个模型，涵盖 ASR/VAD/TTS/标点/翻译/OCR/Embedding/视觉/KWS）
///
/// 为什么把清单单独放一个文件：
///  - 加/删模型只改这里，选择逻辑（`AiModelRegistry`）一行都不用动；
///  - 体积、许可证、语言、评分这些是「产品决策」，集中放才方便横向对比；
///  - 以后如果改成从远端拉清单，替换的也只是这一个文件。
///
/// ## 目标硬件（已确认）
/// 小米 15 Pro / 骁龙 8 Elite / 16GB RAM。这类旗舰**可以放开 `highQuality` 档**
/// （whisper-large-v3-turbo、qwen2.5-3b-instruct）：16GB 内存撑得住 1.6~2GB 的权重
/// 加运行时开销。但请牢记：
///  - 这些模型**依然只能由用户自己下载**，APK 里**不打包任何模型权重**，
///    安装包大小不随清单条目增长（每加一条模型只多几十字节的元数据）；
///  - 上面两个模型 8GB 的内存门槛在 16GB 旗舰上可行，但**仍是估算值**，
///    需要真机校准（见下方 minRamGB 说明）。
///
/// ## 评分
/// `speedRating` / `qualityRating` 是 1~5 的人工标定分（不是从体积算出来的），
/// 用于在选择界面上给用户看「速度 / 质量」两列，见 `_buildMetricsRow`。
///
/// ⚠️ 现状（发布前必须处理）：
///  - 所有 `sha256` 都是 null；
///  - 所有 `minRamGB` 都是**估算值**：按模型体积的经验比例推算
///    （权重 + 量化误差 + 运行时开销），**不是真机实测**。
///    接上原生推理后必须拿低配/高配各一台设备重新校准 —— 估高了会误伤能跑的机器，
///    估低了会放进必然闪退的机器。16GB 旗舰只是「按估算能跑」，
///    不等于已经在小米 15 Pro 上验过。
///
/// 为什么占位用 `.invalid` 而不是 example.com：`.invalid` 是 RFC 2606 保留、
/// 永远解析不到的域名。万一将来有人把占位值接进下载流程，也只会立刻失败，
/// 而不会真的去请求一个别人的地址、把错误数据当成模型文件存下来。
library;

import 'ai_model.dart';

/// Whisper 官方支持 99 语种，这里只列本项目 UI 会展示的常用语种
///
/// 为什么不写满 99 个：这份清单用于展示和筛选，不是能力边界；
/// 写满既占地方又容易抄错，真实的语种数量写在对应条目的 notes 里。
const List<String> _whisperLanguages = <String>[
  'zh',
  'en',
  'ja',
  'ko',
  'fr',
  'de',
  'es',
  'ru',
  'pt',
  'it',
  'ar',
  'hi',
  'yue',
];

/// MADLAD 覆盖面 400+ 语种，同样只列常用的一批（理由同 [_whisperLanguages]）
const List<String> _madladLanguages = <String>[
  'zh',
  'en',
  'ja',
  'ko',
  'fr',
  'de',
  'es',
  'ru',
  'pt',
  'it',
  'ar',
  'hi',
  'tr',
  'vi',
  'th',
  'id',
  'nl',
  'pl',
  'uk',
  'yue',
];

/// 全量模型清单
///
/// 顺序即 `byCapability` 的返回顺序：同类模型把「默认该优先考虑」的排前面，
/// UI 不排序直接展示时也是合理的。
///
/// `kind` 是「哪种模型」而不是「能干什么」：翻译能力下 nmt 和 llm 都在，
/// 排序时轻量档要让位给专用 NMT（详见 `AiModelRegistry` 的 kind 优先表）。
class AiModelCatalog {
  AiModelCatalog._();

  static const List<AiModel> all = <AiModel>[
    // ── VAD / 语音活动检测 ──────────────────────────────────────────────
    AiModel(
      id: 'silero-vad',
      displayName: 'Silero VAD 语音活动检测',
      capabilities: <AiCapability>{AiCapability.vad},
      kind: ModelKind.vad,
      tier: ModelTier.light,
      sizeMB: 2,
      speedRating: 5,
      qualityRating: 5,
      languages: <String>[],
      license: 'Apache-2.0',
      minRamGB: 1.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.githubRelease,
          url:
              'https://github.com/k2-fsa/sherpa-onnx/releases/'
              'download/asr-models/silero_vad.onnx',
          sha256: null,
        ),
      ],
      notes: '2MB 就能过滤掉无声片段，省下大量白跑的 ASR 计算，值得一直开着',
    ),
    // ── ASR：低延迟流式中英 ────────────────────────────────────────────
    AiModel(
      id: 'zipformer-zh-en-streaming',
      displayName: 'Zipformer 中英流式识别',
      capabilities: <AiCapability>{AiCapability.asrStreaming, AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.light,
      sizeMB: 80,
      speedRating: 5,
      qualityRating: 3,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
              'resolve/main/encoder-epoch-99-avg-1.int8.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'encoder-epoch-99-avg-1.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
                'resolve/main/encoder-epoch-99-avg-1.int8.onnx',
            'decoder-epoch-99-avg-1.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
                'resolve/main/decoder-epoch-99-avg-1.int8.onnx',
            'joiner-epoch-99-avg-1.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
                'resolve/main/joiner-epoch-99-avg-1.int8.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
                'resolve/main/tokens.txt',
          },
          fileSha256s: <String, String>{
            'encoder-epoch-99-avg-1.int8.onnx': '8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b',
            'decoder-epoch-99-avg-1.int8.onnx': '1a70c593d71e53f023f5f55b0b4cfff5055abb786ee3992e5f63dc2e273cc4fa',
            'joiner-epoch-99-avg-1.int8.onnx': '1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0',
          },
        ),
      ],
      notes: '80MB 的低延迟流式方案，中英混说也跟得住，低端机优先选它',
    ),
    // ── ASR：SenseVoice 多语 ───────────────────────────────────────────
    AiModel(
      id: 'sensevoice-small',
      displayName: 'SenseVoice Small 多语识别',
      capabilities: <AiCapability>{AiCapability.asr, AiCapability.asrStreaming},
      kind: ModelKind.asr,
      tier: ModelTier.balanced,
      sizeMB: 234,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh', 'en', 'ja', 'ko', 'yue'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/'
              'resolve/main/model.int8.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'model.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/'
                'resolve/main/model.int8.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/'
                'resolve/main/tokens.txt',
          },
          fileSha256s: <String, String>{
            'model.int8.onnx': 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
          },
        ),
      ],
      notes: '自带标点与语种判断，中日韩英粤一把抓，是默认首选的那一档',
    ),
    // ── ASR：Paraformer 中文系 ─────────────────────────────────────────
    AiModel(
      id: 'paraformer-zh-small',
      displayName: 'Paraformer 中文小模型',
      capabilities: <AiCapability>{AiCapability.asrStreaming, AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.light,
      sizeMB: 100,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-paraformer-zh-small-2024-03-09/'
              'resolve/main/model.int8.onnx',
          sha256: '3ef6c19369b912f7caf3cef8e545c5ccd1a33d9d7ec792a46668dc41c4b229ec',
        ),
      ],
      notes: 'Paraformer 中文小模型，100MB 轻量但中文准确率比 Zipformer 好',
    ),
    AiModel(
      id: 'paraformer-zh-full',
      displayName: 'Paraformer 中文完整版',
      capabilities: <AiCapability>{AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.highQuality,
      sizeMB: 310,
      speedRating: 4,
      qualityRating: 5,
      languages: <String>['zh'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-paraformer-zh-2024-03-09/'
              'resolve/main/model.int8.onnx',
          sha256: '90bc03034ae1bef9575f8cc798cd1519c8be8aa9e8b458a033e32017ff4d584c',
        ),
      ],
      notes: '纯中文非流式的天花板，准确率最高但体积大，适合对精度要求严格的场景',
    ),
    AiModel(
      id: 'paraformer-zh-streaming',
      displayName: 'Paraformer 中文流式识别',
      capabilities: <AiCapability>{AiCapability.asrStreaming, AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.balanced,
      sizeMB: 220,
      speedRating: 5,
      qualityRating: 5,
      languages: <String>['zh'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-streaming-paraformer-zh/'
              'resolve/main/encoder.int8.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'encoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-paraformer-zh/'
                'resolve/main/encoder.int8.onnx',
            'decoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-paraformer-zh/'
                'resolve/main/decoder.int8.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-paraformer-zh/'
                'resolve/main/tokens.txt',
          },
          fileSha256s: <String, String>{
            'encoder.int8.onnx': '81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a',
            'decoder.int8.onnx': 'f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f',
          },
        ),
      ],
      notes: '中文流式老牌方案，延迟低；标点要另配，确定纯中文时再选它',
    ),
    AiModel(
      id: 'paraformer-trilingual-streaming',
      displayName: 'Paraformer 三语流式（中粤英）',
      capabilities: <AiCapability>{AiCapability.asrStreaming, AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.balanced,
      sizeMB: 200,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh', 'yue', 'en'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en/'
              'resolve/main/encoder.int8.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'encoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en/'
                'resolve/main/encoder.int8.onnx',
            'decoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en/'
                'resolve/main/decoder.int8.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en/'
                'resolve/main/tokens.txt',
          },
          fileSha256s: <String, String>{
            'encoder.int8.onnx': '6047a644b41b236d9d8e89e3b94ef39d1b7037daab028131b722ca52e10b0357',
            'decoder.int8.onnx': '545427acf508452b7d89969be082c8128c681e3432ff43aef09f6159f4b61a7e',
          },
        ),
      ],
      notes: '中文+粤语+英语三语流式，广东/香港用户首选，比 SenseVoice 粤语更准',
    ),
    // ── ASR：Whisper 多语系 ─────────────────────────────────────────────
    AiModel(
      id: 'whisper-base',
      displayName: 'Whisper Base 99 语种',
      capabilities: <AiCapability>{AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.multilingual,
      sizeMB: 150,
      speedRating: 3,
      qualityRating: 3,
      languages: _whisperLanguages,
      license: 'MIT',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-whisper-base/'
              'resolve/main/base-encoder.int8.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'base-encoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-base/'
                'resolve/main/base-encoder.int8.onnx',
            'base-decoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-base/'
                'resolve/main/base-decoder.int8.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-base/'
                'resolve/main/base-tokens.txt',
          },
          fileSha256s: <String, String>{
            'base-encoder.int8.onnx': '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11',
            'base-decoder.int8.onnx': '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d',
          },
        ),
      ],
      notes: '99 语种覆盖面，中文一般但冷门语种只有它，150MB 适合先跑通流程',
    ),
    AiModel(
      id: 'whisper-small',
      displayName: 'Whisper Small 99 语种',
      capabilities: <AiCapability>{AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.multilingual,
      sizeMB: 500,
      speedRating: 2,
      qualityRating: 4,
      languages: _whisperLanguages,
      license: 'MIT',
      minRamGB: 4.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-whisper-small/'
              'resolve/main/small-encoder.int8.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'small-encoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-small/'
                'resolve/main/small-encoder.int8.onnx',
            'small-decoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-small/'
                'resolve/main/small-decoder.int8.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-small/'
                'resolve/main/small-tokens.txt',
          },
          fileSha256s: <String, String>{
            'small-encoder.int8.onnx': '4cbe7b22fa9026b843b60a68640c747de05bafb1a11b57edc0e66c232d9f33a9',
            'small-decoder.int8.onnx': 'acad50b5c782696e91b55914cc5ab4f756f1532f76e22aa6fc615f39fb69a8ee',
          },
        ),
      ],
      notes: '中文准确率比 base 明显好，代价是慢一倍多，中端机勉强能接受',
    ),
    AiModel(
      id: 'whisper-large-v3',
      displayName: 'Whisper Large v3 99 语种',
      capabilities: <AiCapability>{AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.highQuality,
      sizeMB: 1600,
      speedRating: 2,
      qualityRating: 5,
      languages: _whisperLanguages,
      license: 'MIT',
      minRamGB: 8.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-whisper-large-v3/'
              'resolve/main/large-v3-encoder.int8.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'large-v3-encoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-large-v3/'
                'resolve/main/large-v3-encoder.int8.onnx',
            'large-v3-decoder.int8.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-large-v3/'
                'resolve/main/large-v3-decoder.int8.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-whisper-large-v3/'
                'resolve/main/large-v3-tokens.txt',
          },
          fileSha256s: <String, String>{
            'large-v3-encoder.int8.onnx': 'd531cf17248acc43e8c09b472a0877055e770877857a5332fc1304b36534ec85',
            'large-v3-decoder.int8.onnx': 'ebc6bfd88e162a46cb3edee8a7e727e1dcbc65cabecb19e2573695e4d495e1af',
          },
        ),
      ],
      notes: '99 语种里质量最好的一档（v3 Turbo 仓库 gated，改用非 Turbo 版），1.6GB，仅高配机',
    ),
    // ── ASR：全语种（1600+ 语言）── 旗舰超大模型 ─────────────────────
    AiModel(
      id: 'omnilingual-asr-1b',
      displayName: 'Omnilingual ASR 1600 语种',
      capabilities: <AiCapability>{AiCapability.asr},
      kind: ModelKind.asr,
      tier: ModelTier.highQuality,
      sizeMB: 850,
      speedRating: 2,
      qualityRating: 4,
      languages: <String>['zh', 'en', 'ja', 'ko', 'ar', 'yue'],
      license: 'Apache-2.0',
      minRamGB: 8.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-2025-11-12/'
              'resolve/main/model.onnx',
          sha256: '49465dc6dbf82b86a8025f8b45d7be34d43d63944cb0ed022e45ff212d30d306',
          fileUrls: <String, String>{
            'model.onnx':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-2025-11-12/'
                'resolve/main/model.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-2025-11-12/'
                'resolve/main/tokens.txt',
          },
          fileSha256s: <String, String>{
            'model.onnx': '49465dc6dbf82b86a8025f8b45d7be34d43d63944cb0ed022e45ff212d30d306',
          },
        ),
      ],
      notes: '1600+ 语种的超级覆盖，1B 参数仅旗舰机能跑，冷门方言的最后防线',
    ),
    // ── 标点恢复 ────────────────────────────────────────────────────────
    AiModel(
      id: 'punct-ct-transformer',
      displayName: '标点恢复（中英文）',
      capabilities: <AiCapability>{AiCapability.punctuation},
      kind: ModelKind.punctuation,
      tier: ModelTier.light,
      sizeMB: 95,
      speedRating: 5,
      qualityRating: 5,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/'
              'resolve/main/model.onnx',
          sha256: 'e93593a6dbd69a07f8734ef269dbe861a379755f8d1c8354719432116f2c44bd',
        ),
      ],
      notes: '给 ASR 输出补标点（句号、逗号、问号），让转写结果直接可读。100MB，中英文通用',
    ),
    // ── 翻译专用 ────────────────────────────────────────────────────────
    AiModel(
      id: 'opus-mt-zh-en',
      displayName: 'Opus-MT 中英翻译',
      capabilities: <AiCapability>{AiCapability.translate},
      kind: ModelKind.nmt,
      tier: ModelTier.light,
      sizeMB: 110,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh', 'en'],
      license: 'CC-BY-4.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        // 说明：Opus-MT 的 ONNX 导出（encoder_model.onnx / decoder_model.onnx /
        // vocab.json / tokenizer_config.json）需用 optimum 从
        // Helsinki-NLP/opus-mt-zh-en 导出，见「实时AI字幕接入说明」文档的
        // 「本地离线翻译」章节。标准 HF 仓库不直接提供这几个文件，故此处
        // 无直链可填 —— 用户走「导入」按钮把本地导出的模型目录导进来。
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/Helsinki-NLP/opus-mt-zh-en.invalid',
          sha256: null,
        ),
      ],
      notes: '本地离线中译英，110MB，无需联网也不需 API Key；模型需自行导出 ONNX 后从「导入」引入',
    ),
    AiModel(
      id: 'madlad-400-3b',
      displayName: 'MADLAD-400 3B 多语翻译',
      capabilities: <AiCapability>{AiCapability.translate},
      kind: ModelKind.nmt,
      tier: ModelTier.multilingual,
      sizeMB: 2000,
      speedRating: 2,
      qualityRating: 4,
      languages: _madladLanguages,
      license: 'Apache-2.0',
      minRamGB: 8.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url:
              'https://huggingface.co/google/madlad400-3b-mt/'
              'resolve/main/model-q4k.gguf',
          sha256: 'ea6e5531a3e95213c7f0635988d119e078a655c09306e47851e15d4c0c3f9c37',
          fileUrls: <String, String>{
            'model-q4k.gguf':
                'https://huggingface.co/google/madlad400-3b-mt/'
                'resolve/main/model-q4k.gguf',
            'spiece.model':
                'https://huggingface.co/google/madlad400-3b-mt/'
                'resolve/main/spiece.model',
            'tokenizer.json':
                'https://huggingface.co/google/madlad400-3b-mt/'
                'resolve/main/tokenizer.json',
          },
          fileSha256s: <String, String>{
            'model-q4k.gguf': 'ea6e5531a3e95213c7f0635988d119e078a655c09306e47851e15d4c0c3f9c37',
          },
        ),
      ],
      notes: '覆盖面 400+ 语种，冷门语种几乎只有它能翻；3B GGUF 体积大，只在高配机开',
    ),
  ];
}
