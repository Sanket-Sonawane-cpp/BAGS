import 'dart:async';

import 'package:latlong2/latlong.dart';

import 'api_service.dart';
import 'location_service.dart';

/// Periodically reports this car's position (and current FCM token) to the
/// server, so it knows where to route obstruction alerts.
///
/// docs/PROJECT_CONTEXT.md calls for "location pings every 15-30s ... no
/// continuous streaming" — this is that ping loop. A time-based
/// [Timer.periodic] rather than [LocationService]'s distance-filtered
/// stream: the doc's cadence is explicitly time-based, and a car stopped at
/// a light should still refresh its last-seen time on the server, not go
/// silent just because it hasn't moved [LocationService]'s 20m threshold.
class LocationPinger {
  LocationPinger({
    required ApiService apiService,
    required LocationService locationService,
    required String carId,
    this.interval = const Duration(seconds: 20),
  }) : _apiService = apiService,
       _locationService = locationService,
       _carId = carId;

  final ApiService _apiService;
  final LocationService _locationService;
  final String _carId;
  final Duration interval;

  Timer? _timer;
  String? Function()? _tokenProvider;
  List<LatLng>? Function()? _routeProvider;

  bool get isRunning => _timer != null;

  /// Starts pinging immediately, then every [interval].
  ///
  /// [tokenProvider] and [routeProvider] are called fresh on every tick
  /// rather than read once here, so a token that arrives — or rotates — or
  /// a route started after [start] is picked up on the very next ping with
  /// no restart needed.
  void start({
    String? Function()? tokenProvider,
    List<LatLng>? Function()? routeProvider,
  }) {
    if (_timer != null) return;
    _tokenProvider = tokenProvider;
    _routeProvider = routeProvider;
    _timer = Timer.periodic(interval, (_) => _tick());
    unawaited(_tick());
  }

  /// Pings now rather than at the next tick, e.g. so the server learns
  /// about a route the moment navigation starts. No-op unless running.
  void pingNow() {
    if (_timer != null) unawaited(_tick());
  }

  Future<void> _tick() async {
    try {
      final position = await _locationService.getCurrentPosition();
      await _apiService.postLocation(
        carId: _carId,
        latitude: position.latitude,
        longitude: position.longitude,
        fcmToken: _tokenProvider?.call(),
        route: _routeProvider?.call(),
      );
    } on Exception {
      // Routine on a moving-car connection, or before a GPS fix exists yet;
      // the next tick tries again rather than surfacing this anywhere.
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
