/// A road obstruction detected on-device by the ML model.
///
/// Produced by the detection pipeline (Member A) and sent to the server by the
/// networking layer (Member B). This class is the contract between both halves
/// of the app — change it by agreement, not unilaterally.
class DetectionEvent {
  const DetectionEvent({
    required this.type,
    required this.confidence,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.heading,
  });

  factory DetectionEvent.fromJson(Map<String, dynamic> json) => DetectionEvent(
    type: json['type'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lng'] as num).toDouble(),
    timestamp: DateTime.parse(json['timestamp'] as String).toUtc(),
    heading: (json['heading'] as num?)?.toDouble(),
  );

  /// Obstruction class predicted by the model, e.g. 'pothole' or 'debris'.
  ///
  /// Kept as a String until the ML team finalises its label set; swap for an
  /// enum once the classes are fixed.
  final String type;

  /// Model confidence, in the range 0.0 to 1.0.
  final double confidence;

  /// Where the obstruction was detected.
  final double latitude;
  final double longitude;

  /// When the detection happened, always in UTC.
  final DateTime timestamp;

  /// Which way the car was travelling, in degrees clockwise from north, or
  /// null when unknown (standing still, no GPS bearing). The camera faces
  /// forward, so this says which side of a divided road the hazard was
  /// seen from.
  final double? heading;

  /// Keys are snake_case to match the FastAPI server.
  Map<String, dynamic> toJson() => {
    'type': type,
    'confidence': confidence,
    'lat': latitude,
    'lng': longitude,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'heading': ?heading,
  };

  @override
  String toString() =>
      'DetectionEvent($type ${(confidence * 100).toStringAsFixed(0)}% '
      'at $latitude, $longitude)';
}
