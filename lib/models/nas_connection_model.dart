import 'package:freezed_annotation/freezed_annotation.dart';

part 'nas_connection_model.freezed.dart';
part 'nas_connection_model.g.dart';

/// NAS 协议
enum NasProtocol {
  @JsonValue('smb')
  smb,

  @JsonValue('ftp')
  ftp,

  @JsonValue('webdav')
  webdav,

  @JsonValue('nfs')
  nfs,
}

/// 连接状态
enum NasConnectionStatus {
  @JsonValue('disconnected')
  disconnected,

  @JsonValue('connecting')
  connecting,

  @JsonValue('connected')
  connected,

  @JsonValue('error')
  error,
}

/// NAS 连接配置
@freezed
class NasConnection with _$NasConnection {
  const factory NasConnection({
    required String id,
    required String name,
    required NasProtocol protocol,
    required String host,
    @Default(445) int port,
    @Default('') String username,
    @Default('') String password,
    @Default('') String domain, // SMB domain
    @Default('') String shareName, // SMB share
    @Default('/') String remotePath, // root path
    @Default(NasConnectionStatus.disconnected) NasConnectionStatus status,
    @Default('') String errorMessage,
    DateTime? lastConnected,
    @Default(false) bool savePassword,
  }) = _NasConnection;

  factory NasConnection.fromJson(Map<String, dynamic> json) =>
      _$NasConnectionFromJson(json);
}

/// NAS 远程文件项
@freezed
class NasFileItem with _$NasFileItem {
  const factory NasFileItem({
    required String name,
    required String path,
    @Default(false) bool isDirectory,
    @Default(0) int size,
    DateTime? modifiedTime,
    @Default('') String extension, // file extension
    @Default('') String mimeType,
  }) = _NasFileItem;

  factory NasFileItem.fromJson(Map<String, dynamic> json) =>
      _$NasFileItemFromJson(json);

  const NasFileItem._();

  /// 是否为支持的视频文件
  bool get isVideo {
    const videoExtensions = [
      '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv',
      '.webm', '.m4v', '.mpg', '.mpeg', '.3gp', '.ts',
      '.m2ts', '.vob', '.rmvb', '.asf', '.divx',
    ];
    return videoExtensions.any((ext) => extension.toLowerCase() == ext);
  }
}