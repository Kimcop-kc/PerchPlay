// 外挂字幕「同名自动加载 + 记住上次选择」的单测
//
// 需求要点（这些规则很容易写着写着走样，全部钉死）：
//  - 同名判断不能误吃「名字更长」的文件（电影.mp4 不该挂 电影2.srt）
//  - 语言优先级：普通同名（无后缀）永远第一 > 中文/中英双语 > 简体/繁体 > 英文 > 其它
//  - 上次是「关掉字幕」→ 下次别再自动挂
//  - 上次选的文件被删了 → 忽略记忆、走自动加载
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
    test('ensureLoaded 读回记忆（含「关掉字幕」），坏记录被丢掉', () async {
      SharedPreferences.setMockInitialValues({
        'settings.subtitleMemory': [
          const SubtitleMemory(videoPath: 'd:/videos/a.mp4', updatedAt: 5)
              .encode(),
          const SubtitleMemory(
            videoPath: 'd:/videos/b.mp4',
            subtitlePath: 'd:/videos/b.zh.srt',
            updatedAt: 4,
          ).encode(),
          '这不是 JSON，应该被丢掉',
        ],
      });

      final settings = AppSettingsService.instance;
      await settings.ensureLoaded();

      expect(settings.subtitleMemory.length, 2, reason: '坏记录不该让整份记忆失效');
      expect(settings.subtitleMemory.first.videoPath, 'd:/videos/a.mp4',
          reason: '最近使用的排最前');
      expect(settings.subtitleMemoryFor('d:/videos/a.mp4')?.off, isTrue);
      expect(
        settings.subtitleMemoryFor('D:/videos/b.mp4')?.subtitlePath,
        'd:/videos/b.zh.srt',
        reason: 'Windows 路径大小写不敏感，查记忆时也要能对上',
      );
    });

    test('手动选择会写记忆：覆盖同一条、关掉字幕记为 off', () async {
      final settings = AppSettingsService.instance;
      await settings.clearSubtitleMemory();

      await settings.rememberSubtitle('d:/videos/c.mp4', 'd:/videos/c.zh.srt');
      expect(settings.subtitleMemoryFor('d:/videos/c.mp4')?.subtitlePath,
          'd:/videos/c.zh.srt');

      // 用户改成「关掉字幕」：同一个视频只留一条，且状态是 off
      await settings.rememberSubtitle('d:/videos/c.mp4', null);
      expect(settings.subtitleMemoryFor('d:/videos/c.mp4')?.off, isTrue);
      expect(settings.subtitleMemory.length, 1);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('settings.subtitleMemory');
      expect(raw, isNotNull);
      expect(raw!.length, 1);
      expect(SubtitleMemory.tryDecode(raw.single)!.off, isTrue,
          reason: '落盘的必须也是「关掉」语义，而不是被当成没有字幕路径');
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
        const SubtitleMemory(videoPath: video, updatedAt: 1),
      );
      expect(pick.kind, SubtitlePickKind.rememberedOff);
      expect(pick.shouldAttach, isFalse);
      expect(pick.path, isNull);
    });

    test('记得的字幕文件还在：恢复它，哪怕不是优先级最高的', () {
      final en = byName('电影.en.srt');
      final pick = Subtitles.pick(
        candidates,
        SubtitleMemory(videoPath: video, subtitlePath: en.path, updatedAt: 1),
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
        SubtitleMemory(videoPath: video, subtitlePath: gone, updatedAt: 1),
        exists: (_) => false,
      );
      expect(pick.kind, SubtitlePickKind.auto);
      expect(pick.path, candidates.first.path);
    });

    test('记得的字幕文件已被删且没有候选：不挂，也不抛异常', () {
      final pick = Subtitles.pick(
        const <SubtitleCandidate>[],
        const SubtitleMemory(
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
        const SubtitleMemory(
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
  });

  group('SubtitleMemory：排序 / 去重 / 淘汰 / 编解码', () {
    SubtitleMemory entry(int i) => SubtitleMemory(
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
        const SubtitleMemory(videoPath: 'd:/v/1.mp4', updatedAt: 9),
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

    test('编码 / 解码往返（含 null = 关掉字幕、中文路径）', () {
      const off = SubtitleMemory(videoPath: 'd:/v/a.mp4', updatedAt: 1);
      const on = SubtitleMemory(
        videoPath: 'd:/v/电影.mp4',
        subtitlePath: 'd:/v/电影.zh.srt',
        updatedAt: 2,
      );

      for (final memory in [off, on]) {
        final back = SubtitleMemory.tryDecode(memory.encode());
        expect(back, isNotNull);
        expect(back!.videoPath, memory.videoPath);
        expect(back.subtitlePath, memory.subtitlePath);
        expect(back.updatedAt, memory.updatedAt);
        expect(back.off, memory.off);
      }
    });

    test('坏数据返回 null，不抛异常', () {
      expect(SubtitleMemory.tryDecode('不是 JSON'), isNull);
      expect(SubtitleMemory.tryDecode('{"s":"d:/v/a.srt"}'), isNull,
          reason: '没有视频路径的记录没法用');
      expect(SubtitleMemory.tryDecode('[]'), isNull);
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
  });
}
