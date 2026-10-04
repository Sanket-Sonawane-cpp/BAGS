import 'package:bags/core/models/alert_event.dart';
import 'package:bags/core/providers.dart';
import 'package:bags/core/services/api_service.dart';
import 'package:bags/features/navigation/navigation_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

AlertEvent _alert(
  String id,
  double lat,
  double lng, {
  String type = 'accident',
  Duration age = Duration.zero,
  bool confirmed = true,
}) => AlertEvent(
  id: id,
  type: type,
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.now().toUtc().subtract(age),
  distanceMeters: 0,
  confirmed: confirmed,
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

  test('a hazard pushed again with news is updated', () {
    final history =
        container.read(alertHistoryProvider.notifier) as _FakeHistory;
    history.push(_alert('a', 0.001, 0, confirmed: false));
    expect(container.read(knownHazardsProvider).single.confirmed, isFalse);

    history.push(_alert('a', 0.001, 0));
    expect(container.read(knownHazardsProvider).single.confirmed, isTrue);
  });

  test('each type is dropped after its own lifetime', () async {
    api.serverAlerts = [
      _alert('accident', 0.001, 0, age: const Duration(minutes: 90)),
      _alert(
        'pothole',
        0.002,
        0,
        type: 'pothole',
        age: const Duration(minutes: 90),
      ),
    ];
    await container
        .read(knownHazardsProvider.notifier)
        .refreshAround(const LatLng(0, 0), 5000);
    expect(ids(), ['pothole']);
  });

  group('AlertEvent.fromJson', () {
    Map<String, dynamic> json([Map<String, dynamic> extra = const {}]) => {
      'id': 'h1',
      'type': 'accident',
      'lat': '18.5',
      'lng': '73.8',
      'timestamp': '2026-10-04T10:00:00+00:00',
      'distance_m': '120.5',
      ...extra,
    };

    test('reads confirmation as FCM sends it, all strings', () {
      final alert = AlertEvent.fromJson(
        json({'confirmed': 'false', 'reports': '1'}),
      );
      expect(alert.confirmed, isFalse);
      expect(alert.reports, 1);
      expect(AlertEvent.fromJson(json({'confirmed': 'true'})).confirmed, true);
    });

    test('reads confirmation as /alerts sends it', () {
      final alert = AlertEvent.fromJson(
        json({'confirmed': false, 'reports': 3}),
      );
      expect(alert.confirmed, isFalse);
      expect(alert.reports, 3);
    });

    test('trusts alerts from a server that does not say', () {
      final alert = AlertEvent.fromJson(json());
      expect(alert.confirmed, isTrue);
      expect(alert.reports, 1);
      expect(alert.headings, isEmpty);
    });

    test('reads directions as FCM and /alerts send them', () {
      expect(AlertEvent.fromJson(json({'headings': '90,270'})).headings, [
        90,
        270,
      ]);
      expect(AlertEvent.fromJson(json({'headings': ''})).headings, isEmpty);
      expect(
        AlertEvent.fromJson(
          json({
            'headings': [10, 20.5],
          }),
        ).headings,
        [10, 20.5],
      );
    });
  });
}
