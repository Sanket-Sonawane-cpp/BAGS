import 'package:bags/features/navigation/route_progress.dart';
import 'package:bags/features/navigation/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// An L-shaped route: ~1.1 km north along a meridian, then ~1.1 km east.
/// 0.01° of latitude is ~1113 m.
final _corner = const LatLng(0.01, 0);
final _route = NavRoute(
  points: const [
    LatLng(0, 0),
    LatLng(0.005, 0),
    LatLng(0.01, 0),
    LatLng(0.01, 0.005),
    LatLng(0.01, 0.01),
  ],
  steps: [
    const RouteStep(
      instruction: 'Head out',
      location: LatLng(0, 0),
      distanceMeters: 1113,
      maneuverType: 'depart',
    ),
    RouteStep(
      instruction: 'Turn right',
      location: _corner,
      distanceMeters: 1113,
      maneuverType: 'turn',
      modifier: 'right',
    ),
    const RouteStep(
      instruction: 'Arrive',
      location: LatLng(0.01, 0.01),
      distanceMeters: 0,
      maneuverType: 'arrive',
    ),
  ],
  distanceMeters: 2226,
  durationSeconds: 200,
);

void main() {
  test('at the start, the next maneuver is the first turn', () {
    final update = RouteProgress(_route).update(const LatLng(0, 0));
    expect(update.nextStep?.instruction, 'Turn right');
    expect(update.distanceToNextMeters, closeTo(1113, 5));
    expect(update.remainingMeters, closeTo(2226, 10));
    expect(update.offRouteMeters, lessThan(1));
    expect(update.arrived, isFalse);
  });

  test('past the corner, the next maneuver is arrival', () {
    final progress = RouteProgress(_route)..update(const LatLng(0.005, 0));
    final update = progress.update(const LatLng(0.01, 0.002));
    expect(update.nextStep?.maneuverType, 'arrive');
    expect(update.remainingMeters, closeTo(890, 10));
    expect(update.remainingSeconds, closeTo(80, 2));
  });

  test('a fix beside the road reports how far off route it is', () {
    // ~111 m east of the first leg.
    final update = RouteProgress(_route).update(const LatLng(0.003, 0.001));
    expect(update.offRouteMeters, closeTo(111, 2));
  });

  test('arrives within the arrival radius of the destination', () {
    final progress = RouteProgress(_route)..update(const LatLng(0.01, 0.005));
    expect(progress.update(const LatLng(0.01, 0.0099)).arrived, isTrue);
  });
}
