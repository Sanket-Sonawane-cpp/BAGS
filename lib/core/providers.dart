import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/alert_event.dart';
import 'services/api_service.dart';
import 'services/location_service.dart';
import 'services/notification_service.dart';

/// Where the alert server lives.
///
/// Defaults to the Android emulator's alias for the host machine's localhost.
/// On a physical phone the laptop must be addressed by its LAN IP instead,
/// which is passed in at run time rather than hardcoded, because it changes
/// with the network:
///
///     flutter run --dart-define=SERVER_URL=http://192.168.1.5:8000
const String serverBaseUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

final locationServiceProvider = Provider<LocationService>(
  (ref) => const LocationService(),
);

final apiServiceProvider = Provider<ApiService>((ref) {
  final api = ApiService(baseUrl: serverBaseUrl);
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
