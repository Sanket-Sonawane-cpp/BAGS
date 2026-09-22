import 'dart:io';

import 'package:camera/camera.dart';

/// Thin wrapper over [CameraController] so the rest of the app never deals
/// with camera device selection / lifecycle directly.
///
/// Mirrors the shape of `LocationService` in `lib/core/services/`: open the
/// device, then hand back a controller/frame stream once it's ready.
class CameraService {
  CameraController? _controller;

  CameraController? get controller => _controller;

  bool get isReady => _controller?.value.isInitialized ?? false;

  /// Finds the rear camera and opens it.
  ///
  /// Resolution is deliberately modest: [FramePreprocessor] downscales every
  /// frame to the model's input size anyway (224x224-ish), so a high-res
  /// capture would only cost battery and conversion time. `medium` (~720p)
  /// is still sharp enough for the preview widget.
  Future<CameraController> initialise() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available on this device.');
    }

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      // bgra8888 (iOS) and nv21 (Android) are the two formats
      // FramePreprocessor knows how to decode. yuv420's per-platform plane
      // layout is messier and isn't needed here.
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.nv21,
    );

    await controller.initialize();
    _controller = controller;
    return controller;
  }

  Future<void> startStream(void Function(CameraImage image) onFrame) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('Call initialise() before startStream().');
    }
    if (controller.value.isStreamingImages) return;
    await controller.startImageStream(onFrame);
  }

  Future<void> stopStream() async {
    final controller = _controller;
    if (controller != null && controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
  }
}
