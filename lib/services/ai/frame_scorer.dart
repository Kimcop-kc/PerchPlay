import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// 纯 Dart 的视频帧质量评分，不依赖任何原生库或 AI 模型。
///
/// 算法核心：
/// - **亮度方差**（σ² of luminance）：全黑帧方差≈0，正常帧方差高。
/// - **拉普拉斯锐度**（4-邻域拉普拉斯梯度能量）：模糊帧梯度低，清晰帧梯度高。
///
/// 乘积 `亮度方差 × 拉普拉斯能量` 同时惩罚黑帧（低方差）和模糊帧（低锐度），
/// 正常画面得分最高。**不依赖单一阈值**，只保证同一视频内多个候选帧的相对
/// 排序正确——因此不同视频的分值没有可比性（那是预期的）。
///
/// [nima-frame-quality] 模型是可选增强，没有它时这个纯算法就是兜底实现。
class FrameScorer {
  /// 评分用到的降采样宽度：200px 足够判断黑帧/模糊，再大只会加解码开销。
  static const int _maxWidth = 200;

  /// 4-邻域拉普拉斯核半径
  static const int _lapRadius = 1;

  /// 解码 JPEG 字节并评分。
  ///
  /// 返回值无单位，仅在同一视频的不同帧之间比较有意义。
  /// 典型值：黑帧 < 100，模糊帧 100~500，正常帧 1000~5000+。
  static double score(Uint8List jpegBytes) {
    final image = img.decodeImage(jpegBytes);
    if (image == null) return 0;

    // 长边降到 _maxWidth 以内：评分不需要原图精度，降采样能削掉压缩噪声
    // 对锐度判断的干扰，而且速度大幅提升。
    final w = image.width;
    final h = image.height;
    img.Image small;
    if (w > h && w > _maxWidth) {
      small = img.copyResize(image, width: _maxWidth);
    } else if (h > _maxWidth) {
      small = img.copyResize(image, height: _maxWidth);
    } else {
      small = image;
    }

    final pixels = small.width * small.height;
    if (pixels == 0) return 0;

    // 第一步：逐像素提取灰度，同时累加亮度均值
    final gray = Float64List(pixels);
    double sum = 0;
    for (var y = 0; y < small.height; y++) {
      for (var x = 0; x < small.width; x++) {
        final p = small.getPixel(x, y);
        // ITU-R BT.601 亮度公式, 0~255
        final g = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        final idx = y * small.width + x;
        gray[idx] = g;
        sum += g;
      }
    }

    // 第二步：亮度方差
    final mean = sum / pixels;
    double variance = 0;
    for (var i = 0; i < pixels; i++) {
      final d = gray[i] - mean;
      variance += d * d;
    }
    variance /= pixels;

    // 第三步：拉普拉斯梯度能量（4-邻域）
    //   0  1  0
    //   1 -4  1
    //   0  1  0
    // 先算响应再平方再累加，比「先平方再卷积」对噪声更稳健
    double lapEnergy = 0;
    final sw = small.width;
    final sh = small.height;
    for (var y = _lapRadius; y < sh - _lapRadius; y++) {
      for (var x = _lapRadius; x < sw - _lapRadius; x++) {
        final c = gray[y * sw + x];
        final n = gray[(y - 1) * sw + x];
        final s = gray[(y + 1) * sw + x];
        final w_ = gray[y * sw + (x - 1)];
        final e = gray[y * sw + (x + 1)];
        final lap = 4 * c - n - s - w_ - e;
        lapEnergy += lap * lap;
      }
    }
    // 按有效像素数归一化（排除边界一圈）
    final validPixels = (sw - 2 * _lapRadius) * (sh - 2 * _lapRadius);
    if (validPixels > 0) {
      lapEnergy /= validPixels;
    }

    return variance * lapEnergy;
  }

  /// 从文件路径读取 JPEG 并评分（便捷包装）。
  ///
  /// 文件不存在或不是有效的 JPEG 返回 0。
  static double scoreFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return 0;
      return score(file.readAsBytesSync());
    } catch (_) {
      return 0;
    }
  }
}