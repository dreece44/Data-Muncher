import 'package:flutter/material.dart';

import '../../application/storage_alert/storage_alert.dart';

/// In-app storage warning on the home page (DAT-36).
///
/// Shown alongside the notification, and the only warning for users who
/// turned notifications off. Wraps on narrow phones and with large text.
class StorageAlertBanner extends StatelessWidget {
  const StorageAlertBanner({
    super.key,
    required this.level,
    required this.reading,
    required this.onFreeUp,
  });

  final StorageLevel level;
  final StorageReading reading;
  final VoidCallback onFreeUp;

  @override
  Widget build(BuildContext context) {
    final critical = level == StorageLevel.critical;
    final color = critical ? Colors.red.shade700 : Colors.orange.shade800;
    final message = StorageAlertMessage.of(level, reading);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(critical ? Icons.sd_card_alert : Icons.storage, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(message.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text(message.body),
              ]),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onFreeUp, child: const Text('FREE UP SPACE')),
          ),
        ]),
      ),
    );
  }
}
