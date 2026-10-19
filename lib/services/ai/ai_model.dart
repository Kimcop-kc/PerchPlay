/// 端侧 AI 模型的**纯数据描述**（骨架版本）
///
/// 为什么先只做数据：模型选择里最容易出错、又最不值得上真机试的部分是
/// 「内存够不够」「语言支不支持」「先从哪个源下」。把它拆成不可变的数据 + 纯函数，
/// 现在就能用单测把规则钉死；等以后接原生推理时，UI 层拿到的已经是「选好的模型」。
/// 这一层**不碰原生、不碰网络、不碰文件系统**，所以单测跑起来是毫秒级。
enum AiCapability {
  /// 语音活动检测：只判断「有没有人声」，是最省算力的前置过滤
  vad,

  /// 语音识别：整段音频转文字（非流式，可以等录完再跑）
  asr,

  /// 流式语音识别：边说边出字，实时字幕 / 通话场景要这个
  asrStreaming,

  /// 机器翻译（文本）
  translate,

  /// 标点恢复：给无标点的识别文本自动加标点
  punctuation,
}

/// 模型档位
///
/// 为什么档位和 [AiModel.sizeMB] 同时存在：同体积的模型质量差别很大
/// （专用翻译模型 vs 通用 LLM），光按体积排不出合适的默认值。
/// 档位是人工标定过的「意图」，体积只在同一档位内当质量代理用。
enum ModelTier {
  /// 极轻量：低端机、常驻后台也扛得住，质量一般
  light,

  /// 均衡：默认推荐档，中端机能跑
  balanced,

  /// 高质量：慢、吃内存，只在设备明确扛得住时用
  highQuality,

  /// 多语言：靠语种覆盖取胜，而不是靠单语质量
  multilingual,
}

/// 下载来源
///
/// 为什么只有两个：国内直连魔搭（ModelScope）更稳，所以做默认；
/// Hugging Face 覆盖更全，做备选。「默认魔搭、失败退 HF」的排序逻辑见
/// `AiModelRegistry.mirrorsFor`。
enum DownloadSource {
  /// 魔搭 / ModelScope（国内优先）
  modelscope,

  /// Hugging Face Hub
  huggingface,

  /// GitHub Releases 直链（tar.bz2 归档）
  githubRelease,
}

/// 模型类别：跟 [AiCapability] 不是一回事
///
/// 能力回答「这个模型能干什么」，类别回答「它是哪种模型」。同一个能力可以由
/// 不同类别实现，而类别直接决定「同档位里该优先选谁」：
///  - 翻译：轻量档要优先专用 NMT（参数全花在翻译上，更快更省电），
///    更高档位才轮到 LLM（译文更自然、能控制格式）；
///  - 分类：只有 LLM 干得了，NMT 不掺和。
/// 所以排序需要这个维度 —— 光靠 tier + 体积排不出来，100MB 的 NMT 会比
/// 400MB 的小 LLM 翻得更好。具体优先级表见 `AiModelRegistry.recommended`。
enum ModelKind {
  /// 语音活动检测
  vad,

  /// 语音识别（含流式）
  asr,

  /// 通用大语言模型（分类 / 翻译都靠它）
  llm,

  /// 专用神经机器翻译模型（只做翻译：单语种对或大规模多语覆盖）
  nmt,

  /// 标点恢复（独立的标点模型，不耦合在 ASR 里）
  punctuation,
}

/// 一个下载镜像
class ModelMirror {
  /// 来源站点
  final DownloadSource source;

  /// 单文件下载地址（兼容旧模型条目，新条目用 [fileUrls]）
  ///
  /// [fileUrls] 存在时忽略此字段；都不存在则为不可下载的占位条目。
  final String url;

  /// 文件 sha256（小写十六进制），仅对单文件条目有效；
  /// 多文件条目各自的校验值在 [fileSha256s] 里按文件名分别指定
  final String? sha256;

  /// 多文件模型的**直接下载链接**（文件名 → 完整 URL）
  ///
  /// 非空时下载器会逐文件 GET 并存到模型目录。每个 URL 需独立可下载。
  /// 空 = 单文件模式（回退到 [url]）。
  final Map<String, String>? fileUrls;

  /// 多文件模型的**逐文件 sha256**（文件名 → 小写十六进制）
  ///
  /// 非空时下载器每完成一个文件立即校验，失败则放弃该镜像、切下一个镜像重试，
  /// 不浪费用户流量。key 必须和 [fileUrls] 的 key 一致。
  /// 空 = 不校验（旧条目兼容）。
  final Map<String, String>? fileSha256s;

  const ModelMirror({
    required this.source,
    required this.url,
    this.sha256,
    this.fileUrls,
    this.fileSha256s,
  });

  /// 获取某个文件名的预期 sha256（先查 fileSha256s，再回退到 mirror 级别 sha256）
  String? sha256ForFile(String fileName) {
    if (fileSha256s != null && fileSha256s!.containsKey(fileName)) {
      return fileSha256s![fileName]!.toLowerCase();
    }
    // 单文件模式 mirror.sha256 即该文件的校验值
    if (fileUrls == null || fileUrls!.isEmpty) {
      return sha256?.toLowerCase();
    }
    return null;
  }

  /// 是否包含可下载的文件（单文件或 fileUrls 都不为空）
  bool get hasDownloadableContent =>
      fileUrls != null && fileUrls!.isNotEmpty ||
      (fileUrls == null && url.isNotEmpty && !url.endsWith('.invalid'));

  /// 该镜像是否只含占位 URL（尚未补真实地址）
  bool get isPlaceholder => !hasDownloadableContent;

  /// 当前镜像要求下载的所有文件数
  int get fileCount => fileUrls?.length ?? 1;

  /// 校验值是否存在（所有文件都需要 sha256 才算校验完整）
  ///
  /// 补全 sha256 后下载时会当场校验，坏文件不落盘，避免浪费流量。
  bool get hasChecksum {
    if (sha256?.isNotEmpty == true) return true;
    if (fileSha256s != null && fileSha256s!.isNotEmpty) {
      // 多文件模式：每种文件都要有校验值
      if (fileUrls != null) {
        return fileUrls!.keys.every((k) => fileSha256s!.containsKey(k));
      }
      return true;
    }
    return false;
  }

  @override
  String toString() => 'ModelMirror(${source.name}, $url'
      '${fileUrls != null ? ', ${fileUrls!.length} file(s)' : ''})';
}

/// 一个可下载的端侧模型
///
/// 全部字段 final：清单是编译期数据，运行期不该被就地改（否则「同一台机器两次
/// 推荐出不同模型」这种问题会非常难查）。
class AiModel {
  /// 稳定 id（如 `sensevoice-small`），用来存用户选择、拼下载路径。
  /// 不要随手改：改了等于把用户已经下好的文件变成孤儿。
  final String id;

  /// 中文展示名（UI 上人看的）
  final String displayName;

  /// 支持的能力；一个模型可以有多个（如 SenseVoice 既做整段也做流式）
  final Set<AiCapability> capabilities;

  /// 模型类别：同档位内排序时决定优先级（见 [ModelKind] 与
  /// `AiModelRegistry.recommended`）。和能力是两个维度：SenseVoice 和 Whisper
  /// 都做 ASR，但前者是 asr、后者也是 asr；opus-mt 和 qwen 都做翻译，
  /// 却是 nmt / llm 两种类别 —— 只靠能力分不开。
  final ModelKind kind;

  /// 人工标定的档位
  final ModelTier tier;

  /// 模型体积（MB）。用 MB 而不是字节：这个粒度只用于展示和排序，
  /// 精确的字节数在真实下载时由服务端 Content-Length 决定。
  final int sizeMB;

  /// 速度评分 1~5（5 = 最快）
  ///
  /// 为什么单独打分而不从体积推算：小模型不一定快（有些小模型用 CPU 不友好的
  /// 结构），大模型也不一定慢（量化 + 专用算子可以很快）。这个分数是给用户
  /// 在「选择界面」上直接看的，必须是人工/实测标定的，不能是公式算出来的。
  final int speedRating;

  /// 质量评分 1~5（5 = 质量最好）
  ///
  /// 和体积也不是线性关系：100MB 的专用翻译模型能打赢 400MB 的通用小 LLM。
  /// UI 用它和 [speedRating] 一起构成「速度 / 质量」两列，用户自己权衡。
  final int qualityRating;

  /// 支持的语言（ISO 639-1 代码之类的短码），如 `['zh','en','ja','ko','yue']`
  ///
  /// 空列表 = 与语言无关（如 VAD）；只列**常用语种**，不是完整能力边界
  /// （Whisper 99 语种、MADLAD 400+ 语种没法逐条抄全，数量写在 [notes] 里）。
  /// 这样 UI 直接拿来做语言筛选，不用为了「列全」维护一张巨大的表。
  final List<String> languages;

  /// 许可证名（如 `Apache-2.0` / `MIT` / `Gemma Terms`）
  ///
  /// 单独留字段是因为它决定「能不能随 App 打包分发」，不是装饰性信息：
  /// 非标准开源的模型只能让用户自己下载，见具体条目的 notes。
  final String license;

  /// 推荐的最低设备内存（GB）
  ///
  /// 低于这个值不推荐：模型权重 + 运行时 KV cache 会一起把低内存设备撑爆，
  /// 到时候表现为闪退而不是「慢」，用户根本不知道发生了什么。
  ///
  /// ⚠️ **清单里的数值全是估算**：按模型体积的经验比例推算（权重 + 量化误差 +
  /// 运行时开销），不是在本项目真机上实测得到的。接上原生推理后必须拿低配/高配
  /// 各一台设备重新校准，否则要么误伤能跑的机器，要么放进会闪退的机器。
  final double minRamGB;

  /// 下载镜像，**按优先级排序**
  final List<ModelMirror> mirrors;

  /// 一句话说明：速度 / 质量 / 适用场景
  final String notes;

  const AiModel({
    required this.id,
    required this.displayName,
    required this.capabilities,
    required this.kind,
    required this.tier,
    required this.sizeMB,
    required this.speedRating,
    required this.qualityRating,
    required this.languages,
    required this.license,
    required this.minRamGB,
    required this.mirrors,
    required this.notes,
  });

  /// 是否具备某个能力
  bool supports(AiCapability capability) => capabilities.contains(capability);

  /// 体积的展示文本：≥1GB 用 GB，避免 UI 上出现 「1600 MB」这种不好读的数字
  String get sizeLabel =>
      sizeMB >= 1024 ? '${(sizeMB / 1024).toStringAsFixed(1)} GB' : '$sizeMB MB';

  @override
  String toString() =>
      'AiModel($id, ${kind.name}/${tier.name}, ${sizeMB}MB)';
}
