import 'dart:async';

import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/models/detection_event.dart';
import '../../core/services/location_service.dart';
import 'camera_service.dart';
import 'inference_service.dart';

/// Only classes at or above this confidence are reported as a detection.
///
/// Tuned for a real obstruction model later; with the placeholder classifier
/// this mostly just keeps the dev screen from scrolling a detection every
/// frame, since its output is meaningless noise until it's swapped out.
const double _defaultConfidenceThreshold = 0.5;

/// What one processed frame produced, and how long the model took on it.
class FrameResult {
  const FrameResult({required this.result, required this.elapsed});

  /// The model's best guess, or null when it saw nothing worth reporting.
  final ClassificationResult? result;

  /// Preprocessing + inference + parsing for this frame.
  final Duration elapsed;
}

/// Runs the camera → model → [DetectionEvent] pipeline end to end.
///
/// This is Member A's half of the app's one shared contract (see
/// docs/PROJECT_CONTEXT.md): everything upstream — camera, preprocessing,
/// inference — is internal to this class, and [detections] is the only
/// thing the rest of the app (Member B's alerts/networking layer) needs to
/// consume. See the doc's "Integration checkpoint" step.
///
/// [InferenceService] auto-detects whether the loaded model is a
/// [ModelKind.classifier] or [ModelKind.detector] (e.g. a converted YOLO
/// export) and normalizes both to the same "nothing found" signal: a
/// detector via [InferenceService.run] returning null once its NMS finds no
/// box, a classifier by ImageNet convention — output class 0 means
/// "background" and is never emitted.
class DetectionPipeline {
  DetectionPipeline({
    required this.inferenceService,
    CameraService? cameraService,
    LocationService? locationService,
    this.minInterval = const Duration(milliseconds: 300), // ~3fps
    this.confidenceThreshold = _defaultConfidenceThreshold,
  }) : _cameraService = cameraService ?? CameraService(),
       _locationService = locationService ?? const LocationService();

  final InferenceService inferenceService;
  final CameraService _cameraService;
  final LocationService _locationService;

  /// Minimum gap between two inference runs. Frames arriving faster than
  /// this are dropped, not queued — a backlog of stale frames is never
  /// useful in a moving car, so there is nothing to gain by keeping one.
  /// Keeps inference in the doc's 2-5fps battery/perf budget regardless of
  /// the camera's native frame rate.
  final Duration minInterval;

  /// Fallback for labels the model has no threshold of its own for — see
  /// [InferenceService.classThresholds].
  final double confidenceThreshold;

  /// The confidence a [label] must reach to count as a detection.
  double thresholdFor(String label) =>
      inferenceService.thresholdFor(label) ?? confidenceThreshold;

  /// How long a detection waits for a fresh GPS fix before falling back to
  /// the last known one.
  static const Duration _positionTimeout = Duration(seconds: 2);

  DateTime? _lastRun;
  bool _busy = false;
  Position? _lastPosition;
  CameraController? _cameraController;

  final StreamController<DetectionEvent> _detections =
      StreamController<DetectionEvent>.broadcast();

  /// A [DetectionEvent] per frame classified above [confidenceThreshold] as
  /// something other than background, tagged with the current GPS fix.
  Stream<DetectionEvent> get detections => _detections.stream;

  final StreamController<FrameResult> _rawResults =
      StreamController<FrameResult>.broadcast();

  /// Every processed frame, including ones where nothing was seen — lets the
  /// UI show inference is running and how fast.
  Stream<FrameResult> get rawResults => _rawResults.stream;

  CameraController? get cameraController => _cameraController;

  bool get isRunning => _cameraController?.value.isStreamingImages ?? false;

  /// Result of asking for location access during [start], surfaced so the
  /// dev screen can explain why detections might never carry a position.
  LocationAccess? locationAccess;

  /// Opens the camera, loads the model, asks for location permission, and
  /// starts the frame → detection loop.
  ///
  /// Safe to call again after [stop]; the camera and model are only
  /// (re)loaded once each.
  Future<CameraController> start() async {
    locationAccess ??= await _locationService.ensurePermission();

    if (!inferenceService.isLoaded) {
      await inferenceService.load();
    }

    var controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      controller = await _cameraService.initialise();
      _cameraController = controller;
    }

    await _cameraService.startStream(_onFrame);
    return controller;
  }

  void _onFrame(CameraImage frame) {
    final now = DateTime.now();
    if (_busy) return; // previous inference still running — drop this frame
    if (_lastRun != null && now.difference(_lastRun!) < minInterval) return;

    _lastRun = now;
    _busy = true;
    unawaited(_process(frame));
  }

  Future<void> _process(CameraImage frame) async {
    try {
      final stopwatch = Stopwatch()..start();
      final result = await inferenceService.run(frame);
      if (!_rawResults.isClosed) {
        _rawResults.add(
          FrameResult(result: result, elapsed: stopwatch.elapsed),
        );
      }
      // A detector reports null when nothing on this frame cleared its own
      // (lower, pre-NMS) score threshold — nothing to gate here.
      if (result == null) return;

      // Only a classifier has this convention; a detector's "nothing found"
      // is already handled by the null check above.
      if (inferenceService.kind == ModelKind.classifier &&
          result.classIndex == 0) {
        return;
      }
      if (result.confidence < thresholdFor(result.label)) return;

      final position = await _currentPositionOrNull();
      if (position == null || _detections.isClosed) return;

      _detections.add(
        DetectionEvent(
          type: result.label,
          confidence: result.confidence,
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    } catch (error, stackTrace) {
      // Deliberately broad, not `on Exception`: a malformed frame buffer
      // throws RangeError (an Error), not Exception — that previously
      // escaped this catch entirely as an unhandled async error, silently
      // killing every single frame's processing while the UI showed nothing
      // more informative than "Waiting for first frame...". A single bad
      // frame (a partial buffer during a resolution change, a native decode
      // failure, ...) still shouldn't take the whole stream down.
      // ignore: avoid_catches_without_on_clauses
      if (!_rawResults.isClosed) _rawResults.addError(error, stackTrace);
    } finally {
      _busy = false;
    }
  }

  Future<Position?> _currentPositionOrNull() async {
    if (locationAccess != LocationAccess.granted) return null;
    try {
      // Bounded: an untimed high-accuracy request can hang for as long as
      // there's no GPS fix (indoors, cold start), stalling the frame loop
      // and then dropping the detection it was meant to tag.
      return _lastPosition = await _locationService
          .getCurrentPosition()
          .timeout(_positionTimeout);
    } on Exception {
      // No fresh fix in time — a slightly stale position still places the
      // obstruction far better than dropping the detection outright.
      try {
        return _lastPosition ??= await _locationService.getLastKnownPosition();
      } on Exception {
        return null; // no fix has ever existed on this device yet
      }
    }
  }

  Future<void> stop() => _cameraService.stopStream();

  Future<void> dispose() async {
    await stop();
    await _cameraService.dispose();
    await inferenceService.dispose();
    await _detections.close();
    await _rawResults.close();
  }
}
