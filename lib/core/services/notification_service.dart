import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../models/alert_event.dart';

/// Handles messages that arrive while the app is backgrounded or killed.
///
/// This must be a top-level function, not a method or closure: Android spins up
/// a separate Dart isolate to run it, and can only reach a function it can name
/// at the top level. It also cannot touch any UI state, because no widget tree
/// exists in that isolate.
@pragma('vm:entry-point')
Future<void> handleBackgroundMessage(RemoteMessage message) async {
  // Deliberately minimal. For hazards the server attaches a `notification`
  // block, which the OS shows on its own; tapping it comes back through
  // onMessageOpenedApp / getInitialMessage. Only data-only pushes (the
  // "clear road" class) end up here, and they have nothing to show.
  debugPrint('Background alert received: ${message.data}');
}

/// Receives obstruction alerts pushed by the server.
///
/// Push is used rather than a socket the app holds open: it survives NAT and
/// cellular handoffs, works when the app is backgrounded, and does not drain
/// the battery keeping a connection alive.
class NotificationService {
  NotificationService({FirebaseMessaging? messaging})
    : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  final StreamController<AlertEvent> _alerts =
      StreamController<AlertEvent>.broadcast();

  /// Alerts as they arrive, from any app state.
  Stream<AlertEvent> get alerts => _alerts.stream;

  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedSub;

  /// Asks for notification permission and starts listening.
  ///
  /// Returns the FCM token for this device, or null if permission was refused.
  /// The token is how the server addresses this specific phone, so it must be
  /// sent upstream and refreshed when it changes.
  Future<String?> initialise() async {
    final settings = await _messaging.requestPermission();

    // On Android 13+ this is a real runtime prompt; on older Android it is
    // granted automatically. On iOS it is always a prompt.
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      debugPrint('Notification permission not granted: '
          '${settings.authorizationStatus}');
      return null;
    }

    // Foreground: the driver is looking at the screen, so the app shows its own
    // banner rather than a system notification.
    _onMessageSub = FirebaseMessaging.onMessage.listen(_emit);

    // The user tapped a system notification and it brought the app forward.
    _onOpenedSub = FirebaseMessaging.onMessageOpenedApp.listen(_emit);

    // The app was launched from cold by tapping a notification, so the message
    // never passes through either stream above.
    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      _emit(initial);
    }

    return _messaging.getToken();
  }

  /// Fires whenever FCM reissues this device's token.
  ///
  /// Tokens rotate on reinstall, restore, and occasionally on their own. A
  /// stale token on the server means alerts silently stop arriving, so the new
  /// value must be sent upstream every time.
  Stream<String> get tokenRefresh => _messaging.onTokenRefresh;

  void _emit(RemoteMessage message) {
    // Alerts are parsed from the data payload, not the notification block
    // (which exists only for the OS to show while backgrounded), so the app
    // gets a typed object rather than a title string. Note every value arrives as a String — AlertEvent.fromJson
    // parses leniently for exactly this reason.
    if (message.data.isEmpty) return;

    try {
      _alerts.add(AlertEvent.fromJson(message.data));
    } on Exception catch (error) {
      // A malformed push must not take the app down mid-drive.
      debugPrint('Ignoring unparseable alert ${message.data}: $error');
    }
  }

  Future<void> dispose() async {
    await _onMessageSub?.cancel();
    await _onOpenedSub?.cancel();
    await _alerts.close();
  }
}
