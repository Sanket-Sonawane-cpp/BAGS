import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../core/models/alert_event.dart';

/// Notices this car driving past a known hazard, camera running, without
/// the model spotting it: evidence the hazard has been cleared.
///
/// Nothing else reports a hazard as gone, so without this a cleared
/// accident would keep sending cars on detours until it expired. One car
/// missing it proves little (the model misses things, the view may be
/// blocked), so this is only a vote: the server removes a hazard once
/// several different cars miss it and nobody has seen it since.
///
/// Feed it the car's position ([moved]), each frame the model checks
/// ([frameChecked]) and each detection ([detected]); it calls [onNotSeen]
/// as the car leaves a hazard behind unseen.
class ClearanceWatcher {
  ClearanceWatcher({required this.detectableTypes, required this.onNotSeen});

  /// Hazard types the model can detect. Only these get votes: a model with
  /// no pothole class not seeing a pothole says nothing about it.
  final Set<String> detectableTypes;

  final void Function(AlertEvent hazard) onNotSeen;

  /// A pass starts this close to a hazard, and is over once the car is this
  /// far away again — by then it's well past. A report's position is the
  /// reporting car's, typically some way before the hazard itself.
  static const double watchMeters = 150;

  /// The car must come at least this close for a pass to count, so a car on
  /// a parallel street doesn't vote. Allows for GPS error and for fixes only
  /// arriving every 20 m.
  static const double passMeters = 40;

  /// The model must have checked at least this many frames during a pass —
  /// a few seconds' worth at its ~3 per second — for not seeing anything to
  /// mean something.
  static const int minFrames = 10;

  final Map<String, _Pass> _passes = {};

  /// The car is at [me]; [hazards] are the ones known now.
  void moved(LatLng me, Iterable<AlertEvent> hazards) {
    const distance = Distance();
    final known = <String>{};
    for (final hazard in hazards) {
      known.add(hazard.id);
      if (!detectableTypes.contains(hazard.type)) continue;
      final away = distance(me, LatLng(hazard.latitude, hazard.longitude));
      if (away <= watchMeters) {
        final pass = _passes.putIfAbsent(hazard.id, () => _Pass(hazard));
        pass.closest = math.min(pass.closest, away);
        continue;
      }
      final pass = _passes.remove(hazard.id);
      if (pass != null &&
          pass.closest <= passMeters &&
          pass.frames >= minFrames &&
          !pass.seen) {
        onNotSeen(hazard);
      }
    }
    // Hazards that went (cleared or expired) mid-pass: nothing to vote on.
    _passes.removeWhere((id, _) => !known.contains(id));
  }

  /// The model checked a frame.
  void frameChecked() {
    for (final pass in _passes.values) {
      pass.frames++;
    }
  }

  /// The model saw [type] with the car at [at].
  void detected(String type, LatLng at) {
    const distance = Distance();
    for (final pass in _passes.values) {
      final hazard = pass.hazard;
      if (hazard.type == type &&
          distance(at, LatLng(hazard.latitude, hazard.longitude)) <=
              watchMeters) {
        pass.seen = true;
      }
    }
  }

  /// Detection stopped: passes under way can't be judged.
  void reset() => _passes.clear();
}

/// The car near one hazard.
class _Pass {
  _Pass(this.hazard);

  final AlertEvent hazard;
  double closest = double.infinity;
  int frames = 0;
  bool seen = false;
}
