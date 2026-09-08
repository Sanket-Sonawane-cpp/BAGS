/// A warning pushed from the server about an obstruction another car detected
/// nearby.
///
/// Consumed by the alerts layer (Member B). Arrives as a Firebase Cloud
/// Messaging data payload, so it is parsed rather than constructed locally.
class AlertEvent {
  const AlertEvent({
    required this.id,
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.distanceMeters,
  });

  /// Builds an alert from an FCM data payload.
  ///
  /// FCM delivers every data value as a String, so numeric fields are parsed
  /// leniently instead of cast — a plain `as double` works against a mocked
  /// JSON server but throws on a real push.
  factory AlertEvent.fromJson(Map<String, dynamic> json) => AlertEvent(
    id: json['id'].toString(),
    type: json['type'].toString(),
    latitude: _toDouble(json['lat']),
    longitude: _toDouble(json['lng']),
    timestamp: DateTime.parse(json['timestamp'].toString()).toUtc(),
    distanceMeters: _toDouble(json['distance_m']),
  );

  /// Server-assigned id, used to avoid showing the same alert twice.
  final String id;

  /// Obstruction class, matching [DetectionEvent.type].
  final String type;

  /// Where the obstruction is.
  final double latitude;
  final double longitude;

  /// When it was originally detected, always in UTC.
  final DateTime timestamp;

  /// How far this car is from the obstruction, as computed by the server.
  final double distanceMeters;

  static double _toDouble(Object? value) =>
      value is num ? value.toDouble() : double.parse(value.toString());

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'lat': latitude,
    'lng': longitude,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'distance_m': distanceMeters,
  };

  @override
  String toString() =>
      'AlertEvent($type ${distanceMeters.toStringAsFixed(0)}m away)';
}
