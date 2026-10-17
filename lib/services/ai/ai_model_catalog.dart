/// 端侧 AI 模型清单（**骨架版本：直链与校验值都还是占位**）
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
/// 用于在选择界面上给用户看「速度 / 质量」两列，见 `AiModelSelector.tableRow`。
///
/// ⚠️ 现状（发布前必须处理）：
///  - 所有 `url` 都是占位域名，**真实 URL 待填**；
///  - 所有 `sha256` 都是 null（每个条目上方有 TODO 注释）；
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
///
/// `kind` 是「哪种模型」而不是「能干什么」：翻译能力下 nmt 和 llm 都在，
/// 排序时轻量档要让位给专用 NMT（详见 `AiModelRegistry` 的 kind 优先表）。
class AiModelCatalog {
  AiModelCatalog._();

  static const List<AiModel> all = <AiModel>[
    // ── 语音类 ──────────────────────────────────────────────────────────
    AiModel(
      id: 'silero-vad',
      displayName: 'Silero VAD 语音活动检测',
      capabilities: <AiCapability>{AiCapability.vad},
      kind: ModelKind.vad,
      tier: ModelTier.light,
      sizeMB: 2,
      // 5/5：任务本身极简（判断有没有人声），小模型就能做到接近满分
      speedRating: 5,
      qualityRating: 5,
      // 与语言无关：它只判断「这段音频里有没有人声」，不关心说的是什么
      languages: <String>[],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.asr,
      tier: ModelTier.light,
      sizeMB: 80,
      // 5/3：流式延迟低、速度是强项，准确率明显不如 SenseVoice
      speedRating: 5,
      qualityRating: 3,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.asr,
      tier: ModelTier.balanced,
      sizeMB: 230,
      // 5/4：非流式几乎实时，准确率好、自带标点；纯中文仍略逊 Paraformer
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh', 'en', 'ja', 'ko', 'yue'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
      minRamGB: 3.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        // 魔搭优先，但 onnx 转换版暂无官方镜像（仅占位）
        ModelMirror(
          source: DownloadSource.modelscope,
          url: 'https://modelscope.invalid/models/sensevoice-small',
          sha256: null,
        ),
        // HF 直链（每文件一次 HTTP GET，无需解压）
        // sha256 暂无：HF CDN 有 ETag 校验，发布前补 post-download 校验值
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
        ),
        // GitHub Releases (.tar.bz2，下载后用 archive 解压——P1 补)
        ModelMirror(
          source: DownloadSource.githubRelease,
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
              'asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-'
              '2024-07-17.tar.bz2',
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
      kind: ModelKind.asr,
      tier: ModelTier.balanced,
      sizeMB: 220,
      // 5/5：中文识别最强的一档，流式延迟也低（标点要另配不算在质量里）
      speedRating: 5,
      qualityRating: 5,
      languages: <String>['zh'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.asr,
      tier: ModelTier.multilingual,
      sizeMB: 150,
      // 3/3：手机端跑 Whisper 编码器不快，base 的准确率也只是一般
      speedRating: 3,
      qualityRating: 3,
      languages: _whisperLanguages,
      license: 'MIT',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.asr,
      tier: ModelTier.multilingual,
      sizeMB: 500,
      // 2/4：慢（手机上更明显），准确率比 base 好一档
      speedRating: 2,
      qualityRating: 4,
      languages: _whisperLanguages,
      license: 'MIT',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.asr,
      tier: ModelTier.highQuality,
      sizeMB: 1600,
      // 2/5：质量最好，但 1.6GB 在手机端只能算「能跑」，别指望实时
      speedRating: 2,
      qualityRating: 5,
      languages: _whisperLanguages,
      license: 'MIT',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
      // 16GB 旗舰（骁龙 8 Elite）按估算可跑，但仍需真机验证
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
      // 故意不声明 translate：0.6B 的翻译质量还到不了能用的程度。
      // 硬塞进翻译档位只会让「轻量翻译」选到 400MB、却不如 100MB 的 Opus-MT ——
      // 既费流量又更慢，还会把用户对「轻量档够用」的预期骗掉。
      // 它该做的是自己擅长的文本分类。
      capabilities: <AiCapability>{AiCapability.classify},
      kind: ModelKind.llm,
      tier: ModelTier.light,
      sizeMB: 400,
      // 5/2：够快，但 0.6B 的推理能力有限，只适合分类这种窄任务
      speedRating: 5,
      qualityRating: 2,
      languages: <String>['zh', 'en', 'ja', 'ko'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      notes: '极小通用 LLM，专做文本分类；0.6B 做翻译还没到能用的程度，别拿它翻',
    ),
    AiModel(
      id: 'qwen3-1.7b',
      displayName: 'Qwen3 1.7B',
      capabilities: <AiCapability>{
        AiCapability.translate,
        AiCapability.classify,
      },
      kind: ModelKind.llm,
      tier: ModelTier.balanced,
      sizeMB: 1100,
      // 3/4：手机上解码速度还行，翻译质量对小 LLM 来说算好
      speedRating: 3,
      qualityRating: 4,
      languages: <String>['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.llm,
      tier: ModelTier.highQuality,
      sizeMB: 2000,
      // 2/5：质量最好，手机上每个 token 都很贵
      speedRating: 2,
      qualityRating: 5,
      languages: <String>['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
      // 16GB 旗舰（骁龙 8 Elite）按估算可跑，但仍需真机验证
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
      kind: ModelKind.llm,
      tier: ModelTier.light,
      sizeMB: 550,
      // 3/3：中规中矩，和 Qwen3-1.7B 比都不占优（许可证也特殊）
      speedRating: 3,
      qualityRating: 3,
      languages: <String>['en', 'zh', 'ja', 'ko', 'fr', 'de', 'es', 'ru'],
      // 许可证不是标准开源：允许用户自己下载，但**本项目不打包分发**
      // （Gemma Terms 对再分发/使用场景有额外限制，跟着安装包发出去风险太大）。
      license: 'Gemma Terms',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.nmt,
      tier: ModelTier.light,
      sizeMB: 100,
      // 5/4：专用模型推理极快；中英对质量已经很能打
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh', 'en'],
      license: 'CC-BY-4.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
      kind: ModelKind.nmt,
      // 档位是 multilingual 而不是 highQuality：它的价值是 400+ 语种覆盖
      // （用户要找小语种时才需要），不是「中文翻译质量更高」。
      // 放在 highQuality 会抢走「高质量翻译」的默认位 —— 中文场景下
      // qwen2.5-3b-instruct 更合适；真要小语种的人会主动挑「多语言」档。
      tier: ModelTier.multilingual,
      sizeMB: 2000,
      // 2/4：覆盖广但慢；小语种质量比中文场景的 3B LLM 更可靠
      speedRating: 2,
      qualityRating: 4,
      languages: _madladLanguages,
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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

    // ── 语义搜索（embedding）────────────────────────────────────────────
    AiModel(
      id: 'bge-small-zh-v1.5',
      displayName: 'BGE Small 中文向量',
      // 只做 embedding：不生成文字，所以 kind 是 embedding 而不是 llm。
      // 影库几百部片子的向量在内存里算余弦相似度是毫秒级，
      // 中文小模型里它的性价比最高（100MB 就能把「用一句话搜片」跑起来）。
      capabilities: <AiCapability>{AiCapability.embed},
      kind: ModelKind.embedding,
      tier: ModelTier.light,
      sizeMB: 100,
      // 5/4：小而且快，中文语义检索质量够用
      speedRating: 5,
      qualityRating: 4,
      languages: <String>['zh'],
      license: 'MIT',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
      minRamGB: 2.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/bge-small-zh-v1.5',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/BAAI/bge-small-zh-v1.5',
          sha256: null,
        ),
      ],
      notes: '100MB 中文嵌入模型，几百部片子的语义搜索毫秒级，性价比最高',
    ),
    AiModel(
      id: 'bge-m3',
      displayName: 'BGE-M3 多语向量',
      capabilities: <AiCapability>{AiCapability.embed},
      kind: ModelKind.embedding,
      tier: ModelTier.multilingual,
      sizeMB: 2200,
      // 2/5：多语种检索质量最好，2.2GB 只有旗舰才考虑
      speedRating: 2,
      qualityRating: 5,
      languages: <String>[
        'zh',
        'en',
        'ja',
        'ko',
        'fr',
        'de',
        'es',
        'ru',
        'ar',
        'hi',
        'pt',
        'yue',
      ],
      license: 'MIT',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
      minRamGB: 8.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/bge-m3',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/BAAI/bge-m3',
          sha256: null,
        ),
      ],
      notes: '多语种语义搜索，覆盖面最广；2.2GB 体积大，只有旗舰机值得装',
    ),

    // ── 视觉类 ──────────────────────────────────────────────────────────
    AiModel(
      id: 'rapidocr-onnx',
      displayName: 'RapidOCR 硬字幕识别',
      capabilities: <AiCapability>{AiCapability.ocr},
      kind: ModelKind.ocr,
      tier: ModelTier.light,
      sizeMB: 20,
      // 4/4：20MB 就能出结果，中文准确率不错但不是最好
      speedRating: 4,
      qualityRating: 4,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
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
    AiModel(
      id: 'paddleocr-ppocr-v4',
      displayName: 'PaddleOCR PP-OCRv4',
      // 只做 ocr（不兼 embed/frameScore）：识别硬字幕（烧进画面的字幕）时
      // 中文准确率高于 RapidOCR，是「硬字幕转双语」的主选。
      capabilities: <AiCapability>{AiCapability.ocr},
      kind: ModelKind.ocr,
      tier: ModelTier.light,
      sizeMB: 15,
      // 4/5：速度和 RapidOCR 同级，中文识别质量更高一档
      speedRating: 4,
      qualityRating: 5,
      languages: <String>['zh', 'en'],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
      minRamGB: 2.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/paddleocr-ppocr-v4',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/PaddlePaddle/PaddleOCR',
          sha256: null,
        ),
      ],
      notes: '硬字幕转双语的主选：15MB、中文准确率高于 RapidOCR，速度也够快',
    ),
    AiModel(
      id: 'nima-frame-quality',
      displayName: 'NIMA 画面质量评分',
      // ⚠️ 可选增强，不是必需品：智能抽帧默认靠纯算法（亮度方差 + 拉普拉斯
      // 锐度/梯度能量）筛掉黑帧、纯色帧和模糊帧，没有任何模型也能用。
      // 这个模型只是额外提供「构图好不好看」的主观分，没有它功能照常。
      capabilities: <AiCapability>{AiCapability.frameScore},
      kind: ModelKind.vision,
      tier: ModelTier.light,
      sizeMB: 10,
      // 5/3：纯前向推理很快；主观美观度的判断只是「锦上添花」
      speedRating: 5,
      qualityRating: 3,
      // 与语言无关：它只看像素，不看文字
      languages: <String>[],
      license: 'Apache-2.0',
      // 估算值，待真机校准（按模型体积经验推算，非实测）
      minRamGB: 2.0,
      // TODO(发布前): 补真实 sha256 与可下载直链；骨架阶段 sha256 一律留 null
      mirrors: <ModelMirror>[
        ModelMirror(
          source: DownloadSource.modelscope,
          url: '$_modelscopePrefix/nima-frame-quality',
          sha256: null,
        ),
        ModelMirror(
          source: DownloadSource.huggingface,
          url: '$_huggingfacePrefix/idealo/image-quality-assessment',
          sha256: null,
        ),
      ],
      notes: '可选增强：从视频里挑「不是黑帧、不糊」的一帧当封面；纯算法也能做',
    ),
  ];
}
