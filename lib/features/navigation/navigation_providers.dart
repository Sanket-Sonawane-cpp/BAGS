import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/hazards.dart';
import '../../core/models/alert_event.dart';
import '../../core/providers.dart';
import '../../core/services/api_service.dart';
import 'hazard_routing.dart';
import 'routing_service.dart';

/// OpenRouteService API key, which lets routes avoid hazards outright (see
/// [RoutingService.canAvoid]). Entered in Settings and remembered; can be
/// seeded at build time with `--dart-define=ORS_API_KEY=...`. Empty means
/// none: routing falls back to the public OSRM server.
class OrsApiKey extends Notifier<String> {
  static const _key = 'ors_api_key';
  static const _seed = String.fromEnvironment('ORS_API_KEY');

  @override
  String build() =>
      ref.watch(sharedPreferencesProvider).getString(_key) ?? _seed;

  Future<void> set(String key) async {
    final cleaned = key.trim();
    await ref.read(sharedPreferencesProvider).setString(_key, cleaned);
    state = cleaned;
  }
}

final orsApiKeyProvider = NotifierProvider<OrsApiKey, String>(OrsApiKey.new);

final routingServiceProvider = Provider<RoutingService>((ref) {
  final key = ref.watch(orsApiKeyProvider);
  final service = RoutingService(orsApiKey: key.isEmpty ? null : key);
  ref.onDispose(service.dispose);
  return service;
});

final hazardRoutePlannerProvider = Provider<HazardRoutePlanner>(
  (ref) => HazardRoutePlanner(ref.watch(routingServiceProvider)),
);

/// Hazards worth showing on the map and routing around: pushed alerts plus
/// whatever the server knows about nearby, one entry per hazard.
///
/// The server merges repeat reports into one hazard and drops hazards once
/// they expire or are cleared. Pushed alerts outside the synced area don't
/// hear about that, so this also drops reports past their type's
/// [HazardStyle.lifetime], and merges repeats of the same thing in the same
/// spot from older servers.
class KnownHazards extends Notifier<List<AlertEvent>> {
  /// Reports of the same type closer than this are one hazard.
  static const double mergeRadiusMeters = 30;

  final Map<String, AlertEvent> _reports = {};

  @override
  List<AlertEvent> build() {
    // Only alerts newly pushed, or pushed again with news (now confirmed):
    // re-adding the whole history would bring back reports a refresh has
    // since dropped as deleted on the server.
    ref.listen(alertHistoryProvider, (previous, alerts) {
      final seen = Set<AlertEvent>.identity()..addAll(previous ?? const []);
      _add(alerts.where((alert) => !seen.contains(alert)));
    });
    for (final alert in ref.read(alertHistoryProvider)) {
      _reports[alert.id] = alert;
    }
    return _merged();
  }

  /// Syncs with what the server knows within [radiusMeters] of [center].
  ///
  /// The server is the source of truth for that area: anything cached there
  /// that it no longer returns (cleared by `/reset`, or deleted) is dropped.
  /// Failures are ignored: the map just keeps what it already has.
  Future<void> refreshAround(LatLng center, double radiusMeters) async {
    final List<AlertEvent> alerts;
    try {
      alerts = await ref
          .read(apiServiceProvider)
          .fetchNearbyAlerts(
            latitude: center.latitude,
            longitude: center.longitude,
            radiusMeters: radiusMeters,
          );
    } on ApiException {
      // Routine on a moving-car connection; the next refresh tries again.
      return;
    }

    const distance = Distance();
    final current = {for (final alert in alerts) alert.id};
    _reports.removeWhere(
      (id, alert) =>
          !current.contains(id) &&
          distance(center, LatLng(alert.latitude, alert.longitude)) <=
              radiusMeters,
    );
    _add(alerts);
  }

  void _add(Iterable<AlertEvent> alerts) {
    for (final alert in alerts) {
      _reports[alert.id] = alert;
    }
    state = _merged();
  }

  List<AlertEvent> _merged() {
    final now = DateTime.now().toUtc();
    _reports.removeWhere(
      (_, alert) =>
          alert.timestamp.add(hazardStyle(alert.type).lifetime).isBefore(now),
    );

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
