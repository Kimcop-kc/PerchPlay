import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/providers/nas_provider.dart';

void main() {
  group('NasState.copyWith', () {
    test('未传 errorMessage 时保留原错误（不误清空）', () {
      const state = NasState(errorMessage: '连接失败');
      final updated = state.copyWith(isLoading: true);
      expect(updated.errorMessage, '连接失败');
      expect(updated.isLoading, true);
    });

    test('传 errorMessage 时更新错误', () {
      const state = NasState(errorMessage: '旧错误');
      final updated = state.copyWith(errorMessage: '新错误');
      expect(updated.errorMessage, '新错误');
    });

    test('clearError=true 时清空错误', () {
      const state = NasState(errorMessage: '旧错误');
      final updated = state.copyWith(clearError: true);
      expect(updated.errorMessage, isNull);
    });
  });
}
