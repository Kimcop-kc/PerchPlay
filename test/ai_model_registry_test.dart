// 端侧 AI 模型注册表的单测
//
// 这一层是「纯数据 + 纯函数」，所以规则必须钉死在测试里 —— 一旦规则走样，
// 表现是「某台机器下完模型跑不起来」或者「明明有能用的模型却说没有」，
// 都是用户很难自己定位的问题。覆盖点：
//  - 清单本身要完整：id 唯一、体积 > 0、至少一条镜像、能力/许可证非空
//  - 内存门槛压过所有偏好（装不下的模型不能被推荐）
//  - 默认 tier 顺序：balanced → light → multilingual → highQuality
//  - preferredTier 优先；该档没有候选时退回默认顺序而不是返回 null
//  - 镜像顺序：指定来源排第一；模型没有该来源时保持原顺序，且不污染清单
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/ai/ai_model.dart';
import 'package:perchplay/services/ai/ai_model_catalog.dart';
import 'package:perchplay/services/ai/ai_model_registry.dart';

/// 造一个测试用模型
///
/// 为什么需要它：真实清单里每个能力都至少有一个模型，想验证
/// 「没有候选 → null」「HF 原顺序被提到前面」这类边界，只能自己造数据。
AiModel _testModel({
  required String id,
  required AiCapability capability,
  ModelTier tier = ModelTier.light,
  int sizeMB = 10,
  double minRamGB = 1.0,
  List<ModelMirror>? mirrors,
}) {
  return AiModel(
    id: id,
    displayName: '测试模型 $id',
    capabilities: <AiCapability>{capability},
    tier: tier,
    sizeMB: sizeMB,
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
    notes: '仅测试用',
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

    test('需求点名的模型都在，体积/许可证/档位与约定一致', () {
      const expected = <String, ({int sizeMB, String license, ModelTier tier})>{
        'silero-vad': (
          sizeMB: 2,
          license: 'Apache-2.0',
          tier: ModelTier.light
        ),
        'zipformer-zh-en-streaming': (
          sizeMB: 80,
          license: 'Apache-2.0',
          tier: ModelTier.light
        ),
        'sensevoice-small': (
          sizeMB: 230,
          license: 'Apache-2.0',
          tier: ModelTier.balanced
        ),
        'paraformer-zh-streaming': (
          sizeMB: 220,
          license: 'Apache-2.0',
          tier: ModelTier.balanced
        ),
        'whisper-base': (
          sizeMB: 150,
          license: 'MIT',
          tier: ModelTier.multilingual
        ),
        'whisper-small': (
          sizeMB: 500,
          license: 'MIT',
          tier: ModelTier.multilingual
        ),
        'whisper-large-v3-turbo': (
          sizeMB: 1600,
          license: 'MIT',
          tier: ModelTier.highQuality
        ),
        'qwen3-0.6b': (
          sizeMB: 400,
          license: 'Apache-2.0',
          tier: ModelTier.light
        ),
        'qwen3-1.7b': (
          sizeMB: 1100,
          license: 'Apache-2.0',
          tier: ModelTier.balanced
        ),
        'qwen2.5-3b-instruct': (
          sizeMB: 2000,
          license: 'Apache-2.0',
          tier: ModelTier.highQuality
        ),
        'gemma-3-1b': (
          sizeMB: 550,
          license: 'Gemma Terms',
          tier: ModelTier.light
        ),
        'opus-mt-zh-en': (
          sizeMB: 100,
          license: 'CC-BY-4.0',
          tier: ModelTier.light
        ),
        'madlad-400-3b': (
          sizeMB: 2000,
          license: 'Apache-2.0',
          tier: ModelTier.highQuality
        ),
        'rapidocr-onnx': (
          sizeMB: 20,
          license: 'Apache-2.0',
          tier: ModelTier.light
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
      }
      expect(catalog.length, greaterThanOrEqualTo(14),
          reason: '约定里点名的 14 个模型都要有');
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
      expect(registry.byCapability(AiCapability.ocr).map((m) => m.id),
          <String>['rapidocr-onnx']);
    });

    test('返回的是副本：调用方改了不会污染注册表', () {
      final asr = registry.byCapability(AiCapability.asr);
      asr.clear();
      expect(registry.byCapability(AiCapability.asr), isNotEmpty,
          reason: '清单是共享数据，查询结果必须是新列表');
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
      expect(
        registry
            .recommended(capability: AiCapability.ocr, deviceRamGB: 2.0)
            ?.id,
        'rapidocr-onnx',
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
          reason: '同档位内体积大的优先：230MB > 220MB');
      expect(pick.minRamGB, lessThanOrEqualTo(8));
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
      expect(light?.id, 'gemma-3-1b',
          reason: 'light 档里 550MB 最大，且已过 4GB 门槛');
    });

    test('preferredTier 没有候选时退回默认顺序', () {
      // 4GB 下没有任何 highQuality 翻译模型能过门槛
      final pick = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 4,
        preferredTier: ModelTier.highQuality,
      );
      expect(pick, isNotNull);
      expect(pick!.id, 'gemma-3-1b',
          reason: '退到 light 档里体积最大的那个（550MB）');
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

    test('同档同体积时按 id 兜底，结果稳定可复现', () {
      final first = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 16,
        preferredTier: ModelTier.highQuality,
      );
      final second = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 16,
        preferredTier: ModelTier.highQuality,
      );
      expect(first?.tier, ModelTier.highQuality);
      expect(first?.sizeMB, 2000);
      expect(first?.id, second?.id,
          reason: '两条 2000MB 的高质量翻译模型，顺序必须由 id 决定而不是清单顺序');
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
