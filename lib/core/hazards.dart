import 'package:flutter/material.dart';

/// How a hazard class looks everywhere in the UI, so an accident is the same
/// red car on the live overlay, in the alert banner and in history.
class HazardStyle {
  const HazardStyle({
    required this.label,
    required this.icon,
    required this.color,
    this.isHazard = true,
    this.blocksRoad = false,
  });

  final String label;
  final IconData icon;
  final Color color;

  /// False for classes that mean "all clear", such as `non_accident`.
  final bool isHazard;

  /// Whether it's worth driving a different way to avoid. A pothole only
  /// earns a warning; an accident or a flood earns a reroute. False for
  /// unknown classes, so a new model label can't start moving cars around
  /// before anyone has decided what it means.
  final bool blocksRoad;
}

const Map<String, HazardStyle> _styles = {
  'accident': HazardStyle(
    label: 'Accident',
    icon: Icons.car_crash,
    color: Color(0xFFE53935),
    blocksRoad: true,
  ),
  'fallen_object': HazardStyle(
    label: 'Fallen object',
    icon: Icons.warning_rounded,
    color: Color(0xFFFB8C00),
    blocksRoad: true,
  ),
  'flood': HazardStyle(
    label: 'Flood',
    icon: Icons.flood,
    color: Color(0xFF1E88E5),
    blocksRoad: true,
  ),
  'pothole': HazardStyle(
    label: 'Pothole',
    icon: Icons.report,
    color: Color(0xFF8D6E63),
  ),
  'non_accident': HazardStyle(
    label: 'Clear road',
    icon: Icons.check_circle,
    color: Color(0xFF43A047),
    isHazard: false,
  ),
};

/// Style for a model/server class name. Unknown classes (a retrained model
/// with new labels, an old server alert) still render, just generically.
HazardStyle hazardStyle(String type) =>
    _styles[type] ??
    HazardStyle(
      label: type.replaceAll('_', ' '),
      icon: Icons.warning_amber_rounded,
      color: const Color(0xFF757575),
    );

/// Renders a distance the way a driver reads a road sign.
///
/// Metre precision is noise at speed, so anything past 1 km is shown in
/// kilometres and shorter distances are rounded to the nearest 10 m.
String formatDistance(double meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 10).round() * 10} m';
}

/// "just now", "4 min ago", "2 h ago", or a date past a day.
String formatAgo(DateTime time, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(time);
  if (elapsed.inSeconds < 60) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours} h ago';
  final local = time.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}
