import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/models/alert_event.dart';
import '../../core/models/detection_event.dart';
import '../../core/providers.dart';
import '../../core/services/location_service.dart';
import 'alert_banner.dart';

/// Working screen for the alerts half of the app.
///
/// This is a development surface, not the final driving UI: it surfaces the
/// FCM token, server reachability and GPS state so each piece can be verified
/// independently before the detection pipeline exists to drive it.
class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  AlertEvent? _banner;
  Timer? _bannerTimer;

  Position? _position;
  LocationAccess? _access;
  bool? _serverReachable;
  String? _status;

  @override
  void initState() {
    super.initState();
    // Deferred because these touch providers, which cannot be read while the
    // widget is still being constructed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshLocation();
      _checkServer();
    });
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLocation() async {
    final service = ref.read(locationServiceProvider);
    final access = await service.ensurePermission();
    if (!mounted) return;

    setState(() => _access = access);
    if (access != LocationAccess.granted) return;

    try {
      final position = await service.getCurrentPosition();
      if (mounted) setState(() => _position = position);
    } on Exception catch (error) {
      if (mounted) setState(() => _status = 'Location failed: $error');
    }
  }

  Future<void> _checkServer() async {
    final reachable = await ref.read(apiServiceProvider).isReachable();
    if (mounted) setState(() => _serverReachable = reachable);
  }

  /// Sends a fake detection at the current position.
  ///
  /// Lets the whole upload path be exercised before Member A's camera pipeline
  /// exists to produce real ones.
  Future<void> _sendTestDetection() async {
    final position = _position;
    if (position == null) {
      setState(() => _status = 'Need a GPS fix first');
      return;
    }

    setState(() => _status = 'Sending...');
    try {
      final id = await ref.read(apiServiceProvider).postDetection(
        DetectionEvent(
          type: 'pothole',
          confidence: 0.9,
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      if (mounted) setState(() => _status = 'Server accepted it as $id');
    } on Exception catch (error) {
      if (mounted) setState(() => _status = '$error');
    }
  }

  void _showBanner(AlertEvent alert) {
    // A driver is not looking at the screen when this fires, so the alert has
    // to announce itself physically as well as visually.
    HapticFeedback.heavyImpact();

    setState(() => _banner = alert);
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _banner = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(alertStreamProvider, (_, next) {
      final alert = next.value;
      if (alert != null) _showBanner(alert);
    });

    // Read so the provider stays alive and keeps accumulating history.
    final alerts = ref.watch(alertHistoryProvider);
    final token = ref.watch(fcmTokenProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: Column(
        children: [
          if (_banner != null)
            AlertBanner(
              alert: _banner!,
              onDismiss: () => setState(() => _banner = null),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _ServerField(
                  reachable: _serverReachable,
                  onChanged: () {
                    setState(() => _serverReachable = null);
                    _checkServer();
                  },
                ),
                _StatusTile(
                  label: 'Location permission',
                  value: _access?.name ?? 'checking...',
                  ok: _access == null ? null : _access == LocationAccess.granted,
                ),
                _StatusTile(
                  label: 'Position',
                  value: _position == null
                      ? 'no fix'
                      : '${_position!.latitude.toStringAsFixed(5)}, '
                          '${_position!.longitude.toStringAsFixed(5)}',
                  ok: _position != null,
                ),
                _StatusTile(
                  label: 'FCM token',
                  value: token.when(
                    loading: () => 'requesting...',
                    error: (error, _) => '$error',
                    data: (value) => value ?? 'permission refused',
                  ),
                  ok: token.value != null,
                  // Needed to target a test push from the Firebase console.
                  onTap: token.value == null
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: token.value!),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Token copied')),
                            );
                          }
                        },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _refreshLocation,
                      child: const Text('Refresh GPS'),
                    ),
                    FilledButton.tonal(
                      onPressed: _checkServer,
                      child: const Text('Ping server'),
                    ),
                    FilledButton.tonal(
                      onPressed: _sendTestDetection,
                      child: const Text('Send test detection'),
                    ),
                  ],
                ),
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  Text(_status!, style: const TextStyle(color: Colors.blueGrey)),
                ],
                const Divider(height: 32),
                Text(
                  'Alerts received (${alerts.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (alerts.isEmpty)
                  const Text(
                    'None yet. Send a test push from the Firebase console, '
                    'targeting the token above.',
                    style: TextStyle(color: Colors.grey),
                  ),
                for (final alert in alerts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.warning_amber_rounded),
                    title: Text(alert.type),
                    subtitle: Text(
                      '${formatDistance(alert.distanceMeters)} · '
                      '${alert.timestamp.toLocal()}',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Editable server address.
///
/// A text field rather than a build-time constant because a laptop's LAN IP
/// changes with every DHCP lease, and rebuilding the app for each one wastes
/// minutes that add up fast.
class _ServerField extends ConsumerStatefulWidget {
  const _ServerField({required this.reachable, required this.onChanged});

  final bool? reachable;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ServerField> createState() => _ServerFieldState();
}

class _ServerFieldState extends ConsumerState<_ServerField> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(serverUrlProvider),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    await ref.read(serverUrlProvider.notifier).set(_controller.text);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            switch (widget.reachable) {
              null => Icons.hourglass_empty,
              true => Icons.check_circle,
              false => Icons.error,
            },
            color: switch (widget.reachable) {
              null => Colors.grey,
              true => Colors.green,
              false => Colors.red,
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Server',
                isDense: true,
                helperText: switch (widget.reachable) {
                  null => 'checking...',
                  true => 'reachable',
                  false => 'unreachable',
                },
              ),
              onSubmitted: (_) => _save(),
            ),
          ),
          IconButton(
            onPressed: _save,
            icon: const Icon(Icons.save),
            tooltip: 'Save and retest',
          ),
        ],
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.label,
    required this.value,
    this.ok,
    this.onTap,
  });

  final String label;
  final String value;

  /// null renders neutral, for a check that has not finished yet.
  final bool? ok;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      onTap: onTap,
      leading: Icon(
        switch (ok) {
          null => Icons.hourglass_empty,
          true => Icons.check_circle,
          false => Icons.error,
        },
        color: switch (ok) {
          null => Colors.grey,
          true => Colors.green,
          false => Colors.red,
        },
      ),
      title: Text(label),
      subtitle: Text(value),
      trailing: onTap == null ? null : const Icon(Icons.copy, size: 18),
    );
  }
}
