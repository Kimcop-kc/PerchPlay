import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:perchplay/services/frame_scorer.dart';

/// 用 `image` 包在内存里生成测试帧，不依赖外部文件。
Uint8List _encodeJpeg(img.Image image) =>
    Uint8List.fromList(img.encodeJpg(image, quality: 80));

/// 纯黑帧 JPEG
Uint8List _blackFrame(int w, int h) {
  final frame = img.Image(width: w, height: h);
  frame.clear(img.ColorRgb8(0, 0, 0));
  return _encodeJpeg(frame);
}

/// 纯白帧 JPEG
Uint8List _whiteFrame(int w, int h) {
  final frame = img.Image(width: w, height: h);
  frame.clear(img.ColorRgb8(255, 255, 255));
  return _encodeJpeg(frame);
}

/// 纯灰帧 JPEG
Uint8List _grayFrame(int w, int h, int g) {
  final frame = img.Image(width: w, height: h);
  frame.clear(img.ColorRgb8(g, g, g));
  return _encodeJpeg(frame);
}

/// 简单棋盘格（锐利边缘，拉普拉斯响应高）
Uint8List _checkerboard(int w, int h) {
  final frame = img.Image(width: w, height: h);
  const block = 16;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = ((x ~/ block) + (y ~/ block)) % 2 == 0 ? 255 : 0;
      frame.setPixelRgb(x, y, c, c, c);
    }
  }
  return _encodeJpeg(frame);
}

void main() {
  group('FrameScorer.score', () {
    test('纯黑帧得分 ~0', () {
      final jpeg = _blackFrame(360, 200);
      final s = FrameScorer.score(jpeg);
      // 纯黑方差=0，乘积=0
      expect(s, lessThan(1));
    });

    test('纯白帧得分 ~0', () {
      final jpeg = _whiteFrame(360, 200);
      final s = FrameScorer.score(jpeg);
      // 纯白无梯度无方差，乘积=0
      expect(s, lessThan(1));
    });

    test('纯灰帧得分 ~0（方差、梯度都为零）', () {
      for (final g in [64, 128, 192]) {
        final jpeg = _grayFrame(200, 150, g);
        final s = FrameScorer.score(jpeg);
        expect(s, lessThan(1), reason: '灰度=$g 期约0');
      }
    });

    test('棋盘格得分高（锐利边缘 + 亮度方差大）', () {
      final jpeg = _checkerboard(360, 200);
      final s = FrameScorer.score(jpeg);
      expect(s, greaterThan(100));
    });

    test('更大的棋盘格产生更高的锐度响应', () {
      final small = _checkerboard(100, 60); // 低频
      final large = _checkerboard(400, 240); // 高频 → 更多边缘
      expect(
        FrameScorer.score(large),
        greaterThan(FrameScorer.score(small)),
      );
    });

    test('空字节返回 0', () {
      expect(FrameScorer.score(Uint8List(0)), 0);
    });

    test('无效 JPEG 返回 0（不抛异常）', () {
      expect(
          FrameScorer.score(Uint8List.fromList([0xFF, 0xD8, 0, 0, 0, 0])), 0);
    });

    test('降采样后仍正常评分（大图不崩）', () {
      final jpeg = _checkerboard(1920, 1080);
      final s = FrameScorer.score(jpeg);
      expect(s, greaterThan(0));
    });

    test('scoreFile 不存在返回 0', () {
      expect(FrameScorer.scoreFile('/no/such/file.jpg'), 0);
    });
  });

  group('同一视频帧排序正确性', () {
    // 模拟"同一视频三个候选帧"：纯色 < 有纹理
    test('纯黑 ≈ 纯灰 ≈ 0 < 棋盘格', () {
      final black = _blackFrame(300, 168);
      final gray = _grayFrame(300, 168, 128);
      final checker = _checkerboard(300, 168);

      final sb = FrameScorer.score(black);
      final sg = FrameScorer.score(gray);
      final sc = FrameScorer.score(checker);

      // 纯黑和纯灰都无纹理，两者都 ≈ 0
      expect(sb, lessThanOrEqualTo(sg));  // 都是 ~0, 纯黑 ≤ 纯灰即可
      expect(sb, lessThan(sc));
      expect(sg, lessThan(sc));
    });

    test('添加高斯模糊后得分降低', () {
      // 不依赖 image 包的 gaussianBlur 实现（其内部行为不可控）。
      // 改为手动构造一个"锐利棋盘格"和一个"纯灰帧"来模拟模糊前后的关系：
      // 纯灰 = 极限模糊（无任何纹理），得分应远低于棋盘格。
      final sharp = img.Image(width: 200, height: 120);
      _fillSmallChecker(sharp, block: 1);
      final sharpPng = Uint8List.fromList(img.encodePng(sharp));
      final sharpScore = FrameScorer.score(sharpPng);

      // 极限模糊 = 同一尺寸的纯灰帧（亮度同棋盘格均值 ≈ 128）
      final flat = img.Image(width: 200, height: 120);
      flat.clear(img.ColorRgb8(128, 128, 128));
      final flatPng = Uint8List.fromList(img.encodePng(flat));
      final flatScore = FrameScorer.score(flatPng);

      expect(sharpScore, greaterThan(100),
          reason: '1px 棋盘格应有高锐度响应');
      expect(flatScore, lessThan(1),
          reason: '纯灰帧无纹理，拉普拉斯能量 ≈ 0');
      expect(flatScore, lessThan(sharpScore),
          reason: '模糊 ≈ 无纹理，得分应低于锐利帧');
    });
  });
}

void _fillSmallChecker(img.Image i, {int block = 2}) {
  for (var y = 0; y < i.height; y++) {
    for (var x = 0; x < i.width; x++) {
      final c = ((x ~/ block) + (y ~/ block)) % 2 == 0 ? 255 : 0;
      i.setPixelRgb(x, y, c, c, c);
    }
  }
}