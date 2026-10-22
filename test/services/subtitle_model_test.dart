import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/online_subtitle.dart';
import 'package:perchplay/services/subtitle/language_code.dart';
import 'package:perchplay/services/subtitle/subtitle_source.dart';

void main() {
  group('OnlineSubtitle 模型', () {
    test('完整字段序列化 + 反序列化', () {
      const s = OnlineSubtitle(
        id: '12345',
        name: 'Movie.2023.1080p.WEB-DL',
        source: 'opensubtitles',
        languageCode: 'zh',
        languageName: '中文',
        format: 'srt',
        downloadUrl: 'https://example.com/sub.srt',
        fileSizeBytes: 12345,
        movieName: 'Movie',
        year: 2023,
        season: null,
        episode: null,
        releaseGroup: 'WEB-DL',
        isHearingImpaired: false,
        isForced: false,
        matchScore: 0.95,
        matchReason: '文件名精确匹配',
      );

      final json = s.toJson();
      final restored = OnlineSubtitle.fromJson(json);
      expect(restored.id, '12345');
      expect(restored.source, 'opensubtitles');
      expect(restored.languageCode, 'zh');
      expect(restored.year, 2023);
      expect(restored.matchScore, 0.95);
      expect(restored.season, isNull);
    });

    test('可选字段缺失用 null', () {
      const s = OnlineSubtitle(
        id: '1',
        name: 'x',
        source: 'subdl',
        languageCode: 'en',
        languageName: 'English',
        format: 'srt',
        downloadUrl: 'url',
      );

      expect(s.year, isNull);
      expect(s.season, isNull);
      expect(s.episode, isNull);
      expect(s.releaseGroup, isNull);
      expect(s.matchScore, isNull);
      expect(s.isDownloaded, false);
      expect(s.isHearingImpaired, false);
      expect(s.isForced, false);
    });

    test('去重依据 id + source（不同服务同 id 不冲突）', () {
      const a = OnlineSubtitle(
        id: '1',
        name: 'x',
        source: 'opensubtitles',
        languageCode: 'en',
        languageName: 'English',
        format: 'srt',
        downloadUrl: 'a',
      );
      const b = OnlineSubtitle(
        id: '1',
        name: 'x',
        source: 'subdl',
        languageCode: 'en',
        languageName: 'English',
        format: 'srt',
        downloadUrl: 'b',
      );
      expect(a == b, false);
      expect(a.hashCode == b.hashCode, false);
    });

    test('copyWith 更新下载状态', () {
      const s = OnlineSubtitle(
        id: '1',
        name: 'x',
        source: 'subdl',
        languageCode: 'en',
        languageName: 'English',
        format: 'srt',
        downloadUrl: 'url',
      );
      final updated = s.copyWith(isDownloaded: true);
      expect(updated.isDownloaded, true);
      expect(s.isDownloaded, false); // 原对象不变
    });
  });

  group('LanguageCode 归一化', () {
    test('两字母原样返回', () {
      expect(LanguageCode.normalize('en'), 'en');
      expect(LanguageCode.normalize('zh'), 'zh');
    });

    test('三字母映射', () {
      expect(LanguageCode.normalize('eng'), 'en');
      expect(LanguageCode.normalize('chi'), 'zh');
      expect(LanguageCode.normalize('jpn'), 'ja');
    });

    test('全名映射', () {
      expect(LanguageCode.normalize('English'), 'en');
      expect(LanguageCode.normalize('Chinese'), 'zh');
      expect(LanguageCode.normalize('Japanese'), 'ja');
    });

    test('带地区后缀', () {
      expect(LanguageCode.normalize('zh-CN'), 'zh');
      expect(LanguageCode.normalize('pt-BR'), 'pt');
      expect(LanguageCode.normalize('zh-Hans'), 'zh');
    });

    test('大小写不敏感', () {
      expect(LanguageCode.normalize('EN'), 'en');
      expect(LanguageCode.normalize('Zh'), 'zh');
    });

    test('未知代码返回原值小写', () {
      expect(LanguageCode.normalize('xx'), 'xx');
      expect(LanguageCode.normalize(''), '');
      expect(LanguageCode.normalize(null), '');
    });

    test('显示名', () {
      expect(LanguageCode.displayName('zh'), '中文');
      expect(LanguageCode.displayName('en'), '英文');
      expect(LanguageCode.displayName('xx'), 'xx');
    });
  });

  group('SubtitleServiceException 错误分类', () {
    test('类型与消息', () {
      const e = SubtitleServiceException(
        SubtitleErrorType.quotaExceeded,
        'quota exceeded',
        statusCode: 429,
      );
      expect(e.type, SubtitleErrorType.quotaExceeded);
      expect(e.statusCode, 429);
      expect(e.toString(), contains('quota exceeded'));
    });
  });

  group('SubtitleQuery', () {
    test('空查询构造', () {
      const q = SubtitleQuery();
      expect(q.fileName, isNull);
      expect(q.title, isNull);
      expect(q.year, isNull);
    });

    test('完整查询构造', () {
      const q = SubtitleQuery(
        fileName: 'Movie.2023.mkv',
        title: 'Movie',
        year: 2023,
        imdbId: 'tt1234567',
        season: 1,
        episode: 2,
        languageCode: 'zh',
        format: 'srt',
      );
      expect(q.fileName, 'Movie.2023.mkv');
      expect(q.imdbId, 'tt1234567');
      expect(q.season, 1);
      expect(q.episode, 2);
    });
  });
}
