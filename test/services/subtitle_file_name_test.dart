import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/subtitle/subtitle_file_name.dart';

void main() {
  group('SubtitleFileName 文件名安全', () {
    test('路径分隔符替换为下划线', () {
      expect(SubtitleFileName.sanitize('a/b\\c.srt'), 'a_b_c.srt');
    });

    test('路径穿越被阻止', () {
      // `../evil.srt` → `..`和`/`都替换为`_`并折叠，最终为安全的 `evil.srt`
      final result = SubtitleFileName.sanitize('../evil.srt');
      expect(result, 'evil.srt');
      expect(result.contains('..'), false);
      expect(result.contains('/'), false);
    });

    test('非法字符替换为下划线', () {
      expect(SubtitleFileName.sanitize('a<b>c|d*.srt'), 'a_b_c_d_.srt');
    });

    test('保留中文和合法字符', () {
      expect(SubtitleFileName.sanitize('星际穿越.2014.srt'), '星际穿越.2014.srt');
    });

    test('超长文件名截断（保留扩展名）', () {
      final long = '${'a' * 200}.srt';
      final result = SubtitleFileName.sanitize(long);
      expect(result.length, lessThanOrEqualTo(120));
      expect(result.endsWith('.srt'), true);
    });

    test('空结果兜底', () {
      expect(SubtitleFileName.sanitize('   '), 'subtitle');
      expect(SubtitleFileName.sanitize('///'), 'subtitle');
      expect(SubtitleFileName.sanitize('___'), 'subtitle');
    });

    test('格式识别', () {
      expect(SubtitleFileName.isSupportedFormat('a.srt'), true);
      expect(SubtitleFileName.isSupportedFormat('a.ass'), true);
      expect(SubtitleFileName.isSupportedFormat('a.ssa'), true);
      expect(SubtitleFileName.isSupportedFormat('a.vtt'), true);
      expect(SubtitleFileName.isSupportedFormat('a.zip'), true);
      expect(SubtitleFileName.isSupportedFormat('a.txt'), false);
      expect(SubtitleFileName.isSupportedFormat('a.mp4'), false);
    });
  });
}
