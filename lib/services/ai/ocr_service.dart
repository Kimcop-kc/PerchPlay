import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

/// 端侧 OCR 服务（PP-OCRv5 ONNX，基于 onnxruntime 1.4.1）。
///
/// 支持的模型目录：RapidOCR ONNX（bluecopa/rapidocr-onnx）
///
/// Pipeline：detection → 方向分类（可选）→ recognition
///
/// 典型用法：
/// ```dart
/// final ocr = OcrService();
/// await ocr.loadModel('/path/to/rapidocr-onnx');
/// final results = await ocr.recognize('/path/to/image.png');
/// ```
class OcrService {
  OrtSession? _detSession;
  OrtSession? _recSession;
  OrtSession? _clsSession;
  List<String> _dict = [];
  String? _loadedDir;

  // 缓存运行时发现的 I/O 名称
  String? _detInputName;
  String? _recInputName;
  String? _clsInputName;

  // ── 模型参数 ──

  static const int _detLimitSideLen = 960;
  static const double _detThresh = 0.3;
  static const int _recImageHeight = 48;
  static const int _clsImageHeight = 48;
  static const int _clsImageWidth = 192;
  static const double _clsThresh = 0.9;
  static const List<double> _mean = [0.485, 0.456, 0.406];
  static const List<double> _std = [0.229, 0.224, 0.225];

  // ── 生命周期 ──

  Future<void> dispose() async {
    try {
      _detSession?.release();
    } catch (_) {}
    try {
      _recSession?.release();
    } catch (_) {}
    try {
      _clsSession?.release();
    } catch (_) {}
    _detSession = null;
    _recSession = null;
    _clsSession = null;
    _dict = [];
    _loadedDir = null;
  }

  bool get isLoaded => _detSession != null && _recSession != null;

  /// 加载 OCR 模型目录。
  Future<void> loadModel(String modelDir) async {
    if (_loadedDir == modelDir && isLoaded) return;
    await dispose();

    final d = Directory(modelDir);
    if (!d.existsSync()) {
      debugPrint('[OcrService] 模型目录不存在: $modelDir');
      return;
    }

    OrtEnv.instance.init();

    final files = d.listSync().whereType<File>().toList();
    final Map<String, File> fileMap = {};
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last;
      fileMap[name] = f;
    }

    // 检测模型（必需）
    final detFile = fileMap['PP-OCRv5_det.onnx'];
    if (detFile == null) {
      debugPrint('[OcrService] 缺少检测模型 PP-OCRv5_det.onnx');
      return;
    }

    // 识别模型 — mobile 优先
    File? recFile = fileMap['ch_PP-OCRv5_rec_mobile_infer.onnx'];
    recFile ??= fileMap['PP-OCRv5_server_rec_infer.onnx'];
    if (recFile == null) {
      debugPrint('[OcrService] 缺少识别模型');
      return;
    }

    // 字典
    final dictFile = fileMap['ppocrv5_dict.txt'];
    if (dictFile == null) {
      debugPrint('[OcrService] 缺少字典 ppocrv5_dict.txt');
      return;
    }

    // 分类（可选）
    final clsFile = fileMap['ch_ppocr_mobile_v2.0_cls_infer.onnx'];

    try {
      final opts = OrtSessionOptions();
      _detSession = OrtSession.fromFile(detFile, opts);
      _recSession = OrtSession.fromFile(recFile, opts);
      if (clsFile != null) {
        _clsSession = OrtSession.fromFile(clsFile, opts);
      }
      opts.release();

      // 缓存 I/O 名称
      if (_detSession!.inputNames.isNotEmpty) {
        _detInputName = _detSession!.inputNames.first;
      }
      if (_recSession!.inputNames.isNotEmpty) {
        _recInputName = _recSession!.inputNames.first;
      }
      if (_clsSession != null && _clsSession!.inputNames.isNotEmpty) {
        _clsInputName = _clsSession!.inputNames.first;
      }

      final dictText = await dictFile.readAsString();
      _dict = dictText
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      _loadedDir = modelDir;

      debugPrint('[OcrService] 加载完成: det_in=${_detInputName ?? "?"}'
          ' rec_in=${_recInputName ?? "?"}'
          ' cls=${_clsSession != null ? "有" : "无"}'
          ' dict=${_dict.length}');
    } catch (e) {
      debugPrint('[OcrService] 加载失败: $e');
      await dispose();
    }
  }

  // ── 主入口 ──

  /// 识别图片中的文字。
  Future<List<OcrResult>?> recognize(String imagePath) async {
    if (!isLoaded) {
      debugPrint('[OcrService] 模型未加载');
      return null;
    }

    final file = File(imagePath);
    if (!file.existsSync()) {
      debugPrint('[OcrService] 图片不存在: $imagePath');
      return null;
    }

    try {
      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        debugPrint('[OcrService] 无法解码图片');
        return null;
      }
      return await _recognize(image);
    } catch (e) {
      debugPrint('[OcrService] 识别异常: $e');
      return null;
    }
  }

  // ── 识别管道 ──

  Future<List<OcrResult>> _recognize(img.Image srcImage) async {
    final detSession = _detSession;
    final recSession = _recSession;
    if (detSession == null || recSession == null) return <OcrResult>[];
    if (_dict.isEmpty) return <OcrResult>[];

    final srcW = srcImage.width.toDouble();
    final srcH = srcImage.height.toDouble();

    // ── Step 1: 文字检测 ──
    final detInputTensor = _prepareDetInput(srcImage);
    final detInputs = <String, OrtValue>{_detInputName ?? 'x': detInputTensor};
    final runOpts1 = OrtRunOptions();
    final detOutputs = detSession.run(runOpts1, detInputs);
    final detOut = detOutputs.firstWhere((o) => o != null, orElse: () => null);
    if (detOut == null) {
      runOpts1.release();
      for (final o in detOutputs) {
        o?.release();
      }
      detInputTensor.release();
      return <OcrResult>[];
    }

    final detValue = _tensorValueAsList(detOut);

    // PP-OCRv5 det output: [1, 1, h', w'] — stride 4
    final ratio = _detLimitSideLen / max(srcImage.width, srcImage.height);
    final w = (srcImage.width * ratio).round();
    final h = (srcImage.height * ratio).round();
    final padW = ((w + 31) ~/ 32) * 32;
    final padH = ((h + 31) ~/ 32) * 32;
    final int mapH = padH ~/ 4;
    final int mapW = padW ~/ 4;

    final boxes = _boxesFromDetMap(detValue, mapH, mapW, srcW, srcH);

    // Release detection resources
    for (final o in detOutputs) {
      o?.release();
    }
    detInputTensor.release();
    runOpts1.release();

    if (boxes.isEmpty) {
      debugPrint('[OcrService] 未检测到文字区域');
      return <OcrResult>[];
    }

    debugPrint('[OcrService] 检测到 ${boxes.length} 个文字区域');

    // ── Step 2+3: 逐框分类 + 识别 ──
    final results = <OcrResult>[];
    for (final box in boxes) {
      final cropped = _crop(srcImage, box);
      if (cropped.width < 4 || cropped.height < 4) continue;

      var use180 = false;
      if (_clsSession != null) {
        use180 = _classify(cropped);
      }

      final decode = _decodeBox(cropped, recSession, use180);
      if (decode.text.isNotEmpty) {
        results.add(OcrResult(
          text: decode.text,
          confidence: decode.confidence,
          box: box,
        ));
      }
    }

    return results;
  }

  // ── 预处理 ──

  OrtValueTensor _prepareDetInput(img.Image image) {
    final ratio = _detLimitSideLen / max(image.width, image.height);
    final w = (image.width * ratio).round();
    final h = (image.height * ratio).round();
    final resized = img.copyResize(image,
        width: w, height: h, interpolation: img.Interpolation.linear);

    final padW = ((w + 31) ~/ 32) * 32;
    final padH = ((h + 31) ~/ 32) * 32;
    final padded = img.Image(width: padW, height: padH);
    img.fill(padded, color: img.ColorRgb8(0, 0, 0));
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        padded.setPixel(x, y, resized.getPixel(x, y));
      }
    }

    return _imageToNchw(padded, padH, padW);
  }

  OrtValueTensor _imageToNchw(img.Image image, int h, int w) {
    final channelLen = h * w;
    final data = Float32List(3 * channelLen);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = image.getPixel(x, y);
        final base = y * w + x;
        data[base] = (px.r / 255.0 - _mean[0]) / _std[0];
        data[channelLen + base] = (px.g / 255.0 - _mean[1]) / _std[1];
        data[2 * channelLen + base] = (px.b / 255.0 - _mean[2]) / _std[2];
      }
    }
    return OrtValueTensor.createTensorWithDataList(data, [1, 3, h, w]);
  }

  // ── 检测后处理 ──

  List<OcrBox> _boxesFromDetMap(
    Float32List detMap,
    int mapH,
    int mapW,
    double imageW,
    double imageH,
  ) {
    final total = mapH * mapW;
    if (detMap.length < total) return <OcrBox>[];

    final bits = Uint8List(total);
    for (int i = 0; i < total; i++) {
      bits[i] = detMap[i] > _detThresh ? 1 : 0;
    }

    final visited = Uint8List(total);
    final components = <_Component>[];
    final scaleX = imageW / mapW;
    final scaleY = imageH / mapH;

    for (int y = 0; y < mapH; y++) {
      for (int x = 0; x < mapW; x++) {
        final idx = y * mapW + x;
        if (bits[idx] == 0 || visited[idx] != 0) continue;

        final queue = <int>[idx];
        visited[idx] = 1;
        int minX = x, maxX = x, minY = y, maxY = y;
        int head = 0;

        while (head < queue.length) {
          final cur = queue[head++];
          final cx = cur % mapW;
          final cy = cur ~/ mapW;
          if (cx < minX) minX = cx;
          if (cx > maxX) maxX = cx;
          if (cy < minY) minY = cy;
          if (cy > maxY) maxY = cy;

          for (final dir in const [
            (0, -1),
            (0, 1),
            (-1, 0),
            (1, 0)
          ]) {
            final nx = cx + dir.$1;
            final ny = cy + dir.$2;
            if (nx < 0 || nx >= mapW || ny < 0 || ny >= mapH) continue;
            final nidx = ny * mapW + nx;
            if (bits[nidx] != 0 && visited[nidx] == 0) {
              visited[nidx] = 1;
              queue.add(nidx);
            }
          }
        }

        final bw = maxX - minX + 1;
        final bh = maxY - minY + 1;
        if (bw >= 2 && bh >= 2) {
          components.add(_Component(minX, minY, maxX, maxY));
        }
      }
    }

    final boxes = <OcrBox>[];
    for (final c in components) {
      final x1 = (c.x1 * scaleX).round().clamp(0, imageW.round());
      final y1 = (c.y1 * scaleY).round().clamp(0, imageH.round());
      final x2 = (c.x2 * scaleX).round().clamp(1, imageW.round());
      final y2 = (c.y2 * scaleY).round().clamp(1, imageH.round());
      if (x2 > x1 + 4 && y2 > y1 + 8) {
        boxes.add(OcrBox(x1, y1, x2, y2));
      }
    }

    return boxes;
  }

  // ── 裁剪 ──

  img.Image _crop(img.Image src, OcrBox box) {
    final x1 = box.x1.clamp(0, src.width - 1);
    final y1 = box.y1.clamp(0, src.height - 1);
    final x2 = box.x2.clamp(1, src.width);
    final y2 = box.y2.clamp(1, src.height);
    return img.copyCrop(src,
        x: x1, y: y1, width: x2 - x1, height: y2 - y1);
  }

  // ── 方向分类 ──

  bool _classify(img.Image cropped) {
    final clsSession = _clsSession;
    if (clsSession == null) return false;
    if (cropped.width < 4 || cropped.height < 4) return false;

    try {
      final tensor = _resizeNchw(cropped, _clsImageHeight, _clsImageWidth);
      final runOpts = OrtRunOptions();
      final outputs =
          clsSession.run(runOpts, <String, OrtValue>{_clsInputName ?? 'x': tensor});
      final result = outputs.firstWhere((o) => o != null, orElse: () => null);
      if (result != null) {
        final probs = _tensorValueAsList(result);
        if (probs.length >= 2 && probs[1] > _clsThresh) {
          for (final o in outputs) {
            o?.release();
          }
          tensor.release();
          runOpts.release();
          return true;
        }
        for (final o in outputs) {
          o?.release();
        }
        tensor.release();
      }
      runOpts.release();
    } catch (e) {
      debugPrint('[OcrService] 方向分类异常: $e');
    }
    return false;
  }

  // ── 识别（逐框） ──

  ({String text, double confidence}) _decodeBox(
    img.Image cropped,
    OrtSession recSession,
    bool use180,
  ) {
    try {
      final ratio =
          cropped.height > 0 ? _recImageHeight / cropped.height : 1.0;
      int targetW = (cropped.width * ratio).round();
      targetW = ((targetW + 3) ~/ 4) * 4;
      if (targetW < 8) targetW = 8;

      var tensor = _resizeNchw(cropped, _recImageHeight, targetW);
      if (use180) {
        tensor = _rotate180(tensor, _recImageHeight, targetW);
      }

      final runOpts = OrtRunOptions();
      final outputs = recSession.run(
        runOpts,
        <String, OrtValue>{_recInputName ?? 'x': tensor},
      );
      final result =
          outputs.firstWhere((o) => o != null, orElse: () => null);
      if (result == null) {
        tensor.release();
        runOpts.release();
        return (text: '', confidence: 0.0);
      }

      final logits = _tensorValueAsList(result);
      final int numChars = _dict.length;
      if (numChars == 0 || logits.length < numChars) {
        for (final o in outputs) {
          o?.release();
        }
        tensor.release();
        runOpts.release();
        return (text: '', confidence: 0.0);
      }

      final int T = logits.length ~/ numChars;

      // CTC greedy decode
      final buffer = StringBuffer();
      int prevIdx = -1;
      double totalConf = 0.0;
      int decodeCount = 0;
      for (int t = 0; t < T; t++) {
        final offset = t * numChars;
        int bestIdx = 0;
        double bestVal = logits[offset].toDouble();
        for (int c = 1; c < numChars; c++) {
          final val = logits[offset + c].toDouble();
          if (val > bestVal) {
            bestVal = val;
            bestIdx = c;
          }
        }
        if (bestIdx != prevIdx && bestIdx > 0 && bestIdx < numChars) {
          buffer.write(_dict[bestIdx]);
          totalConf += bestVal;
          decodeCount++;
        }
        prevIdx = bestIdx;
      }
      final confidence =
          decodeCount > 0 ? totalConf / decodeCount : 0.0;

      for (final o in outputs) {
        o?.release();
      }
      tensor.release();
      runOpts.release();

      return (text: buffer.toString().trim(), confidence: confidence);
    } catch (e) {
      debugPrint('[OcrService] 识别单字异常: $e');
      return (text: '', confidence: 0.0);
    }
  }

  // ── 辅助函数 ──

  OrtValueTensor _resizeNchw(img.Image src, int targetH, int targetW) {
    final resized = img.copyResize(src,
        width: targetW,
        height: targetH,
        interpolation: img.Interpolation.linear);
    return _imageToNchw(resized, targetH, targetW);
  }

  OrtValueTensor _rotate180(OrtValueTensor src, int h, int w) {
    final raw = _tensorValueAsList(src);
    final channelLen = h * w;
    final rotated = Float32List(3 * channelLen);
    for (int c = 0; c < 3; c++) {
      final offset = c * channelLen;
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          rotated[offset + y * w + x] =
              raw[offset + (h - 1 - y) * w + (w - 1 - x)];
        }
      }
    }
    src.release();
    return OrtValueTensor.createTensorWithDataList(rotated, [1, 3, h, w]);
  }

  static Float32List _tensorValueAsList(OrtValue value) {
    try {
      final v = (value as dynamic).value;
      if (v is Float32List) return v;
      if (v is List<double>) return Float32List.fromList(v);
      if (v is List<num>) return Float32List.fromList(v.map((e) => e.toDouble()).toList());
      if (v is List<int>) return Float32List.fromList(v.map((e) => e.toDouble()).toList());
      debugPrint('[OcrService] 无法读取 tensor value, type=${v.runtimeType}');
      return Float32List(0);
    } catch (e) {
      debugPrint('[OcrService] tensor value 读取失败: $e');
      return Float32List(0);
    }
  }
}

/// OCR 文字框坐标，原图像素坐标系。
class OcrBox {
  const OcrBox(this.x1, this.y1, this.x2, this.y2);
  final int x1, y1, x2, y2;
  int get width => x2 - x1;
  int get height => y2 - y1;
  @override
  String toString() => '($x1,$y1)-($x2,$y2)';
}

// ── 内部类型 ──

class _Component {
  const _Component(this.x1, this.y1, this.x2, this.y2);
  final int x1, y1, x2, y2;
}

// ── 公开类型 ──

/// OCR 识别结果。
class OcrResult {
  const OcrResult({
    required this.text,
    required this.confidence,
    required this.box,
  });

  final String text;
  final double confidence;
  final OcrBox box;

  int get x1 => box.x1;
  int get y1 => box.y1;
  int get x2 => box.x2;
  int get y2 => box.y2;

  @override
  String toString() =>
      'OcrResult("$text" ${confidence.toStringAsFixed(3)} @ $box)';
}