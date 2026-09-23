import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/alert_event.dart';
import 'services/api_service.dart';
import 'services/location_service.dart';
import 'services/notification_service.dart';
import 'services/trip_reporter.dart';

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

/// Stable identifier for this car, generated once and kept thereafter.
///
/// The FCM token cannot serve this purpose: it rotates on reinstall and
/// occasionally on its own, and the server needs a handle that survives that
/// so a car's location history stays attached to one identity.
final carIdProvider = Provider<String>((ref) {
  const key = 'car_id';
  final preferences = ref.watch(sharedPreferencesProvider);

  final existing = preferences.getString(key);
  if (existing != null) return existing;

  final random = Random.secure();
  final id = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  // Not awaited: the value is already returned, and a failed write only means
  // a new id next launch.
  preferences.setString(key, id);
  return id;
});

final locationServiceProvider = Provider<LocationService>(
  (ref) => const LocationService(),
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

final tripReporterProvider = Provider<TripReporter>((ref) {
  final reporter = TripReporter(
    api: ref.watch(apiServiceProvider),
    location: ref.watch(locationServiceProvider),
    carId: ref.watch(carIdProvider),
  );
  ref.onDispose(reporter.dispose);
  return reporter;
});

/// Registers this device for pushes, and re-registers whenever FCM rotates the
/// token.
///
/// A stale token on the server is silent: pushes are accepted and dropped, so
/// nothing surfaces as an error until someone notices alerts stopped arriving.
final deviceRegistrationProvider = FutureProvider<void>((ref) async {
  final token = await ref.watch(fcmTokenProvider.future);
  if (token == null) return;

  final reporter = ref.watch(tripReporterProvider);
  await reporter.register(token);

  final subscription = ref
      .watch(notificationServiceProvider)
      .tokenRefresh
      .listen(reporter.register);
  ref.onDispose(subscription.cancel);
});

/// Alerts as they arrive from the server.
final alertStreamProvider = StreamProvider<AlertEvent>(
  (ref) => ref.watch(notificationServiceProvider).alerts,
);

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
