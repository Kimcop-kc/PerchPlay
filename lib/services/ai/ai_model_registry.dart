/// 模型注册表的**纯查询 / 选择逻辑**
///
/// 为什么把这些规则单独拆出来：推荐哪一档、镜像怎么排序，都是有明确业务含义的
/// 决策（内存门槛、默认来源），一旦和 UI、下载器、原生加载混在一起就只能靠真机试。
/// 这里全部是纯函数：输入清单 + 设备内存，输出一个模型或 null，可以穷举单测。
/// **无 IO、无原生、无网络**。
library;

import 'ai_model.dart';
import 'ai_model_catalog.dart';

/// 模型注册表
///
/// [models] 可注入：单测里用几条假模型就能验证规则，不用被真实清单的数值绑住。
class AiModelRegistry {
  /// 可选的全部模型（不可变；清单一改就得重新启动，符合「静态清单」的定位）
  final List<AiModel> models;

  /// 默认下载来源：魔搭优先
  ///
  /// 为什么默认魔搭：国内直连更稳，失败再退 Hugging Face（见 [mirrorsFor]）。
  /// 做成字段而不是常量，是为了让「用户手动指定优先源」这类设置能直接改它，
  /// 而不用在调用点上到处传参。
  final DownloadSource defaultSource;

  AiModelRegistry({
    List<AiModel>? models,
    this.defaultSource = DownloadSource.modelscope,
  }) : models = List<AiModel>.unmodifiable(models ?? AiModelCatalog.all);

  /// 全项目共用的一份
  ///
  /// 清单是静态数据，每次 new 一份只会让比较和缓存变麻烦；用 static final 懒加载，
  /// 测试里要隔离就自己 new 一个带假清单的实例。
  static final AiModelRegistry instance = AiModelRegistry();

  /// 按 id 找模型；找不到返回 null
  ///
  /// 保存用户选择时存的是 id，读回来要先落成 AiModel 才能展示，
  /// 所以这个查询是「持久化」那一侧的入口。
  AiModel? byId(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// 具备某个能力的全部模型，按清单顺序返回
  ///
  /// 返回新列表：调用方想排序/过滤时随便改，不会污染 [models]。
  List<AiModel> byCapability(AiCapability capability) {
    return <AiModel>[
      for (final model in models)
        if (model.supports(capability)) model,
    ];
  }

  /// 默认 tier 的优先级
  ///
  /// balanced 最均衡，放第一；light 是「跑得动就好」的保底；
  /// multilingual 靠语种覆盖而不是单语质量，排第三；
  /// highQuality **故意放最后** —— 它最慢最吃内存，设备很可能带不动，
  /// 只有前面几档都选不出来时才轮到它。
  static const List<ModelTier> _tierFallback = <ModelTier>[
    ModelTier.balanced,
    ModelTier.light,
    ModelTier.multilingual,
    ModelTier.highQuality,
  ];

  /// 为某台设备推荐一个模型；没有可用候选时返回 null
  ///
  /// 规则（顺序即优先级）：
  ///  1. **先过内存门槛** `minRamGB <= deviceRamGB`：装不下的一律不算候选。
  ///     这一条压过所有偏好 —— 推荐了也跑不起来，等于没推荐。
  ///  2. 给了 [preferredTier] 就优先它；该档位没有通过门槛的候选时，
  ///     退回默认顺序继续找（而不是直接返回 null：有能用的模型却告诉用户
  ///     「没有可用模型」是最糟的体验）。
  ///  3. 默认顺序：balanced → light → multilingual → highQuality（见 [_tierFallback]）。
  ///  4. 同一档位内的排序（[capability] 感知，见 [_compareInTier]）：
  ///     a) **类别优先**：按 [_kindPreference] 里该能力的类别顺序（翻译是 nmt → llm）；
  ///     b) 体积从大到小：同类别里体积大的通常质量更好，且门槛已过、不会撑爆设备；
  ///     c) id：只作最后确定性兜底，**不承载产品语义**。
  ///
  /// 为什么体积不能排在类别前面：100MB 的专用 NMT 翻译质量就比 400MB 的
  /// 通用小 LLM 好，纯按体积排会把「轻量翻译」错选成 LLM。
  AiModel? recommended({
    required AiCapability capability,
    required double deviceRamGB,
    ModelTier? preferredTier,
  }) {
    final eligible = <AiModel>[
      for (final model in models)
        if (model.supports(capability) && model.minRamGB <= deviceRamGB) model,
    ];
    if (eligible.isEmpty) return null;

    // 偏好档位放最前，其余档位按默认顺序跟在后面（并且跳过重复项）。
    // 注意不能只写 `if (!order.contains(tier)) insert(0, ...)`：默认顺序本来就
    // 包含全部四个档位，那样写等于永远不插入，偏好会静默失效。
    final order = <ModelTier>[
      if (preferredTier != null) preferredTier,
      for (final tier in _tierFallback)
        if (tier != preferredTier) tier,
    ];

    for (final tier in order) {
      final inTier = <AiModel>[
        for (final model in eligible)
          if (model.tier == tier) model,
      ];
      if (inTier.isEmpty) continue;
      inTier.sort((a, b) => _compareInTier(capability, a, b));
      return inTier.first;
    }
    // 理论上到不了：tier 枚举已全覆盖，且 eligible 非空
    return null;
  }

  /// 每个能力「优先选哪类模型」—— 列表索引越小越优先
  ///
  /// 为什么需要这张表：同档位里体积说明不了质量。翻译这种能力，
  /// 100MB 的专用 NMT 比 400MB 的通用小 LLM 更快也更准（参数全花在翻译上）。
  ///  - translate：nmt > llm。纯翻译用 NMT 更快更省电；LLM 的优势是译文更自然、
  ///    能控制格式（双语对照之类），那属于更高档位才需要权衡的事 ——
  ///    现清单里 balanced 及以上没有 nmt 候选，所以这条实际只影响 light 档。
  ///  - classify：只有 llm 干得了，NMT 不做分类。
  ///  - asr / asrStreaming / ocr / vad：各归各类，没有跨类比较的必要，
  ///    表里只放一类，等于「同类内按体积比」。
  ///
  /// 不在表里的类别：排在该能力所有已列类别之后（见 [_kindRank]）。
  static const Map<AiCapability, List<ModelKind>> _kindPreference =
      <AiCapability, List<ModelKind>>{
    AiCapability.translate: <ModelKind>[ModelKind.nmt, ModelKind.llm],
    AiCapability.classify: <ModelKind>[ModelKind.llm],
    AiCapability.asr: <ModelKind>[ModelKind.asr],
    AiCapability.asrStreaming: <ModelKind>[ModelKind.asr],
    AiCapability.ocr: <ModelKind>[ModelKind.ocr],
    AiCapability.vad: <ModelKind>[ModelKind.vad],
  };

  /// 某类别在该能力下的优先级（越小越优先；不在表里 = 最后）
  static int _kindRank(AiCapability capability, ModelKind kind) {
    final order = _kindPreference[capability] ?? const <ModelKind>[];
    final index = order.indexOf(kind);
    return index < 0 ? order.length : index;
  }

  /// 同档位内的排序：类别 → 体积从大到小 → id 兜底
  ///
  /// 三级键各自的作用：
  ///  - 类别：见 [_kindPreference]，是真正的产品决策；
  ///  - 体积：同类别内当质量代理（门槛已过，选大的不会撑爆设备）；
  ///  - id：**只**用来让结果确定。清单顺序将来会调整，不兜底的话
  ///    「同类别同体积」的推荐结果会随清单顺序漂移，测试也会时灵时不灵 ——
  ///    但 id 的大小没有任何业务含义，别拿它当产品偏好读。
  static int _compareInTier(AiCapability capability, AiModel a, AiModel b) {
    final byKind =
        _kindRank(capability, a.kind).compareTo(_kindRank(capability, b.kind));
    if (byKind != 0) return byKind;
    final bySize = b.sizeMB.compareTo(a.sizeMB);
    if (bySize != 0) return bySize;
    // 仅作确定性兜底：不承载产品语义
    return a.id.compareTo(b.id);
  }

  /// 按优先级返回某个模型的镜像列表
  ///
  /// 这就是「默认魔搭、失败退 HF」的实现基础：
  ///  - 传了 [preferred]（或实例的 [defaultSource]）且该来源存在 →
  ///    把它整体提到最前面，同来源内部保持清单里的原顺序；
  ///  - 没有该来源 → 原样返回 [AiModel.mirrors] 的顺序，
  ///    绝不能因为「偏好不存在」就把列表清空或重排成随机结果。
  ///
  /// 返回新列表，不原地改 model.mirrors（清单是共享的常量数据）。
  List<ModelMirror> mirrorsFor(AiModel model, {DownloadSource? preferred}) {
    final source = preferred ?? defaultSource;
    final first = <ModelMirror>[
      for (final mirror in model.mirrors)
        if (mirror.source == source) mirror,
    ];
    if (first.isEmpty) return List<ModelMirror>.of(model.mirrors);
    return <ModelMirror>[
      ...first,
      for (final mirror in model.mirrors)
        if (mirror.source != source) mirror,
    ];
  }
}

/// 展示辅助：把模型数据拼成 UI 能用的一行/两行文字
///
/// 为什么集中在这里：同一个模型要在「推荐卡片」「下载列表」「设置页」出现三次，
/// 文案散在三处必然走样（有的显示 MB、有的显示 GB、有的忘了许可证）。
class AiModelSelector {
  AiModelSelector._();

  /// 能力的中文短标签
  static String capabilityLabel(AiCapability capability) {
    switch (capability) {
      case AiCapability.vad:
        return '人声检测';
      case AiCapability.asr:
        return '语音识别';
      case AiCapability.asrStreaming:
        return '实时识别';
      case AiCapability.translate:
        return '翻译';
      case AiCapability.classify:
        return '文本分类';
      case AiCapability.ocr:
        return '字幕识别';
    }
  }

  /// 档位的中文短标签
  static String tierLabel(ModelTier tier) {
    switch (tier) {
      case ModelTier.light:
        return '轻量';
      case ModelTier.balanced:
        return '均衡';
      case ModelTier.highQuality:
        return '高质量';
      case ModelTier.multilingual:
        return '多语言';
    }
  }

  /// 下载来源的中文名
  static String sourceLabel(DownloadSource source) {
    switch (source) {
      case DownloadSource.modelscope:
        return '魔搭';
      case DownloadSource.huggingface:
        return 'Hugging Face';
    }
  }

  /// 一句话描述，如「SenseVoice Small 多语识别 · 约 230 MB · 中文/English · Apache-2.0」
  static String describe(AiModel model) {
    return <String>[
      model.displayName,
      '约 ${model.sizeLabel}',
      _languagesLabel(model),
      model.license,
    ].join(' · ');
  }

  /// 带适用场景说明的长描述（推荐卡片里用）
  static String describeWithNotes(AiModel model) {
    return '${describe(model)}（${tierLabel(model.tier)}）\n${model.notes}';
  }

  /// 语言列表 → 展示文本
  ///
  /// 空列表按「与语言无关」处理（VAD 这类）；只列几个再补「等」，
  /// 因为一行里塞 13 个语种代码没人看得下去。
  static String _languagesLabel(AiModel model) {
    if (model.languages.isEmpty) return '语言无关';
    const labels = <String, String>{
      'zh': '中文',
      'en': 'English',
      'ja': '日本語',
      'ko': '한국어',
      'yue': '粤语',
    };
    final shown = <String>[
      for (final code in model.languages.take(4)) labels[code] ?? code,
    ];
    final tail = model.languages.length > shown.length ? ' 等' : '';
    return '${shown.join('/')}$tail';
  }
}
