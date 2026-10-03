import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'models/alert_event.dart';
import 'polyline.dart';
import 'services/api_service.dart';
import 'services/location_pinger.dart';
import 'services/location_service.dart';
import 'services/notification_service.dart';

/// Fallback server address, used the first time the app runs.
///
/// Defaults to the Android emulator's alias for the host machine's localhost.
/// Can be seeded at build time for a device:
///
///     flutter run --dart-define=SERVER_URL=http://192.168.1.34:8000
///
/// Once the user edits the address in-app, the saved value wins over this.
const String defaultServerUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

/// Overridden in main() once SharedPreferences has loaded, which keeps every
/// consumer of the stored settings synchronous.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Override this in main()'),
);

/// The server address, editable at run time and remembered across restarts.
///
/// A laptop's LAN IP changes whenever DHCP reassigns it, and a compile-time
/// constant would mean a full rebuild every time that happens.
class ServerUrl extends Notifier<String> {
  static const _key = 'server_url';

  @override
  String build() =>
      ref.watch(sharedPreferencesProvider).getString(_key) ?? defaultServerUrl;

  Future<void> set(String url) async {
    final cleaned = url.trim().replaceAll(RegExp(r'/+$'), '');
    await ref.read(sharedPreferencesProvider).setString(_key, cleaned);
    state = cleaned;
  }

  Future<void> reset() async {
    await ref.read(sharedPreferencesProvider).remove(_key);
    state = defaultServerUrl;
  }
}

final serverUrlProvider = NotifierProvider<ServerUrl, String>(ServerUrl.new);

/// Identifies this phone to the server across restarts, so a location ping
/// updates the same server-side car record instead of creating a new one
/// every launch. Generated once and persisted — not tied to any account
/// system, since the app doesn't have one.
class CarId extends Notifier<String> {
  static const _key = 'car_id';

  @override
  String build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final existing = prefs.getString(_key);
    if (existing != null) return existing;

    final generated = const Uuid().v4();
    // Fire-and-forget: the id is already decided and usable this session
    // regardless of whether the write below lands before it's read again;
    // worst case a slow write just means one extra id generated on a crash
    // before it landed, not a correctness problem.
    unawaited(prefs.setString(_key, generated));
    return generated;
  }
}

final carIdProvider = NotifierProvider<CarId, String>(CarId.new);

/// Whether this phone's own detections are posted to the server, so other
/// cars get alerted about them. On by default — that's the app's purpose —
/// and remembered, so turning it off for a test drive sticks.
class ReportDetections extends Notifier<bool> {
  static const _key = 'report_detections';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(_key) ?? true;

  Future<void> set(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(_key, value);
    state = value;
  }
}

final reportDetectionsProvider = NotifierProvider<ReportDetections, bool>(
  ReportDetections.new,
);

final locationServiceProvider = Provider<LocationService>(
  (ref) => const LocationService(),
);

/// Location permission, asked for once at startup. `ref.invalidate` it to
/// ask again (e.g. after the user returns from system settings).
final locationAccessProvider = FutureProvider<LocationAccess>(
  (ref) => ref.watch(locationServiceProvider).ensurePermission(),
);

/// Whether the server answers its health check. Re-runs by itself when the
/// server address changes; `ref.invalidate` it to re-check on demand.
final serverReachableProvider = FutureProvider<bool>(
  (ref) => ref.watch(apiServiceProvider).isReachable(),
);

final apiServiceProvider = Provider<ApiService>((ref) {
  // Watching rather than reading means editing the address rebuilds the client
  // with the new base URL, instead of silently keeping the old one.
  final api = ApiService(baseUrl: ref.watch(serverUrlProvider));
  ref.onDispose(api.dispose);
  return api;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService();
  ref.onDispose(service.dispose);
  return service;
});

/// Starts FCM and exposes this device's token.
///
/// The server addresses pushes to this token, so it has to be registered
/// upstream before any alert can reach this phone.
final fcmTokenProvider = FutureProvider<String?>(
  (ref) => ref.watch(notificationServiceProvider).initialise(),
);

/// Alerts as they arrive from the server.
final alertStreamProvider = StreamProvider<AlertEvent>(
  (ref) => ref.watch(notificationServiceProvider).alerts,
);

/// Fires whenever FCM reissues this device's token — see
/// [NotificationService.tokenRefresh]. Wrapped as a provider (rather than
/// [LocationPinger] subscribing to the raw stream directly) so
/// [latestFcmTokenProvider] can combine it with [fcmTokenProvider] the same
/// way the rest of this file combines streams and futures.
final _tokenRefreshProvider = StreamProvider<String>(
  (ref) => ref.watch(notificationServiceProvider).tokenRefresh,
);

/// The current FCM token, kept up to date after [fcmTokenProvider] resolves.
///
/// [fcmTokenProvider] only reflects the token as of app start; a
/// [LocationPinger] tick needs whatever the token actually *is* right now,
/// including a rotation that happened after launch (reinstall, restore, the
/// occasional spontaneous rotation FCM does on its own).
class LatestFcmToken extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(fcmTokenProvider, (_, next) {
      final token = next.value;
      if (token != null) state = token;
    });
    ref.listen(_tokenRefreshProvider, (_, next) {
      final token = next.value;
      if (token != null) state = token;
    });
    // The listeners above only see changes; start from whatever FCM already
    // has, in case the token resolved before this provider was first read.
    return ref.read(fcmTokenProvider).value;
  }
}

final latestFcmTokenProvider = NotifierProvider<LatestFcmToken, String?>(
  LatestFcmToken.new,
);

/// The route this car is navigating, thinned for sending, or null when it
/// isn't. Rides along on location pings so the server can push hazards
/// reported anywhere ahead on it — not just within its push radius.
class ActiveRoute extends Notifier<List<LatLng>?> {
  /// Thinning keeps the road's shape to within this; well inside the
  /// server's 50 m on-route corridor.
  static const double toleranceMeters = 10;

  @override
  List<LatLng>? build() => null;

  void set(List<LatLng>? points) =>
      state = points == null ? null : simplifyPolyline(points, toleranceMeters);
}

final activeRouteProvider = NotifierProvider<ActiveRoute, List<LatLng>?>(
  ActiveRoute.new,
);

final locationPingerProvider = Provider<LocationPinger>((ref) {
  final pinger = LocationPinger(
    apiService: ref.watch(apiServiceProvider),
    locationService: ref.watch(locationServiceProvider),
    carId: ref.watch(carIdProvider),
  );
  ref.onDispose(pinger.stop);
  return pinger;
});

/// Every alert received this session, newest first.
///
/// [alertStreamProvider] only carries one alert at a time; this keeps the
/// history the UI needs to render a list.
class AlertHistory extends Notifier<List<AlertEvent>> {
  @override
  List<AlertEvent> build() {
    ref.listen(alertStreamProvider, (_, next) {
      final alert = next.value;
      if (alert == null) return;

      // The same obstruction can be pushed more than once as the car
      // approaches it; the server-assigned id is what makes it identifiable.
      if (state.any((existing) => existing.id == alert.id)) return;

      state = [alert, ...state];
    });

    return const [];
  }

  void clear() => state = const [];
}

final alertHistoryProvider = NotifierProvider<AlertHistory, List<AlertEvent>>(
  AlertHistory.new,
);
