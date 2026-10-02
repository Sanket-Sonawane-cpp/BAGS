import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/hazards.dart';
import '../../core/models/alert_event.dart';
import '../../core/providers.dart';
import '../../core/services/api_service.dart';
import 'hazard_routing.dart';
import 'routing_service.dart';

final routingServiceProvider = Provider<RoutingService>((ref) {
  final service = RoutingService();
  ref.onDispose(service.dispose);
  return service;
});

final hazardRoutePlannerProvider = Provider<HazardRoutePlanner>(
  (ref) => HazardRoutePlanner(ref.watch(routingServiceProvider)),
);

/// Hazards worth showing on the map and routing around: pushed alerts plus
/// whatever the server knows about nearby, one entry per hazard.
///
/// The server keeps every detection forever and a car reports the same
/// hazard many times as it passes, so this drops old reports and merges
/// repeats of the same thing in the same spot.
class KnownHazards extends Notifier<List<AlertEvent>> {
  /// Reports older than this are dropped. Accidents and fallen objects are
  /// usually cleared well within it, and nothing reports a hazard as gone.
  static const Duration maxAge = Duration(hours: 2);

  /// Reports of the same type closer than this are one hazard.
  static const double mergeRadiusMeters = 30;

  final Map<String, AlertEvent> _reports = {};

  @override
  List<AlertEvent> build() {
    ref.listen(alertHistoryProvider, (_, alerts) => _add(alerts));
    for (final alert in ref.read(alertHistoryProvider)) {
      _reports[alert.id] = alert;
    }
    return _merged();
  }

  /// Fetches what the server knows within [radiusMeters] of [center].
  ///
  /// Failures are ignored: the map just keeps what it already has.
  Future<void> refreshAround(LatLng center, double radiusMeters) async {
    try {
      final alerts = await ref
          .read(apiServiceProvider)
          .fetchNearbyAlerts(
            latitude: center.latitude,
            longitude: center.longitude,
            radiusMeters: radiusMeters,
          );
      _add(alerts);
    } on ApiException {
      // Routine on a moving-car connection; the next refresh tries again.
    }
  }

  void _add(Iterable<AlertEvent> alerts) {
    for (final alert in alerts) {
      _reports[alert.id] = alert;
    }
    state = _merged();
  }

  List<AlertEvent> _merged() {
    final cutoff = DateTime.now().toUtc().subtract(maxAge);
    _reports.removeWhere((_, alert) => alert.timestamp.isBefore(cutoff));

    const distance = Distance();
    final newestFirst = _reports.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final kept = <AlertEvent>[];
    for (final alert in newestFirst) {
      if (!hazardStyle(alert.type).isHazard) continue;
      final point = LatLng(alert.latitude, alert.longitude);
      final repeat = kept.any(
        (k) =>
            k.type == alert.type &&
            distance(point, LatLng(k.latitude, k.longitude)) <
                mergeRadiusMeters,
      );
      if (!repeat) kept.add(alert);
    }
    return kept;
  }
}

final knownHazardsProvider = NotifierProvider<KnownHazards, List<AlertEvent>>(
  KnownHazards.new,
);
