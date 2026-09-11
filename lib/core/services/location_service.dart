import 'package:geolocator/geolocator.dart';

/// Outcome of asking the device for location access.
///
/// Modelled as an enum rather than a bool because the three failure cases need
/// different responses from the UI: [serviceDisabled] means send the user to
/// device settings, [denied] means we may ask again, and [deniedForever] means
/// only a trip to the app's settings page can help.
enum LocationAccess { granted, serviceDisabled, denied, deniedForever }

/// Thin wrapper over geolocator so the rest of the app never deals with
/// permission plumbing directly.
class LocationService {
  const LocationService();

  /// Only report a new fix once the car has moved this far.
  ///
  /// Without it the GPS reports continuously and wakes the CPU even while
  /// stopped at a traffic light, which matters on a drive-length session.
  static const int _distanceFilterMeters = 20;

  static const LocationSettings _settings = LocationSettings(
    // Road positions need to be accurate enough to place an obstruction in the
    // correct lane-ish area, not just the correct suburb.
    accuracy: LocationAccuracy.high,
    distanceFilter: _distanceFilterMeters,
  );

  /// Walks the full permission sequence and reports where it ended up.
  ///
  /// Call this before [getCurrentPosition] or [positionStream]; both throw if
  /// permission was never granted.
  Future<LocationAccess> ensurePermission() async {
    // Device-level GPS toggle. An app permission is useless while this is off,
    // and requesting permission would not prompt the user to turn it on.
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      // Only prompts if the user has not permanently declined; otherwise it
      // returns deniedForever without showing anything.
      permission = await Geolocator.requestPermission();
    }

    return switch (permission) {
      LocationPermission.always ||
      LocationPermission.whileInUse => LocationAccess.granted,
      LocationPermission.deniedForever => LocationAccess.deniedForever,
      LocationPermission.denied ||
      LocationPermission.unableToDetermine => LocationAccess.denied,
    };
  }

  /// Opens the OS settings page for this app, so a [LocationAccess.deniedForever]
  /// user can undo their choice. There is no way to re-prompt in-app.
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  /// Opens the device location settings, for [LocationAccess.serviceDisabled].
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  /// A single fix, for tagging a detection the moment it happens.
  Future<Position> getCurrentPosition() =>
      Geolocator.getCurrentPosition(locationSettings: _settings);

  /// Continuous fixes, for reporting where this car is so the server knows who
  /// is near a reported obstruction.
  ///
  /// This only emits on movement (see [_distanceFilterMeters]); the caller is
  /// responsible for deciding how often to actually send a ping upstream.
  Stream<Position> positionStream() =>
      Geolocator.getPositionStream(locationSettings: _settings);
}
