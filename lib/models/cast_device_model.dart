/// 投屏协议类型
enum CastProtocol { dlna, chromecast, airplay, miracast, unknown }

/// 设备连接状态
enum CastDeviceStatus { discovered, connecting, connected, disconnected, error }

/// 可投屏设备
class CastDevice {
  final String id;
  final String name;
  final CastProtocol protocol;
  final CastDeviceStatus status;
  final String host;
  final int port;
  final String location;
  final String serviceType;
  final String manufacturer;
  final String modelName;
  final String iconUrl;
  final bool supportsVideo;
  final bool supportsAudio;
  final bool supportsImage;
  final DateTime? lastSeen;

  const CastDevice({
    required this.id,
    required this.name,
    this.protocol = CastProtocol.unknown,
    this.status = CastDeviceStatus.discovered,
    this.host = '',
    this.port = 0,
    this.location = '',
    this.serviceType = '',
    this.manufacturer = '',
    this.modelName = '',
    this.iconUrl = '',
    this.supportsVideo = false,
    this.supportsAudio = false,
    this.supportsImage = false,
    this.lastSeen,
  });

  CastDevice copyWith({
    String? id,
    String? name,
    CastProtocol? protocol,
    CastDeviceStatus? status,
    String? host,
    int? port,
    String? location,
    String? serviceType,
    String? manufacturer,
    String? modelName,
    String? iconUrl,
    bool? supportsVideo,
    bool? supportsAudio,
    bool? supportsImage,
    DateTime? lastSeen,
  }) {
    return CastDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      status: status ?? this.status,
      host: host ?? this.host,
      port: port ?? this.port,
      location: location ?? this.location,
      serviceType: serviceType ?? this.serviceType,
      manufacturer: manufacturer ?? this.manufacturer,
      modelName: modelName ?? this.modelName,
      iconUrl: iconUrl ?? this.iconUrl,
      supportsVideo: supportsVideo ?? this.supportsVideo,
      supportsAudio: supportsAudio ?? this.supportsAudio,
      supportsImage: supportsImage ?? this.supportsImage,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'protocol': protocol.name,
      'status': status.name,
      'host': host,
      'port': port,
      'location': location,
      'serviceType': serviceType,
      'manufacturer': manufacturer,
      'modelName': modelName,
      'iconUrl': iconUrl,
      'supportsVideo': supportsVideo,
      'supportsAudio': supportsAudio,
      'supportsImage': supportsImage,
      'lastSeen': lastSeen?.toIso8601String(),
    };
  }

  factory CastDevice.fromJson(Map<String, dynamic> json) {
    return CastDevice(
      id: json['id'] as String,
      name: json['name'] as String,
      protocol: _parseProtocol(json['protocol'] as String?),
      status: _parseStatus(json['status'] as String?),
      host: json['host'] as String? ?? '',
      port: json['port'] as int? ?? 0,
      location: json['location'] as String? ?? '',
      serviceType: json['serviceType'] as String? ?? '',
      manufacturer: json['manufacturer'] as String? ?? '',
      modelName: json['modelName'] as String? ?? '',
      iconUrl: json['iconUrl'] as String? ?? '',
      supportsVideo: json['supportsVideo'] as bool? ?? false,
      supportsAudio: json['supportsAudio'] as bool? ?? false,
      supportsImage: json['supportsImage'] as bool? ?? false,
      lastSeen: json['lastSeen'] != null
          ? DateTime.parse(json['lastSeen'] as String)
          : null,
    );
  }

  static CastProtocol _parseProtocol(String? s) {
    switch (s) {
      case 'dlna':
        return CastProtocol.dlna;
      case 'chromecast':
        return CastProtocol.chromecast;
      case 'airplay':
        return CastProtocol.airplay;
      case 'miracast':
        return CastProtocol.miracast;
      default:
        return CastProtocol.unknown;
    }
  }

  static CastDeviceStatus _parseStatus(String? s) {
    switch (s) {
      case 'connecting':
        return CastDeviceStatus.connecting;
      case 'connected':
        return CastDeviceStatus.connected;
      case 'disconnected':
        return CastDeviceStatus.disconnected;
      case 'error':
        return CastDeviceStatus.error;
      default:
        return CastDeviceStatus.discovered;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastDevice && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// DLNA 服务描述
class DlnaServiceDescriptor {
  final String serviceType;
  final String serviceId;
  final String controlUrl;
  final String eventSubUrl;
  final String scpdUrl;

  const DlnaServiceDescriptor({
    required this.serviceType,
    required this.serviceId,
    required this.controlUrl,
    required this.eventSubUrl,
    required this.scpdUrl,
  });

  DlnaServiceDescriptor copyWith({
    String? serviceType,
    String? serviceId,
    String? controlUrl,
    String? eventSubUrl,
    String? scpdUrl,
  }) {
    return DlnaServiceDescriptor(
      serviceType: serviceType ?? this.serviceType,
      serviceId: serviceId ?? this.serviceId,
      controlUrl: controlUrl ?? this.controlUrl,
      eventSubUrl: eventSubUrl ?? this.eventSubUrl,
      scpdUrl: scpdUrl ?? this.scpdUrl,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serviceType': serviceType,
      'serviceId': serviceId,
      'controlUrl': controlUrl,
      'eventSubUrl': eventSubUrl,
      'scpdUrl': scpdUrl,
    };
  }

  factory DlnaServiceDescriptor.fromJson(Map<String, dynamic> json) {
    return DlnaServiceDescriptor(
      serviceType: json['serviceType'] as String,
      serviceId: json['serviceId'] as String,
      controlUrl: json['controlUrl'] as String,
      eventSubUrl: json['eventSubUrl'] as String,
      scpdUrl: json['scpdUrl'] as String,
    );
  }
}
