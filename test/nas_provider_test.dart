import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/providers/nas_provider.dart';

void main() {
  group('NasState.copyWith', () {
    test('鏈紶 errorMessage 鏃朵繚鐣欏師閿欒锛堜笉璇竻绌猴級', () {
      const state = NasState(errorMessage: '杩炴帴澶辫触');
      final updated = state.copyWith(isLoading: true);
      expect(updated.errorMessage, '杩炴帴澶辫触');
      expect(updated.isLoading, true);
    });

    test('浼?errorMessage 鏃舵洿鏂伴敊璇?, () {
      const state = NasState(errorMessage: '鏃ч敊璇?);
      final updated = state.copyWith(errorMessage: '鏂伴敊璇?);
      expect(updated.errorMessage, '鏂伴敊璇?);
    });

    test('clearError=true 鏃舵竻绌洪敊璇?, () {
      const state = NasState(errorMessage: '鏃ч敊璇?);
      final updated = state.copyWith(clearError: true);
      expect(updated.errorMessage, isNull);
    });
  });
}
