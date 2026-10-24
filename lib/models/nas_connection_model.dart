/// NAS 协议
enum NasProtocol { smb, ftp, webdav, nfs }

/// 连接状态
enum NasConnectionStatus { disconnected, connecting, connected, error }

/// NAS 连接配置
class NasConnection {
  final String id;
  final String name;
  final NasProtocol protocol;
  final String host;
  final int port;
  final String username;
  final String password;
  final String domain;
  final String shareName;
  final String remotePath;
  final NasConnectionStatus status;
  final String errorMessage;
  final DateTime? lastConnected;
  final bool savePassword;

  /// WebDAV / FTP 使用 HTTPS（默认根据端口猜测：443 = true）
  final bool useHttps;

  const NasConnection({
    required this.id,
    required this.name,
    required this.protocol,
    required this.host,
    this.port = 445,
    this.username = '',
    this.password = '',
    this.domain = '',
    this.shareName = '',
    this.remotePath = '/',
    this.status = NasConnectionStatus.disconnected,
    this.errorMessage = '',
    this.lastConnected,
    this.savePassword = false,
    this.useHttps = false,
  });

  NasConnection copyWith({
    String? id,
    String? name,
    NasProtocol? protocol,
    String? host,
    int? port,
    String? username,
    String? password,
    String? domain,
    String? shareName,
    String? remotePath,
    NasConnectionStatus? status,
    String? errorMessage,
    DateTime? lastConnected,
    String? useHttpsStr,
    bool? useHttps,
    // 注意：`savePassword` 原来是漏的 —— 方法体里写了
    // `savePassword: savePassword ?? this.savePassword`，但参数表没这个参数，
    // 于是它引用到的是类字段自身，永远是 `bool`（非 null），
    // 编译器报 dead_null_aware_expression。虽然结果恰好正确，
    // 但意味着 copyWith 无法修改这个字段，且语义含糊。补上参数。
    bool? savePassword,
  }) {
    // 兼容 JSON 反序列化：可能传入字符串 "true"/"false"
    final https = useHttps ??
        (useHttpsStr != null ? useHttpsStr == 'true' : this.useHttps);
    return NasConnection(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      domain: domain ?? this.domain,
      shareName: shareName ?? this.shareName,
      remotePath: remotePath ?? this.remotePath,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      lastConnected: lastConnected ?? this.lastConnected,
      savePassword: savePassword ?? this.savePassword,
      useHttps: https,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'protocol': protocol.name,
      'host': host,
      'port': port,
      'username': username,
      'password': savePassword ? password : '',
      'domain': domain,
      'shareName': shareName,
      'remotePath': remotePath,
      'status': status.name,
      'errorMessage': errorMessage,
      'lastConnected': lastConnected?.toIso8601String(),
      'savePassword': savePassword,
      'useHttps': useHttps,
    };
  }

  factory NasConnection.fromJson(Map<String, dynamic> json) {
    // useHttps 兼容布尔 或 字符串 "true"/"false"
    final rawHttps = json['useHttps'];
    final useHttps = rawHttps is bool
        ? rawHttps
        : rawHttps is String
            ? rawHttps == 'true'
            : false;
    return NasConnection(
      id: json['id'] as String,
      name: json['name'] as String,
      protocol: _parseProtocol(json['protocol'] as String?),
      host: json['host'] as String,
      port: json['port'] as int? ?? 445,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      shareName: json['shareName'] as String? ?? '',
      remotePath: json['remotePath'] as String? ?? '/',
      status: _parseStatus(json['status'] as String?),
      errorMessage: json['errorMessage'] as String? ?? '',
      lastConnected: json['lastConnected'] != null
          ? DateTime.parse(json['lastConnected'] as String)
          : null,
      savePassword: json['savePassword'] as bool? ?? false,
      useHttps: useHttps,
    );
  }

  static NasProtocol _parseProtocol(String? s) {
    switch (s) {
      case 'ftp':
        return NasProtocol.ftp;
      case 'webdav':
        return NasProtocol.webdav;
      case 'nfs':
        return NasProtocol.nfs;
      default:
        return NasProtocol.smb;
    }
  }

  static NasConnectionStatus _parseStatus(String? s) {
    switch (s) {
      case 'connecting':
        return NasConnectionStatus.connecting;
      case 'connected':
        return NasConnectionStatus.connected;
      case 'error':
        return NasConnectionStatus.error;
      default:
        return NasConnectionStatus.disconnected;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NasConnection &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// NAS 远程文件项
class NasFileItem {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedTime;
  final String extension;
  final String mimeType;

  const NasFileItem({
    required this.name,
    required this.path,
    this.isDirectory = false,
    this.size = 0,
    this.modifiedTime,
    this.extension = '',
    this.mimeType = '',
  });

  NasFileItem copyWith({
    String? name,
    String? path,
    bool? isDirectory,
    int? size,
    DateTime? modifiedTime,
    String? extension,
    String? mimeType,
  }) {
    return NasFileItem(
      name: name ?? this.name,
      path: path ?? this.path,
      isDirectory: isDirectory ?? this.isDirectory,
      size: size ?? this.size,
      modifiedTime: modifiedTime ?? this.modifiedTime,
      extension: extension ?? this.extension,
      mimeType: mimeType ?? this.mimeType,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      'isDirectory': isDirectory,
      'size': size,
      'modifiedTime': modifiedTime?.toIso8601String(),
      'extension': extension,
      'mimeType': mimeType,
    };
  }

  factory NasFileItem.fromJson(Map<String, dynamic> json) {
    return NasFileItem(
      name: json['name'] as String,
      path: json['path'] as String,
      isDirectory: json['isDirectory'] as bool? ?? false,
      size: json['size'] as int? ?? 0,
      modifiedTime: json['modifiedTime'] != null
          ? DateTime.parse(json['modifiedTime'] as String)
          : null,
      extension: json['extension'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? '',
    );
  }

  /// 是否为支持的视频文件。
  ///
  /// ## 为什么从 name 推导，而不只看 [extension]
  ///
  /// [extension] 是构造时可选的字段，而三个解析分支（WebDAV / FTP / SMB）
  /// 全都**没有传它** —— 于是它恒为空串，这个 getter 恒返回 false。
  /// 表现就是：点视频文件毫无反应（既不是目录、也不被识别为视频）。
  ///
  /// 现在优先用 [extension]，为空时从 [name] 自己截取后缀，
  /// 这样不依赖调用方是否记得传字段。
  bool get isVideo {
    // 实际后缀：优先显式字段，否则从文件名取
    var ext = extension.trim().toLowerCase();
    if (ext.isEmpty) {
      final dot = name.lastIndexOf('.');
      if (dot >= 0 && dot < name.length - 1) {
        ext = name.substring(dot + 1).toLowerCase();
      }
    }
    // 统一成不带点的形式比较（历史列表里带点，去掉更稳）
    if (ext.startsWith('.')) ext = ext.substring(1);
    if (ext.isEmpty) return false;

    const videoExtensions = {
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v',
      'mpg', 'mpeg', '3gp', 'ts', 'm2ts', 'vob', 'rmvb', 'asf',
      'divx', 'xvid', 'f4v', 'ogv', '3g2',
    };
    return videoExtensions.contains(ext);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NasFileItem &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}
