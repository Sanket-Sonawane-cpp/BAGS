import 'dart:convert';

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

  /// OSRM's maneuver type (`turn`, `roundabout`, `arrive`, ...) and direction
  /// (`left`, `slight right`, ...), kept for picking an icon.
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

/// Place search and driving routes from free OpenStreetMap services, so the
/// app needs no API key or billing account.
///
/// Both default endpoints are public demo servers: fine for a prototype, but
/// rate-limited (Nominatim allows at most one request per second, and forbids
/// search-as-you-type). Point [routingBaseUrl] / [geocodingBaseUrl] at a
/// self-hosted instance before this sees real traffic.
class RoutingService {
  RoutingService({
    http.Client? client,
    this.routingBaseUrl = 'https://router.project-osrm.org',
    this.geocodingBaseUrl = 'https://nominatim.openstreetmap.org',
  }) : _client = client ?? http.Client();

  final String routingBaseUrl;
  final String geocodingBaseUrl;
  final http.Client _client;

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
  Future<NavRoute> route(LatLng from, LatLng to) async {
    // OSRM takes coordinates as lng,lat — the reverse of LatLng's order.
    final coords =
        '${from.longitude},${from.latitude};'
        '${to.longitude},${to.latitude}';
    final body = await _get(
      Uri.parse('$routingBaseUrl/route/v1/driving/$coords').replace(
        queryParameters: const {
          'overview': 'full',
          'geometries': 'geojson',
          'steps': 'true',
        },
      ),
    );

    final json = jsonDecode(body) as Map<String, dynamic>;
    final routes = json['routes'] as List<dynamic>? ?? const [];
    if (json['code'] != 'Ok' || routes.isEmpty) {
      throw ApiException('No route found (${json['code']})');
    }

    final route = routes.first as Map<String, dynamic>;
    final geometry = route['geometry'] as Map<String, dynamic>;
    final leg = (route['legs'] as List<dynamic>).first as Map<String, dynamic>;

    return NavRoute(
      points: [
        for (final c in geometry['coordinates'] as List<dynamic>)
          _lngLat(c as List<dynamic>),
      ],
      steps: [
        for (final s in leg['steps'] as List<dynamic>)
          _parseStep(s as Map<String, dynamic>),
      ],
      distanceMeters: (route['distance'] as num).toDouble(),
      durationSeconds: (route['duration'] as num).toDouble(),
    );
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

  Future<String> _get(Uri uri) async {
    final http.Response response;
    try {
      response = await _client.get(uri, headers: _headers).timeout(_timeout);
    } on Exception catch (error) {
      throw ApiException('Could not reach ${uri.host}: $error');
    }
    if (response.statusCode != 200) {
      throw ApiException(
        '${uri.host} rejected the request',
        statusCode: response.statusCode,
      );
    }
    return response.body;
  }

  void dispose() => _client.close();
}
