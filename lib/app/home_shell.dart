import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/alert_event.dart';
import '../core/models/detection_event.dart';
import '../core/providers.dart';
import '../core/services/location_pinger.dart';
import '../core/services/location_service.dart';
import '../features/alerts/alert_banner.dart';
import '../features/alerts/alerts_screen.dart';
import '../features/detection/detection_providers.dart';
import '../features/detection/drive_screen.dart';
import '../features/navigation/navigation_screen.dart';

/// Root of the app: Drive / Navigate / Alerts tabs, plus the work that has to
/// happen whichever tab is showing.
///
/// Tabs live in an [IndexedStack], so switching never tears one down — in
/// particular detection keeps running on the Drive tab while the driver
/// follows a route on Navigate.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const _alertsTab = 2;

  int _tab = 0;

  /// Alerts already seen on the Alerts tab, for the unread badge.
  int _seenAlerts = 0;

  AlertEvent? _banner;
  Timer? _bannerTimer;

  @override
  void dispose() {
    _bannerTimer?.cancel();
    super.dispose();
  }

  bool get _locationGranted =>
      ref.read(locationAccessProvider).value == LocationAccess.granted;

  /// Starts the periodic "here is where I am" ping to the server — only once
  /// permission is granted, so it isn't failing every 20 s until the user
  /// answers the prompt. `start()` is a no-op if already running.
  void _startPinger(LocationPinger pinger) {
    if (!_locationGranted) return;
    pinger.start(tokenProvider: () => ref.read(latestFcmTokenProvider));
  }

  void _showBanner(AlertEvent alert) {
    // A driver isn't looking at the screen when this fires, so the alert has
    // to announce itself physically as well as visually.
    HapticFeedback.heavyImpact();
    setState(() => _banner = alert);
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _banner = null);
    });
  }

  Future<void> _report(DetectionEvent event) async {
    if (!ref.read(reportDetectionsProvider)) return;
    try {
      await ref
          .read(apiServiceProvider)
          .postDetection(event, carId: ref.read(carIdProvider));
    } on Exception {
      // Routine on a moving-car connection; the next detection tries again.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref
      ..listen(locationAccessProvider, (_, next) {
        if (next.value == LocationAccess.granted) {
          _startPinger(ref.read(locationPingerProvider));
        }
      })
      // A new server address rebuilds the pinger; the old one was stopped
      // on disposal, so the replacement needs starting.
      ..listen(locationPingerProvider, (_, next) => _startPinger(next))
      ..listen(alertStreamProvider, (_, next) {
        final alert = next.value;
        if (alert != null) _showBanner(alert);
      })
      ..listen(detectionStreamProvider, (_, next) {
        final event = next.value;
        if (event != null) unawaited(_report(event));
      });

    // Watched so they start at launch rather than when first shown: FCM
    // registration, the token tracker, and alert history must all be live
    // before the first push arrives.
    ref
      ..watch(fcmTokenProvider)
      ..watch(latestFcmTokenProvider);
    final alerts = ref.watch(alertHistoryProvider);
    final detecting = ref.watch(detectionRunningProvider);

    if (_tab == _alertsTab) _seenAlerts = alerts.length;
    final unread = (alerts.length - _seenAlerts).clamp(0, 99);

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _tab,
            children: const [DriveScreen(), NavigationScreen(), AlertsScreen()],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, animation) => SlideTransition(
                    position: Tween(
                      begin: const Offset(0, -1.2),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                  child: _banner == null
                      ? const SizedBox.shrink()
                      : AlertBanner(
                          key: ValueKey(_banner!.id),
                          alert: _banner!,
                          onDismiss: () => setState(() => _banner = null),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: detecting,
              smallSize: 8,
              child: const Icon(Icons.videocam_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: detecting,
              smallSize: 8,
              child: const Icon(Icons.videocam),
            ),
            label: 'Drive',
          ),
          const NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Navigate',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_outlined),
            ),
            selectedIcon: const Icon(Icons.notifications),
            label: 'Alerts',
          ),
        ],
      ),
    );
  }
}
