import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api_service.dart';
import 'location_service.dart';

/// Keeps the server informed about this car while a trip is running.
///
/// Two jobs: register how to reach this phone with a push, and report where it
/// is often enough that the server can decide whether a newly reported
/// obstruction is relevant to it.
class TripReporter {
  TripReporter({
    required this.api,
    required this.location,
    required this.carId,
  });

  final ApiService api;
  final LocationService location;

  /// Stable identity for this car, see carIdProvider.
  final String carId;

  /// Don't send more than one ping per this interval.
  ///
  /// The position stream only emits on movement, but in heavy traffic that can
  /// still be many times a minute. The server only needs a rough idea of where
  /// this car is, so anything more frequent is wasted battery and data.
  static const Duration _minimumPingGap = Duration(seconds: 20);

  StreamSubscription<Position>? _positionSub;
  DateTime? _lastPingAt;

  /// The most recent position actually reported, for display.
  Position? get lastReported => _lastReported;
  Position? _lastReported;

  bool get isRunning => _positionSub != null;

  /// Registers this device for pushes. Safe to call repeatedly.
  Future<void> register(String fcmToken) async {
    await api.registerDevice(carId: carId, fcmToken: fcmToken);
  }

  /// Begins reporting position until [stop] is called.
  ///
  /// Returns false if location permission is not available.
  Future<bool> start() async {
    if (isRunning) return true;

    if (await location.ensurePermission() != LocationAccess.granted) {
      return false;
    }

    _positionSub = location.positionStream().listen(
      _onPosition,
      onError: (Object error) => debugPrint('Position stream failed: $error'),
    );
    return true;
  }

  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _lastPingAt = null;
  }

  Future<void> _onPosition(Position position) async {
    final now = DateTime.now();
    if (_lastPingAt != null && now.difference(_lastPingAt!) < _minimumPingGap) {
      return;
    }
    _lastPingAt = now;

    try {
      await api.postLocation(
        carId: carId,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      _lastReported = position;
    } on ApiException catch (error) {
      // Connectivity drops constantly in a moving car. Missing one ping is
      // unremarkable; the next one will carry a fresher position anyway, so
      // there is nothing worth retrying or surfacing.
      debugPrint('Location ping skipped: $error');
    }
  }

  Future<void> dispose() => stop();
}
