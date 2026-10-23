import 'dart:convert';
import 'dart:typed_data';

/// 115 网盘的 RSA 还原实现（纯 Dart，零第三方依赖）。
///
/// ## 方向说明（最容易搞反的一点）
///
/// 115 的链路是：
/// ```
/// 服务端：c = m ^ d mod n      （d 是服务端私钥，不公开）
/// 客户端：m = c ^ e mod n      （e = 0x10001，公开）
/// ```
/// 因为 `d * e ≡ 1 (mod φ(n))`，所以 `(m^d)^e ≡ m`，客户端只用公钥即可还原。
///
/// **注意**：反过来「用 e 加密、再用 e 解码」在数学上不成立，
/// 所以不能用「自己加密再自己解」做往返验证，只能用已知密钥对验证。
///
/// ## 完整链路
/// ```
/// base64 密文
///   → b64decode
///   → 每 128 字节：pow(block, e, n)，剥掉首个 0x00 之前的内容
///   → 得到 [randKey(16B) + body]
///   → keyL = genKey(randKey, 12)
///   → tmp  = reverse( xor(body, keyL) )
///   → plain = xor(tmp, RSA_KEY)        // RSA_KEY = 8D A5 A5 8D
///   → jsonDecode → {"<pickcode>":{"file_url":"..."}}
/// ```
///
/// 参考实现：p115cipher（Python）。
class P115Cipher {
  P115Cipher._();

  /// RSA 模数 n（115 公钥，1024 位）。
  static final BigInt _n = BigInt.parse(
    '8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b860213'
    '6477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633'
    '8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9'
    'f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb7'
    '1683',
    radix: 16,
  );

  /// RSA 公钥指数 e。
  static final BigInt _e = BigInt.from(0x10001);

  /// 固定 XOR 密钥（p115cipher 的 `RSA_KEY`）。
  static const List<int> _rsaKey = [0x8d, 0xa5, 0xa5, 0x8d];

  /// `G_key_l`：第二层 XOR 常量。
  static const List<int> _gKeyL = [
    0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46,
  ];

  /// `G_kts`：`genKey` 用的置换表。
  static const List<int> _gKts = [
    0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe,
    0x7d, 0xa6, 0x73, 0xb8,
    0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14,
    0x6a, 0xb4, 0xf1, 0xaa,
    0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5,
    0x36, 0x34, 0x62, 0xa6,
    0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d,
    0x8f, 0x89, 0x13, 0xb7,
    0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8,
    0xfe, 0xfe, 0x7e, 0x86,
    0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c,
    0x7e, 0x9d, 0x7a, 0x81,
    0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa,
    0xba, 0x81, 0x60, 0x48,
    0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26,
    0x5f, 0xbe, 0xe8, 0x1e,
    0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f,
    0xcc, 0xc3, 0xb8, 0xf5,
  ];

  /// 把 115 的密文（base64 字符串或原始字节）还原成明文字节。
  ///
  /// [modulus] / [exponent] 仅供测试注入，生产用内置 115 公钥。
  /// 返回 null 表示格式不符或解码失败，调用方应降级到其它通道。
  static Uint8List? decryptBytes(
    Object? cipherData, {
    BigInt? modulus,
    BigInt? exponent,
  }) {
    try {
      final raw = _toCipherBytes(cipherData);
      if (raw == null || raw.isEmpty) return null;

      // ① 分段模幂 + 剥 PKCS#1 填充
      final rsaPlain = _rsaDecrypt(
        raw,
        n: modulus ?? _n,
        e: exponent ?? _e,
      );
      if (rsaPlain.length <= 16) return null;

      // ② 前 16 字节 randKey → 派生 12 字节 XOR 密钥
      final randKey = Uint8List.sublistView(rsaPlain, 0, 16);
      final body = Uint8List.sublistView(rsaPlain, 16);
      final keyL = genKey(randKey, 12);

      // ③ 先 XOR 再整体逆序
      final xored = xorBytes(body, keyL);
      final reversed = Uint8List.fromList(xored.reversed.toList());

      // ④ 再与固定 RSA_KEY 做一次 XOR
      return xorBytes(reversed, Uint8List.fromList(_rsaKey));
    } catch (_) {
      return null;
    }
  }

  /// 解码并解析成 JSON（Map / List）。115 `downurl` 的 `data` 就是这形态。
  static Object? decryptJson(
    Object? cipherData, {
    BigInt? modulus,
    BigInt? exponent,
  }) {
    final bytes =
        decryptBytes(cipherData, modulus: modulus, exponent: exponent);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      var end = bytes.length;
      while (end > 0 && bytes[end - 1] == 0) {
        end--;
      }
      final text = utf8.decode(bytes.sublist(0, end), allowMalformed: true);
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _toCipherBytes(Object? v) {
    if (v is Uint8List) return v;
    if (v is List<int>) return Uint8List.fromList(v);
    if (v is String) {
      if (v.isEmpty) return null;
      try {
        return base64Decode(v);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 复刻 `rsa_decrypt_with_pubkey`。
  ///
  /// 每 `blockSize` 字节做 `pow(block, e, n)`，再剥掉首个 0x00 及之前的内容。
  /// 能这样剥的原因：PKCS#1 v1.5 填充是 `00 02 <非零> 00 <正文>`，
  /// 首字节 0x00 在最小长度大端表示里被省略，于是 `index(0)` 正落在
  /// 正文前的分隔符上。
  static Uint8List _rsaDecrypt(
    Uint8List cipher, {
    required BigInt n,
    required BigInt e,
    int blockSize = 128,
  }) {
    final out = BytesBuilder(copy: false);
    for (var start = 0; start < cipher.length; start += blockSize) {
      final end = (start + blockSize > cipher.length)
          ? cipher.length
          : start + blockSize;
      final block = Uint8List.sublistView(cipher, start, end);
      final p = bytesToBigInt(block).modPow(e, n);
      final pb = bigIntToBytes(p);

      final zeroAt = pb.indexOf(0);
      if (zeroAt < 0) {
        throw const FormatException('115 RSA 块缺少填充分隔符');
      }
      out.add(Uint8List.sublistView(pb, zeroAt + 1));
    }
    return out.takeBytes();
  }

  /// 复刻 `rsa_gen_key`：由 randKey 派生 skLen 字节 XOR 密钥。
  static Uint8List genKey(Uint8List randKey, int skLen) {
    final k = Uint8List(skLen);
    var length = skLen * (skLen - 1);
    var index = 0;
    for (var i = 0; i < skLen; i++) {
      final x = (randKey[i] + _gKts[index]) & 0xff;
      k[i] = _gKts[length] ^ x;
      length -= skLen;
      index += skLen;
    }
    return k;
  }

  /// 复刻 p115cipher 的 `xor`。
  ///
  /// 先处理 `len(src) & 3` 个头部字节，之后按 `len(key)` 分块，
  /// **每块密钥下标从 0 重新开始**。因每块 src/key 等长，
  /// 「大端整数异或」退化为逐字节异或。
  static Uint8List xorBytes(Uint8List src, Uint8List key) {
    final n = src.length;
    final out = Uint8List(n);
    if (n == 0 || key.isEmpty) return out;

    // n & 3：头部余数（Python 里写作 len(src) & 0b11）
    final head = n & 3;
    for (var p = 0; p < head; p++) {
      out[p] = src[p] ^ key[p % key.length];
    }

    final klen = key.length;
    var start = head;
    while (start < n) {
      final end = (start + klen > n) ? n : start + klen;
      for (var p = start; p < end; p++) {
        out[p] = src[p] ^ key[p - start];
      }
      start = end;
    }
    return out;
  }

  static BigInt bytesToBigInt(Uint8List b) {
    var r = BigInt.zero;
    for (final byte in b) {
      r = (r << 8) | BigInt.from(byte);
    }
    return r;
  }

  /// 等价 Python 的 `to_bytes(p, (p.bit_length() + 7) >> 3)`：最小长度大端。
  static Uint8List bigIntToBytes(BigInt v) {
    if (v == BigInt.zero) return Uint8List(0);
    final bytes = <int>[];
    var x = v;
    final mask = BigInt.from(0xff);
    while (x > BigInt.zero) {
      bytes.add((x & mask).toInt());
      x = x >> 8;
    }
    return Uint8List.fromList(bytes.reversed.toList());
  }

  /// 内置常量（测试用）。
  static BigInt get modulus => _n;
  static BigInt get exponent => _e;
  static List<int> get rsaKey => List.unmodifiable(_rsaKey);
  static List<int> get gKeyL => List.unmodifiable(_gKeyL);
}
