// 外挂字幕「同名自动加载 + 记住上次选择」的单测
//
// 需求要点（这些规则很容易写着写着走样，全部钉死）：
//  - 同名判断不能误吃「名字更长」的文件（电影.mp4 不该挂 电影2.srt）
//  - 语言优先级：普通同名（无后缀）永远第一 > 中文/中英双语 > 简体/繁体 > 英文 > 其它
//  - 记忆三态：外挂文件 / 内嵌轨（trackId）/ 关掉；旧格式（只存路径）要能兼容
//  - 上次是「关掉字幕」→ 下次别再自动挂；记住的文件被删 / 轨道消失 → 忽略记忆
//  - 没有记忆但片源有内嵌字幕轨 → 不自动挂外挂
//  - 记忆有上限（300 条，按最近使用淘汰），SharedPreferences 不会无限长
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:perchplay/services/app_settings_service.dart';
import 'package:perchplay/services/library_hidden_service.dart';
import 'package:perchplay/services/subtitle_auto_service.dart';
import 'package:perchplay/services/subtitle_matcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ⚠️ AppSettingsService 是单例，_loaded 一旦为 true 就不会再读 SharedPreferences。
  // 所以「从磁盘读回记忆」这条必须放在最前面（测试文件内用例按声明顺序执行）。
  group('AppSettingsService：记忆的持久化', () {
    test('ensureLoaded 读回三种记忆（含旧格式），坏记录被丢掉', () async {
      SharedPreferences.setMockInitialValues({
        'settings.subtitleMemory': [
          // 旧版本写的外挂记录：没有 k 字段，只有 s
          '{"v":"d:/videos/legacy.mp4","s":"d:/videos/legacy.zh.srt","t":7}',
          // 旧版本写的「关掉字幕」：s 为 null（升级后必须仍然是 off）
          '{"v":"d:/videos/legacyoff.mp4","s":null,"t":6}',
          // 新版本的 embedded 记忆
          const SubtitleMemory.embedded(
            videoPath: 'd:/videos/emb.mp4',
            trackId: '2',
            language: 'chi',
            updatedAt: 5,
          ).encode(),
          '这不是 JSON，应该被丢掉',
        ],
      });

      final settings = AppSettingsService.instance;
      await settings.ensureLoaded();

      expect(settings.subtitleMemory.length, 3, reason: '坏记录不该让整份记忆失效');
      expect(settings.subtitleMemory.first.videoPath, 'd:/videos/legacy.mp4',
          reason: '最近使用的排最前');

      final legacy = settings.subtitleMemoryFor('D:/videos/legacy.mp4');
      expect(legacy?.kind, SubtitleMemoryKind.external,
          reason: '旧格式有路径 = 外挂字幕，升级不能把记忆清掉');
      expect(legacy?.subtitlePath, 'd:/videos/legacy.zh.srt');

      expect(settings.subtitleMemoryFor('d:/videos/legacyoff.mp4')?.off, isTrue,
          reason: '旧格式 s=null 仍是「关掉字幕」，不能被当成没记忆');

      final embedded = settings.subtitleMemoryFor('d:/videos/emb.mp4');
      expect(embedded?.kind, SubtitleMemoryKind.embedded);
      expect(embedded?.trackId, '2');
      expect(embedded?.language, 'chi');
    });

    test('手动选择会写记忆：外挂 / 内嵌 / 关掉三种状态互相覆盖', () async {
      final settings = AppSettingsService.instance;
      await settings.clearSubtitleMemory();

      await settings.rememberSubtitle('d:/videos/c.mp4', 'd:/videos/c.zh.srt');
      expect(settings.subtitleMemoryFor('d:/videos/c.mp4')?.kind,
          SubtitleMemoryKind.external);

      // 用户改选内嵌轨：同一个视频只留一条，类型变成 embedded
      await settings.rememberEmbeddedSubtitle('d:/videos/c.mp4', '3',
          language: 'chi');
      var memory = settings.subtitleMemoryFor('d:/videos/c.mp4');
      expect(memory?.kind, SubtitleMemoryKind.embedded);
      expect(memory?.trackId, '3');
      expect(memory?.language, 'chi');
      expect(settings.subtitleMemory.length, 1);

      // 再改成「关掉字幕」
      await settings.rememberSubtitle('d:/videos/c.mp4', null);
      memory = settings.subtitleMemoryFor('d:/videos/c.mp4');
      expect(memory?.off, isTrue);
      expect(settings.subtitleMemory.length, 1);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('settings.subtitleMemory');
      expect(raw, isNotNull);
      expect(raw!.length, 1);
      expect(SubtitleMemory.tryDecode(raw.single)!.off, isTrue,
          reason: '落盘的必须也是「关掉」语义，而不是被当成没有字幕');
    });

    test('记忆条数有上限，超出后淘汰最旧的', () async {
      final settings = AppSettingsService.instance;
      await settings.clearSubtitleMemory();

      const total = SubtitleMemory.maxEntries + 5;
      for (var i = 0; i < total; i++) {
        await settings.rememberSubtitle('d:/v/$i.mp4', 'd:/v/$i.srt');
      }

      expect(settings.subtitleMemory.length, SubtitleMemory.maxEntries);
      expect(settings.subtitleMemoryFor('d:/v/${total - 1}.mp4'), isNotNull,
          reason: '最新一条必须还在');
      expect(settings.subtitleMemoryFor('d:/v/0.mp4'), isNull,
          reason: '最旧的 5 条应被淘汰');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('settings.subtitleMemory')!.length,
          SubtitleMemory.maxEntries);
    });
  });

  group('findCandidates：同名字幕的识别与排序', () {
    const video = 'd:/videos/电影.mp4';

    List<String> names(List<SubtitleCandidate> list) =>
        [for (final c in list) c.fileName];

    test('只认同名 / 视频名.后缀，且只认字幕扩展名', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.srt',
        '电影.mp4',
        '电影2.srt', // 名字更长，不是这部电影的字幕
        '电影花絮.srt', // 同上，没有 `.` 分隔
        '别的电影.srt',
      ]);
      expect(names(candidates), ['电影.srt']);
      expect(candidates.single.path, endsWith('电影.srt'));
    });

    test('扩展名大小写不敏感，.ass/.ssa/.vtt/.sub 都算', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.vtt',
        '电影.SRT',
        '电影.ass',
        '电影.ssa',
        '电影.txt', // 不是字幕
      ]);
      // 同档同后缀时按扩展名顺序（srt > ass > ssa > vtt），保证结果稳定
      expect(names(candidates), ['电影.SRT', '电影.ass', '电影.ssa', '电影.vtt']);
    });

    test('优先级：中文/中英 > 简体/繁体 > 英文 > 其它', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.ja.srt',
        '电影.en.srt',
        '电影.繁体.srt',
        '电影.中文.srt',
      ]);
      expect(names(candidates), [
        '电影.中文.srt',
        '电影.繁体.srt',
        '电影.en.srt',
        '电影.ja.srt',
      ]);
    });

    test('chs / chi / 中英双语 都属于中文档（语言档里最高）', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.en.srt',
        '电影.chs.srt',
        '电影.中英.srt',
        '电影.chi.srt',
      ]);
      expect(
        candidates.take(3).map((c) => c.fileName).toSet(),
        {'电影.chs.srt', '电影.中英.srt', '电影.chi.srt'},
      );
      expect(candidates.last.fileName, '电影.en.srt');
    });

    test('普通同名优先于不可识别的后缀', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.导演剪辑.srt',
        '电影.srt',
      ]);
      // 不可识别的后缀归最后一档，普通同名在最前面（0 档）
      expect(names(candidates), ['电影.srt', '电影.导演剪辑.srt']);
    });

    test('普通同名永远第一，语言档位只决定其后的顺序', () {
      // 普通同名（无语言后缀）是用户自己放在视频旁边的那份，压过任何语言档：
      // 电影.srt 与 电影.en.srt 并存时必须是 电影.srt
      final candidates = Subtitles.findCandidates(video, [
        '电影.srt',
        '电影.en.srt',
      ]);
      expect(names(candidates), ['电影.srt', '电影.en.srt']);
    });

    test('普通同名也压过中文档', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.zh.srt',
        '电影.srt',
      ]);
      expect(names(candidates), ['电影.srt', '电影.zh.srt']);
    });

    test('只有 电影.en.srt 时选中它', () {
      final candidates = Subtitles.findCandidates(video, ['电影.en.srt']);
      expect(candidates.single.fileName, '电影.en.srt');
      // 自动挑选（无记忆）就该挂它，不能因为"没有中文字幕"就不挂
      final pick = Subtitles.pick(candidates, null);
      expect(pick.kind, SubtitlePickKind.auto);
      expect(pick.path, candidates.single.path);
    });

    test('多段后缀（电影.zh.chs.srt）也能认成中文', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.en.srt',
        '电影.zh.chs.srt',
      ]);
      expect(candidates.first.fileName, '电影.zh.chs.srt');
    });

    test('语言名映射成中文显示名', () {
      final candidates = Subtitles.findCandidates(video, [
        '电影.中英.srt',
        '电影.繁体.srt',
        '电影.en.srt',
      ]);
      expect(
        [for (final c in candidates) c.language],
        ['中英双语', '繁体中文', 'English'],
      );
      expect(candidates.first.title, '中英双语 (SRT)');
    });

    test('Windows 上文件名大小写不同也算同名', () {
      final candidates = Subtitles.findCandidates('d:/videos/Movie.mp4', [
        'MOVIE.ZH.srt',
      ]);
      expect(candidates.single.fileName, 'MOVIE.ZH.srt');
      expect(candidates.single.language, '中文');
    });
  });

  group('pick：记忆与自动挑选的取舍', () {
    const video = 'd:/videos/电影.mp4';
    final candidates = Subtitles.findCandidates(video, [
      '电影.zh.srt',
      '电影.en.srt',
    ]);

    SubtitleCandidate byName(String name) =>
        candidates.firstWhere((c) => c.fileName == name);

    test('没有记忆时挂优先级最高的候选', () {
      final pick = Subtitles.pick(candidates, null);
      expect(pick.kind, SubtitlePickKind.auto);
      expect(pick.path, candidates.first.path);
      expect(pick.candidate?.fileName, '电影.zh.srt');
      expect(pick.shouldAttach, isTrue);
    });

    test('记得「关掉字幕」时什么都不挂', () {
      final pick = Subtitles.pick(
        candidates,
        const SubtitleMemory.off(videoPath: video, updatedAt: 1),
      );
      expect(pick.kind, SubtitlePickKind.rememberedOff);
      expect(pick.shouldAttach, isFalse);
      expect(pick.path, isNull);
    });

    test('记得的字幕文件还在：恢复它，哪怕不是优先级最高的', () {
      final en = byName('电影.en.srt');
      final pick = Subtitles.pick(
        candidates,
        SubtitleMemory.external(
          videoPath: video,
          subtitlePath: en.path,
          updatedAt: 1,
        ),
        exists: (_) => true,
      );
      expect(pick.kind, SubtitlePickKind.rememberedFile);
      expect(pick.path, en.path);
      expect(pick.candidate?.fileName, '电影.en.srt');
    });

    test('记得的字幕文件已被删：忽略记忆，回落到自动挑选', () {
      final gone = byName('电影.en.srt').path;
      final pick = Subtitles.pick(
        candidates,
        SubtitleMemory.external(
          videoPath: video,
          subtitlePath: gone,
          updatedAt: 1,
        ),
        exists: (_) => false,
      );
      expect(pick.kind, SubtitlePickKind.auto);
      expect(pick.path, candidates.first.path);
    });

    test('记得的字幕文件已被删且没有候选：不挂，也不抛异常', () {
      final pick = Subtitles.pick(
        const <SubtitleCandidate>[],
        const SubtitleMemory.external(
          videoPath: video,
          subtitlePath: 'd:/videos/电影.en.srt',
          updatedAt: 1,
        ),
        exists: (_) => false,
      );
      expect(pick.kind, SubtitlePickKind.none);
      expect(pick.shouldAttach, isFalse);
    });

    test('记得的字幕不在同目录候选里（用户从别处选的）也能恢复', () {
      const outside = 'd:/subs/外部字幕.ass';
      final pick = Subtitles.pick(
        candidates,
        const SubtitleMemory.external(
          videoPath: video,
          subtitlePath: outside,
          updatedAt: 1,
        ),
        exists: (_) => true,
      );
      expect(pick.kind, SubtitlePickKind.rememberedFile);
      expect(pick.path, outside);
      expect(pick.candidate?.title, contains('ASS'),
          reason: '面板要能显示成「外挂字幕 (ASS)」这类可读文字');
    });

    test('既没有候选也没有记忆：不挂', () {
      final pick = Subtitles.pick(const <SubtitleCandidate>[], null);
      expect(pick.kind, SubtitlePickKind.none);
      expect(pick.shouldAttach, isFalse);
    });

    // ─── 内嵌轨相关 ───

    test('没有记忆但有内嵌字幕轨：不自动挂外挂', () {
      final pick = Subtitles.pick(
        candidates,
        null,
        embeddedTrackIds: const ['1'],
      );
      expect(pick.kind, SubtitlePickKind.embeddedPreferred);
      expect(pick.shouldAttach, isFalse);
      expect(pick.trackId, isNull);
    });

    test('记忆是内嵌轨且 trackId 还在：选回那一轨', () {
      final pick = Subtitles.pick(
        candidates,
        const SubtitleMemory.embedded(
          videoPath: video,
          trackId: '2',
          updatedAt: 1,
        ),
        embeddedTrackIds: const ['1', '2'],
      );
      expect(pick.kind, SubtitlePickKind.rememberedEmbedded);
      expect(pick.trackId, '2');
      expect(pick.shouldAttach, isFalse, reason: '内嵌轨不是外挂文件，不该又挂一份外挂');
    });

    test('记忆是内嵌轨但 trackId 已不存在：忽略记忆（有内嵌轨就不挂外挂）', () {
      final pick = Subtitles.pick(
        candidates,
        const SubtitleMemory.embedded(
          videoPath: video,
          trackId: '9',
          updatedAt: 1,
        ),
        embeddedTrackIds: const ['1'],
      );
      expect(pick.kind, SubtitlePickKind.embeddedPreferred);
      expect(pick.trackId, isNull);
    });

    test('记忆是内嵌轨且 trackId 已不存在、也没有内嵌轨：回落到自动挂外挂', () {
      final pick = Subtitles.pick(
        candidates,
        const SubtitleMemory.embedded(
          videoPath: video,
          trackId: '9',
          updatedAt: 1,
        ),
      );
      expect(pick.kind, SubtitlePickKind.auto);
      expect(pick.path, candidates.first.path);
    });

    test('记忆优先于「有内嵌轨」：关掉字幕仍然不挂', () {
      final pick = Subtitles.pick(
        candidates,
        const SubtitleMemory.off(videoPath: video, updatedAt: 1),
        embeddedTrackIds: const ['1'],
      );
      expect(pick.kind, SubtitlePickKind.rememberedOff);
    });

    test('记忆优先于「有内嵌轨」：记住的外挂仍然挂', () {
      final en = byName('电影.en.srt');
      final pick = Subtitles.pick(
        candidates,
        SubtitleMemory.external(
          videoPath: video,
          subtitlePath: en.path,
          updatedAt: 1,
        ),
        exists: (_) => true,
        embeddedTrackIds: const ['1'],
      );
      expect(pick.kind, SubtitlePickKind.rememberedFile);
      expect(pick.path, en.path);
    });
  });

  group('SubtitleMemory：排序 / 去重 / 淘汰 / 编解码', () {
    SubtitleMemory entry(int i) => SubtitleMemory.external(
          videoPath: 'd:/v/$i.mp4',
          subtitlePath: 'd:/v/$i.srt',
          updatedAt: i,
        );

    test('新记忆插到最前，同一个视频只留最新一条', () {
      var list = <SubtitleMemory>[];
      list = SubtitleMemory.upsert(list, entry(1));
      list = SubtitleMemory.upsert(list, entry(2));
      list = SubtitleMemory.upsert(
        list,
        const SubtitleMemory.off(videoPath: 'd:/v/1.mp4', updatedAt: 9),
      );

      expect([for (final e in list) e.videoPath], ['d:/v/1.mp4', 'd:/v/2.mp4']);
      expect(list.first.off, isTrue, reason: '后来改成关闭，要覆盖掉旧的路径');
    });

    test('超过上限时从尾部丢最旧的', () {
      var list = <SubtitleMemory>[];
      for (var i = 1; i <= 5; i++) {
        list = SubtitleMemory.upsert(list, entry(i), maxEntries: 3);
      }
      expect([for (final e in list) e.videoPath],
          ['d:/v/5.mp4', 'd:/v/4.mp4', 'd:/v/3.mp4']);
    });

    test('上限默认 300 条', () {
      expect(SubtitleMemory.maxEntries, 300);
    });

    test('三种状态编码 / 解码往返（含中文路径、语言标签）', () {
      const off = SubtitleMemory.off(videoPath: 'd:/v/a.mp4', updatedAt: 1);
      const external = SubtitleMemory.external(
        videoPath: 'd:/v/电影.mp4',
        subtitlePath: 'd:/v/电影.zh.srt',
        updatedAt: 2,
      );
      const embedded = SubtitleMemory.embedded(
        videoPath: 'd:/v/电影.mp4',
        trackId: '2',
        language: 'chi',
        updatedAt: 3,
      );

      for (final memory in [off, external, embedded]) {
        final back = SubtitleMemory.tryDecode(memory.encode());
        expect(back, isNotNull, reason: '${memory.kind} 应该能解析回去');
        expect(back!.videoPath, memory.videoPath);
        expect(back.kind, memory.kind);
        expect(back.subtitlePath, memory.subtitlePath);
        expect(back.trackId, memory.trackId);
        expect(back.language, memory.language);
        expect(back.updatedAt, memory.updatedAt);
      }
    });

    test('旧格式（没有 k 字段）仍按「有路径=外挂、null=关掉」解析', () {
      final oldExternal = SubtitleMemory.tryDecode(
          '{"v":"d:/v/a.mp4","s":"d:/v/a.zh.srt","t":3}');
      expect(oldExternal?.kind, SubtitleMemoryKind.external);
      expect(oldExternal?.subtitlePath, 'd:/v/a.zh.srt');

      final oldOff =
          SubtitleMemory.tryDecode('{"v":"d:/v/a.mp4","s":null,"t":3}');
      expect(oldOff?.kind, SubtitleMemoryKind.off);
      expect(oldOff?.off, isTrue);
    });

    test('坏数据返回 null，不抛异常', () {
      expect(SubtitleMemory.tryDecode('不是 JSON'), isNull);
      expect(SubtitleMemory.tryDecode('{"s":"d:/v/a.srt"}'), isNull,
          reason: '没有视频路径的记录没法用');
      expect(SubtitleMemory.tryDecode('[]'), isNull);
      expect(
        SubtitleMemory.tryDecode('{"v":"d:/v/a.mp4","k":"embedded","t":1}'),
        isNull,
        reason: 'embedded 却没有 trackId，没法恢复，丢掉比猜好',
      );
      expect(
        SubtitleMemory.tryDecode('{"v":"d:/v/a.mp4","k":"external","t":1}'),
        isNull,
        reason: 'external 却没有路径，同上',
      );
      expect(
        SubtitleMemory.tryDecode('{"v":"d:/v/a.mp4","k":"something","t":1}'),
        isNull,
        reason: '不认识的类型（未来版本写的）丢掉',
      );
    });
  });

  // 上面都是纯逻辑；这一组用真实临时目录跑一遍 IO 串联
  // （列目录 → 排序 → 查记忆 → 判文件还在不在），
  // 顺便验证「删掉字幕文件后记忆失效」在真实文件系统上也成立。
  group('SubtitleAutoService：真实目录 + 记忆', () {
    late Directory dir;
    late String video;
    late String zh;
    late String en;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('subtitle_auto_test');
      video = p.join(dir.path, '电影.mp4');
      zh = p.join(dir.path, '电影.zh.srt');
      en = p.join(dir.path, '电影.en.srt');
      File(video).writeAsStringSync('');
      File(zh).writeAsStringSync('');
      File(en).writeAsStringSync('');
    });

    tearDown(() async {
      await AppSettingsService.instance.clearSubtitleMemory();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录清理失败不影响结论
      }
    });

    test('同目录同名字幕按优先级自动挂（中文优先）', () async {
      final pick = await SubtitleAutoService.instance.resolve(video);
      expect(pick.kind, SubtitlePickKind.auto);
      expect(pick.path, zh);
    });

    test('用户选过英文：下次打开恢复英文', () async {
      await SubtitleAutoService.instance.remember(video, en);
      final pick = await SubtitleAutoService.instance.resolve(video);
      expect(pick.kind, SubtitlePickKind.rememberedFile);
      expect(pick.path, en);
    });

    test('用户关掉字幕：下次不再自动挂', () async {
      await SubtitleAutoService.instance.remember(video, null);
      final pick = await SubtitleAutoService.instance.resolve(video);
      expect(pick.kind, SubtitlePickKind.rememberedOff);
      expect(pick.shouldAttach, isFalse);
    });

    test('记住的字幕文件被删：忽略记忆，回落到自动加载', () async {
      await SubtitleAutoService.instance.remember(video, zh);
      File(zh).deleteSync();
      final pick = await SubtitleAutoService.instance.resolve(video);
      expect(pick.kind, SubtitlePickKind.auto);
      expect(pick.path, en, reason: '中文没了，剩下英文应被自动挑中');
    });

    test('命中记忆时刷新「最近使用」，常看的片子不会被挤掉', () async {
      final settings = AppSettingsService.instance;
      await settings.rememberSubtitle(video, en);
      // 另一部片子后选的，排在更前面
      await settings.rememberSubtitle('d:/videos/other.mp4', 'd:/videos/o.srt');
      expect(
        settings.subtitleMemory.first.videoPath,
        LibraryHiddenService.normalizePath('d:/videos/other.mp4'),
      );

      await SubtitleAutoService.instance.resolve(video);

      expect(
        settings.subtitleMemory.first.videoPath,
        LibraryHiddenService.normalizePath(video),
        reason: '打开视频恢复记忆时应把它标成最近使用，淘汰顺序才不会把它先踢掉',
      );
    });

    // ─── 内嵌轨：有片源自带字幕时不自动挂外挂 ───

    test('没有记忆但有内嵌字幕轨：不自动挂同目录外挂', () async {
      final pick = await SubtitleAutoService.instance
          .resolve(video, embeddedTrackIds: ['1']);
      expect(pick.kind, SubtitlePickKind.embeddedPreferred);
      expect(pick.shouldAttach, isFalse);
    });

    test('记忆是内嵌轨：resolve 返回要恢复的 trackId', () async {
      await AppSettingsService.instance
          .rememberEmbeddedSubtitle(video, '2', language: 'chi');
      final pick = await SubtitleAutoService.instance
          .resolve(video, embeddedTrackIds: ['1', '2']);
      expect(pick.kind, SubtitlePickKind.rememberedEmbedded);
      expect(pick.trackId, '2');
      expect(pick.shouldAttach, isFalse);
    });

    test('记忆的内嵌轨已不存在：忽略记忆，有内嵌轨就不挂外挂', () async {
      await AppSettingsService.instance.rememberEmbeddedSubtitle(video, '9');
      final pick = await SubtitleAutoService.instance
          .resolve(video, embeddedTrackIds: ['1']);
      expect(pick.kind, SubtitlePickKind.embeddedPreferred);
      expect(pick.trackId, isNull);
    });
  });
}
