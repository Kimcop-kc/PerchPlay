import 'dart:io';
import 'package:flutter_video_thumbnail_plus/flutter_video_thumbnail_plus.dart';

class ThumbnailService {
  static const _quality = 80;
  static const _size = 360;

  Future<String?> generate(String videoPath) async {
    try {
      final thumbnailPath = await FlutterVideoThumbnailPlus.thumbnailFile(
        video: videoPath,
        thumbnailPath: Directory.systemTemp.path,
        imageFormat: ImageFormat.jpeg,
        maxWidth: _size,
        quality: _quality,
      );
      return thumbnailPath;
    } catch (_) {
      return null;
    }
  }
}