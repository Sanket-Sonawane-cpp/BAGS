import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/alert_event.dart';
import '../models/detection_event.dart';

/// Thrown when the server rejects a request or cannot be reached.
///
/// Networking failures are expected and routine in a moving car, so callers
/// should treat these as normal control flow rather than crashes.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($message${statusCode == null ? '' : ', '
      'status $statusCode'})';
}

/// Talks to the alert server.
///
/// Only small JSON events cross this boundary — never camera frames. Detection
/// runs on-device precisely so this stays cheap enough for cellular data.
class ApiService {
  ApiService({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  /// Root of the server, e.g. `http://192.168.1.5:8000`.
  ///
  /// Must be the laptop's LAN address, not `localhost` — `localhost` on the
  /// phone means the phone itself.
  final String baseUrl;

  final http.Client _client;

  /// Requests are abandoned after this long.
  ///
  /// Without a timeout a request on a dead cellular connection hangs until the
  /// OS gives up, which can be minutes.
  static const Duration _timeout = Duration(seconds: 10);

  /// Reports an obstruction this car detected.
  ///
  /// Returns the server-assigned id.
  Future<String> postDetection(DetectionEvent event) async {
    final response = await _post('/detection', event.toJson());
    return (jsonDecode(response) as Map<String, dynamic>)['id'].toString();
  }

  /// Tells the server how to reach this car with a push.
  ///
  /// Must be called again whenever FCM reissues the token, otherwise the server
  /// keeps pushing to a dead address and alerts simply stop arriving with no
  /// visible error anywhere.
  Future<void> registerDevice({
    required String carId,
    required String fcmToken,
  }) async {
    await _post('/register', {'car_id': carId, 'fcm_token': fcmToken});
  }

  /// Reports where this car currently is, so the server knows to alert it about
  /// obstructions reported nearby.
  ///
  /// [fcmToken] rides along on the same ping rather than a separate
  /// register-token call, so a token refresh reaches the server on the very
  /// next periodic ping with no extra plumbing — see [LocationPinger]. Omit
  /// it (leave null) only before the token is available yet, e.g. while FCM
  /// permission is still being requested on first launch.
  Future<void> postLocation({
    required String carId,
    required double latitude,
    required double longitude,
    String? fcmToken,
  }) async {
    await _post('/location', {
      'car_id': carId,
      'lat': latitude,
      'lng': longitude,
      if (fcmToken != null) 'fcm_token': fcmToken,
    });
  }

  /// Obstructions near a point.
  ///
  /// Live alerts arrive by FCM push; this exists for testing the alert UI
  /// without depending on push delivery, and as a catch-up fetch when the app
  /// starts mid-journey.
  Future<List<AlertEvent>> fetchNearbyAlerts({
    required double latitude,
    required double longitude,
    double radiusMeters = 2000,
  }) async {
    final uri = Uri.parse('$baseUrl/alerts').replace(
      queryParameters: {
        'lat': '$latitude',
        'lng': '$longitude',
        'radius_m': '$radiusMeters',
      },
    );

    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_timeout);
    } on Exception catch (error) {
      throw ApiException('Could not reach the server: $error');
    }

    if (response.statusCode != 200) {
      throw ApiException('Failed to fetch alerts', statusCode: response.statusCode);
    }

    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded
        .map((json) => AlertEvent.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Cheap check that the server is reachable, for a settings/debug screen.
  Future<bool> isReachable() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } on Exception {
      return false;
    }
  }

  Future<String> _post(String path, Map<String, dynamic> body) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on Exception catch (error) {
      throw ApiException('Could not reach the server: $error');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'Server rejected $path: ${response.body}',
        statusCode: response.statusCode,
      );
    }

    return response.body;
  }

  /// Releases the underlying HTTP connections.
  void dispose() => _client.close();
}
