import 'package:flutter/material.dart';

import '../../core/models/alert_event.dart';

/// A single obstruction warning, sized to be read at a glance while driving.
///
/// Everything here is deliberately blunt: one line of large text, a strong
/// colour, and distance as the most prominent value, because distance is what
/// the driver actually acts on.
class AlertBanner extends StatelessWidget {
  const AlertBanner({required this.alert, this.onDismiss, super.key});

  final AlertEvent alert;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFB3261E),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.white, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatDistance(alert.distanceMeters),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      alert.type.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: 'Dismiss',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders a distance the way a driver reads a road sign.
///
/// Metre precision is noise at speed, so anything past 1 km is shown in
/// kilometres and shorter distances are rounded to the nearest 10 m.
String formatDistance(double meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1)} km ahead';
  }
  final rounded = (meters / 10).round() * 10;
  return '$rounded m ahead';
}
