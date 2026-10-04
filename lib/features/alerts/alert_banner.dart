import 'package:flutter/material.dart';

import '../../core/hazards.dart';
import '../../core/models/alert_event.dart';

/// A single hazard warning, sized to be read at a glance while driving.
///
/// Everything here is deliberately blunt: a strong colour per hazard, and
/// distance as the largest text, because distance is what the driver
/// actually acts on.
class AlertBanner extends StatelessWidget {
  const AlertBanner({required this.alert, this.onDismiss, super.key});

  final AlertEvent alert;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final style = hazardStyle(alert.type);
    return Material(
      color: style.color,
      elevation: 3,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 6, 14),
        child: Row(
          children: [
            Icon(style.icon, color: Colors.white, size: 40),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${formatDistance(alert.distanceMeters)} ahead',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    alert.confirmed
                        ? style.label.toUpperCase()
                        : '${style.label.toUpperCase()} · UNCONFIRMED',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.4,
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
    );
  }
}
