import 'dart:convert';

import 'package:bags/core/models/alert_event.dart';
import 'package:bags/core/polyline.dart';
import 'package:bags/core/services/api_service.dart';
import 'package:bags/features/navigation/hazard_routing.dart';
import 'package:bags/features/navigation/route_progress.dart';
import 'package:bags/features/navigation/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

/// A straight route north along a meridian. 0.01° of latitude is ~1113 m.
NavRoute _straight(List<LatLng> points, {double duration = 200}) => NavRoute(
  points: points,
  steps: [
    RouteStep(
      instruction: 'Head out',
      location: points.first,
      distanceMeters: 0,
      maneuverType: 'depart',
    ),
    RouteStep(
      instruction: 'Arrive',
      location: points.last,
      distanceMeters: 0,
      maneuverType: 'arrive',
    ),
  ],
  distanceMeters: 2226,
  durationSeconds: duration,
);

AlertEvent _hazard(String id, double lat, double lng) => AlertEvent(
  id: id,
  type: 'accident',
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.utc(2026),
  distanceMeters: 0,
);

const _from = LatLng(0, 0);
const _to = LatLng(0.02, 0);
final _direct = _straight(const [_from, LatLng(0.01, 0), _to]);

/// A route that bulges ~1.1 km east around the middle.
final _eastward = _straight(const [
  _from,
  LatLng(0.005, 0.01),
  LatLng(0.015, 0.01),
  _to,
], duration: 300);

/// Serves canned routes instead of calling OSRM, and records what it was
/// asked for.
class _FakeRouting extends RoutingService {
  _FakeRouting({required this.alternatives, this.detour});

  final List<NavRoute> alternatives;
  final NavRoute? detour;
  final List<List<LatLng>> viaRequests = [];

  @override
  Future<List<NavRoute>> routes(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
    bool alternatives = false,
    List<LatLng> avoid = const [],
  }) async {
    if (via.isEmpty) return this.alternatives;
    viaRequests.add(via);
    return [detour ?? this.alternatives.first];
  }
}

/// Like OpenRouteService: routes around `avoid` points when asked, or fails
/// when [around] is null (no way around).
class _FakeAvoidingRouting extends RoutingService {
  _FakeAvoidingRouting({this.around});

  final NavRoute? around;
  final List<List<LatLng>> avoidRequests = [];

  @override
  bool get canAvoid => true;

  @override
  Future<List<NavRoute>> routes(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
    bool alternatives = false,
    List<LatLng> avoid = const [],
  }) async {
    if (avoid.isEmpty) return [_direct];
    avoidRequests.add(avoid);
    final route = around;
    if (route == null) throw const ApiException('Route could not be found');
    return [route];
  }
}

void main() {
  group('RouteProgress.project', () {
    test('places a point beside the route by distance along it', () {
      final at = RouteProgress(_direct)
          .project(const LatLng(0.01, 0.0002)); // ~22 m east of the midpoint
      expect(at.alongMeters, closeTo(1113, 5));
      expect(at.offRouteMeters, closeTo(22, 3));
    });
  });

  group('hazardsOnRoute', () {
    test('keeps only hazards near the line, in route order', () {
      final found = hazardsOnRoute(_direct, [
        _hazard('far', 0.01, 0.003), // ~330 m off
        _hazard('late', 0.015, 0.0001),
        _hazard('early', 0.005, -0.0001),
      ]);
      expect(found.map((h) => h.hazard.id), ['early', 'late']);
    });
  });

  group('HazardRoutePlanner', () {
    final midHazard = _hazard('mid', 0.01, 0);

    test('keeps the fastest route when nothing is on it', () async {
      final plan = await HazardRoutePlanner(
        _FakeRouting(alternatives: [_direct, _eastward]),
      ).plan(_from, _to, [_hazard('elsewhere', 0.01, 0.05)]);
      expect(plan.route, same(_direct));
      expect(plan.avoidedCount, 0);
      expect(plan.onRoute, isEmpty);
    });

    test('takes a clean alternative over a blocked fastest route', () async {
      final routing = _FakeRouting(alternatives: [_direct, _eastward]);
      final plan = await HazardRoutePlanner(routing)
          .plan(_from, _to, [midHazard]);
      expect(plan.route, same(_eastward));
      expect(plan.avoidedCount, 1);
      expect(plan.onRoute, isEmpty);
      expect(routing.viaRequests, isEmpty);
    });

    test(
      'forces a detour beside the hazard when no alternative is clean',
      () async {
        final routing = _FakeRouting(
          alternatives: [_direct],
          detour: _eastward,
        );
        final plan = await HazardRoutePlanner(routing)
            .plan(_from, _to, [midHazard]);
        expect(plan.route, same(_eastward));

        // First detour point: 400 m to the side of the hazard, perpendicular
        // to a north-running road, so due west or east of it.
        final via = routing.viaRequests.first.single;
        expect(via.latitude, closeTo(0.01, 1e-9));
        expect(const Distance()(via, const LatLng(0.01, 0)), closeTo(400, 2));
      },
    );

    test('reports a hazard it cannot get around', () async {
      final plan = await HazardRoutePlanner(
        _FakeRouting(alternatives: [_direct]),
      ).plan(_from, _to, [midHazard]);
      expect(plan.route, same(_direct));
      expect(plan.avoidedCount, 0);
      expect(plan.onRoute.single.hazard.id, 'mid');
    });

    test('only warns about hazards that do not block the road', () async {
      final routing = _FakeRouting(alternatives: [_direct, _eastward]);
      final pothole = AlertEvent(
        id: 'pothole',
        type: 'pothole',
        latitude: 0.01,
        longitude: 0,
        timestamp: DateTime.utc(2026),
        distanceMeters: 0,
      );
      final plan = await HazardRoutePlanner(routing)
          .plan(_from, _to, [pothole]);
      expect(plan.route, same(_direct));
      expect(plan.avoidedCount, 0);
      expect(plan.onRoute.single.hazard.id, 'pothole');
    });

    test('asks a routing engine that can avoid areas to avoid them', () async {
      final routing = _FakeAvoidingRouting(around: _eastward);
      final plan = await HazardRoutePlanner(routing)
          .plan(_from, _to, [midHazard, _hazard('off', 0.01, 0.05)]);
      expect(plan.route, same(_eastward));
      expect(plan.avoidedCount, 1);
      expect(routing.avoidRequests.single, hasLength(2));
    });

    test('keeps the fastest route when no route avoids them', () async {
      final plan = await HazardRoutePlanner(_FakeAvoidingRouting())
          .plan(_from, _to, [midHazard]);
      expect(plan.route, same(_direct));
      expect(plan.onRoute.single.hazard.id, 'mid');
    });

    test('leaves hazards at the start alone', () async {
      final routing = _FakeRouting(alternatives: [_direct, _eastward]);
      final plan = await HazardRoutePlanner(routing)
          .plan(_from, _to, [_hazard('here', 0.0005, 0)]); // ~55 m away
      expect(plan.route, same(_direct));
      expect(routing.viaRequests, isEmpty);
    });
  });

  group('RoutingService.routes', () {
    test('joins via-point legs without a mid-route arrive/depart', () async {
      Map<String, dynamic> step(String type, List<double> at) => {
        'maneuver': {'type': type, 'location': at},
        'name': '',
        'distance': 100,
      };
      late Uri requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response(
          jsonEncode({
            'code': 'Ok',
            'routes': [
              {
                'distance': 200,
                'duration': 20,
                'geometry': {
                  'coordinates': [
                    [0, 0],
                    [0.001, 0],
                    [0.002, 0],
                  ],
                },
                'legs': [
                  {
                    'steps': [
                      step('depart', [0, 0]),
                      step('arrive', [0.001, 0]),
                    ],
                  },
                  {
                    'steps': [
                      step('depart', [0.001, 0]),
                      step('turn', [0.0015, 0]),
                      step('arrive', [0.002, 0]),
                    ],
                  },
                ],
              },
            ],
          }),
          200,
        );
      });

      final routes = await RoutingService(client: client).routes(
        const LatLng(0, 0),
        const LatLng(0, 0.002),
        via: const [LatLng(0, 0.001)],
        alternatives: true,
      );

      expect(routes.single.steps.map((s) => s.maneuverType), [
        'depart',
        'turn',
        'arrive',
      ]);
      expect(requested.path, endsWith('0.0,0.0;0.001,0.0;0.002,0.0'));
      // OSRM ignores alternatives with via points; don't ask for them.
      expect(requested.queryParameters, isNot(contains('alternatives')));
    });

    test('asks OpenRouteService to avoid areas, and reads its route', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'features': [
              {
                'geometry': {
                  'coordinates': [
                    [0, 0],
                    [0.001, 0],
                    [0.002, 0],
                  ],
                },
                'properties': {
                  'summary': {'distance': 222.0, 'duration': 30.0},
                  'segments': [
                    {
                      'steps': [
                        {
                          'type': 11,
                          'instruction': 'Head east',
                          'distance': 111.0,
                          'way_points': [0, 1],
                        },
                        {
                          'type': 0,
                          'instruction': 'Turn left onto MG Road',
                          'distance': 111.0,
                          'way_points': [1, 2],
                        },
                        {
                          'type': 10,
                          'instruction': 'Arrive',
                          'distance': 0.0,
                          'way_points': [2, 2],
                        },
                      ],
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final route =
          (await RoutingService(client: client, orsApiKey: 'k').routes(
            const LatLng(0, 0),
            const LatLng(0, 0.002),
            avoid: const [LatLng(0.0005, 0.001)],
          )).single;

      expect(sent.headers['Authorization'], 'k');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      final polygons =
          body['options']['avoid_polygons']['coordinates'] as List<dynamic>;
      final ring = (polygons.single as List<dynamic>).single as List<dynamic>;
      expect(ring.first, ring.last); // closed
      expect(route.distanceMeters, 222);
      expect(route.steps[1].instruction, 'Turn left onto MG Road');
      expect(route.steps[1].modifier, 'left');
      expect(route.steps[1].location, const LatLng(0, 0.001));
      expect(route.steps.last.maneuverType, 'arrive');
    });
  });

  group('simplifyPolyline', () {
    test('drops points on a straight line, keeps corners', () {
      final simplified = simplifyPolyline(const [
        LatLng(0, 0),
        LatLng(0.001, 0),
        LatLng(0.002, 0),
        LatLng(0.002, 0.002),
      ], 10);
      expect(simplified, const [
        LatLng(0, 0),
        LatLng(0.002, 0),
        LatLng(0.002, 0.002),
      ]);
    });
  });
}
