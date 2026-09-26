import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'routing_service.dart';

/// Where the car is along a route, as of one GPS fix.
class NavUpdate {
  const NavUpdate({
    required this.nextStep,
    required this.distanceToNextMeters,
    required this.remainingMeters,
    required this.remainingSeconds,
    required this.offRouteMeters,
    required this.arrived,
  });

  /// The upcoming maneuver, or null once past the last one.
  final RouteStep? nextStep;
  final double distanceToNextMeters;
  final double remainingMeters;
  final double remainingSeconds;

  /// How far the fix is from the route line; large means a wrong turn.
  final double offRouteMeters;
  final bool arrived;
}

/// Tracks progress along a [NavRoute] from successive GPS fixes.
///
/// Positions are snapped to the nearest route segment and progress only ever
/// moves forward, so a road that later passes back near itself doesn't make
/// the instructions jump ahead. Pure Dart, no plugins — testable without a
/// device.
class RouteProgress {
  RouteProgress(this.route) {
    final points = route.points;
    _cumulative = List.filled(points.length, 0);
    for (var i = 1; i < points.length; i++) {
      _cumulative[i] =
          _cumulative[i - 1] + _metersBetween(points[i - 1], points[i]);
    }

    // Each maneuver sits on a route vertex; find it by searching forward from
    // the previous one so repeated positions map to the right occurrence.
    var from = 0;
    _stepVertex = [
      for (final step in route.steps)
        from = _nearestVertex(step.location, from),
    ];
  }

  final NavRoute route;

  /// Distance along the route to each vertex.
  late final List<double> _cumulative;

  /// The route vertex each step's maneuver happens at.
  late final List<int> _stepVertex;

  /// Index of the segment (vertex i to i+1) the car was last snapped to.
  int _segment = 0;

  /// How many segments ahead of the last known one to look for the car. Keeps
  /// the snap local, and a fix that's nowhere near this window is off-route.
  static const int _searchWindow = 150;

  /// Within this of the destination counts as arrived; GPS is rarely better.
  static const double arrivalRadiusMeters = 30;

  double get totalMeters => _cumulative.isEmpty ? 0 : _cumulative.last;

  NavUpdate update(LatLng position) {
    final points = route.points;
    if (points.length < 2) {
      return const NavUpdate(
        nextStep: null,
        distanceToNextMeters: 0,
        remainingMeters: 0,
        remainingSeconds: 0,
        offRouteMeters: 0,
        arrived: true,
      );
    }

    var bestSegment = _segment;
    var bestDistance = double.infinity;
    var bestFraction = 0.0;
    final end = math.min(_segment + _searchWindow, points.length - 1);
    for (var i = _segment; i < end; i++) {
      final (distance, fraction) = _toSegment(
        position,
        points[i],
        points[i + 1],
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        bestSegment = i;
        bestFraction = fraction;
      }
    }
    _segment = bestSegment;

    final along =
        _cumulative[bestSegment] +
        bestFraction *
            (_cumulative[bestSegment + 1] - _cumulative[bestSegment]);
    final remaining = math.max(0.0, totalMeters - along);

    // The next maneuver is the first one past the segment the car is on.
    RouteStep? next;
    var toNext = remaining;
    for (var i = 0; i < route.steps.length; i++) {
      if (_stepVertex[i] > bestSegment) {
        next = route.steps[i];
        toNext = _cumulative[_stepVertex[i]] - along;
        break;
      }
    }

    return NavUpdate(
      nextStep: next,
      distanceToNextMeters: math.max(0, toNext),
      remainingMeters: remaining,
      remainingSeconds: totalMeters == 0
          ? 0
          : route.durationSeconds * remaining / totalMeters,
      offRouteMeters: bestDistance,
      arrived: remaining <= arrivalRadiusMeters,
    );
  }

  int _nearestVertex(LatLng target, int from) {
    var best = from;
    var bestDistance = double.infinity;
    for (var i = from; i < route.points.length; i++) {
      final d = _metersBetween(target, route.points[i]);
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  /// Distance from [p] to segment [a]-[b], and how far along it (0..1) the
  /// closest point is.
  ///
  /// Uses a flat local projection: exact enough over the tens of meters a
  /// road segment spans, and far cheaper than great-circle math per fix.
  static (double, double) _toSegment(LatLng p, LatLng a, LatLng b) {
    final scale = math.cos(p.latitudeInRad);
    final ax = (a.longitude - p.longitude) * scale;
    final ay = a.latitude - p.latitude;
    final bx = (b.longitude - p.longitude) * scale;
    final by = b.latitude - p.latitude;
    final dx = bx - ax;
    final dy = by - ay;
    final lengthSq = dx * dx + dy * dy;
    final t = lengthSq == 0
        ? 0.0
        : ((-ax * dx - ay * dy) / lengthSq).clamp(0.0, 1.0);
    final cx = ax + t * dx;
    final cy = ay + t * dy;
    return (math.sqrt(cx * cx + cy * cy) * _metersPerDegree, t);
  }

  static const double _metersPerDegree = 111320;

  static double _metersBetween(LatLng a, LatLng b) {
    final scale = math.cos((a.latitudeInRad + b.latitudeInRad) / 2);
    final dx = (b.longitude - a.longitude) * scale;
    final dy = b.latitude - a.latitude;
    return math.sqrt(dx * dx + dy * dy) * _metersPerDegree;
  }
}
