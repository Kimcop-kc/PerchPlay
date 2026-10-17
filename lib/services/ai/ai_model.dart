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

  /// 文本分类：给一行文本贴标签（片名归类、语种判定等）
  classify,

  /// 光学字符识别：这里主要用于识别画面里的硬字幕
  ocr,
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
  modelscope,
  huggingface,
}

/// 一个下载镜像
class ModelMirror {
  /// 来源站点
  final DownloadSource source;

  /// 下载地址
  final String url;

  /// 文件 sha256（小写十六进制）
  ///
  /// **允许为空，但发布前必须补齐**：没有校验值的下载等于把「完整性」交给网络，
  /// 而模型文件动辄几百 MB、下载中断或被劫持都不是理论问题。
  /// 骨架阶段一律留 null，并且**故意**不提供「默认通过」的判断，
  /// 让调用方必须显式处理「缺校验信息」的情况，而不是假装校验过了。
  final String? sha256;

  const ModelMirror({
    required this.source,
    required this.url,
    this.sha256,
  });

  /// 有没有可用的校验值（空字符串按没有处理，避免上游填了个 `''` 就以为校验过了）
  bool get hasChecksum => sha256?.isNotEmpty ?? false;

  @override
  String toString() => 'ModelMirror(${source.name}, $url)';
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

  /// 人工标定的档位
  final ModelTier tier;

  /// 模型体积（MB）。用 MB 而不是字节：这个粒度只用于展示和排序，
  /// 精确的字节数在真实下载时由服务端 Content-Length 决定。
  final int sizeMB;

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
  final double minRamGB;

  /// 下载镜像，**按优先级排序**
  final List<ModelMirror> mirrors;

  /// 一句话说明：速度 / 质量 / 适用场景
  final String notes;

  const AiModel({
    required this.id,
    required this.displayName,
    required this.capabilities,
    required this.tier,
    required this.sizeMB,
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
  String toString() => 'AiModel($id, ${tier.name}, ${sizeMB}MB)';
}
