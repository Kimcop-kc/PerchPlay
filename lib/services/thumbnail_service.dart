import 'dart:io';
import 'package:video_thumbnail/video_thumbnail.dart';

class ThumbnailService {
  static const _quality = 80;
  static const _size = 360;

  Future<String?> generate(String videoPath) async {
    try {
      final thumbnailPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: Directory.systemTemp.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: _size,
        quality: _quality,
      );
      return thumbnailPath;
    } catch (_) {
      return null;
    }
  }
}