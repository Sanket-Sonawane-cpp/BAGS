import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/hazards.dart';
import '../../core/models/alert_event.dart';
import '../../core/models/detection_event.dart';
import '../../core/providers.dart';
import '../../core/services/api_service.dart';
import '../navigation/navigation_providers.dart';
import 'clearance_watcher.dart';
import 'detection_pipeline.dart';
import 'inference_service.dart';

/// The ML team's hazard detector: Ultralytics YOLO11n (`ml/model.onnx`,
/// converted with `tools/convert_to_tflite.py`), float32, NHWC input, raw
/// detection head (`[1, 8, 8400]`: box + 4 class scores per anchor, no NMS
/// in the graph). [InferenceService] reads shape/layout/output kind off the
/// model itself and decodes + NMSes a raw head with [YoloDecoder], so a
/// retrained drop-in only needs the two constants below kept in sync with
/// the model's class list and thresholds.
///
/// Replaces the YOLO26n (`assets/models/hazard_detector.tflite`, post-NMS
/// `[1, 300, 6]` output), still bundled to switch back to.
const String modelAsset = 'assets/models/hazard_detector_yolo11n.tflite';

/// Class order exactly as in the model's metadata (`classes`) — keep in sync
/// with the ML team's dataset, not guessed independently.
const List<String> modelLabels = [
  'accident',
  'non_accident',
  'fallen_object',
  'flood',
];

/// Per-class alert thresholds: the YOLO26n metadata's `deploy_conf`, the
/// confidence at which each class hit the ML team's target precision on
/// their test set. The YOLO11n came without its own metadata, so these are
/// a stand-in until the ML team publishes its values.
const Map<String, double> modelClassThresholds = {
  'accident': 0.469,
  'non_accident': 0.406,
  'fallen_object': 0.477,
  'flood': 0.25,
};

/// `assets/models/placeholder_classifier.tflite` — the original bring-up
/// model, kept around for smoke-testing the camera/inference plumbing in
/// isolation (e.g. on a device where the real 80MB model is too slow) since
/// it needs no GPS/labels setup to produce *some* output.
const String placeholderModelAsset =
    'assets/models/placeholder_classifier.tflite';

final inferenceServiceProvider = Provider<InferenceService>((ref) {
  return InferenceService(
    modelAsset: modelAsset,
    labels: modelLabels,
    classThresholds: modelClassThresholds,
  );
});

final detectionPipelineProvider = Provider<DetectionPipeline>((ref) {
  final pipeline = DetectionPipeline(
    inferenceService: ref.watch(inferenceServiceProvider),
  );
  // Disposing the pipeline disposes the inference service (and its camera
  // and interpreter) with it — see DetectionPipeline.dispose.
  ref.onDispose(pipeline.dispose);
  return pipeline;
});

/// Detections above the confidence threshold, tagged with a GPS fix. This is
/// the stream Member B's networking layer consumes at the doc's
/// "Integration checkpoint" step.
final detectionStreamProvider = StreamProvider<DetectionEvent>((ref) {
  return ref.watch(detectionPipelineProvider).detections;
});

/// Whether the camera → model loop is running. Kept here rather than read
/// off [DetectionPipeline.isRunning] so widgets rebuild when it changes —
/// e.g. the tab bar's "detecting" dot while another tab is showing.
class DetectionRunning extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool running) => state = running;
}

final detectionRunningProvider = NotifierProvider<DetectionRunning, bool>(
  DetectionRunning.new,
);

/// Every processed frame, background and empty frames included — drives the
/// live overlay and the per-frame timing readout.
final rawInferenceStreamProvider = StreamProvider<FrameResult>((ref) {
  return ref.watch(detectionPipelineProvider).rawResults;
});

/// Every detection received this session, newest first.
///
/// Mirrors `AlertHistory` in `lib/core/providers.dart`: [detectionStreamProvider]
/// only carries one event at a time, this keeps what the dev screen shows.
class DetectionHistory extends Notifier<List<DetectionEvent>> {
  @override
  List<DetectionEvent> build() {
    ref.listen(detectionStreamProvider, (_, next) {
      final event = next.value;
      if (event != null) state = [event, ...state];
    });
    return const [];
  }

  void clear() => state = const [];
}

final detectionHistoryProvider =
    NotifierProvider<DetectionHistory, List<DetectionEvent>>(
      DetectionHistory.new,
    );

/// Votes to the server that a known hazard is gone when this car drives
/// past it, detecting, without seeing it — see [ClearanceWatcher]. Only
/// while detection runs, and only with reporting on: a vote is a report
/// too. Watched from HomeShell, so it runs whichever tab is showing.
final clearanceWatcherProvider = Provider<ClearanceWatcher>((ref) {
  Future<void> vote(AlertEvent hazard, double? heading) async {
    if (!ref.read(reportDetectionsProvider)) return;
    try {
      await ref
          .read(apiServiceProvider)
          .postNotSeen(
            hazard.id,
            carId: ref.read(carIdProvider),
            heading: heading,
          );
    } on ApiException {
      // Offline, or the hazard is already gone: nothing worth retrying.
    }
  }

  final watcher = ClearanceWatcher(
    detectableTypes: {
      for (final label in modelLabels)
        if (hazardStyle(label).isHazard) label,
    },
    onNotSeen: (hazard, heading) => unawaited(vote(hazard, heading)),
  );

  // Fixes only while detecting: a pass with the camera off proves nothing.
  StreamSubscription<Position>? positions;
  void follow({required bool detecting}) {
    unawaited(positions?.cancel());
    positions = null;
    watcher.reset();
    if (!detecting) return;
    positions = ref
        .read(locationServiceProvider)
        .positionStream()
        .listen(
          (fix) => watcher.moved(
            LatLng(fix.latitude, fix.longitude),
            ref.read(knownHazardsProvider),
          ),
          // A GPS hiccup; the next fix carries on.
          onError: (Object _) {},
        );
  }

  ref
    ..listen(
      detectionRunningProvider,
      (_, detecting) => follow(detecting: detecting),
      fireImmediately: true,
    )
    ..listen(rawInferenceStreamProvider, (_, frame) {
      if (frame is AsyncData) watcher.frameChecked();
    })
    ..listen(detectionStreamProvider, (_, next) {
      final event = next.value;
      if (event != null) {
        watcher.detected(event.type, LatLng(event.latitude, event.longitude));
      }
    })
    ..onDispose(() => positions?.cancel());
  return watcher;
});
