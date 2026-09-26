import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hazards.dart';
import '../../core/providers.dart';
import '../detection/detection_providers.dart';
import '../settings/settings_screen.dart';

enum _Feed { nearby, mine }

/// History for this session: hazards other cars reported near this one, and
/// hazards this phone spotted itself.
class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  _Feed _feed = _Feed.nearby;

  @override
  Widget build(BuildContext context) {
    final alerts = ref.watch(alertHistoryProvider);
    final detections = ref.watch(detectionHistoryProvider);

    final items = _feed == _Feed.nearby
        ? [
            for (final a in alerts)
              _Item(
                type: a.type,
                detail: '${formatDistance(a.distanceMeters)} away',
                time: a.timestamp,
              ),
          ]
        : [
            for (final d in detections)
              _Item(
                type: d.type,
                detail: '${(d.confidence * 100).round()}% confident',
                time: d.timestamp,
              ),
          ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              onPressed: () => _feed == _Feed.nearby
                  ? ref.read(alertHistoryProvider.notifier).clear()
                  : ref.read(detectionHistoryProvider.notifier).clear(),
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear',
            ),
          IconButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SegmentedButton<_Feed>(
              segments: [
                ButtonSegment(
                  value: _Feed.nearby,
                  icon: const Icon(Icons.cell_tower),
                  label: Text('Nearby (${alerts.length})'),
                ),
                ButtonSegment(
                  value: _Feed.mine,
                  icon: const Icon(Icons.videocam_outlined),
                  label: Text('Spotted by me (${detections.length})'),
                ),
              ],
              selected: {_feed},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _feed = s.first),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? _EmptyState(feed: _feed)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _HazardTile(item: items[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Item {
  const _Item({required this.type, required this.detail, required this.time});

  final String type;
  final String detail;
  final DateTime time;
}

class _HazardTile extends StatelessWidget {
  const _HazardTile({required this.item});

  final _Item item;

  @override
  Widget build(BuildContext context) {
    final style = hazardStyle(item.type);
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: style.color.withValues(alpha: 0.15),
          child: Icon(style.icon, color: style.color),
        ),
        title: Text(
          style.label,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(item.detail),
        trailing: Text(formatAgo(item.time), style: theme.textTheme.bodySmall),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.feed});

  final _Feed feed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, body) = switch (feed) {
      _Feed.nearby => (
        Icons.notifications_none_rounded,
        'No hazards nearby',
        'When another car reports a hazard close to you, it shows up here '
            'and on screen.',
      ),
      _Feed.mine => (
        Icons.videocam_off_outlined,
        'Nothing spotted yet',
        'Start detection on the Drive tab. Hazards your camera finds are '
            'listed here.',
      ),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
