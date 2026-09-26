import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/hazards.dart';
import '../../core/providers.dart';
import '../../core/services/location_service.dart';
import '../detection/detection_providers.dart';

/// Connection, sharing and device details — everything a driver sets once
/// and a developer checks when something isn't working.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: const [
          _Section(title: 'Server', child: _ServerCard()),
          _Section(title: 'Sharing', child: _SharingCard()),
          _Section(title: 'Location', child: _LocationCard()),
          _Section(title: 'This device', child: _DeviceCard()),
          _Section(title: 'Detection model', child: _ModelCard()),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Card(clipBehavior: Clip.antiAlias, child: child),
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
class _ServerCard extends ConsumerStatefulWidget {
  const _ServerCard();

  @override
  ConsumerState<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends ConsumerState<_ServerCard> {
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
    // A changed address re-checks on its own; an unchanged one needs a nudge.
    ref.invalidate(serverReachableProvider);
  }

  @override
  Widget build(BuildContext context) {
    final reachable = ref.watch(serverReachableProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'http://192.168.1.10:8000',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatusDot(ok: reachable.isLoading ? null : reachable.value),
              const SizedBox(width: 8),
              Expanded(
                child: Text(switch (reachable) {
                  AsyncLoading() => 'Checking…',
                  AsyncData(value: true) => 'Connected',
                  _ => 'Can’t reach the server',
                }),
              ),
              TextButton(
                onPressed: () => ref.invalidate(serverReachableProvider),
                child: const Text('Test'),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: _save,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SharingCard extends ConsumerWidget {
  const _SharingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile(
      secondary: const Icon(Icons.share_location_outlined),
      title: const Text('Report hazards I detect'),
      subtitle: const Text('Warns other cars near the hazard'),
      value: ref.watch(reportDetectionsProvider),
      onChanged: ref.read(reportDetectionsProvider.notifier).set,
    );
  }
}

class _LocationCard extends ConsumerStatefulWidget {
  const _LocationCard();

  @override
  ConsumerState<_LocationCard> createState() => _LocationCardState();
}

class _LocationCardState extends ConsumerState<_LocationCard> {
  Position? _position;
  String? _positionError;
  bool _locating = false;

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _positionError = null;
    });
    try {
      final position = await ref
          .read(locationServiceProvider)
          .getCurrentPosition()
          .timeout(const Duration(seconds: 10));
      if (mounted) setState(() => _position = position);
    } on Exception catch (error) {
      if (mounted) setState(() => _positionError = '$error');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(locationAccessProvider).value;
    final service = ref.read(locationServiceProvider);
    final pinging = ref.watch(locationPingerProvider).isRunning;
    final position = _position;

    return Column(
      children: [
        ListTile(
          leading: _StatusDot(
            ok: access == null ? null : access == LocationAccess.granted,
          ),
          title: const Text('Permission'),
          subtitle: Text(switch (access) {
            null => 'Checking…',
            LocationAccess.granted => 'Allowed',
            LocationAccess.serviceDisabled => 'Location is turned off',
            LocationAccess.denied => 'Not allowed yet',
            LocationAccess.deniedForever => 'Blocked in system settings',
          }),
          trailing: switch (access) {
            LocationAccess.serviceDisabled => TextButton(
              onPressed: service.openLocationSettings,
              child: const Text('Turn on'),
            ),
            LocationAccess.deniedForever => TextButton(
              onPressed: service.openAppSettings,
              child: const Text('Open settings'),
            ),
            LocationAccess.denied => TextButton(
              onPressed: () => ref.invalidate(locationAccessProvider),
              child: const Text('Allow'),
            ),
            _ => null,
          },
        ),
        ListTile(
          leading: const Icon(Icons.my_location),
          title: const Text('Current position'),
          subtitle: Text(
            _positionError ??
                (position == null
                    ? 'Tap refresh to get a fix'
                    : '${position.latitude.toStringAsFixed(5)}, '
                          '${position.longitude.toStringAsFixed(5)} '
                          '(±${position.accuracy.round()} m)'),
          ),
          trailing: _locating
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  onPressed: access == LocationAccess.granted ? _locate : null,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                ),
        ),
        ListTile(
          leading: _StatusDot(ok: pinging),
          title: const Text('Position sharing'),
          subtitle: Text(
            pinging
                ? 'Sending every 20 s so nearby alerts reach you'
                : 'Starts once location is allowed',
          ),
        ),
      ],
    );
  }
}

class _DeviceCard extends ConsumerWidget {
  const _DeviceCard();

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label copied')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final carId = ref.watch(carIdProvider);
    final token = ref.watch(fcmTokenProvider);

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.directions_car_outlined),
          title: const Text('Car ID'),
          subtitle: Text(carId, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.copy, size: 18),
          onTap: () => _copy(context, 'Car ID', carId),
        ),
        ListTile(
          leading: _StatusDot(ok: token.isLoading ? null : token.value != null),
          title: const Text('Push notifications'),
          subtitle: Text(
            token.when(
              loading: () => 'Setting up…',
              error: (error, _) => '$error',
              data: (value) => value ?? 'Permission refused',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Needed to target a test push from the Firebase console.
          trailing: token.value == null
              ? null
              : const Icon(Icons.copy, size: 18),
          onTap: token.value == null
              ? null
              : () => _copy(context, 'Push token', token.value!),
        ),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(modelAsset.split('/').last, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Alerts fire once a hazard reaches its confidence threshold:',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final label in modelLabels)
                Chip(
                  avatar: Icon(
                    hazardStyle(label).icon,
                    color: hazardStyle(label).color,
                    size: 18,
                  ),
                  label: Text(
                    '${hazardStyle(label).label} '
                    '${((modelClassThresholds[label] ?? 0.5) * 100).round()}%',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.ok});

  /// null while still checking.
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    return Icon(
      switch (ok) {
        true => Icons.check_circle,
        false => Icons.error,
        null => Icons.hourglass_empty,
      },
      color: switch (ok) {
        true => const Color(0xFF43A047),
        false => Theme.of(context).colorScheme.error,
        null => Colors.grey,
      },
    );
  }
}
