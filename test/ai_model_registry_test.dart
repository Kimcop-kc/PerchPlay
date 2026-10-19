// 端侧 AI 模型注册表的单测
//
// 这一层是「纯数据 + 纯函数」。覆盖点：
//  - 清单完整性：id 唯一、体积 > 0、每条至少一条镜像、能力/许可证非空
//  - 内存门槛压过所有偏好
//  - 默认 tier 顺序：balanced → light → multilingual → highQuality
//  - preferredTier 优先；无候选时退回默认顺序
//  - 同档位排序：kind 优先 → 体积从大到小 → id 兜底
//  - 镜像顺序：指定来源排第一，不污染清单
//  - translate 各档位分别落到谁（nmt 优先）
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/ai/ai_model.dart';
import 'package:perchplay/services/ai/ai_model_catalog.dart';
import 'package:perchplay/services/ai/ai_model_registry.dart';

/// 造一个测试用模型。
AiModel _testModel({
  required String id,
  required AiCapability capability,
  ModelKind kind = ModelKind.asr,
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
      final ids = <String>{};
      for (final model in catalog) {
        expect(ids.add(model.id), isTrue, reason: '模型 id 重复：${model.id}');
        expect(model.sizeMB, greaterThan(0), reason: '${model.id} 体积必须为正');
        expect(model.capabilities, isNotEmpty,
            reason: '${model.id} 至少要有一种能力');
        expect(model.kind, isNotNull);
        expect(model.license.isNotEmpty, isTrue,
            reason: '${model.id} 许可证不能为空');
        expect(model.mirrors, isNotEmpty, reason: '${model.id} 至少要有一条镜像');
      }
    });

    test('现清单模型数量正确（ASR 11 + 标点 1 + 翻译 2 = 14）', () {
      expect(catalog.length, 14,
          reason: '精简后应只剩 14 个模型，多了说明有漏删的、少了说明误删了');
    });

    test('需求点名的模型都在，体积/许可证/档位/类别与约定一致', () {
      const expected = <String, ({int sizeMB, String license, ModelTier tier, ModelKind kind})>{
        'silero-vad': (sizeMB: 2, license: 'Apache-2.0', tier: ModelTier.light, kind: ModelKind.vad),
        'sensevoice-small': (sizeMB: 234, license: 'Apache-2.0', tier: ModelTier.balanced, kind: ModelKind.asr),
        'paraformer-zh-streaming': (sizeMB: 220, license: 'Apache-2.0', tier: ModelTier.balanced, kind: ModelKind.asr),
        'whisper-large-v3': (sizeMB: 1600, license: 'Apache-2.0', tier: ModelTier.highQuality, kind: ModelKind.asr),
        'punct-ct-transformer': (sizeMB: 95, license: 'Apache-2.0', tier: ModelTier.light, kind: ModelKind.punctuation),
        'opus-mt-zh-en': (sizeMB: 110, license: 'CC-BY-4.0', tier: ModelTier.light, kind: ModelKind.nmt),
        'madlad-400-3b': (sizeMB: 2000, license: 'Apache-2.0', tier: ModelTier.multilingual, kind: ModelKind.nmt),
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
    });
  });

  group('byCapability', () {
    test('每个能力都有模型，且查询只返回带该能力的模型', () {
      for (final capability in AiCapability.values) {
        final hits = registry.byCapability(capability);
        expect(hits, isNotEmpty,
            reason: '${capability.name} 一个模型都没有，对应功能等于没实现');
        expect(hits.every((m) => m.supports(capability)), isTrue,
            reason: '${capability.name} 的查询结果里混进了不支持它的模型');
      }
    });

    test('返回的是副本：调用方改了不会污染注册表', () {
      final asr = registry.byCapability(AiCapability.asr);
      asr.clear();
      expect(registry.byCapability(AiCapability.asr), isNotEmpty,
          reason: '清单是共享数据，查询结果必须是新列表');
    });

    test('ASR 能力包含 SenseVoice 与多个 Paraformer', () {
      final ids = registry.byCapability(AiCapability.asr).map((m) => m.id);
      expect(ids, contains('sensevoice-small'));
      expect(ids, contains('paraformer-zh-streaming'));
    });
  });

  group('recommended', () {
    test('内存门槛：4GB 设备不会被推荐超标的模型', () {
      final pick = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 4,
      );
      expect(pick, isNotNull, reason: '4GB 下仍有轻量翻译模型可用');
      expect(pick!.minRamGB, lessThanOrEqualTo(4),
          reason: '推荐结果必须过内存门槛');
      expect(pick.id, 'opus-mt-zh-en',
          reason: '4GB 下 highQuality 的 madlad 被门坎拦掉，light 里优先 NMT');
    });

    test('8GB 设备在语音识别上优先拿到 balanced 档', () {
      final pick = registry.recommended(
        capability: AiCapability.asr,
        deviceRamGB: 8,
      );
      expect(pick, isNotNull);
      expect(pick!.tier, ModelTier.balanced,
          reason: '有 balanced 候选时应优先于 light');
      expect(pick.minRamGB, lessThanOrEqualTo(8));
    });

    test('translate 各 preferredTier 落到指定模型', () {
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
        reason: '轻量翻译选专用 NMT',
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

    test('preferredTier 没有候选时退回默认顺序', () {
      // translate 没有 balanced 档模型，指定 balanced 应回退到 light（opus-mt）
      final pick = registry.recommended(
        capability: AiCapability.translate,
        deviceRamGB: 16,
        preferredTier: ModelTier.balanced,
      );
      expect(pick, isNotNull,
          reason: '偏好档位没有候选时应回退，而不是返回 null');
      expect(pick!.minRamGB, lessThanOrEqualTo(16));
    });

    test('capability 无候选时返回 null', () {
      final empty = AiModelRegistry(
        models: <AiModel>[
          _testModel(id: 'only-vad', capability: AiCapability.vad),
        ],
      );
      expect(
        empty.recommended(capability: AiCapability.translate, deviceRamGB: 16),
        isNull,
        reason: '没有翻译模型时不该编一个出来',
      );
    });

    test('同档位内 nmt 胜过体积更大的 llm（translate）', () {
      final injected = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'nmt-small',
            capability: AiCapability.translate,
            kind: ModelKind.nmt,
            sizeMB: 100,
            tier: ModelTier.light,
          ),
          _testModel(
            id: 'llm-big',
            capability: AiCapability.translate,
            kind: ModelKind.llm,
            sizeMB: 1000,
            tier: ModelTier.light,
          ),
        ],
      );
      expect(
        injected
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'nmt-small',
        reason: '同档位里 nmt 优先于 llm，哪怕体积更小',
      );
    });

    test('id 兜底只在 tier/kind/体积全部平手时才生效', () {
      final a = _testModel(
          id: 'aaa', capability: AiCapability.asr, sizeMB: 100);
      final b = _testModel(
          id: 'bbb', capability: AiCapability.asr, sizeMB: 100);
      final injected = AiModelRegistry(models: <AiModel>[b, a]);
      expect(
        injected.recommended(capability: AiCapability.asr, deviceRamGB: 16)?.id,
        'aaa',
        reason: '全部平手时按 id 字典序兜底，保证确定性',
      );
    });
  });

  group('显式默认模型', () {
    test('没指定档位时按显式默认选', () {
      expect(
        registry.recommended(capability: AiCapability.asr, deviceRamGB: 16)?.id,
        'sensevoice-small',
        reason: 'ASR 显式默认是 sensevoice-small',
      );
      expect(
        registry.recommended(capability: AiCapability.vad, deviceRamGB: 16)?.id,
        'silero-vad',
        reason: 'VAD 显式默认是 silero-vad',
      );
      expect(
        registry
            .recommended(capability: AiCapability.asrStreaming, deviceRamGB: 16)
            ?.id,
        'paraformer-zh-streaming',
        reason: '流式 ASR 显式默认是 paraformer-zh-streaming',
      );
      expect(
        registry
            .recommended(capability: AiCapability.translate, deviceRamGB: 16)
            ?.id,
        'opus-mt-zh-en',
        reason: '翻译显式默认是 opus-mt-zh-en（本地 offshore）',
      );
    });

    test('指定 preferredTier 时显式默认不生效，按档位走', () {
      // 注入构造：证明默认表确实被跳过
      final injected = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'light-asr',
            capability: AiCapability.asr,
            kind: ModelKind.asr,
            tier: ModelTier.light,
            sizeMB: 10,
          ),
          _testModel(
            id: 'balanced-asr',
            capability: AiCapability.asr,
            kind: ModelKind.asr,
            tier: ModelTier.balanced,
            sizeMB: 20,
          ),
        ],
        defaultModelIds: const <AiCapability, String>{
          AiCapability.asr: 'light-asr',
        },
      );
      expect(
        injected
            .recommended(
              capability: AiCapability.asr,
              deviceRamGB: 16,
              preferredTier: ModelTier.balanced,
            )
            ?.id,
        'balanced-asr',
        reason: '用户明确挑了档位，默认表必须让位',
      );
    });

    test('显式默认被内存门槛拦掉时回退到原有排序', () {
      final injected = AiModelRegistry(
        models: <AiModel>[
          _testModel(
            id: 'big-default',
            capability: AiCapability.asr,
            minRamGB: 8,
            sizeMB: 10,
          ),
          _testModel(
            id: 'small-alt',
            capability: AiCapability.asr,
            minRamGB: 1,
            sizeMB: 5,
          ),
        ],
        defaultModelIds: const <AiCapability, String>{
          AiCapability.asr: 'big-default',
        },
      );
      expect(
        injected
            .recommended(capability: AiCapability.asr, deviceRamGB: 4)
            ?.id,
        'small-alt',
        reason: '默认模型装不下就必须让位',
      );
    });

    test('显式默认配错时静默回退，不抛异常', () {
      final missing = AiModelRegistry(
        models: <AiModel>[
          _testModel(id: 'real-asr', capability: AiCapability.asr),
        ],
        defaultModelIds: const <AiCapability, String>{
          AiCapability.asr: 'does-not-exist',
        },
      );
      expect(
        missing.recommended(capability: AiCapability.asr, deviceRamGB: 16)?.id,
        'real-asr',
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
          reason: '不能原地改清单');
    });

    test('模型没有该来源时保持原顺序', () {
      final model = registry.byId('madlad-400-3b')!;
      final before = model.mirrors.map((m) => m.url).toList();
      final mirrors = registry.mirrorsFor(
          model, preferred: DownloadSource.githubRelease);
      expect(mirrors.map((m) => m.url).toList(), before,
          reason: '偏好来源不存在时不能重排、更不能清空');
    });
  });

  group('评分与表格渲染', () {
    test('全清单评分都在 1~5', () {
      for (final model in catalog) {
        expect(model.speedRating, inInclusiveRange(1, 5),
            reason: '${model.id} 的速度评分越界');
        expect(model.qualityRating, inInclusiveRange(1, 5),
            reason: '${model.id} 的质量评分越界');
      }
    });

    test('stars 把 1~5 之外的分数夹紧到边界', () {
      expect(AiModelSelector.stars(0), '★☆☆☆☆');
      expect(AiModelSelector.stars(1), '★☆☆☆☆');
      expect(AiModelSelector.stars(3), '★★★☆☆');
      expect(AiModelSelector.stars(5), '★★★★★');
      expect(AiModelSelector.stars(99), '★★★★★');
    });

    test('表格行六列，顺序为 模型/体积/语言/速度/质量/定位', () {
      final model = registry.byId('sensevoice-small')!;
      final cells = AiModelSelector.tableRow(model).split(' | ');
      expect(cells.length, 6,
          reason: '固定六列才能对齐：${AiModelSelector.tableRow(model)}');
      expect(cells[0], contains('SenseVoice'));
      expect(cells[3], AiModelSelector.stars(model.speedRating));
      expect(cells[4], AiModelSelector.stars(model.qualityRating));

      expect(
        AiModelSelector.tableHeader.split(' | '),
        <String>['模型', '体积', '语言', '速度', '质量', '定位'],
      );

      // 语言无关的模型（VAD）
      final vadRow = AiModelSelector.tableRow(registry.byId('silero-vad')!);
      expect(vadRow.split(' | ')[2], '语言无关');

      expect(AiModelSelector.table(catalog).length, catalog.length + 1);
    });

    test('notes 里出现竖线时表格仍是六列', () {
      final weird = _testModel(
        id: 'pipe-model',
        capability: AiCapability.asr,
        notes: '含竖线 | 的说明 | 再一根',
      );
      final row = AiModelSelector.tableRow(weird);
      final cells = row.split(' | ');
      expect(cells.length, 6, reason: '竖线必须被替换掉');
      expect(cells[5], '含竖线 / 的说明 / 再一根');
    });
  });

  group('展示辅助', () {
    test('describe 拼出名字/体积/语言/许可证', () {
      final model = registry.byId('sensevoice-small')!;
      final text = AiModelSelector.describe(model);
      expect(text, contains('SenseVoice'));
      expect(text, contains('234 MB'));
      expect(text, contains('中文'));
      expect(text, contains('Apache-2.0'));

      expect(AiModelSelector.tierLabel(model.tier), '均衡');
      expect(AiModelSelector.capabilityLabel(AiCapability.asrStreaming), '实时识别');
      expect(AiModelSelector.sourceLabel(DownloadSource.modelscope), '魔搭');

      final vad = registry.byId('silero-vad')!;
      expect(vad.languages, isEmpty);
      expect(AiModelSelector.describe(vad), contains('语言无关'));
    });
  });
}