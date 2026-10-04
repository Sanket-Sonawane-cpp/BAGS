import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../core/hazards.dart';
import '../../core/models/alert_event.dart';
import 'route_progress.dart';
import 'routing_service.dart';

/// A reported hazard that lies on a route.
class HazardOnRoute {
  const HazardOnRoute(
    this.hazard,
    this.alongMeters, {
    this.sameDirection = true,
  });

  final AlertEvent hazard;

  /// How far along the route it is, comparable with [NavUpdate.alongMeters].
  final double alongMeters;

  /// Whether it was reported by a car going the same way as the route there
  /// (or nobody's direction is known). If not, it was only seen from the
  /// other direction, and may be on the far side of a divided road.
  final bool sameDirection;

  /// Whether to drive a different way to avoid it: [worthAvoiding], and
  /// reported from this route's direction. On an undivided road a hazard
  /// seen only by oncoming cars may still be in this lane, so it stays on
  /// the route as a warning rather than being ignored.
  bool get blocksThisRoute => sameDirection && worthAvoiding(hazard);
}

/// Hazards within [corridorMeters] of the route line, in the order the route
/// reaches them.
///
/// A hazard's position is the reporting car's GPS fix, which is routinely
/// 10–30 m off, so the corridor is wider than a road.
List<HazardOnRoute> hazardsOnRoute(
  NavRoute route,
  Iterable<AlertEvent> hazards, {
  double corridorMeters = 40,
}) {
  final progress = RouteProgress(route);
  final found = <HazardOnRoute>[];
  for (final hazard in hazards) {
    final at = progress.project(LatLng(hazard.latitude, hazard.longitude));
    if (at.offRouteMeters > corridorMeters) continue;
    // Anywhere near it, so a hazard right at a turn counts for the road
    // the route approaches it on.
    final directions = progress.directionsAround(at.alongMeters);
    found.add(
      HazardOnRoute(
        hazard,
        at.alongMeters,
        sameDirection:
            hazard.headings.isEmpty ||
            directions.any((d) => sameWay(d, hazard.headings)),
      ),
    );
  }
  found.sort((a, b) => a.alongMeters.compareTo(b.alongMeters));
  return found;
}

/// A route chosen by [HazardRoutePlanner], and the hazards it still passes.
class PlannedRoute {
  const PlannedRoute({
    required this.route,
    required this.onRoute,
    required this.avoidedCount,
  });

  final NavRoute route;

  /// Every hazard on [route], including ones that couldn't be avoided.
  final List<HazardOnRoute> onRoute;

  /// How many hazards on the fastest route this one steers clear of.
  final int avoidedCount;
}

/// Picks a driving route that avoids road-blocking hazards where it can.
///
/// Only confirmed hazards that block the road on the route's side
/// ([HazardOnRoute.blocksThisRoute]) are avoided; the rest, like potholes,
/// a single unconfirmed report, or one only seen by oncoming cars, stay on
/// the route as warnings.
///
/// With OpenRouteService ([RoutingService.canAvoid]) that's usually one
/// request: route around the blocking hazards at once. Its avoid areas
/// close a road both ways, so only hazards blocking the route's side go in,
/// with more added if the way around runs into them.
///
/// The public OSRM server can't be told "avoid this point", so without it
/// this works with what it can do: first ask for alternative routes, and if
/// all of them pass a hazard, force detours through a point beside the
/// first one. Requests go one at a time and stop at the first clean route,
/// keeping load on the shared demo server low.
class HazardRoutePlanner {
  const HazardRoutePlanner(this._routing);

  final RoutingService _routing;

  /// Hazards this close to the start or destination are left alone: there's
  /// no route around something you're already standing at, and trying just
  /// produces loops. It also covers a car's own fresh report right under it.
  static const double endpointClearanceMeters = 150;

  /// How far to the side of a hazard detour points go, tried in order.
  static const List<double> _detourOffsetsMeters = [400, 1000];

  /// The most avoid requests per plan, each adding the hazards the last way
  /// around ran into.
  static const int _maxAvoidRounds = 3;

  Future<PlannedRoute> plan(
    LatLng from,
    LatLng to,
    Iterable<AlertEvent> hazards,
  ) async {
    const distance = Distance();
    final avoidable = [
      for (final h in hazards)
        if (worthAvoiding(h) &&
            distance(from, _point(h)) > endpointClearanceMeters &&
            distance(to, _point(h)) > endpointClearanceMeters)
          h,
    ];

    final candidates = await _routing.routes(
      from,
      to,
      alternatives: !_routing.canAvoid,
    );
    final fastest = candidates.first;
    List<HazardOnRoute> blockingOn(NavRoute route) => [
      for (final h in hazardsOnRoute(route, avoidable))
        if (h.sameDirection) h,
    ];
    final blockingFastest = blockingOn(fastest);

    PlannedRoute result(NavRoute route, List<HazardOnRoute> blocking) =>
        PlannedRoute(
          route: route,
          onRoute: hazardsOnRoute(route, hazards),
          avoidedCount: math.max(0, blockingFastest.length - blocking.length),
        );

    if (blockingFastest.isEmpty) return result(fastest, blockingFastest);

    // Best so far: fewest hazards, then quickest.
    var best = fastest;
    var bestBlocking = blockingFastest;
    void consider(NavRoute route) {
      final blocking = blockingOn(route);
      if (blocking.length < bestBlocking.length ||
          (blocking.length == bestBlocking.length &&
              route.durationSeconds < best.durationSeconds)) {
        best = route;
        bestBlocking = blocking;
      }
    }

    if (_routing.canAvoid) {
      final avoid = {for (final h in blockingFastest) h.hazard};
      for (var round = 0; round < _maxAvoidRounds; round++) {
        final NavRoute around;
        try {
          around = (await _routing.routes(
            from,
            to,
            avoid: [for (final h in avoid) _point(h)],
          )).first;
        } on Exception {
          // No way around them all (e.g. the only bridge is blocked): keep
          // the best so far, with the hazards on it flagged.
          break;
        }
        consider(around);
        final more = [
          for (final h in blockingOn(around))
            if (!avoid.contains(h.hazard)) h.hazard,
        ];
        if (more.isEmpty) break;
        avoid.addAll(more);
      }
      return result(best, bestBlocking);
    }

    candidates.skip(1).forEach(consider);
    if (bestBlocking.isEmpty) return result(best, bestBlocking);

    final first = blockingFastest.first;
    for (final via in _detourPoints(fastest, first.hazard)) {
      try {
        consider((await _routing.routes(from, to, via: [via])).first);
      } on Exception {
        // One failed detour isn't fatal; the others may still work.
        continue;
      }
      if (bestBlocking.isEmpty) break;
    }
    return result(best, bestBlocking);
  }

  /// Points to either side of [hazard], perpendicular to the route's
  /// direction there, nearest first.
  static List<LatLng> _detourPoints(NavRoute route, AlertEvent hazard) {
    final at = _point(hazard);
    final (east, north) = _directionAt(route, at);
    return [
      for (final offset in _detourOffsetsMeters)
        for (final side in const [1, -1])
          _offset(at, -north * offset * side, east * offset * side),
    ];
  }

  /// Unit vector (east, north) of the route segment nearest [point].
  static (double, double) _directionAt(NavRoute route, LatLng point) {
    const distance = Distance();
    final points = route.points;
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      final d = distance(point, points[i]) + distance(point, points[i + 1]);
      if (d < bestDistance && points[i] != points[i + 1]) {
        bestDistance = d;
        best = i;
      }
    }
    if (points.length < 2) return (0, 1);

    final a = points[best];
    final b = points[best + 1];
    final east = (b.longitude - a.longitude) * math.cos(a.latitudeInRad);
    final north = b.latitude - a.latitude;
    final length = math.sqrt(east * east + north * north);
    return length == 0 ? (0, 1) : (east / length, north / length);
  }

  static LatLng _offset(LatLng from, double eastMeters, double northMeters) {
    const metersPerDegree = 111320;
    return LatLng(
      from.latitude + northMeters / metersPerDegree,
      from.longitude +
          eastMeters / (metersPerDegree * math.cos(from.latitudeInRad)),
    );
  }

  static LatLng _point(AlertEvent hazard) =>
      LatLng(hazard.latitude, hazard.longitude);
}
