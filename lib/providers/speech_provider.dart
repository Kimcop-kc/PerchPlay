import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ai/speech_service.dart';

/// 全局语音识别服务（单例）。
final speechServiceProvider = Provider<SpeechService>((ref) {
  final service = SpeechService();
  ref.onDispose(() => service.dispose());
  return service;
});