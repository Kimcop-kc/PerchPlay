/// 端侧 AI 模型清单（**骨架版本：直链与校验值都还是占位**）
///
/// 为什么把清单单独放一个文件：
///  - 加/删模型只改这里，选择逻辑（`AiModelRegistry`）一行都不用动；
///  - 体积、许可证、语言这些是「产品决策」，集中放才方便横向对比；
///  - 以后如果改成从远端拉清单，替换的也只是这一个文件。
///
/// ⚠️ 现状（发布前必须处理）：
///  - 所有 `url` 都是占位域名，**真实 URL 待填**；
///  - 所有 `sha256` 都是 null（每个条目上方有 TODO 注释）。
///
/// 为什么占位用 `.invalid` 而不是 example.com：`.invalid` 是 RFC 2606 保留、
/// 永远解析不到的域名。万一将来有人把占位值接进下载流程，也只会立刻失败，
/// 而不会真的去请求一个别人的地址、把错误数据当成模型文件存下来。
library;

import 'ai_model.dart';

/// 魔搭（ModelScope）占位前缀 —— **真实 URL 待填**
const String _modelscopePrefix = 'https://modelscope.invalid/models';

/// Hugging Face 占位前缀 —— **真实 URL 待填**
const String _huggingfacePrefix = 'https://huggingface.invalid';

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
class AiModelCatalog {
  AiModelCatalog._();

  static const List<AiModel> all = <AiModel>[
    // ── 语音类 ──────────────────────────────────────────────────────────
    AiModel(
      id: 'silero-vad',
      displayName: 'Silero VAD 语音活动检测',
      capabilities: <AiCapability>{AiCapability.vad},
      tier: ModelTier.light,
      sizeMB: 2,
      // 与语言无关：它只判断「这段音频里有没有人声」，不关心说的是什么
      languages: <String>[],
      license: 'Apache-2.0',
      minRamGB: 1.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/silero-vad',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/snakers4/silero-vad',
          sha256: null,
        ),
      ],
      notes: '2MB 就能过滤掉无声片段，省下大量白跑的 ASR 计算，值得一直开着',
    ),
    AiModel(
      id: 'zipformer-zh-en-streaming',
      displayName: 'Zipformer 中英流式识别',
      capabilities: <AiCapability>{
        AiCapability.asrStreaming,
        AiCapability.asr,
      },
      tier: ModelTier.light,
      sizeMB: 80,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/zipformer-zh-en-streaming',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/k2-fsa/sherpa-onnx-streaming-zipformer-bilingual-zh-en',
          sha256: null,
        ),
      ],
      notes: '80MB 的低延迟流式方案，中英混说也跟得住，低端机优先选它',
    ),
    AiModel(
      id: 'sensevoice-small',
      displayName: 'SenseVoice Small 多语识别',
      capabilities: <AiCapability>{
        AiCapability.asr,
        AiCapability.asrStreaming,
      },
      tier: ModelTier.balanced,
      sizeMB: 230,
      languages: <String>['zh', 'en', 'ja', 'ko', 'yue'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/sensevoice-small',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/FunAudioLLM/SenseVoiceSmall',
          sha256: null,
        ),
      ],
      notes: '自带标点与语种判断，中日韩英粤一把抓，是默认首选的那一档',
    ),
    AiModel(
      id: 'paraformer-zh-streaming',
      displayName: 'Paraformer 中文流式识别',
      capabilities: <AiCapability>{
        AiCapability.asrStreaming,
        AiCapability.asr,
      },
      tier: ModelTier.balanced,
      sizeMB: 220,
      languages: <String>['zh'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/paraformer-zh-streaming',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/funasr/paraformer-zh-streaming',
          sha256: null,
        ),
      ],
      notes: '中文流式老牌方案，延迟低；标点要另配，确定纯中文时再选它',
    ),
    AiModel(
      id: 'whisper-base',
      displayName: 'Whisper Base 99 语种',
      capabilities: <AiCapability>{AiCapability.asr},
      tier: ModelTier.multilingual,
      sizeMB: 150,
      languages: _whisperLanguages,
      license: 'MIT',
      minRamGB: 2.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/whisper-base',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/openai/whisper-base',
          sha256: null,
        ),
      ],
      notes: '99 语种覆盖面，中文一般但冷门语种只有它，150MB 适合先跑通流程',
    ),
    AiModel(
      id: 'whisper-small',
      displayName: 'Whisper Small 99 语种',
      capabilities: <AiCapability>{AiCapability.asr},
      tier: ModelTier.multilingual,
      sizeMB: 500,
      languages: _whisperLanguages,
      license: 'MIT',
      minRamGB: 4.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/whisper-small',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/openai/whisper-small',
          sha256: null,
        ),
      ],
      notes: '中文准确率比 base 明显好，代价是慢一倍多，中端机勉强能接受',
    ),
    AiModel(
      id: 'whisper-large-v3-turbo',
      displayName: 'Whisper Large v3 Turbo',
      capabilities: <AiCapability>{AiCapability.asr},
      tier: ModelTier.highQuality,
      sizeMB: 1600,
      languages: _whisperLanguages,
      license: 'MIT',
      minRamGB: 8.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/whisper-large-v3-turbo',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/openai/whisper-large-v3-turbo',
          sha256: null,
        ),
      ],
      notes: '99 语种里质量最好的一档，1.6GB 还吃内存，基本只适合桌面/高配机',
    ),

    // ── 语言模型（做分类 / 翻译）─────────────────────────────────────────
    AiModel(
      id: 'qwen3-0.6b',
      displayName: 'Qwen3 0.6B',
      capabilities: <AiCapability>{
        AiCapability.classify,
        AiCapability.translate,
      },
      tier: ModelTier.light,
      sizeMB: 400,
      languages: <String>['zh', 'en', 'ja', 'ko'],
      license: 'Apache-2.0',
      minRamGB: 3.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/qwen3-0.6b',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/Qwen/Qwen3-0.6B',
          sha256: null,
        ),
      ],
      notes: '极小通用 LLM，做文本分类和短句翻译够用，速度优先时的兜底',
    ),
    AiModel(
      id: 'qwen3-1.7b',
      displayName: 'Qwen3 1.7B',
      capabilities: <AiCapability>{
        AiCapability.translate,
        AiCapability.classify,
      },
      tier: ModelTier.balanced,
      sizeMB: 1100,
      languages: <String>['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      license: 'Apache-2.0',
      minRamGB: 6.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/qwen3-1.7b',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/Qwen/Qwen3-1.7B',
          sha256: null,
        ),
      ],
      notes: '小 LLM 里质量与速度的平衡点，1.1GB 需要中高端机才带得动',
    ),
    AiModel(
      id: 'qwen2.5-3b-instruct',
      displayName: 'Qwen2.5 3B Instruct',
      capabilities: <AiCapability>{AiCapability.translate},
      tier: ModelTier.highQuality,
      sizeMB: 2000,
      languages: <String>['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      license: 'Apache-2.0',
      minRamGB: 8.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/qwen2.5-3b-instruct',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/Qwen/Qwen2.5-3B-Instruct',
          sha256: null,
        ),
      ],
      notes: '指令跟随更好、翻译腔更少，但 3B 在手机上大概只有几个 token/s',
    ),
    AiModel(
      id: 'gemma-3-1b',
      displayName: 'Gemma 3 1B',
      capabilities: <AiCapability>{AiCapability.translate},
      tier: ModelTier.light,
      sizeMB: 550,
      languages: <String>['en', 'zh', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      // 许可证不是标准开源：允许用户自己下载，但**本项目不打包分发**
      // （Gemma Terms 对再分发/使用场景有额外限制，跟着安装包发出去风险太大）。
      license: 'Gemma Terms',
      minRamGB: 4.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      // 只有 HF 一条：Google 官方发布在 HF，魔搭上没有官方镜像，
      // 所以这个模型正好用来验证「指定来源不存在时保持原顺序」。
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/google/gemma-3-1b-it',
          sha256: null,
        ),
      ],
      notes: '质量不错的小模型；许可证是 Gemma Terms，只让用户自己下载、不随包分发',
    ),

    // ── 翻译专用 ────────────────────────────────────────────────────────
    AiModel(
      id: 'opus-mt-zh-en',
      displayName: 'Opus-MT 中英翻译',
      capabilities: <AiCapability>{AiCapability.translate},
      tier: ModelTier.light,
      sizeMB: 100,
      languages: <String>['zh', 'en'],
      license: 'CC-BY-4.0',
      minRamGB: 2.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/opus-mt-zh-en',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/Helsinki-NLP/opus-mt-zh-en',
          sha256: null,
        ),
      ],
      // 纯翻译模型比同体积 LLM 更快更准：参数全花在翻译上，
      // 不用先「理解任务再回答」，所以 100MB 就能打赢 400MB 的通用小模型。
      notes: '100MB 的专用翻译模型，比同体积 LLM 更快也更准，只做中英时首选',
    ),
    AiModel(
      id: 'madlad-400-3b',
      displayName: 'MADLAD-400 3B 多语翻译',
      capabilities: <AiCapability>{AiCapability.translate},
      tier: ModelTier.highQuality,
      sizeMB: 2000,
      languages: _madladLanguages,
      license: 'Apache-2.0',
      minRamGB: 8.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      // 只有 HF 一条（同样是「没有该源时保持原顺序」的第二种情况）。
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/google/madlad400-3b-mt',
          sha256: null,
        ),
      ],
      // 覆盖面 400+ 语种：冷门语种基本只有它能翻，代价是 3B 体积和高内存门槛。
      notes: '覆盖面 400+ 语种，冷门语种几乎只有它能翻；3B 体积大，只在高配机开',
    ),

    // ── 视觉类 ──────────────────────────────────────────────────────────
    AiModel(
      id: 'rapidocr-onnx',
      displayName: 'RapidOCR 硬字幕识别',
      capabilities: <AiCapability>{AiCapability.ocr},
      tier: ModelTier.light,
      sizeMB: 20,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      minRamGB: 2.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/rapidocr-onnx',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/RapidAI/RapidOCR',
          sha256: null,
        ),
      ],
      notes: '20MB 就能认出画面里的硬字幕，检测+识别一体，适合逐帧抽检',
    ),
  ];
}
