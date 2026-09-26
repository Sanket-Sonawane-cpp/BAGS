import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/detection_event.dart';
import 'detection_pipeline.dart';
import 'inference_service.dart';

/// The ML team's hazard detector: Ultralytics YOLO26n, exported end-to-end
/// (NMS inside the graph, `[1, 300, 6]` output) with NCHW float32 input.
/// [InferenceService] reads shape/layout/output kind off the model itself,
/// so a retrained drop-in only needs the two constants below kept in sync
/// with its `ml/hazard_detector.metadata.json`.
///
/// ~7-8x faster than the YOLO11m it replaced (now `ml/obstruction_detector
/// .tflite`, out of the app bundle) on the same CPU. Still float32 — an int8 build would be faster again.
const String modelAsset = 'assets/models/hazard_detector.tflite';

/// Class order exactly as in the model's metadata (`classes`) — keep in sync
/// with the ML team's dataset, not guessed independently.
const List<String> modelLabels = [
  'accident',
  'non_accident',
  'fallen_object',
  'flood',
];

/// Per-class alert thresholds, the metadata's `deploy_conf`: the confidence
/// at which each class hit the ML team's target precision on their test set.
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
