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
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/'
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
          url: 'https://huggingface.co/csukuangfj/'
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
            'encoder-epoch-99-avg-1.int8.onnx':
                '8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b',
            'decoder-epoch-99-avg-1.int8.onnx':
                '1a70c593d71e53f023f5f55b0b4cfff5055abb786ee3992e5f63dc2e273cc4fa',
            'joiner-epoch-99-avg-1.int8.onnx':
                '1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0',
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
          url: 'https://huggingface.co/csukuangfj/'
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
            'model.int8.onnx':
                'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
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
          url: 'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-paraformer-zh-small-2024-03-09/'
              'resolve/main/model.int8.onnx',
          sha256:
              '3ef6c19369b912f7caf3cef8e545c5ccd1a33d9d7ec792a46668dc41c4b229ec',
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
          url: 'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-paraformer-zh-2024-03-09/'
              'resolve/main/model.int8.onnx',
          sha256:
              '90bc03034ae1bef9575f8cc798cd1519c8be8aa9e8b458a033e32017ff4d584c',
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
          url: 'https://huggingface.co/csukuangfj/'
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
            'encoder.int8.onnx':
                '81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a',
            'decoder.int8.onnx':
                'f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f',
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
          url: 'https://huggingface.co/csukuangfj/'
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
            'encoder.int8.onnx':
                '6047a644b41b236d9d8e89e3b94ef39d1b7037daab028131b722ca52e10b0357',
            'decoder.int8.onnx':
                '545427acf508452b7d89969be082c8128c681e3432ff43aef09f6159f4b61a7e',
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
          url: 'https://huggingface.co/csukuangfj/'
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
            'base-encoder.int8.onnx':
                '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11',
            'base-decoder.int8.onnx':
                '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d',
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
          url: 'https://huggingface.co/csukuangfj/'
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
            'small-encoder.int8.onnx':
                '4cbe7b22fa9026b843b60a68640c747de05bafb1a11b57edc0e66c232d9f33a9',
            'small-decoder.int8.onnx':
                'acad50b5c782696e91b55914cc5ab4f756f1532f76e22aa6fc615f39fb69a8ee',
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
          url: 'https://huggingface.co/csukuangfj/'
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
            'large-v3-encoder.int8.onnx':
                'd531cf17248acc43e8c09b472a0877055e770877857a5332fc1304b36534ec85',
            'large-v3-decoder.int8.onnx':
                'ebc6bfd88e162a46cb3edee8a7e727e1dcbc65cabecb19e2573695e4d495e1af',
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
          url: 'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-2025-11-12/'
              'resolve/main/model.onnx',
          sha256:
              '49465dc6dbf82b86a8025f8b45d7be34d43d63944cb0ed022e45ff212d30d306',
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
            'model.onnx':
                '49465dc6dbf82b86a8025f8b45d7be34d43d63944cb0ed022e45ff212d30d306',
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
          url: 'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12/'
              'resolve/main/model.onnx',
          sha256:
              'e93593a6dbd69a07f8734ef269dbe861a379755f8d1c8354719432116f2c44bd',
        ),
      ],
      notes: '给 ASR 输出补标点（句号、逗号、问号），让转写结果直接可读。100MB，中英文通用',
    ),
    // ── 关键词识别 ────────────────────────────────────────────────────
    AiModel(
      id: 'keyword-spotter-heysnips',
      displayName: '关键词识别 Hey Snips',
      capabilities: <AiCapability>{AiCapability.keywordSpotting},
      kind: ModelKind.keywordSpotting,
      tier: ModelTier.light,
      sizeMB: 2,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['en'],
      license: 'Apache-2.0',
      minRamGB: 1.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.githubRelease,
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/'
              'download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2',
          sha256: null,
        ),
      ],
      notes: '2MB 就能做关键词唤醒，可作为语音指令的前置触发（需要在代码里配关键词列表）',
    ),
    // ── 说话人分离 ────────────────────────────────────────────────────
    AiModel(
      id: 'speaker-diarization',
      displayName: '说话人分离',
      capabilities: <AiCapability>{AiCapability.speakerDiarization},
      kind: ModelKind.speakerDiarization,
      tier: ModelTier.light,
      sizeMB: 30,
      speedRating: 4,
      qualityRating: 4,
      languages: <String>[],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.githubRelease,
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/'
              'download/speaker-segmentation-models/'
              'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
          sha256: null,
        ),
      ],
      notes: '多人对话里区分「谁在什么时候说话」，配合 ASR 做会议纪要/采访字幕',
    ),
    // ── TTS 语音合成 ────────────────────────────────────────────────────
    AiModel(
      id: 'vits-zh',
      displayName: 'VITS 中文语音合成',
      capabilities: <AiCapability>{AiCapability.tts},
      kind: ModelKind.tts,
      tier: ModelTier.light,
      sizeMB: 30,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/csukuangfj/'
              'vits-hf-zh-jp-zomehwh/'
              'resolve/main/vits-hf-zh-jp-zomehwh.onnx',
          sha256:
              '227f68cec4ee79e80845b2f7bbb9f9f654b95cab1d69be54e78af46c33e07935',
          fileUrls: <String, String>{
            'vits-hf-zh-jp-zomehwh.onnx':
                'https://huggingface.co/csukuangfj/'
                'vits-hf-zh-jp-zomehwh/'
                'resolve/main/vits-hf-zh-jp-zomehwh.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'vits-hf-zh-jp-zomehwh/'
                'resolve/main/tokens.txt',
          },
          fileSha256s: <String, String>{
            'vits-hf-zh-jp-zomehwh.onnx':
                '227f68cec4ee79e80845b2f7bbb9f9f654b95cab1d69be54e78af46c33e07935',
          },
        ),
      ],
      notes: '中文 TTS，把字幕文字读出来；VITS 质量不错但非商用训练集来源需注意',
    ),
    AiModel(
      id: 'vits-en-ljspeech',
      displayName: 'VITS 英文语音合成',
      capabilities: <AiCapability>{AiCapability.tts},
      kind: ModelKind.tts,
      tier: ModelTier.light,
      sizeMB: 30,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['en'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/csukuangfj/'
              'vits-coqui-en-ljspeech/'
              'resolve/main/model.onnx',
          sha256:
              '3c4468add71e72431dec810545dcb44639b0b1fa117994d72dad0864f95ee9fd',
        ),
      ],
      notes: '英文 TTS，用 LJSpeech 数据集训练，朗读腔自然，适合字幕朗读',
    ),
    AiModel(
      id: 'vits-yue',
      displayName: 'VITS 粤语语音合成',
      capabilities: <AiCapability>{AiCapability.tts},
      kind: ModelKind.tts,
      tier: ModelTier.light,
      sizeMB: 25,
      speedRating: 5,
      qualityRating: 3,
      languages: <String>['yue'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/csukuangfj/'
              'vits-cantonese-hf-xiaomaiiwn/'
              'resolve/main/vits-cantonese-hf-xiaomaiiwn.onnx',
          sha256:
              '7d8d4f5550b607999417a99131b034c8cc2b8dca69f9e9fdefeff6655643c139',
          fileUrls: <String, String>{
            'vits-cantonese-hf-xiaomaiiwn.onnx':
                'https://huggingface.co/csukuangfj/'
                'vits-cantonese-hf-xiaomaiiwn/'
                'resolve/main/vits-cantonese-hf-xiaomaiiwn.onnx',
            'tokens.txt':
                'https://huggingface.co/csukuangfj/'
                'vits-cantonese-hf-xiaomaiiwn/'
                'resolve/main/tokens.txt',
          },
          fileSha256s: <String, String>{
            'vits-cantonese-hf-xiaomaiiwn.onnx':
                '7d8d4f5550b607999417a99131b034c8cc2b8dca69f9e9fdefeff6655643c139',
          },
        ),
      ],
      notes: '粤语 TTS，用「小麥」开源数据集训练，适合配粤语字幕',
    ),
    // ── LLM 语言模型 ─────────────────────────────────────────────────
    AiModel(
      id: 'qwen3-0.6b',
      displayName: 'Qwen3 0.6B',
      capabilities: <AiCapability>{AiCapability.classify},
      kind: ModelKind.llm,
      tier: ModelTier.light,
      sizeMB: 400,
      speedRating: 5,
      qualityRating: 2,
      languages: <String>['zh', 'en', 'ja', 'ko'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/Qwen/Qwen3-0.6B.invalid',
          sha256: null,
        ),
      ],
      notes: '极小通用 LLM，专做文本分类；0.6B 做翻译还没到能用的程度，别拿它翻；仓库无 GGUF，等 llama.cpp 转化再开',
    ),
    AiModel(
      id: 'qwen3-1.7b',
      displayName: 'Qwen3 1.7B',
      capabilities: <AiCapability>{AiCapability.translate, AiCapability.classify},
      kind: ModelKind.llm,
      tier: ModelTier.balanced,
      sizeMB: 1100,
      speedRating: 3,
      qualityRating: 4,
      languages: <String>['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      license: 'Apache-2.0',
      minRamGB: 6.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/Qwen/Qwen3-1.7B.invalid',
          sha256: null,
        ),
      ],
      notes: '小 LLM 里质量与速度的平衡点，1.1GB 需要中高端机才带得动；仓库无 GGUF，等 llama.cpp 转化再开',
    ),
    AiModel(
      id: 'qwen2.5-3b-instruct',
      displayName: 'Qwen2.5 3B Instruct',
      capabilities: <AiCapability>{AiCapability.translate},
      kind: ModelKind.llm,
      tier: ModelTier.highQuality,
      sizeMB: 2000,
      speedRating: 2,
      qualityRating: 5,
      languages: <String>['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      license: 'Apache-2.0',
      minRamGB: 8.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct.invalid',
          sha256: null,
        ),
      ],
      notes: '指令跟随更好、翻译腔更少，但 3B 在手机上大概只有几个 token/s；仓库无 GGUF，等 llama.cpp 转化再开',
    ),
    AiModel(
      id: 'gemma-3-1b',
      displayName: 'Gemma 3 1B',
      capabilities: <AiCapability>{AiCapability.translate},
      kind: ModelKind.llm,
      tier: ModelTier.light,
      sizeMB: 550,
      speedRating: 3,
      qualityRating: 3,
      languages: <String>['en', 'zh', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      license: 'Gemma Terms',
      minRamGB: 4.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/google/gemma-3-1b-it.invalid',
          sha256: null,
        ),
      ],
      notes: '质量不错的小模型；gated 需 HF token、仓库无 GGUF，等 llama.cpp 转化再开',
    ),
    // ── 翻译专用 ────────────────────────────────────────────────────────
    AiModel(
      id: 'opus-mt-zh-en',
      displayName: 'Opus-MT 中英翻译',
      capabilities: <AiCapability>{AiCapability.translate},
      kind: ModelKind.nmt,
      tier: ModelTier.light,
      sizeMB: 100,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh', 'en'],
      license: 'CC-BY-4.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/Helsinki-NLP/opus-mt-zh-en.invalid',
          sha256: null,
        ),
      ],
      notes: '100MB 的专用翻译模型，比同体积 LLM 更快也更准；需 PyTorch→ONNX 转化，暂不可用',
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
          url: 'https://huggingface.co/google/madlad400-3b-mt/'
              'resolve/main/model-q4k.gguf',
          sha256:
              'ea6e5531a3e95213c7f0635988d119e078a655c09306e47851e15d4c0c3f9c37',
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
            'model-q4k.gguf':
                'ea6e5531a3e95213c7f0635988d119e078a655c09306e47851e15d4c0c3f9c37',
          },
        ),
      ],
      notes: '覆盖面 400+ 语种，冷门语种几乎只有它能翻；3B GGUF 体积大，只在高配机开',
    ),
    // ── 语义搜索（embedding）───────────────────────────────────────────
    AiModel(
      id: 'bge-small-zh-v1.5',
      displayName: 'BGE Small 中文向量',
      capabilities: <AiCapability>{AiCapability.embed},
      kind: ModelKind.embedding,
      tier: ModelTier.light,
      sizeMB: 100,
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh'],
      license: 'MIT',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/BAAI/bge-small-zh-v1.5.invalid',
          sha256: null,
        ),
      ],
      notes: '100MB 中文嵌入模型，几百部片子的语义搜索毫秒级；暂无 ONNX 导出，需自行转换',
    ),
    AiModel(
      id: 'bge-m3',
      displayName: 'BGE-M3 多语向量',
      capabilities: <AiCapability>{AiCapability.embed},
      kind: ModelKind.embedding,
      tier: ModelTier.multilingual,
      sizeMB: 2200,
      speedRating: 2,
      qualityRating: 5,
      languages: <String>[
        'zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru', 'ar', 'hi', 'pt', 'yue',
      ],
      license: 'MIT',
      minRamGB: 8.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/BAAI/bge-m3/'
              'resolve/main/onnx/model.onnx',
          sha256:
              'f84251230831afb359ab26d9fd37d5936d4d9bb5d1d5410e66442f630f24435b',
          fileUrls: <String, String>{
            'model.onnx':
                'https://huggingface.co/BAAI/bge-m3/'
                'resolve/main/onnx/model.onnx',
            'model.onnx_data':
                'https://huggingface.co/BAAI/bge-m3/'
                'resolve/main/onnx/model.onnx_data',
            'sentencepiece.bpe.model':
                'https://huggingface.co/BAAI/bge-m3/'
                'resolve/main/onnx/sentencepiece.bpe.model',
            'tokenizer.json':
                'https://huggingface.co/BAAI/bge-m3/'
                'resolve/main/onnx/tokenizer.json',
            'config.json':
                'https://huggingface.co/BAAI/bge-m3/'
                'resolve/main/onnx/config.json',
            'special_tokens_map.json':
                'https://huggingface.co/BAAI/bge-m3/'
                'resolve/main/onnx/special_tokens_map.json',
            'tokenizer_config.json':
                'https://huggingface.co/BAAI/bge-m3/'
                'resolve/main/onnx/tokenizer_config.json',
          },
          fileSha256s: <String, String>{
            'model.onnx':
                'f84251230831afb359ab26d9fd37d5936d4d9bb5d1d5410e66442f630f24435b',
            'sentencepiece.bpe.model':
                'cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865',
            'tokenizer.json':
                '6710678b12670bc442b99edc952c4d996ae309a7020c1fa0096dd245c2faf790',
          },
        ),
      ],
      notes: '多语种语义搜索，覆盖面最广；2.2GB 体积大，只有旗舰机值得装',
    ),
    // ── OCR ──────────────────────────────────────────────────────────────
    AiModel(
      id: 'rapidocr-onnx',
      displayName: 'RapidOCR 硬字幕识别',
      capabilities: <AiCapability>{AiCapability.ocr},
      kind: ModelKind.ocr,
      tier: ModelTier.light,
      sizeMB: 20,
      speedRating: 4,
      qualityRating: 4,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/bluecopa/rapidocr-onnx/'
              'resolve/main/PP-OCRv5_det.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'PP-OCRv5_det.onnx':
                'https://huggingface.co/bluecopa/rapidocr-onnx/'
                'resolve/main/PP-OCRv5_det.onnx',
            'PP-OCRv5_server_rec_infer.onnx':
                'https://huggingface.co/bluecopa/rapidocr-onnx/'
                'resolve/main/PP-OCRv5_server_rec_infer.onnx',
            'ch_PP-OCRv5_rec_mobile_infer.onnx':
                'https://huggingface.co/bluecopa/rapidocr-onnx/'
                'resolve/main/ch_PP-OCRv5_rec_mobile_infer.onnx',
            'ch_ppocr_mobile_v2.0_cls_infer.onnx':
                'https://huggingface.co/bluecopa/rapidocr-onnx/'
                'resolve/main/ch_ppocr_mobile_v2.0_cls_infer.onnx',
            'SLANet_plus.onnx':
                'https://huggingface.co/bluecopa/rapidocr-onnx/'
                'resolve/main/SLANet_plus.onnx',
            'PP-DocLayoutV3.onnx':
                'https://huggingface.co/bluecopa/rapidocr-onnx/'
                'resolve/main/PP-DocLayoutV3.onnx',
            'ppocrv5_dict.txt':
                'https://huggingface.co/bluecopa/rapidocr-onnx/'
                'resolve/main/ppocrv5_dict.txt',
          },
          fileSha256s: <String, String>{
            'PP-OCRv5_det.onnx':
                '127edf0182bb3d218ad59476377b02ca90296cfb4cc85df55042d671a3e53aeb',
            'PP-OCRv5_server_rec_infer.onnx':
                '13d0dda27d63dc0f4938af48df2c55b33f3c989a0bd5eacb8410e30f1735f644',
            'ch_PP-OCRv5_rec_mobile_infer.onnx':
                '5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5',
            'ch_ppocr_mobile_v2.0_cls_infer.onnx':
                'e47acedf663230f8863ff1ab0e64dd2d82b838fceb5957146dab185a89d6215c',
            'SLANet_plus.onnx':
                'd57a942af6a2f57d6a4a0372573c696a2379bf5857c45e2ac69993f3b334514b',
            'PP-DocLayoutV3.onnx':
                'd24809294b2f9f1a9a2767043a64df2714b66e5be056887be2233d1117d784f6',
          },
        ),
      ],
      notes: '20MB 就能认出画面里的硬字幕，检测+识别一体，适合逐帧抽检',
    ),
    AiModel(
      id: 'paddleocr-ppocr-v4',
      displayName: 'PaddleOCR PP-OCRv4',
      capabilities: <AiCapability>{AiCapability.ocr},
      kind: ModelKind.ocr,
      tier: ModelTier.light,
      sizeMB: 15,
      speedRating: 4,
      qualityRating: 5,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/aoiandroid/paddleocr-ppocrv5-onnx/'
              'resolve/main/PP-OCRv5_server_det_infer.onnx',
          sha256: null,
          fileUrls: <String, String>{
            'PP-OCRv5_server_det_infer.onnx':
                'https://huggingface.co/aoiandroid/paddleocr-ppocrv5-onnx/'
                'resolve/main/PP-OCRv5_server_det_infer.onnx',
            'PP-OCRv5_server_rec_infer.onnx':
                'https://huggingface.co/aoiandroid/paddleocr-ppocrv5-onnx/'
                'resolve/main/PP-OCRv5_server_rec_infer.onnx',
            'ppocrv5_dict.txt':
                'https://huggingface.co/aoiandroid/paddleocr-ppocrv5-onnx/'
                'resolve/main/ppocrv5_dict.txt',
          },
          fileSha256s: <String, String>{
            'PP-OCRv5_server_det_infer.onnx':
                '127edf0182bb3d218ad59476377b02ca90296cfb4cc85df55042d671a3e53aeb',
            'PP-OCRv5_server_rec_infer.onnx':
                '13d0dda27d63dc0f4938af48df2c55b33f3c989a0bd5eacb8410e30f1735f644',
          },
        ),
      ],
      notes: '硬字幕转双语的主选：15MB、中文准确率高于 RapidOCR，速度也够快',
    ),
    // ── 画面质量评分 ──────────────────────────────────────────────────
    AiModel(
      id: 'nima-frame-quality',
      displayName: 'NIMA 画面质量评分',
      capabilities: <AiCapability>{AiCapability.frameScore},
      kind: ModelKind.vision,
      tier: ModelTier.light,
      sizeMB: 10,
      speedRating: 5,
      qualityRating: 3,
      languages: <String>[],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: 'https://huggingface.co/csukuangfj/'
              'sherpa-onnx-nemo-enc-dec-ctc-model.invalid',
          sha256: null,
        ),
      ],
      notes: '可选增强；仓库不存在/已删除，等找到替代模型再开启',
    ),
  ];
}
