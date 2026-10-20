class HeatLocation {
  const HeatLocation({
    required this.id,
    required this.name,
    this.timezone,
    this.latitude,
    this.longitude,
  });

  final int id;
  final String name;
  final String? timezone;
  final double? latitude;
  final double? longitude;

  factory HeatLocation.fromJson(Map<String, dynamic> json) {
    return HeatLocation(
      id: _asInt(json['id']) ?? 0,
      name: (json['name'] ?? 'HeatGuard location').toString(),
      timezone: json['timezone']?.toString(),
      latitude: _asDouble(json['latitude']),
      longitude: _asDouble(json['longitude']),
    );
  }
}

class HeatDashboard {
  const HeatDashboard({
    required this.location,
    required this.locations,
    required this.dataStatus,
    required this.statusMessage,
    required this.recommendations,
    required this.disclaimer,
    required this.history,
    required this.alerts,
    required this.thresholds,
    this.current,
    this.activeAlert,
    this.lastSuccessAtDisplay,
    this.lastError,
    this.riskSourceUrl,
    this.staleAfterSeconds,
  });

  final HeatLocation location;
  final List<HeatLocation> locations;
  final String dataStatus;
  final String statusMessage;
  final List<String> recommendations;
  final String disclaimer;
  final HeatHistory history;
  final List<HeatAlert> alerts;
  final List<HeatThreshold> thresholds;
  final Map<String, dynamic>? current;
  final HeatAlert? activeAlert;
  final String? lastSuccessAtDisplay;
  final Map<String, dynamic>? lastError;
  final String? riskSourceUrl;
  final int? staleAfterSeconds;

  double? get temperatureC => _asDouble(current?['temperature_c']);
  double? get humidityPct => _asDouble(current?['humidity_pct']);
  double? get heatIndexC => _asDouble(current?['heat_index_c']);
  String? get observedAtDisplay => current?['observed_at_display']?.toString();
  String get riskLabel =>
      (current?['risk'] as Map<String, dynamic>?)?['label']?.toString() ??
      'Unknown';
  String get riskKey =>
      (current?['risk'] as Map<String, dynamic>?)?['key']?.toString() ??
      'unknown';

  factory HeatDashboard.fromJson(Map<String, dynamic> json) {
    final locationJson = json['location'];
    if (locationJson is! Map<String, dynamic>) {
      throw const FormatException('The dashboard response has no location.');
    }

    final current = json['current'];
    final activeAlert = json['active_alert'];
    final lastError = json['last_error'];
    return HeatDashboard(
      location: HeatLocation.fromJson(locationJson),
      locations: _mapList(json['locations'], HeatLocation.fromJson),
      dataStatus: (json['data_status'] ?? 'no_data').toString(),
      statusMessage: (json['status_message'] ?? '').toString(),
      recommendations: json['recommendations'] is List
          ? (json['recommendations'] as List)
                .map((item) => item.toString())
                .toList()
          : const [],
      disclaimer: (json['disclaimer'] ?? '').toString(),
      current: current is Map<String, dynamic> ? current : null,
      activeAlert: activeAlert is Map<String, dynamic>
          ? HeatAlert.fromJson(activeAlert)
          : null,
      alerts: _mapList(json['alerts'], HeatAlert.fromJson),
      history: HeatHistory.fromJson(
        json['history'] is Map<String, dynamic>
            ? json['history'] as Map<String, dynamic>
            : const {},
      ),
      thresholds: _mapList(json['thresholds'], HeatThreshold.fromJson),
      lastSuccessAtDisplay: json['last_success_at_display']?.toString(),
      lastError: lastError is Map<String, dynamic> ? lastError : null,
      riskSourceUrl: json['risk_source_url']?.toString(),
      staleAfterSeconds: _asInt(json['stale_after_seconds']),
    );
  }
}

class HeatHistory {
  const HeatHistory({required this.hours, required this.points});

  final int hours;
  final List<HeatHistoryPoint> points;

  factory HeatHistory.fromJson(Map<String, dynamic> json) => HeatHistory(
    hours: _asInt(json['hours']) ?? 24,
    points: _mapList(json['points'], HeatHistoryPoint.fromJson),
  );
}

class HeatHistoryPoint {
  const HeatHistoryPoint({
    required this.label,
    required this.observedAt,
    required this.riskKey,
    required this.riskLabel,
    required this.riskLevel,
    this.temperatureC,
    this.humidityPct,
    this.heatIndexC,
  });

  final String label;
  final String? observedAt;
  final String riskKey;
  final String riskLabel;
  final int? riskLevel;
  final double? temperatureC;
  final double? humidityPct;
  final double? heatIndexC;

  factory HeatHistoryPoint.fromJson(Map<String, dynamic> json) =>
      HeatHistoryPoint(
        label: (json['label'] ?? '').toString(),
        observedAt: json['observed_at']?.toString(),
        riskKey: (json['risk_key'] ?? 'unknown').toString(),
        riskLabel: (json['risk_label'] ?? 'Unknown').toString(),
        riskLevel: _asInt(json['risk_level']),
        temperatureC: _asDouble(json['temperature_c']),
        humidityPct: _asDouble(json['humidity_pct']),
        heatIndexC: _asDouble(json['heat_index_c']),
      );
}

class HeatAlert {
  const HeatAlert({
    required this.riskKey,
    required this.riskLabel,
    required this.message,
    required this.recommendations,
    this.heatIndexC,
    this.temperatureC,
    this.humidityPct,
    this.generatedAtDisplay,
    this.observedAtDisplay,
  });

  final String riskKey;
  final String riskLabel;
  final String message;
  final List<String> recommendations;
  final double? heatIndexC;
  final double? temperatureC;
  final double? humidityPct;
  final String? generatedAtDisplay;
  final String? observedAtDisplay;

  factory HeatAlert.fromJson(Map<String, dynamic> json) => HeatAlert(
    riskKey: (json['risk_key'] ?? 'unknown').toString(),
    riskLabel: (json['risk_label'] ?? 'Heat alert').toString(),
    message: (json['message'] ?? '').toString(),
    recommendations: json['recommendations'] is List
        ? (json['recommendations'] as List)
              .map((item) => item.toString())
              .toList()
        : const [],
    heatIndexC: _asDouble(json['heat_index_c']),
    temperatureC: _asDouble(json['temperature_c']),
    humidityPct: _asDouble(json['humidity_pct']),
    generatedAtDisplay: json['generated_at_display']?.toString(),
    observedAtDisplay: json['observed_at_display']?.toString(),
  );
}

class HeatThreshold {
  const HeatThreshold({
    required this.key,
    required this.label,
    required this.shortLabel,
    required this.level,
    required this.color,
    this.minC,
    this.maxC,
  });

  final String key;
  final String label;
  final String shortLabel;
  final int level;
  final String color;
  final double? minC;
  final double? maxC;

  factory HeatThreshold.fromJson(Map<String, dynamic> json) => HeatThreshold(
    key: (json['key'] ?? 'unknown').toString(),
    label: (json['label'] ?? 'Unknown').toString(),
    shortLabel: (json['short_label'] ?? json['label'] ?? 'Unknown').toString(),
    level: _asInt(json['level']) ?? 0,
    color: (json['color'] ?? '#728078').toString(),
    minC: _asDouble(json['min_c']),
    maxC: _asDouble(json['max_c']),
  );
}

class GeocodeResult {
  const GeocodeResult({
    required this.name,
    required this.displayName,
    required this.latitude,
    required this.longitude,
    required this.timezone,
    this.admin1,
    this.country,
  });

  final String name;
  final String displayName;
  final double latitude;
  final double longitude;
  final String timezone;
  final String? admin1;
  final String? country;

  factory GeocodeResult.fromJson(Map<String, dynamic> json) => GeocodeResult(
    name: (json['name'] ?? '').toString(),
    displayName: (json['display_name'] ?? json['name'] ?? '').toString(),
    latitude: _asDouble(json['latitude']) ?? 0,
    longitude: _asDouble(json['longitude']) ?? 0,
    timezone: (json['timezone'] ?? 'Asia/Manila').toString(),
    admin1: json['admin1']?.toString(),
    country: json['country']?.toString(),
  );
}

class AddressOption {
  const AddressOption({required this.code, required this.name});

  final String code;
  final String name;

  factory AddressOption.fromJson(Map<String, dynamic> json) => AddressOption(
    code: (json['code'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
  );
}

List<T> _mapList<T>(dynamic value, T Function(Map<String, dynamic>) parser) {
  if (value is! List) return const [];
  return value
      .whereType<Map<String, dynamic>>()
      .map(parser)
      .toList(growable: false);
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}
