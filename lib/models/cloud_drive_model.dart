/// 支持的云盘类型。
///
/// 认证方式分两类：
///  - Cookie 类（夸克 / 115 / 百度）：内嵌 WebView 登录后抓 Cookie
///  - Token 类（阿里云盘）：扫码或 OAuth 换 refresh_token
enum CloudDriveType {
  quark,
  pan115,
  baidu,
  aliyun,
}

extension CloudDriveTypeX on CloudDriveType {
  String get displayName {
    switch (this) {
      case CloudDriveType.quark:
        return '夸克网盘';
      case CloudDriveType.pan115:
        return '115 网盘';
      case CloudDriveType.baidu:
        return '百度网盘';
      case CloudDriveType.aliyun:
        return '阿里云盘';
    }
  }

  /// 登录页 URL（WebView 打开这个让用户扫码/账号密码登录）
  ///
  /// 必须用桌面版 URL + 桌面版 UA，否则夸克 / 115 会检测到移动端，
  /// 强制跳转 App 下载页而不是登录页。
  String get loginUrl {
    switch (this) {
      case CloudDriveType.quark:
        // 夸克网盘桌面版：需桌面 UA 才不会跳转下载页
        return 'https://pan.quark.cn/';
      case CloudDriveType.pan115:
        // 115 桌面版（m.115.com 是手机版，桌面 UA 下也能用但登录入口难找）
        return 'https://115.com/';
      case CloudDriveType.baidu:
        // 百度网盘登录页
        return 'https://pan.baidu.com/login';
      case CloudDriveType.aliyun:
        // 必须用 /sign/in，不能用根路径 `/`。
        //
        // 根路径加载的是 `aliyun-drive-fe/aliyun-drive-home`（产品介绍首页），
        // 那个页面**没有任何登录入口**，在 WebView 里看起来就是「一片空白 /
        // 只有宣传图」，用户根本没地方输入账号 —— 这就是「阿里云没有登录界面」。
        //
        // `/sign/in` 加载的是 `aliyun-drive-fe/h5-sign`，是独立的登录应用
        // （手机号 + 验证码 / 扫码），登录成功后会把 token 写进 localStorage。
        return 'https://www.alipan.com/sign/in';
    }
  }

  /// 登录成功后 Cookie 应包含的关键字段。
  ///
  /// 用它们判断「是否真的登录成功了」——WebView 停在登录页时 Cookie 也有值，
  /// 只有出现这些字段才说明过了登录环节。
  List<String> get requiredCookieKeys {
    switch (this) {
      case CloudDriveType.quark:
        // __pus 是夸克登录后下发的核心会话票
        return ['__pus'];
      case CloudDriveType.pan115:
        return ['UID', 'CID'];
      case CloudDriveType.baidu:
        return ['BDUSS', 'STOKEN'];
      case CloudDriveType.aliyun:
        // 阿里走 token，不用 cookie 判断
        return [];
    }
  }

  /// 该云盘是否需要 refresh token（而非 cookie）
  bool get usesToken => this == CloudDriveType.aliyun;
}

/// 一条云盘连接配置。
class CloudDriveAccount {
  final String id;
  final CloudDriveType type;

  /// 用户给这条连接起的名字（如「我的夸克」）
  final String name;

  /// Cookie 串（Cookie 类云盘用），形如 `a=1; b=2`
  final String cookie;

  /// refresh token（阿里云盘用）
  final String refreshToken;

  /// access token 缓存（阿里云盘用）
  final String accessToken;

  /// access token 过期时间
  final DateTime? tokenExpireAt;

  /// 账号昵称（能取到就显示）
  final String nickname;

  /// 上次连接时间
  final DateTime? lastConnected;

  const CloudDriveAccount({
    required this.id,
    required this.type,
    required this.name,
    this.cookie = '',
    this.refreshToken = '',
    this.accessToken = '',
    this.tokenExpireAt,
    this.nickname = '',
    this.lastConnected,
  });

  /// 是否已持有可用凭证。
  ///
  /// 阿里云盘是 access_token / refresh_token 二选一即可：
  /// WebView 登录时我们优先抓 access_token（可直接调 API，不需要 client_id），
  /// refresh_token 只是兜底。之前只判 refreshToken，导致「抓到了 access_token
  /// 但撑不住 refresh_token」的账号被误判为未登录。
  bool get hasCredential => type.usesToken
      ? (accessToken.isNotEmpty || refreshToken.isNotEmpty)
      : cookie.isNotEmpty;

  CloudDriveAccount copyWith({
    String? id,
    CloudDriveType? type,
    String? name,
    String? cookie,
    String? refreshToken,
    String? accessToken,
    DateTime? tokenExpireAt,
    String? nickname,
    DateTime? lastConnected,
  }) {
    return CloudDriveAccount(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      cookie: cookie ?? this.cookie,
      refreshToken: refreshToken ?? this.refreshToken,
      accessToken: accessToken ?? this.accessToken,
      tokenExpireAt: tokenExpireAt ?? this.tokenExpireAt,
      nickname: nickname ?? this.nickname,
      lastConnected: lastConnected ?? this.lastConnected,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'name': name,
        'cookie': cookie,
        'refreshToken': refreshToken,
        'accessToken': accessToken,
        'tokenExpireAt': tokenExpireAt?.toIso8601String(),
        'nickname': nickname,
        'lastConnected': lastConnected?.toIso8601String(),
      };

  factory CloudDriveAccount.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'quark';
    return CloudDriveAccount(
      id: json['id'] as String? ?? '',
      type: CloudDriveType.values.firstWhere(
        (e) => e.name == typeName,
        orElse: () => CloudDriveType.quark,
      ),
      name: json['name'] as String? ?? '',
      cookie: json['cookie'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      tokenExpireAt: json['tokenExpireAt'] != null
          ? DateTime.tryParse(json['tokenExpireAt'] as String)
          : null,
      nickname: json['nickname'] as String? ?? '',
      lastConnected: json['lastConnected'] != null
          ? DateTime.tryParse(json['lastConnected'] as String)
          : null,
    );
  }
}

/// 云盘里的一个文件条目。
class CloudFileItem {
  final String id;
  final String name;

  /// 文件在该云盘里的路径或父目录 id 链（各家不同，统一存成字符串）
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
  final String extension;

  const CloudFileItem({
    required this.id,
    required this.name,
    required this.path,
    this.isDirectory = false,
    this.size = 0,
    this.modified,
    this.extension = '',
  });

  bool get isVideo => const {
        'mp4',
        'mkv',
        'avi',
        'mov',
        'wmv',
        'flv',
        'webm',
        'm4v',
        'ts',
        'm2ts',
        'mpg',
        'mpeg',
        'rmvb',
        'rm',
        '3gp',
      }.contains(extension.toLowerCase());
}
