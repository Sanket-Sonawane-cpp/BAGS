import 'dart:async';

import 'package:bags/core/models/detection_event.dart';
import 'package:bags/core/services/location_service.dart';
import 'package:bags/features/detection/camera_service.dart';
import 'package:bags/features/detection/detection_pipeline.dart';
import 'package:bags/features/detection/inference_service.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

class _Frame extends Fake implements CameraImage {}

/// Hands frames to the pipeline when the test says so.
class _FakeCamera extends CameraService {
  late void Function(CameraImage image) sendFrame;

  @override
  Future<CameraController> initialise() async => CameraController(
    const CameraDescription(
      name: 'fake',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 0,
    ),
    ResolutionPreset.low,
  );

  @override
  Future<void> startStream(void Function(CameraImage image) onFrame) async =>
      sendFrame = onFrame;

  @override
  Future<void> stopStream() async {}

  @override
  Future<void> dispose() async {}
}

/// Sees an accident in every frame.
class _FakeInference extends InferenceService {
  _FakeInference()
    : super(modelAsset: 'unused', classThresholds: const {'accident': 0.5});

  int runs = 0;

  @override
  bool get isLoaded => true;

  @override
  ModelKind get kind => ModelKind.postNms;

  @override
  Future<ClassificationResult?> run(CameraImage frame) async {
    runs++;
    return const ClassificationResult(
      classIndex: 0,
      label: 'accident',
      confidence: 0.9,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// A GPS that takes until the test says to produce a fix.
class _SlowLocation extends LocationService {
  final fix = Completer<Position>();
  int lookups = 0;

  @override
  Future<LocationAccess> ensurePermission() async => LocationAccess.granted;

  @override
  Future<Position> getCurrentPosition() {
    lookups++;
    return fix.future;
  }
}

void main() {
  test('keeps checking frames while a detection waits for GPS', () async {
    final camera = _FakeCamera();
    final inference = _FakeInference();
    final location = _SlowLocation();
    final pipeline = DetectionPipeline(
      inferenceService: inference,
      cameraService: camera,
      locationService: location,
      minInterval: Duration.zero,
    );
    addTearDown(pipeline.dispose);
    final detections = <DetectionEvent>[];
    pipeline.detections.listen(detections.add);
    await pipeline.start();

    for (var i = 0; i < 3; i++) {
      camera.sendFrame(_Frame());
      await pumpEventQueue();
    }
    // None dropped while the first detection waits for its fix, and they
    // share that one lookup.
    expect(inference.runs, 3);
    expect(location.lookups, 1);
    expect(detections, isEmpty);

    location.fix.complete(
      Position(
        latitude: 18.5,
        longitude: 73.8,
        timestamp: DateTime.utc(2026),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
    );
    await pumpEventQueue();
    expect(detections, hasLength(3));
    expect(detections.every((d) => d.latitude == 18.5), isTrue);
  });
}
