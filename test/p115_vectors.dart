/// 115 RSA 解码的测试向量（由 gen115.py 生成）。
///
/// 生成方式：造一个真实 1024 位 RSA 密钥对 (n, e, d)，
/// 用**服务端的打包方式**（randkey + XOR(reverse(XOR(plain, RSA_KEY)), genKey(randkey,12))）
/// 再用**私钥 d** 分段加密，最后 base64。
///
/// 客户端用**公钥 e** 还原，所以测试里需要注入 testN / testE。
class P115TestVectors {
  P115TestVectors._();

  /// 测试用模数 n（非 115 真实公钥，仅用于验证算法）。
  static final BigInt testN = BigInt.parse(
    'abf60aabb794f6d07d63e370f37af023d4904481b89a72a2072329b362d2f012'
    '8dbf4c3bedcf660d69ab416bbe2aa7366b431e38e304ac1ae2af5aced4d6082f'
    'd9d7809defb82fa1dda47e0dc3d64df8a89d7efaf3347a4ce78c37a35d8ae5'
    '612dfc280db57fd57a7dd4392135f78eeb1ee1adc8ee6bc2b4bfdd246f8fb5a'
    '713',
    radix: 16,
  );

  /// 测试用公钥指数。
  static final BigInt testE = BigInt.from(0x10001);

  /// (明文, base64 密文)
  static const List<(String, String)> cases = [
    (
      '{"a":1}',
      'gFE8ddYKci8CUyghl4fHkdjkRg4s03D3ibMXwc7V4VRbz3RrgDcOD4TdUZDYBFmmHZ'
          'EfqcNrqUokUcZaJB5h/fThEsNlSRusOjdXc8dDvWJYmzoUnGfa9TWhbotrGvAV4P1S'
          'X2T21jpITytrU/TmAOyalumaqLqE5LbLQEpLVKI=',
    ),
    (
      '{"state":true}',
      'C6nWorbu/XQGl2IjEGKfk/1O17jTVycEWcKgF9bPGUoYV81rvmn4HjO6lsAyJa8yEg'
          '+/LC/+AjhACi0bXZtD7HVT3TS4xm6pWwns0Huz6MD14IPZ4c7NdZQQa2Jq0lumNwfC'
          'iKDk/bye5KbYHGegBWFJ/vV2oni9Pmv3biLSeUs=',
    ),
    (
      '{"abc":{"file_url":"https://115.com/a.mp4","file_name":"a.mp4",'
          '"file_size":1024}}',
      'ZnDJbi6YvpksRDOheee3/jPb17oUpObAwf1LZ91nBWYUEvtH3/3oO+ZrhIWNv96zwDX'
          'Qvvzt3uQRQ0OAmB1iQmma7H4F67xBHaCnewy9UkCTIkKWTf4/cv8ihNMlZ0vqNjg'
          'uteVXEzWWGP7orvWE8VUTw2TTxCNRtmmRuDgtOS8=',
    ),
  ];

  /// 长明文（208 字节，触发 RSA 分段）。只校验特征，不比对全文。
  static const String longCipher =
      'cPFmv6Bi4uPpY0QwXoRpgl5YesBJHrL45nV6fPkirDbdwt3NlSlZJOJ61ba55j0daVgW'
      '1REQeb2GOPsR9HaZ88aKEbALzXmFSSepyej+XQnVGCbsNj8wnD9A/IPAhKOFRV+BavZl'
      'zGDSaA2Q32RHjIiClzU66jLPuljJIgkU3o5Y/WnIJV3WQpOQFX2Z+RPuv5DkNE0/57MU'
      'vCE7ZFNSVXcuKNKrX1CgH3y7yUUTbeK+Pu/EH5XfYQeMZWnsd9shpmPkCBnUVq2u3uWT'
      'U8kxFLfSwLS3dvFvPAAPCBsIKAAVz772XNHKf1VQmrM6qEvueLCNn1pkZBZiaScwXqcnd'
      'g==';
}
