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
    bool? savePassword,
  }) {
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
    };
  }

  factory NasConnection.fromJson(Map<String, dynamic> json) {
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

  /// 是否为支持的视频文件
  bool get isVideo {
    const videoExtensions = [
      '.mp4',
      '.mkv',
      '.avi',
      '.mov',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v',
      '.mpg',
      '.mpeg',
      '.3gp',
      '.ts',
      '.m2ts',
      '.vob',
      '.rmvb',
      '.asf',
      '.divx',
    ];
    return videoExtensions.any((ext) => extension.toLowerCase() == ext);
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
