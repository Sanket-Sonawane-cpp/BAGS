import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/detection_event.dart';
import 'detection_pipeline.dart';
import 'inference_service.dart';

/// The ML team's obstruction detector — converted from their `best.onnx`
/// (Ultralytics YOLO11m) via `tools/convert_to_tflite.py`. [InferenceService]
/// reads shape/quantization off the model itself, so dropping in a retrained
/// version means re-running that script and nothing else, as long as the
/// class list below still matches.
///
/// Currently float32 (~80MB) because no representative calibration images
/// exist yet for the int8 build docs/PROJECT_CONTEXT.md's battery/perf
/// section actually calls for — rerun the conversion script with
/// `--quantize --calibration-images <dir>` once some do.
const String modelAsset = 'assets/models/obstruction_detector.tflite';

/// Class order exactly as embedded in best.onnx's metadata (`names` field) —
/// keep in sync with the ML team's dataset, not guessed independently.
const List<String> modelLabels = [
  'accident',
  'non_accident',
  'fallen_object',
  'pothole',
];

/// `assets/models/placeholder_classifier.tflite` — the original bring-up
/// model, kept around for smoke-testing the camera/inference plumbing in
/// isolation (e.g. on a device where the real 80MB model is too slow) since
/// it needs no GPS/labels setup to produce *some* output.
const String placeholderModelAsset =
    'assets/models/placeholder_classifier.tflite';

final inferenceServiceProvider = Provider<InferenceService>((ref) {
  return InferenceService(modelAsset: modelAsset, labels: modelLabels);
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

/// Every processed frame's raw classification, background included — lets
/// the dev screen show inference is actually running frame to frame, not
/// just when a detection clears the confidence threshold.
final rawInferenceStreamProvider = StreamProvider<ClassificationResult>((ref) {
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
