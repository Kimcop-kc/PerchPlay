import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/cloud/p115_cipher.dart';

import 'p115_vectors.dart';

/// 验证 115 的 RSA 还原链路。
///
/// 测试向量由 gen115.py 生成：用真实 1024 位密钥对，按**服务端打包方式**
/// 混淆后用**私钥 d** 加密，客户端用**公钥 e** 还原。
/// 因此这里注入 testN / testE 而非 115 的真实公钥。
void main() {
  final testN = P115TestVectors.testN;
  final testE = P115TestVectors.testE;

  group('P115Cipher 115 RSA 还原', () {
    for (var i = 0; i < P115TestVectors.cases.length; i++) {
      final (plain, cipher) = P115TestVectors.cases[i];

      test('case $i 能还原出原始 JSON 文本', () {
        final got = P115Cipher.decryptBytes(
          cipher,
          modulus: testN,
          exponent: testE,
        );
        expect(got, isNotNull, reason: '解密返回 null');
        expect(utf8.decode(got!), equals(plain));
      });

      test('case $i decryptJson 得到合法 JSON', () {
        final obj = P115Cipher.decryptJson(
          cipher,
          modulus: testN,
          exponent: testE,
        );
        expect(obj, isNotNull);
        expect(obj, isA<Map>());
      });
    }

    test('长明文（208 字节，触发 RSA 分段）也能还原', () {
      final got = P115Cipher.decryptBytes(
        P115TestVectors.longCipher,
        modulus: testN,
        exponent: testE,
      );
      expect(got, isNotNull);
      final text = utf8.decode(got!);
      expect(text, contains('"k":"AAA'));
      expect(text.length, greaterThan(200));
    });

    test('非法密文返回 null 而不是抛异常', () {
      expect(P115Cipher.decryptBytes('not-base64!!!'), isNull);
      expect(P115Cipher.decryptBytes(''), isNull);
      expect(P115Cipher.decryptBytes(null), isNull);
      expect(P115Cipher.decryptBytes(12345), isNull);
    });

    test('xorBytes 单字节 key 退化为整体异或', () {
      final src = Uint8List.fromList([1, 2, 3, 4, 5]);
      final key = Uint8List.fromList([0xff]);
      final out = P115Cipher.xorBytes(src, key);
      expect(out, equals([1 ^ 0xff, 2 ^ 0xff, 3 ^ 0xff, 4 ^ 0xff, 5 ^ 0xff]));
    });

    test('genKey 派生 12 字节密钥', () {
      final rk = Uint8List.fromList(List.filled(16, 0));
      final k = P115Cipher.genKey(rk, 12);
      expect(k.length, 12);
    });

    test('bigIntToBytes / bytesToBigInt 往返一致', () {
      final v = BigInt.parse('0123456789abcdef', radix: 16);
      final b = P115Cipher.bigIntToBytes(v);
      expect(P115Cipher.bytesToBigInt(b), equals(v));
      // 0 对应空数组（与 Python to_bytes 的 0 长度行为一致）
      expect(P115Cipher.bigIntToBytes(BigInt.zero).length, 0);
    });

    test('内置 115 公钥已正确加载', () {
      expect(P115Cipher.modulus.bitLength, 1024);
      expect(P115Cipher.exponent, BigInt.from(0x10001));
    });

    test('内置 RSA_KEY 常量正确', () {
      expect(P115Cipher.rsaKey, equals([0x8d, 0xa5, 0xa5, 0x8d]));
      expect(P115Cipher.gKeyL.length, 12);
    });
  });
}
