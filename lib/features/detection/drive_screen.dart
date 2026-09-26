import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hazards.dart';
import '../../core/providers.dart';
import '../../core/services/location_service.dart';
import '../settings/settings_screen.dart';
import 'detection_pipeline.dart';
import 'detection_providers.dart';

/// The main driving screen: live camera, what the model currently sees, and
/// one big control to start or stop detection.
///
/// Detection keeps running while another tab is showing — the camera stream
/// only stops on the Stop button — so hazards are still caught while the
/// driver follows a route on the map.
class DriveScreen extends ConsumerStatefulWidget {
  const DriveScreen({super.key});

  @override
  ConsumerState<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends ConsumerState<DriveScreen> {
  CameraController? _controller;
  String? _error;
  bool _starting = false;

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final controller = await ref.read(detectionPipelineProvider).start();
      if (!mounted) return;
      setState(() => _controller = controller);
      ref.read(detectionRunningProvider.notifier).set(true);
    } catch (error) {
      // Deliberately broad, not `on Exception`: a missing camera, an
      // unsupported frame format and a rejected hardware delegate all throw
      // Error subtypes, and those need to reach the screen too.
      // ignore: avoid_catches_without_on_clauses
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    await ref.read(detectionPipelineProvider).stop();
    if (!mounted) return;
    setState(() => _controller = null);
    ref.read(detectionRunningProvider.notifier).set(false);
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(detectionRunningProvider);
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (running && controller != null && controller.value.isInitialized)
            Center(child: CameraPreview(controller))
          else
            const _IdleBackdrop(),
          const Positioned(top: 0, left: 0, right: 0, child: _TopBar()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomPanel(
              running: running,
              starting: _starting,
              error: _error,
              onStart: _start,
              onStop: _stop,
            ),
          ),
        ],
      ),
    );
  }
}

class _IdleBackdrop extends StatelessWidget {
  const _IdleBackdrop();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B1F24), Color(0xFF0B0D10)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 180),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.06),
                ),
                child: const Icon(
                  Icons.videocam_outlined,
                  size: 48,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Ready to drive',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Mount your phone facing the road, then start detection. '
                'Hazards it spots are shared with cars nearby.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white60,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Server / GPS / speed at a glance, plus the way into settings.
class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(serverReachableProvider);
    final access = ref.watch(locationAccessProvider);
    final frame = ref.watch(rawInferenceStreamProvider).value;
    final running = ref.watch(detectionRunningProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xAA000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 16),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _StatusChip(
                      icon: Icons.cloud_outlined,
                      label: switch (server) {
                        AsyncData(value: true) => 'Server',
                        AsyncData() => 'Offline',
                        _ => 'Server…',
                      },
                      ok: server.value,
                      onTap: () => ref.invalidate(serverReachableProvider),
                    ),
                    _StatusChip(
                      icon: Icons.gps_fixed,
                      label: switch (access) {
                        AsyncData(value: LocationAccess.granted) => 'GPS',
                        AsyncData() => 'No GPS',
                        _ => 'GPS…',
                      },
                      ok: access.hasValue
                          ? access.value == LocationAccess.granted
                          : null,
                    ),
                    if (running && frame != null)
                      _StatusChip(
                        icon: Icons.speed,
                        label: '${frame.elapsed.inMilliseconds} ms',
                        ok: true,
                      ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.ok,
    this.onTap,
  });

  final IconData icon;
  final String label;

  /// null while still checking.
  final bool? ok;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dot = switch (ok) {
      true => const Color(0xFF66BB6A),
      false => const Color(0xFFEF5350),
      null => Colors.white38,
    };
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(width: 6),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomPanel extends ConsumerWidget {
  const _BottomPanel({
    required this.running,
    required this.starting,
    required this.error,
    required this.onStart,
    required this.onStop,
  });

  final bool running;
  final bool starting;
  final String? error;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final history = ref.watch(detectionHistoryProvider);
    final last = history.isEmpty ? null : history.first;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xDD000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (running) const _LiveReadout(),
            if (error != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            if (last != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Last spotted: ${hazardStyle(last.type).label} · '
                  '${formatAgo(last.timestamp)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            if (running)
              FilledButton.icon(
                onPressed: onStop,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(60),
                ),
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop detection'),
              )
            else
              FilledButton.icon(
                onPressed: starting ? null : onStart,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(60),
                ),
                icon: starting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(starting ? 'Starting…' : 'Start detection'),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the model sees right now, in one large pill.
class _LiveReadout extends ConsumerWidget {
  const _LiveReadout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frame = ref.watch(rawInferenceStreamProvider);
    final pipeline = ref.watch(detectionPipelineProvider);

    final Widget pill = switch (frame) {
      AsyncData(value: FrameResult(result: final result?))
          when result.confidence >= pipeline.thresholdFor(result.label) =>
        _Pill(
          key: ValueKey(result.label),
          style: hazardStyle(result.label),
          text:
              '${hazardStyle(result.label).label} · '
              '${(result.confidence * 100).round()}%',
        ),
      AsyncData() => const _Pill(
        key: ValueKey('clear'),
        text: 'Scanning the road',
      ),
      AsyncError(:final error) => _Pill(
        key: const ValueKey('error'),
        text: 'Frame failed: $error',
      ),
      _ => const _Pill(key: ValueKey('wait'), text: 'Warming up the model…'),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: pill,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.style, super.key});

  final String text;
  final HazardStyle? style;

  @override
  Widget build(BuildContext context) {
    final style = this.style;
    final hazard = style != null && style.isHazard;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: hazard ? style.color : Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(40),
          border: hazard ? null : Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              style?.icon ?? Icons.radar,
              color: Colors.white,
              size: hazard ? 28 : 20,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: hazard ? 22 : 16,
                  fontWeight: hazard ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
