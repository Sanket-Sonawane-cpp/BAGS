import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/services/api_service.dart';

/// A named point the user can route from or to.
class Place {
  const Place({required this.name, required this.point});

  final String name;
  final LatLng point;
}

/// One turn-by-turn instruction: what to do at [location], and how far the
/// road runs after it before the next one.
class RouteStep {
  const RouteStep({
    required this.instruction,
    required this.location,
    required this.distanceMeters,
    required this.maneuverType,
    this.modifier,
  });

  final String instruction;

  /// Where the maneuver happens.
  final LatLng location;

  /// Length of the stretch that starts at [location], up to the next step.
  final double distanceMeters;

  /// OSRM-style maneuver type (`turn`, `roundabout`, `arrive`, ...) and
  /// direction (`left`, `slight right`, ...), kept for picking an icon.
  /// OpenRouteService's numeric step types are mapped onto the same names.
  final String maneuverType;
  final String? modifier;
}

class NavRoute {
  const NavRoute({
    required this.points,
    required this.steps,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  /// The full road geometry, for drawing and for off-route checks.
  final List<LatLng> points;
  final List<RouteStep> steps;
  final double distanceMeters;
  final double durationSeconds;
}

/// Place search and driving routes from free OpenStreetMap services.
///
/// Routes come from OpenRouteService when there's an [orsApiKey] (free to
/// sign up for), because it can route around areas — which is how hazards
/// are avoided. Without one they come from the public OSRM server, which
/// needs no key but can't avoid anything; see [canAvoid].
///
/// The default endpoints are shared public servers: fine for a prototype, but
/// rate-limited (Nominatim allows at most one request per second, and forbids
/// search-as-you-type; OpenRouteService's free plan allows 40 routes a
/// minute). Point the base URLs at self-hosted instances before this sees
/// real traffic.
class RoutingService {
  RoutingService({
    http.Client? client,
    this.orsApiKey,
    this.routingBaseUrl = 'https://router.project-osrm.org',
    this.orsBaseUrl = 'https://api.openrouteservice.org',
    this.geocodingBaseUrl = 'https://nominatim.openstreetmap.org',
  }) : _client = client ?? http.Client();

  final String? orsApiKey;
  final String routingBaseUrl;
  final String orsBaseUrl;
  final String geocodingBaseUrl;
  final http.Client _client;

  /// Whether [routes] can take `avoid` points: only with OpenRouteService.
  bool get canAvoid => orsApiKey?.isNotEmpty ?? false;

  /// How much road around each `avoid` point is ruled out. Covers the
  /// reporting phone's GPS error without closing off parallel streets.
  static const double avoidRadiusMeters = 60;

  static const Duration _timeout = Duration(seconds: 10);

  /// Nominatim's usage policy rejects requests without an identifying agent.
  static const Map<String, String> _headers = {
    'User-Agent': 'bags/0.1 (io.github.aditya692005.bags)',
  };

  /// Places matching [query], ranked nearest-first around [near] when given.
  Future<List<Place>> search(String query, {LatLng? near}) async {
    final params = {
      'q': query,
      'format': 'jsonv2',
      'limit': '8',
      // Biases (but does not restrict) results to roughly a 50 km box, so
      // "MG Road" finds the local one rather than one across the country.
      if (near != null)
        'viewbox':
            '${near.longitude - 0.5},${near.latitude + 0.5},'
            '${near.longitude + 0.5},${near.latitude - 0.5}',
    };
    final body = await _get(
      Uri.parse('$geocodingBaseUrl/search').replace(queryParameters: params),
    );

    return (jsonDecode(body) as List<dynamic>).map((raw) {
      final json = raw as Map<String, dynamic>;
      return Place(
        name: json['display_name'].toString(),
        point: LatLng(
          double.parse(json['lat'].toString()),
          double.parse(json['lon'].toString()),
        ),
      );
    }).toList();
  }

  /// The fastest driving route from [from] to [to].
  Future<NavRoute> route(LatLng from, LatLng to) async =>
      (await routes(from, to)).first;

  /// Driving routes from [from] to [to], fastest first.
  ///
  /// [via] forces the route through those points, in order, e.g. to detour
  /// around a hazard. With [alternatives], OSRM may also return a couple of
  /// other reasonable routes; it only does that when there are no [via]
  /// points, and OpenRouteService routes ignore it. [avoid] keeps the route
  /// [avoidRadiusMeters] clear of each point, and needs [canAvoid].
  Future<List<NavRoute>> routes(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
    bool alternatives = false,
    List<LatLng> avoid = const [],
  }) async {
    if (canAvoid) return _orsRoutes(from, to, via: via, avoid: avoid);
    if (avoid.isNotEmpty) {
      throw ArgumentError('Avoiding points needs an OpenRouteService key');
    }

    // OSRM takes coordinates as lng,lat — the reverse of LatLng's order.
    final coords = [
      from,
      ...via,
      to,
    ].map((p) => '${p.longitude},${p.latitude}').join(';');
    final body = await _get(
      Uri.parse('$routingBaseUrl/route/v1/driving/$coords').replace(
        queryParameters: {
          'overview': 'full',
          'geometries': 'geojson',
          'steps': 'true',
          if (alternatives && via.isEmpty) 'alternatives': 'true',
        },
      ),
    );

    final json = jsonDecode(body) as Map<String, dynamic>;
    final routes = json['routes'] as List<dynamic>? ?? const [];
    if (json['code'] != 'Ok' || routes.isEmpty) {
      throw ApiException('No route found (${json['code']})');
    }

    return [for (final r in routes) _parseRoute(r as Map<String, dynamic>)];
  }

  static NavRoute _parseRoute(Map<String, dynamic> route) {
    final geometry = route['geometry'] as Map<String, dynamic>;
    final legs = route['legs'] as List<dynamic>;

    // Each via point splits the route into legs, and OSRM ends every leg with
    // "arrive" and starts the next with "depart". Only the real start and
    // end should say that, so the ones at via points are dropped.
    final steps = <RouteStep>[];
    for (var i = 0; i < legs.length; i++) {
      final leg = legs[i] as Map<String, dynamic>;
      for (final raw in leg['steps'] as List<dynamic>) {
        final step = _parseStep(raw as Map<String, dynamic>);
        if (i > 0 && step.maneuverType == 'depart') continue;
        if (i < legs.length - 1 && step.maneuverType == 'arrive') continue;
        steps.add(step);
      }
    }

    return NavRoute(
      points: [
        for (final c in geometry['coordinates'] as List<dynamic>)
          _lngLat(c as List<dynamic>),
      ],
      steps: steps,
      distanceMeters: (route['distance'] as num).toDouble(),
      durationSeconds: (route['duration'] as num).toDouble(),
    );
  }

  Future<List<NavRoute>> _orsRoutes(
    LatLng from,
    LatLng to, {
    required List<LatLng> via,
    required List<LatLng> avoid,
  }) async {
    final body = await _post(
      Uri.parse('$orsBaseUrl/v2/directions/driving-car/geojson'),
      {
        // lng,lat order, like OSRM.
        'coordinates': [
          for (final p in [from, ...via, to]) [p.longitude, p.latitude],
        ],
        'instructions': true,
        'units': 'm',
        'language': 'en',
        if (avoid.isNotEmpty)
          'options': {
            'avoid_polygons': {
              'type': 'MultiPolygon',
              'coordinates': [
                for (final p in avoid) [_circle(p, avoidRadiusMeters)],
              ],
            },
          },
      },
      headers: {'Authorization': orsApiKey!},
    );

    final json = jsonDecode(body) as Map<String, dynamic>;
    final features = json['features'] as List<dynamic>? ?? const [];
    if (features.isEmpty) throw const ApiException('No route found');
    return [
      for (final f in features) _parseOrsRoute(f as Map<String, dynamic>),
    ];
  }

  static NavRoute _parseOrsRoute(Map<String, dynamic> feature) {
    final geometry = feature['geometry'] as Map<String, dynamic>;
    final points = [
      for (final c in geometry['coordinates'] as List<dynamic>)
        _lngLat(c as List<dynamic>),
    ];
    final properties = feature['properties'] as Map<String, dynamic>;
    final summary = properties['summary'] as Map<String, dynamic>? ?? const {};
    final segments = properties['segments'] as List<dynamic>? ?? const [];

    // One segment per leg between via points; as with OSRM, only the real
    // start and end should depart and arrive.
    final steps = <RouteStep>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i] as Map<String, dynamic>;
      for (final raw in segment['steps'] as List<dynamic>? ?? const []) {
        final json = raw as Map<String, dynamic>;
        final (type, modifier) = _orsManeuver((json['type'] as num).toInt());
        if (i > 0 && type == 'depart') continue;
        if (i < segments.length - 1 && type == 'arrive') continue;
        final start = ((json['way_points'] as List<dynamic>).first as num)
            .toInt();
        steps.add(
          RouteStep(
            instruction: json['instruction'].toString(),
            location: points[math.min(start, points.length - 1)],
            distanceMeters: (json['distance'] as num? ?? 0).toDouble(),
            maneuverType: type,
            modifier: modifier,
          ),
        );
      }
    }

    return NavRoute(
      points: points,
      steps: steps,
      // Both are left out of the summary for a zero-length route.
      distanceMeters: (summary['distance'] as num? ?? 0).toDouble(),
      durationSeconds: (summary['duration'] as num? ?? 0).toDouble(),
    );
  }

  /// OpenRouteService's numeric step type as an OSRM-style type and
  /// modifier, so icons and arrival work the same for both.
  static (String, String?) _orsManeuver(int type) => switch (type) {
    0 => ('turn', 'left'),
    1 => ('turn', 'right'),
    2 => ('turn', 'sharp left'),
    3 => ('turn', 'sharp right'),
    4 => ('turn', 'slight left'),
    5 => ('turn', 'slight right'),
    7 || 8 => ('roundabout', null),
    9 => ('turn', 'uturn'),
    10 => ('arrive', null),
    11 => ('depart', null),
    12 => ('continue', 'slight left'),
    13 => ('continue', 'slight right'),
    _ => ('continue', 'straight'),
  };

  /// A closed ring of [lng, lat] pairs approximating a circle.
  static List<List<double>> _circle(LatLng center, double radiusMeters) {
    const sides = 12;
    const metersPerDegree = 111320.0;
    final dLat = radiusMeters / metersPerDegree;
    final dLng = dLat / math.cos(center.latitudeInRad);
    final ring = [
      for (var i = 0; i < sides; i++)
        [
          center.longitude + dLng * math.cos(2 * math.pi * i / sides),
          center.latitude + dLat * math.sin(2 * math.pi * i / sides),
        ],
    ];
    return [...ring, ring.first];
  }

  static LatLng _lngLat(List<dynamic> c) =>
      LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());

  static RouteStep _parseStep(Map<String, dynamic> json) {
    final maneuver = json['maneuver'] as Map<String, dynamic>;
    final type = maneuver['type'].toString();
    final modifier = maneuver['modifier']?.toString();
    final road = json['name']?.toString() ?? '';

    return RouteStep(
      instruction: _describe(type, modifier, road),
      location: _lngLat(maneuver['location'] as List<dynamic>),
      distanceMeters: (json['distance'] as num).toDouble(),
      maneuverType: type,
      modifier: modifier,
    );
  }

  /// Human wording for an OSRM maneuver. OSRM returns structured maneuvers,
  /// not sentences, so the phrasing is built here.
  static String _describe(String type, String? modifier, String road) {
    final onto = road.isEmpty ? '' : ' onto $road';
    final direction = modifier ?? 'straight';
    return switch (type) {
      'depart' => road.isEmpty ? 'Head out' : 'Head out on $road',
      'arrive' => 'Arrive at your destination',
      'roundabout' || 'rotary' => 'Enter the roundabout and exit$onto',
      'merge' => 'Merge$onto',
      'on ramp' => 'Take the ramp$onto',
      'off ramp' => 'Take the exit$onto',
      'fork' => 'Keep $direction at the fork$onto',
      'end of road' => 'Turn $direction at the end of the road$onto',
      'continue' || 'new name' =>
        direction == 'straight' ? 'Continue$onto' : 'Keep $direction$onto',
      _ =>
        direction == 'straight'
            ? 'Go straight$onto'
            : direction == 'uturn'
            ? 'Make a U-turn$onto'
            : 'Turn $direction$onto',
    };
  }

  Future<String> _get(Uri uri) =>
      _send(uri, () => _client.get(uri, headers: _headers));

  Future<String> _post(
    Uri uri,
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) => _send(
    uri,
    () => _client.post(
      uri,
      headers: {..._headers, ...headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  Future<String> _send(
    Uri uri,
    Future<http.Response> Function() request,
  ) async {
    final http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on Exception catch (error) {
      throw ApiException('Could not reach ${uri.host}: $error');
    }
    if (response.statusCode != 200) {
      throw ApiException(
        '${uri.host} rejected the request${_reason(response.body)}',
        statusCode: response.statusCode,
      );
    }
    return response.body;
  }

  /// `": <message>"` from an error body, e.g. OpenRouteService's
  /// `{"error": {"code": 2009, "message": "Route could not be found"}}`,
  /// or nothing if there isn't one.
  static String _reason(String body) {
    try {
      final error = (jsonDecode(body) as Map<String, dynamic>)['error'];
      final message = error is Map ? error['message'] : error;
      return message == null ? '' : ': $message';
    } on Object {
      return '';
    }
  }

  void dispose() => _client.close();
}
