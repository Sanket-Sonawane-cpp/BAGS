import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/detection_event.dart';
import '../../core/providers.dart';
import 'detection_providers.dart';

/// Working screen for the detection half of the app.
///
/// Like `AlertsScreen`, this is a development surface, not the final driving
/// UI: it exists to prove camera → model → [DetectionEvent] works end to end
/// on a real device before there's a trained model or a polished UI to
/// build around it.
class DetectionScreen extends ConsumerStatefulWidget {
  const DetectionScreen({super.key});

  @override
  ConsumerState<DetectionScreen> createState() => _DetectionScreenState();
}

class _DetectionScreenState extends ConsumerState<DetectionScreen> {
  CameraController? _controller;
  String? _error;
  bool _starting = false;
  bool _postToServer = false;

  @override
  void dispose() {
    // The pipeline is owned by detectionPipelineProvider, so Riverpod tears
    // down the camera/model with it when the provider scope disposes — not
    // here. This just stops the frame stream so leaving the screen doesn't
    // keep burning battery on inference in the background.
    unawaited(ref.read(detectionPipelineProvider).stop());
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final controller = await ref.read(detectionPipelineProvider).start();
      if (mounted) setState(() => _controller = controller);
    } catch (error) {
      // Deliberately broad, not `on Exception`: a missing camera, an
      // unsupported frame format, and (before InferenceService's delegate
      // fallback existed) a rejected hardware delegate all throw Error
      // subtypes (StateError/ArgumentError/UnsupportedError), not
      // Exception — and those need to reach this screen too, not vanish as
      // an unhandled async error with the UI silently stuck on "Camera off".
      // ignore: avoid_catches_without_on_clauses
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    await ref.read(detectionPipelineProvider).stop();
    if (mounted) setState(() => _controller = null);
  }

  Future<void> _postSafely(DetectionEvent event) async {
    try {
      await ref.read(apiServiceProvider).postDetection(event);
    } on Exception {
      // Routine on a moving-car connection; the history list below is the
      // source of truth for what this device actually detected.
    }
  }

  @override
  Widget build(BuildContext context) {
    final pipeline = ref.watch(detectionPipelineProvider);

    ref.listen(detectionStreamProvider, (_, next) {
      final event = next.value;
      if (event != null && _postToServer) unawaited(_postSafely(event));
    });

    final raw = ref.watch(rawInferenceStreamProvider);
    final history = ref.watch(detectionHistoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Detection')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CameraPreviewBox(controller: _controller),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _starting || pipeline.isRunning ? null : _start,
                child: Text(_starting ? 'Starting...' : 'Start'),
              ),
              FilledButton.tonal(
                onPressed: pipeline.isRunning ? _stop : null,
                child: const Text('Stop'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Also post detections to server'),
            subtitle: const Text(
              "Exercises Member B's postDetection() with real events",
            ),
            value: _postToServer,
            onChanged: (value) => setState(() => _postToServer = value),
          ),
          const Divider(height: 32),
          Text(
            'Live model output',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          raw.when(
            data: (result) => Text(
              '${result.label} · '
              '${(result.confidence * 100).toStringAsFixed(0)}%',
            ),
            loading: () => const Text(
              'Waiting for first frame...',
              style: TextStyle(color: Colors.grey),
            ),
            error: (error, _) =>
                Text('$error', style: const TextStyle(color: Colors.red)),
          ),
          const Divider(height: 32),
          Text(
            'Detections (${history.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (history.isEmpty)
            Text(
              'None yet — needs > '
              '${(pipeline.confidenceThreshold * 100).toStringAsFixed(0)}% '
              'confidence after NMS.',
              style: const TextStyle(color: Colors.grey),
            ),
          for (final event in history)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.warning_amber_rounded),
              title: Text(event.type),
              subtitle: Text(
                '${(event.confidence * 100).toStringAsFixed(0)}% · '
                '${event.latitude.toStringAsFixed(5)}, '
                '${event.longitude.toStringAsFixed(5)}',
              ),
            ),
        ],
      ),
    );
  }
}

class _CameraPreviewBox extends StatelessWidget {
  const _CameraPreviewBox({required this.controller});

  final CameraController? controller;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    final ready = controller != null && controller.value.isInitialized;

    return AspectRatio(
      aspectRatio: ready ? controller.value.aspectRatio : 16 / 9,
      child: ColoredBox(
        color: Colors.black,
        child: ready
            ? CameraPreview(controller)
            : const Center(
                child: Text(
                  'Camera off',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
      ),
    );
  }
}
