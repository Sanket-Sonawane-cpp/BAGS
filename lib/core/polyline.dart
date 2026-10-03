import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// [points] with every point dropped that sits within [toleranceMeters] of
/// the line through its neighbours (Douglas–Peucker).
///
/// A routing engine's geometry has a point every few metres; this keeps the
/// shape of the road with a fraction of them, which matters when the route
/// rides along on every location ping.
List<LatLng> simplifyPolyline(List<LatLng> points, double toleranceMeters) {
  if (points.length < 3) return List.of(points);

  final keep = List<bool>.filled(points.length, false)
    ..[0] = true
    ..[points.length - 1] = true;
  // Explicit stack rather than recursion: a long route has thousands of
  // points, and a straight road would recurse once per point.
  final stack = <(int, int)>[(0, points.length - 1)];
  while (stack.isNotEmpty) {
    final (first, last) = stack.removeLast();
    var farthest = -1;
    var farthestMeters = toleranceMeters;
    for (var i = first + 1; i < last; i++) {
      final d = _offLine(points[i], points[first], points[last]);
      if (d > farthestMeters) {
        farthest = i;
        farthestMeters = d;
      }
    }
    if (farthest < 0) continue;
    keep[farthest] = true;
    stack
      ..add((first, farthest))
      ..add((farthest, last));
  }
  return [
    for (var i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
}

/// Metres from [p] to the segment [a]–[b], on a flat east/north grid around
/// [p] — accurate to well under a metre at road-segment scale.
double _offLine(LatLng p, LatLng a, LatLng b) {
  const metersPerDegree = 111320.0;
  final cosLat = math.cos(p.latitudeInRad);
  double x(LatLng q) => (q.longitude - p.longitude) * cosLat * metersPerDegree;
  double y(LatLng q) => (q.latitude - p.latitude) * metersPerDegree;

  final ax = x(a), ay = y(a);
  final dx = x(b) - ax, dy = y(b) - ay;
  final lengthSq = dx * dx + dy * dy;
  final t = lengthSq == 0
      ? 0.0
      : (-(ax * dx + ay * dy) / lengthSq).clamp(0.0, 1.0);
  final fx = ax + t * dx, fy = ay + t * dy;
  return math.sqrt(fx * fx + fy * fy);
}
