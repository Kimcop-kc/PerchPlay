// 端侧 AI 模型注册表的单测
//
// 这一层是「纯数据 + 纯函数」，所以规则必须钉死在测试里 —— 一旦规则走样，
// 表现是「某台机器下完模型跑不起来」或者「明明有能用的模型却说没有」，
// 都是用户很难自己定位的问题。覆盖点：
//  - 清单本身要完整：id 唯一、体积 > 0、至少一条镜像、能力/许可证非空
//  - 内存门槛压过所有偏好（装不下的模型不能被推荐）
//  - 默认 tier 顺序：balanced → light → multilingual → highQuality
//  - preferredTier 优先；该档没有候选时退回默认顺序而不是返回 null
//  - 同档位内的排序键：kind 优先表 → 体积从大到小 → id（仅确定性兜底）
//  - 镜像顺序：指定来源排第一；模型没有该来源时保持原顺序，且不污染清单
//  - 方案 C 的四条目标行为（translate 各档位分别落到谁）
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/ai/ai_model.dart';
import 'package:perchplay/services/ai/ai_model_catalog.dart';
import 'package:perchplay/services/ai/ai_model_registry.dart';

/// 造一个测试用模型
///
/// 为什么需要它：真实清单里每个能力都至少有一个模型，想验证
/// 「没有候选 → null」「nmt 与 llm 的排序」「id 兜底」这类规则，
/// 只能自己造数据 —— 否则测试就只是在依赖清单里恰好存在某两个条目。
AiModel _testModel({
  required String id,
  required AiCapability capability,
  ModelKind kind = ModelKind.llm,
  ModelTier tier = ModelTier.light,
  int sizeMB = 10,
  int speedRating = 3,
  int qualityRating = 3,
  double minRamGB = 1.0,
  String notes = '仅测试用',
  List<ModelMirror>? mirrors,
}) {
  return AiModel(
    id: id,
    displayName: '测试模型 $id',
    capabilities: <AiCapability>{capability},
    kind: kind,
    tier: tier,
    sizeMB: sizeMB,
    speedRating: speedRating,
    qualityRating: qualityRating,
    languages: const <String>[],
    license: 'MIT',
    minRamGB: minRamGB,
    mirrors: mirrors ??
        <ModelMirror>[
          ModelMirror(
            source: DownloadSource.modelscope,
            url: 'https://example.invalid/$id',
          ),
        ],
    notes: notes,
  );
}

void main() {
  final registry = AiModelRegistry.instance;
  const catalog = AiModelCatalog.all;

  group('清单完整性', () {
    test('id 唯一、体积为正、至少一条镜像、能力与许可证非空', () {
      expect(catalog, isNotEmpty);

      final ids = catalog.map((m) => m.id).toList();
      expect(
        ids.toSet().length,
        ids.length,
        reason: 'id 是持久化用的键，重复会让两个模型的下载目录串台',
      );

      for (final model in catalog) {
        final why = '模型 ${model.id}';
        expect(model.sizeMB, greaterThan(0), reason: '$why 的体积必须 > 0');
        expect(model.minRamGB, greaterThan(0), reason: '$why 需要内存门槛');
        expect(model.mirrors, isNotEmpty, reason: '$why 至少要有一条下载地址');
        expect(model.capabilities, isNotEmpty, reason: '$why 不声明能力就永远不会被推荐');
        expect(model.displayName, isNotEmpty, reason: '$why 要有中文展示名');
        expect(model.notes, isNotEmpty, reason: '$why 要有一句话说明');
        expect(model.license, isNotEmpty, reason: '$why 要标许可证（决定能否随包分发）');
        expect(model.speedRating, inInclusiveRange(1, 5),
            reason: '$why 的速度评分必须是 1~5');
        expect(model.qualityRating, inInclusiveRange(1, 5),
            reason: '$why 的质量评分必须是 1~5');

        for (final mirror in model.mirrors) {
          expect(mirror.url, startsWith('https://'),
              reason: '$why 的下载地址必须是 https');
          // 骨架阶段允许没有 sha256（见 ModelMirror 的注释），
          // 但一旦填了就必须是规范的 64 位小写十六进制，否则等于没校验
          if (mirror.sha256 != null) {
            expect(mirror.sha256, matches(RegExp(r'^[0-9a-f]{64}$')),
                reason: '$why 的 sha256 格式不对');
          }
        }
      }
    });

    test('需求点名的模型都在，体积/许可证/档位/类别与约定一致', () {
      const expected = <
          String,
          ({int sizeMB, String license, ModelTier tier, ModelKind kind})>{
        'silero-vad': (
          sizeMB: 2,
          license: 'Apache-2.0',
          tier: ModelTier.light,
          kind: ModelKind.vad,
        ),
        'zipformer-zh-en-streaming': (
          sizeMB: 80,
          license: 'Apache-2.0',
          tier: ModelTier.light,
          kind: ModelKind.asr,
        ),
        'sensevoice-small': (
          sizeMB: 230,
          license: 'Apache-2.0',
          tier: ModelTier.balanced,
          kind: ModelKind.asr,
        ),
        'paraformer-zh-streaming': (
          sizeMB: 220,
          license: 'Apache-2.0',
          tier: ModelTier.balanced,
          kind: ModelKind.asr,
        ),
        'whisper-base': (
          sizeMB: 150,
          license: 'MIT',
          tier: ModelTier.multilingual,
          kind: ModelKind.asr,
        ),
        'whisper-small': (
          sizeMB: 500,
          license: 'MIT',
          tier: ModelTier.multilingual,
          kind: ModelKind.asr,
        ),
        'whisper-large-v3-turbo': (
          sizeMB: 1600,
          license: 'MIT',
          tier: ModelTier.highQuality,
          kind: ModelKind.asr,
        ),
        'qwen3-0.6b': (
          sizeMB: 400,
          license: 'Apache-2.0',
          tier: ModelTier.light,
          kind: ModelKind.llm,
        ),
        'qwen3-1.7b': (
          sizeMB: 1100,
          license: 'Apache-2.0',
          tier: ModelTier.balanced,
          kind: ModelKind.llm,
        ),
        'qwen2.5-3b-instruct': (
          sizeMB: 2000,
          license: 'Apache-2.0',
          tier: ModelTier.highQuality,
          kind: ModelKind.llm,
        ),
        'gemma-3-1b': (
          sizeMB: 550,
          license: 'Gemma Terms',
          tier: ModelTier.light,
          kind: ModelKind.llm,
        ),
        'opus-mt-zh-en': (
          sizeMB: 100,
          license: 'CC-BY-4.0',
          tier: ModelTier.light,
          kind: ModelKind.nmt,
        ),
        // 方案 C：MADLAD 归「多语言」而不是「高质量」—— 它的价值是 400+ 语种覆盖
        'madlad-400-3b': (
          sizeMB: 2000,
          license: 'Apache-2.0',
          tier: ModelTier.multilingual,
          kind: ModelKind.nmt,
        ),
        'rapidocr-onnx': (
          sizeMB: 20,
          license: 'Apache-2.0',
          tier: ModelTier.light,
          kind: ModelKind.ocr,
        ),
      };

      for (final entry in expected.entries) {
        final model = registry.byId(entry.key);
        expect(model, isNotNull, reason: '清单里缺了 ${entry.key}');
        expect(model!.sizeMB, entry.value.sizeMB,
            reason: '${entry.key} 的体积与约定不一致');
        expect(model.license, entry.value.license,
            reason: '${entry.key} 的许可证与约定不一致');
        expect(model.tier, entry.value.tier,
            reason: '${entry.key} 的档位与约定不一致');
        expect(model.kind, entry.value.kind,
            reason: '${entry.key} 的类别与约定不一致');
      }
      expect(catalog.length, greaterThanOrEqualTo(18),
          reason: '14 个原有条目 + 4 个新模型（bge×2 / paddleocr / nima）');
    });
  });

  group('byCapability', () {
    test('只返回带该能力的模型，且每个能力都至少有一个候选', () {
      for (final capability in AiCapability.values) {
        final hits = registry.byCapability(capability);
        expect(hits, isNotEmpty,
            reason: '${capability.name} 一个模型都没有，对应功能等于没实现');
        expect(hits.every((m) => m.supports(capability)), isTrue,
            reason: '${capability.name} 的查询结果里混进了不支持它的模型');
      }

      // 单一能力的模型：越多越容易在 UI 里被误选，钉住
      expect(registry.byCapability(AiCapability.vad).map((m) => m.id),
          <String>['silero-vad']);
      // ocr 本轮扩到两条（RapidOCR + PaddleOCR），见「新能力」组的数量断言
      expect(registry.byCapability(AiCapability.ocr).map((m) => m.id),
          <String>['rapidocr-onnx', 'paddleocr-ppocr-v4']);
    });

    test('返回的是副本：调用方改了不会污染注册表', () {
      final asr = registry.byCapability(AiCapability.asr);
      asr.clear();
      expect(registry.byCapability(AiCapability.asr), isNotEmpty,
          reason: '清单是共享数据，查询结果必须是新列表');
    });

    test('qwen3-0.6b 不再提供 translate（0.6B 的翻译质量不达标）', () {
      expect(
        registry.byCapability(AiCapability.translate).map((m) => m.id),
        isNot(contains('qwen3-0.6b')),
        reason: '把它塞进翻译候选，会让「轻量翻译」选到 400MB 却不如 100MB 的 Opus-MT',
      );
      final small = registry.byId('qwen3-0.6b')!;
      expect(small.capabilities, <AiCapability>{AiCapability.classify});
      expect(small.supports(AiCapability.translate), isFalse);
      // 它该做的事（分类）仍然能选到它
      expect(
        registry
            .recommended(
              capability: AiCapability.classify,
              deviceRamGB: 8,
              preferredTier: ModelTier.light,
            )
            ?.id,
        'qwen3-0.6b',
      );
    });
  });

  group('recommended', () {
    test('内存门槛：4GB 设备不会被推荐 2GB 的模型', () {
      final pick = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 4,
      );
      expect(pick, isNotNull, reason: '4GB 下仍有轻量翻译模型可用');
      expect(pick!.minRamGB, lessThanOrEqualTo(4),
          reason: '推荐结果必须过内存门槛');
      expect(pick.sizeMB, lessThan(2000),
          reason: '2GB 权重 + 运行时开销，4GB 设备装不下还能用');
      expect(pick.id, 'opus-mt-zh-en',
          reason: '4GB 下 balanced 全被门槛拦掉，light 里优先专用 NMT');

      final highQuality = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 4,
        preferredTier: ModelTier.highQuality,
      );
      expect(highQuality, isNotNull,
          reason: '偏好档位没有候选时应回退，而不是告诉用户没有模型');
      expect(highQuality!.minRamGB, lessThanOrEqualTo(4),
          reason: 'preferredTier 不能越过内存门槛');
    });

    test('内存门槛边界：等于门槛可用，差一点就不可用', () {
      // 2.0GB 恰好过 ocr 的显式默认（PaddleOCR，minRam 2.0）的门槛
      expect(
        registry
            .recommended(capability: AiCapability.ocr, deviceRamGB: 2.0)
            ?.id,
        'paddleocr-ppocr-v4',
      );
      expect(
        registry.recommended(capability: AiCapability.ocr, deviceRamGB: 1.99),
        isNull,
        reason: '内存不够时宁可不推荐，也不要推荐了照着闪退',
      );
    });

    test('8GB 设备在语音识别上优先拿到 balanced 档', () {
      final pick = registry.recommended(
        capability: AiCapability.asr,
        deviceRamGB: 8,
      );
      expect(pick, isNotNull);
      expect(pick!.tier, ModelTier.balanced,
          reason: '已有 light 档（80MB）可选，但 balanced 应优先');
      expect(pick.id, 'sensevoice-small',
          reason: '同为 asr 类别，体积大的优先：230MB > 220MB');
      expect(pick.minRamGB, lessThanOrEqualTo(8));
    });

    test('方案 C：translate 各 preferredTier 落到指定模型', () {
      // 内存足够，本条只验证选型，不验证门槛
      const deviceRamGB = 32.0;

      expect(
        registry
            .recommended(
              capability: AiCapability.translate,
              deviceRamGB: deviceRamGB,
              preferredTier: ModelTier.light,
            )
            ?.id,
        'opus-mt-zh-en',
        reason: '轻量翻译选专用 NMT（100MB），不是 550MB 的 Gemma',
      );
      expect(
        registry
            .recommended(
              capability: AiCapability.translate,
              deviceRamGB: deviceRamGB,
              preferredTier: ModelTier.balanced,
            )
            ?.id,
        'qwen3-1.7b',
        reason: 'balanced 翻译只有 1.7B 这个 LLM',
      );
      expect(
        registry
            .recommended(
              capability: AiCapability.translate,
              deviceRamGB: deviceRamGB,
              preferredTier: ModelTier.highQuality,
            )
            ?.id,
        'qwen2.5-3b-instruct',
        reason: 'MADLAD 已改归多语言档，高质量翻译由 3B LLM 承担',
      );
      expect(
        registry
            .recommended(
              capability: AiCapability.translate,
              deviceRamGB: deviceRamGB,
              preferredTier: ModelTier.multilingual,
            )
            ?.id,
        'madlad-400-3b',
        reason: '多语言档就是给「要小语种」的人准备的',
      );
    });

    test('指定 preferredTier 时优先生效', () {
      final multilingual = registry.recommended(
        capability: AiCapability.asr,
        deviceRamGB: 16,
        preferredTier: ModelTier.multilingual,
      );
      expect(multilingual?.tier, ModelTier.multilingual);
      expect(multilingual?.id, 'whisper-small',
          reason: '同为多语言档，500MB 的比 150MB 的优先');

      final highQuality = registry.recommended(
        capability: AiCapability.asr,
        deviceRamGB: 16,
        preferredTier: ModelTier.highQuality,
      );
      expect(highQuality?.id, 'whisper-large-v3-turbo',
          reason: '16GB 下高质量档能过门槛，且被偏好提到最前');

      final light = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 8,
        preferredTier: ModelTier.light,
      );
      expect(light?.id, 'opus-mt-zh-en',
          reason: 'light 档里 nmt 优先：100MB 的 Opus-MT 胜过 550MB 的 Gemma');
    });

    test('preferredTier 没有候选时退回默认顺序', () {
      // 4GB 下没有任何 highQuality 翻译模型能过门槛
      final pick = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 4,
        preferredTier: ModelTier.highQuality,
      );
      expect(pick, isNotNull);
      expect(pick!.id, 'opus-mt-zh-en',
          reason: '退到 light 档，且档内 nmt 优先');
      expect(pick.tier, ModelTier.light);
    });

    test('capability 无候选时返回 null', () {
      final sparse = AiModelRegistry(
        models: <AiModel>[
          _testModel(id: 'only-vad', capability: AiCapability.vad),
        ],
      );
      expect(
        sparse.recommended(capability: AiCapability.ocr, deviceRamGB: 32),
        isNull,
      );
      expect(
        AiModelRegistry(models: const <AiModel>[])
            .recommended(capability: AiCapability.vad, deviceRamGB: 64),
        isNull,
        reason: '空清单不能抛异常，只能返回 null',
      );
    });

    test('同档位内 nmt 胜过体积更大的 llm（translate）', () {
      final synthetic = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'big-llm',
            capability: AiCapability.translate,
            kind: ModelKind.llm,
            sizeMB: 900,
          ),
          _testModel(
            id: 'small-nmt',
            capability: AiCapability.translate,
            kind: ModelKind.nmt,
            sizeMB: 100,
          ),
        ],
      );
      expect(
        synthetic
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'small-nmt',
        reason: 'kind 键在体积键之前：不能因为 LLM 更大就选它',
      );
    });

    test('同档位内 classify 只认 llm（且不看体积）', () {
      final synthetic = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'big-nmt',
            capability: AiCapability.classify,
            kind: ModelKind.nmt,
            sizeMB: 900,
          ),
          _testModel(
            id: 'small-llm',
            capability: AiCapability.classify,
            kind: ModelKind.llm,
            sizeMB: 100,
          ),
        ],
      );
      expect(
        synthetic
            .recommended(capability: AiCapability.classify, deviceRamGB: 16)
            ?.id,
        'small-llm',
        reason: 'NMT 不做分类，llm 在 kind 表里排第一',
      );
    });

    test('id 兜底只在 tier/kind/体积全部平手时才生效', () {
      // ① 体积不同 → 体积大的赢，id 再小也不该翻身
      final bySize = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'aaa-small',
            capability: AiCapability.translate,
            sizeMB: 100,
          ),
          _testModel(
            id: 'zzz-big',
            capability: AiCapability.translate,
            sizeMB: 900,
          ),
        ],
      );
      expect(
        bySize
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'zzz-big',
        reason: '体积键在 id 之前',
      );

      // ② kind 不同 → kind 表赢，id 和体积都不参与
      final byKind = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'aaa-llm',
            capability: AiCapability.translate,
            kind: ModelKind.llm,
            sizeMB: 900,
          ),
          _testModel(
            id: 'zzz-nmt',
            capability: AiCapability.translate,
            kind: ModelKind.nmt,
            sizeMB: 100,
          ),
        ],
      );
      expect(
        byKind
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'zzz-nmt',
        reason: 'kind 键在 id 之前',
      );

      // ③ 全平手 → 只剩 id，必须是升序，且与清单顺序无关
      AiModel tie(String id) => _testModel(
            id: id,
            capability: AiCapability.translate,
            sizeMB: 500,
          );
      final forward = AiModelRegistry(models: <AiModel>[tie('aaa'), tie('zzz')]);
      final backward = AiModelRegistry(models: <AiModel>[tie('zzz'), tie('aaa')]);
      expect(
        forward
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'aaa',
      );
      expect(
        backward
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'aaa',
        reason: '全部平手时只剩确定性兜底，结果不能受清单顺序影响',
      );
    });
  });

  group('显式默认模型', () {
    test('没指定档位时按显式默认选，且 8 个能力的默认值都钉住', () {
      // OCR 是这条机制存在的理由：PaddleOCR（15MB）体积比 RapidOCR（20MB）小，
      // 纯排序永远选不到它，但产品要它当「硬字幕转双语」的主选。
      expect(
        registry
            .recommended(capability: AiCapability.ocr, deviceRamGB: 16)
            ?.id,
        'paddleocr-ppocr-v4',
      );
      expect(
        registry.recommended(capability: AiCapability.vad, deviceRamGB: 16)?.id,
        'silero-vad',
      );
      expect(
        registry.recommended(capability: AiCapability.asr, deviceRamGB: 16)?.id,
        'sensevoice-small',
      );
      expect(
        registry
            .recommended(capability: AiCapability.asrStreaming, deviceRamGB: 16)
            ?.id,
        'paraformer-zh-streaming',
      );
      expect(
        registry
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'qwen3-1.7b',
      );
      expect(
        registry
            .recommended(capability: AiCapability.classify, deviceRamGB: 16)
            ?.id,
        'qwen3-0.6b',
      );
      expect(
        registry
            .recommended(capability: AiCapability.embed, deviceRamGB: 16)
            ?.id,
        'bge-small-zh-v1.5',
      );
      expect(
        registry
            .recommended(capability: AiCapability.frameScore, deviceRamGB: 16)
            ?.id,
        'nima-frame-quality',
      );
    });

    test('指定 preferredTier 时显式默认不生效，按档位走', () {
      // OCR 的真实清单里：指定 light 后不再看默认表，落回「同档同 kind 体积降序」，
      // 于是选到 20MB 的 RapidOCR —— 和「不指定档位时选 PaddleOCR」并不矛盾：
      // 前者是用户明确要轻量档的兜底排序，后者是产品默认意图。
      final light = registry.recommended(
        capability: AiCapability.ocr,
        deviceRamGB: 16,
        preferredTier: ModelTier.light,
      );
      expect(light?.id, 'rapidocr-onnx');
      expect(light?.tier, ModelTier.light);

      // 注入构造：证明默认表确实被跳过，而不是恰好结果相同
      final injected = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'light-ocr',
            capability: AiCapability.ocr,
            tier: ModelTier.light,
          ),
          _testModel(
            id: 'balanced-ocr',
            capability: AiCapability.ocr,
            tier: ModelTier.balanced,
          ),
        ],
        defaultModelIds: const <AiCapability, String>{
          AiCapability.ocr: 'light-ocr',
        },
      );
      expect(
        injected
            .recommended(capability: AiCapability.ocr, deviceRamGB: 16)
            ?.id,
        'light-ocr',
      );
      expect(
        injected
            .recommended(
              capability: AiCapability.ocr,
              deviceRamGB: 16,
              preferredTier: ModelTier.balanced,
            )
            ?.id,
        'balanced-ocr',
        reason: '用户明确挑了档位，默认表必须让位',
      );
    });

    test('显式默认被内存门槛拦掉时回退到原有排序', () {
      // 真实清单：translate 默认 qwen3-1.7B 要 6GB，4GB 机器装不下
      // → 回退到 light 档（kind 表让 nmt 优先）→ Opus-MT
      expect(
        registry
            .recommended(capability: AiCapability.translate, deviceRamGB: 4)
            ?.id,
        'opus-mt-zh-en',
        reason: '默认模型装不下就必须让位，不能推荐到会闪退的模型',
      );

      // 注入场景更干净：默认模型 minRam 8，备选 minRam 1
      final injected = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'big-default',
            capability: AiCapability.ocr,
            minRamGB: 8,
            sizeMB: 10,
          ),
          _testModel(
            id: 'small-alt',
            capability: AiCapability.ocr,
            minRamGB: 1,
            sizeMB: 5,
          ),
        ],
        defaultModelIds: const <AiCapability, String>{
          AiCapability.ocr: 'big-default',
        },
      );
      expect(
        injected
            .recommended(capability: AiCapability.ocr, deviceRamGB: 4)
            ?.id,
        'small-alt',
      );
      expect(
        injected
            .recommended(capability: AiCapability.ocr, deviceRamGB: 8)
            ?.id,
        'big-default',
        reason: '内存够了默认模型照常生效',
      );
    });

    test('显式默认配错（不存在 / 不支持该能力）时静默回退，不抛异常', () {
      final missing = AiModelRegistry(
        models: <AiModel>[
          _testModel(id: 'real-ocr', capability: AiCapability.ocr),
        ],
        defaultModelIds: const <AiCapability, String>{
          AiCapability.ocr: 'does-not-exist',
        },
      );
      expect(
        missing.recommended(capability: AiCapability.ocr, deviceRamGB: 16)?.id,
        'real-ocr',
      );

      // 指到不支持该能力的模型上时，不能因为「配了就信」而硬塞
      final wrongCapability = AiModelRegistry(
        models: <AiModel>[
          _testModel(id: 'vad-only', capability: AiCapability.vad),
          _testModel(id: 'real-ocr', capability: AiCapability.ocr),
        ],
        defaultModelIds: const <AiCapability, String>{
          AiCapability.ocr: 'vad-only',
        },
      );
      expect(
        wrongCapability
            .recommended(capability: AiCapability.ocr, deviceRamGB: 16)
            ?.id,
        'real-ocr',
      );
    });
  });

  group('mirrorsFor：默认魔搭、失败退 HF', () {
    test('默认来源是魔搭', () {
      expect(registry.defaultSource, DownloadSource.modelscope);
      expect(AiModelRegistry().defaultSource, DownloadSource.modelscope);
    });

    test('指定 huggingface 时 HF 排第一，且不丢镜像', () {
      final model = registry.byId('sensevoice-small')!;
      final mirrors = registry.mirrorsFor(
        model,
        preferred: DownloadSource.huggingface,
      );
      expect(mirrors.length, model.mirrors.length, reason: '重排不能丢地址');
      expect(mirrors.first.source, DownloadSource.huggingface);
      expect(
        mirrors.map((m) => m.url).toSet(),
        model.mirrors.map((m) => m.url).toSet(),
      );
      expect(model.mirrors.first.source, DownloadSource.modelscope,
          reason: '不能原地改清单，否则其他调用方看到的顺序就变了');
    });

    test('指定 modelscope 时魔搭排第一（原顺序是 HF 在前）', () {
      // 构造一个「HF 优先」的模型，验证偏好真的会把魔搭提前
      final hfFirst = _testModel(
        id: 'hf-first',
        capability: AiCapability.translate,
        mirrors: const <ModelMirror>[
          ModelMirror(
            source: DownloadSource.huggingface,
            url: 'https://example.invalid/hf-first-hf',
          ),
          ModelMirror(
            source: DownloadSource.modelscope,
            url: 'https://example.invalid/hf-first-ms',
          ),
        ],
      );
      final mirrors =
          registry.mirrorsFor(hfFirst, preferred: DownloadSource.modelscope);
      expect(mirrors.first.source, DownloadSource.modelscope);
      expect(mirrors.last.source, DownloadSource.huggingface,
          reason: '没有指定来源的镜像要接在后面，作为失败时的退路');
    });

    test('模型没有该来源时保持原顺序', () {
      final gemma = registry.byId('gemma-3-1b')!;
      expect(gemma.mirrors.every((m) => m.source == DownloadSource.huggingface),
          isTrue);
      final mirrors =
          registry.mirrorsFor(gemma, preferred: DownloadSource.modelscope);
      expect(
        mirrors.map((m) => m.url).toList(),
        gemma.mirrors.map((m) => m.url).toList(),
        reason: '偏好来源不存在时不能重排、更不能清空',
      );
    });

    test('不传 preferred 时用实例默认来源', () {
      final model = registry.byId('qwen3-1.7b')!;
      final hfDefault = AiModelRegistry(
        models: <AiModel>[model],
        defaultSource: DownloadSource.huggingface,
      );
      expect(hfDefault.mirrorsFor(model).first.source,
          DownloadSource.huggingface);
      expect(registry.mirrorsFor(model).first.source,
          DownloadSource.modelscope);
    });
  });

  group('评分与表格渲染', () {
    test('全清单都有 speedRating/qualityRating，且都在 1~5', () {
      for (final model in catalog) {
        expect(model.speedRating, inInclusiveRange(1, 5),
            reason: '${model.id} 的速度评分越界');
        expect(model.qualityRating, inInclusiveRange(1, 5),
            reason: '${model.id} 的质量评分越界');
      }
    });

    test('需求给定的评分表逐条落实（14 旧 + 4 新）', () {
      const ratings = <String, ({int speed, int quality})>{
        'silero-vad': (speed: 5, quality: 5),
        'zipformer-zh-en-streaming': (speed: 5, quality: 3),
        'sensevoice-small': (speed: 5, quality: 4),
        'paraformer-zh-streaming': (speed: 5, quality: 5),
        'whisper-base': (speed: 3, quality: 3),
        'whisper-small': (speed: 2, quality: 4),
        'whisper-large-v3-turbo': (speed: 2, quality: 5),
        'qwen3-0.6b': (speed: 5, quality: 2),
        'qwen3-1.7b': (speed: 3, quality: 4),
        'qwen2.5-3b-instruct': (speed: 2, quality: 5),
        'gemma-3-1b': (speed: 3, quality: 3),
        'opus-mt-zh-en': (speed: 5, quality: 4),
        'madlad-400-3b': (speed: 2, quality: 4),
        'rapidocr-onnx': (speed: 4, quality: 4),
        'bge-small-zh-v1.5': (speed: 5, quality: 4),
        'bge-m3': (speed: 2, quality: 5),
        'paddleocr-ppocr-v4': (speed: 4, quality: 5),
        'nima-frame-quality': (speed: 5, quality: 3),
      };
      for (final entry in ratings.entries) {
        final model = registry.byId(entry.key);
        expect(model, isNotNull, reason: '清单里缺了 ${entry.key}');
        expect(model!.speedRating, entry.value.speed,
            reason: '${entry.key} 的速度分与约定不一致');
        expect(model.qualityRating, entry.value.quality,
            reason: '${entry.key} 的质量分与约定不一致');
      }
    });

    test('stars 把 1~5 之外的分数夹紧到边界', () {
      expect(AiModelSelector.stars(0), '★☆☆☆☆');
      expect(AiModelSelector.stars(-3), '★☆☆☆☆');
      expect(AiModelSelector.stars(1), '★☆☆☆☆');
      expect(AiModelSelector.stars(3), '★★★☆☆');
      expect(AiModelSelector.stars(5), '★★★★★');
      expect(AiModelSelector.stars(6), '★★★★★');
      expect(AiModelSelector.stars(99), '★★★★★');
    });

    test('表格行六列，顺序为 模型/体积/语言/速度/质量/定位', () {
      final model = registry.byId('sensevoice-small')!;
      final cells = AiModelSelector.tableRow(model).split(' | ');
      expect(cells.length, 6, reason: '固定六列才能对齐：${AiModelSelector.tableRow(model)}');
      expect(cells[0], contains('SenseVoice'));
      expect(cells[1], contains('230 MB'));
      expect(cells[2], contains('中文'));
      expect(cells[3], AiModelSelector.stars(model.speedRating));
      expect(cells[4], AiModelSelector.stars(model.qualityRating));
      expect(cells[5], model.notes);

      expect(
        AiModelSelector.tableHeader.split(' | '),
        <String>['模型', '体积', '语言', '速度', '质量', '定位'],
      );

      // 语言无关的模型（VAD）不能输出空列
      final vadRow = AiModelSelector.tableRow(registry.byId('silero-vad')!);
      expect(vadRow.split(' | ')[2], '语言无关');

      // 整张表 = 表头 + 每条一行
      expect(AiModelSelector.table(catalog).length, catalog.length + 1);
    });

    test('notes 里出现竖线时表格仍是六列', () {
      final weird = _testModel(
        id: 'pipe-model',
        capability: AiCapability.ocr,
        notes: '含竖线 | 的说明 | 再一根',
      );
      final row = AiModelSelector.tableRow(weird);
      final cells = row.split(' | ');
      expect(cells.length, 6, reason: '竖线必须被替换掉，否则整行错位：$row');
      expect(cells[5], '含竖线 / 的说明 / 再一根');
    });
  });

  group('新能力：embed 与 frameScore', () {
    test('byCapability 落到正确的条目上', () {
      expect(
        registry.byCapability(AiCapability.embed).map((m) => m.id).toList(),
        <String>['bge-small-zh-v1.5', 'bge-m3'],
      );
      expect(
        registry.byCapability(AiCapability.ocr).map((m) => m.id).toList(),
        <String>['rapidocr-onnx', 'paddleocr-ppocr-v4'],
      );
      expect(
        registry
            .byCapability(AiCapability.frameScore)
            .map((m) => m.id)
            .toList(),
        <String>['nima-frame-quality'],
      );
    });

    test('recommended(embed) 在 16GB 旗舰上选出合理默认', () {
      final pick = registry.recommended(
        capability: AiCapability.embed,
        deviceRamGB: 16,
      );
      expect(pick?.id, 'bge-small-zh-v1.5',
          reason: '默认走 light：100MB 中文小模型够用且快');
      expect(pick?.minRamGB, lessThanOrEqualTo(16));

      final multilingual = registry.recommended(
        capability: AiCapability.embed,
        deviceRamGB: 16,
        preferredTier: ModelTier.multilingual,
      );
      expect(multilingual?.id, 'bge-m3', reason: '多语种检索要 M3');

      // 内存不够就不给 2.2GB 的多语模型
      expect(
        registry
            .recommended(capability: AiCapability.embed, deviceRamGB: 4)
            ?.id,
        'bge-small-zh-v1.5',
      );
    });

    test('recommended(ocr) 不会串到别的能力，且默认是 PaddleOCR', () {
      final pick = registry.recommended(
        capability: AiCapability.ocr,
        deviceRamGB: 16,
      );
      expect(pick, isNotNull);
      expect(pick!.kind, ModelKind.ocr);
      expect(pick.supports(AiCapability.ocr), isTrue);
      expect(pick.id, 'paddleocr-ppocr-v4',
          reason: '显式默认指定了「硬字幕转双语」主选，不能再被体积降序挤成 RapidOCR');
    });

    test('frameScore 没有模型时功能也必须照常（能力可空）', () {
      final withoutFrame = AiModelRegistry(
        models: <AiModel>[
          for (final model in catalog)
            if (!model.supports(AiCapability.frameScore)) model,
        ],
      );
      expect(withoutFrame.byCapability(AiCapability.frameScore), isEmpty);
      expect(
        withoutFrame.recommended(
          capability: AiCapability.frameScore,
          deviceRamGB: 16,
        ),
        isNull,
        reason: '没有模型是正常状态（纯算法抽帧就够用），不能当错误',
      );
      // 其它能力不受影响
      expect(withoutFrame.byCapability(AiCapability.embed), isNotEmpty);
      expect(
        withoutFrame.recommended(capability: AiCapability.ocr, deviceRamGB: 16),
        isNotNull,
      );
    });
  });

  group('展示辅助', () {
    test('describe 拼出名字/体积/语言/许可证', () {
      final model = registry.byId('sensevoice-small')!;
      final text = AiModelSelector.describe(model);
      expect(text, contains('SenseVoice'));
      expect(text, contains('230 MB'));
      expect(text, contains('中文'));
      expect(text, contains('Apache-2.0'));

      expect(AiModelSelector.tierLabel(model.tier), '均衡');
      expect(AiModelSelector.capabilityLabel(AiCapability.asrStreaming), '实时识别');
      expect(AiModelSelector.sourceLabel(DownloadSource.modelscope), '魔搭');

      // 语言无关的模型（VAD）不能显示成一串空字符串
      final vad = registry.byId('silero-vad')!;
      expect(vad.languages, isEmpty);
      expect(AiModelSelector.describe(vad), contains('语言无关'));
    });
  });
}
