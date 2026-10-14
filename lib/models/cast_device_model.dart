import 'package:freezed_annotation/freezed_annotation.dart';

part 'cast_device_model.freezed.dart';
part 'cast_device_model.g.dart';

/// 投屏协议类型
enum CastProtocol {
  @JsonValue('dlna')
  dlna,

  @JsonValue('chromecast')
  chromecast,

  @JsonValue('airplay')
  airplay,

  @JsonValue('miracast')
  miracast,

  @JsonValue('unknown')
  unknown,
}

/// 设备连接状态
enum CastDeviceStatus {
  @JsonValue('discovered')
  discovered,

  @JsonValue('connecting')
  connecting,

  @JsonValue('connected')
  connected,

  @JsonValue('disconnected')
  disconnected,

  @JsonValue('error')
  error,
}

/// 可投屏设备
@freezed
class CastDevice with _$CastDevice {
  const factory CastDevice({
    required String id,
    required String name,
    @Default(CastProtocol.unknown) CastProtocol protocol,
    @Default(CastDeviceStatus.discovered) CastDeviceStatus status,
    @Default('') String host,
    @Default(0) int port,
    @Default('') String location, // DLNA DDD URL
    @Default('') String serviceType,
    @Default('') String manufacturer,
    @Default('') String modelName,
    @Default('') String iconUrl,
    @Default(false) bool supportsVideo,
    @Default(false) bool supportsAudio,
    @Default(false) bool supportsImage,
    DateTime? lastSeen,
  }) = _CastDevice;

  factory CastDevice.fromJson(Map<String, dynamic> json) =>
      _$CastDeviceFromJson(json);
}

/// DLNA 服务描述
@freezed
class DlnaServiceDescriptor with _$DlnaServiceDescriptor {
  const factory DlnaServiceDescriptor({
    required String serviceType,
    required String serviceId,
    required String controlUrl,
    required String eventSubUrl,
    required String scpdUrl,
  }) = _DlnaServiceDescriptor;

  factory DlnaServiceDescriptor.fromJson(Map<String, dynamic> json) =>
      _$DlnaServiceDescriptorFromJson(json);
}