import 'package:bags/core/models/alert_event.dart';
import 'package:bags/features/detection/clearance_watcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// [meters] north of the equator on the prime meridian.
LatLng _north(double meters) => LatLng(meters / 111195, 0);

AlertEvent _hazard({String type = 'accident', double at = 0}) => AlertEvent(
  id: '$type@$at',
  type: type,
  latitude: _north(at).latitude,
  longitude: 0,
  timestamp: DateTime.utc(2026),
  distanceMeters: 0,
);

void main() {
  late List<AlertEvent> votes;
  late ClearanceWatcher watcher;

  setUp(() {
    votes = [];
    watcher = ClearanceWatcher(
      detectableTypes: const {'accident', 'flood'},
      onNotSeen: votes.add,
    );
  });

  /// Drives north from 200 m before the origin to 200 m past it, in 20 m
  /// steps (the GPS distance filter), with the model checking [framesPerFix]
  /// frames between fixes and seeing [sees] along the way, if anything.
  void drivePast(
    List<AlertEvent> hazards, {
    double offsetMeters = 0,
    int framesPerFix = 3,
    String? sees,
  }) {
    for (var y = -200.0; y <= 200; y += 20) {
      final me = LatLng(_north(y).latitude, offsetMeters / 111195);
      watcher.moved(me, hazards);
      for (var i = 0; i < framesPerFix; i++) {
        watcher.frameChecked();
      }
      if (sees != null && y == -40) watcher.detected(sees, me);
    }
  }

  test('votes once the car has driven past a hazard without seeing it', () {
    final hazard = _hazard();
    drivePast([hazard]);
    expect(votes, [hazard]);
  });

  test('does not vote when the model saw it', () {
    drivePast([_hazard()], sees: 'accident');
    expect(votes, isEmpty);
  });

  test('seeing something else does not count as seeing it', () {
    drivePast([_hazard()], sees: 'flood');
    expect(votes, hasLength(1));
  });

  test('does not vote from a street 100 m away', () {
    drivePast([_hazard()], offsetMeters: 100);
    expect(votes, isEmpty);
  });

  test('does not vote unless the model was checking frames', () {
    drivePast([_hazard()], framesPerFix: 0);
    expect(votes, isEmpty);
  });

  test('does not vote on types the model cannot detect', () {
    drivePast([_hazard(type: 'pothole')]);
    expect(votes, isEmpty);
  });

  test('does not vote on a hazard that went while passing it', () {
    final hazard = _hazard();
    watcher.moved(_north(-100), [hazard]);
    for (var i = 0; i < 20; i++) {
      watcher.frameChecked();
    }
    watcher.moved(_north(0), [hazard]);
    watcher.moved(_north(200), const []); // cleared on the server meanwhile
    watcher.moved(_north(220), [hazard]); // and back: a new pass, not a vote
    expect(votes, isEmpty);
  });

  test('a pass cut short by detection stopping does not vote', () {
    final hazard = _hazard();
    watcher.moved(_north(-100), [hazard]);
    for (var i = 0; i < 20; i++) {
      watcher.frameChecked();
    }
    watcher
      ..moved(_north(0), [hazard])
      ..reset()
      ..moved(_north(200), [hazard]);
    expect(votes, isEmpty);
  });
}
