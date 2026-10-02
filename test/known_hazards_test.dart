import 'package:bags/core/models/alert_event.dart';
import 'package:bags/core/providers.dart';
import 'package:bags/core/services/api_service.dart';
import 'package:bags/features/navigation/navigation_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

AlertEvent _alert(String id, double lat, double lng) => AlertEvent(
  id: id,
  type: 'accident',
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.now().toUtc(),
  distanceMeters: 0,
);

/// Answers `/alerts` with whatever the test sets, ignoring the area.
class _FakeApi extends ApiService {
  _FakeApi() : super(baseUrl: 'http://unused');

  List<AlertEvent> serverAlerts = [];

  @override
  Future<List<AlertEvent>> fetchNearbyAlerts({
    required double latitude,
    required double longitude,
    double radiusMeters = 2000,
  }) async => serverAlerts;
}

/// Alert history without Firebase behind it.
class _FakeHistory extends AlertHistory {
  @override
  List<AlertEvent> build() => const [];

  void push(AlertEvent alert) => state = [alert, ...state];
}

void main() {
  late _FakeApi api;
  late ProviderContainer container;

  setUp(() {
    api = _FakeApi();
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        alertHistoryProvider.overrideWith(_FakeHistory.new),
      ],
    );
    addTearDown(container.dispose);
  });

  List<String> ids() =>
      container.read(knownHazardsProvider).map((a) => a.id).toList();

  test(
    'drops hazards the server no longer has, inside the synced area',
    () async {
      final hazards = container.read(knownHazardsProvider.notifier);
      api.serverAlerts = [_alert('near', 0.001, 0), _alert('far', 1, 0)];
      await hazards.refreshAround(const LatLng(0, 0), 200000);
      expect(ids(), unorderedEquals(['near', 'far']));

      // Server reset: nothing left. Only the area that was synced is cleared.
      api.serverAlerts = [];
      await hazards.refreshAround(const LatLng(0, 0), 5000);
      expect(ids(), ['far']);
    },
  );

  test('a new push does not bring back a hazard the server dropped', () async {
    final history =
        container.read(alertHistoryProvider.notifier) as _FakeHistory;
    final hazards = container.read(knownHazardsProvider.notifier);

    history.push(_alert('old', 0.001, 0));
    expect(ids(), ['old']);

    api.serverAlerts = [];
    await hazards.refreshAround(const LatLng(0, 0), 5000);
    expect(ids(), isEmpty);

    history.push(_alert('new', 0.002, 0.002));
    expect(ids(), ['new']);
  });
}
