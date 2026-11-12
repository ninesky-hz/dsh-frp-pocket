import 'package:flutter/material.dart';

import '../services/probe.dart';

/// 主机状态点：绿=在线、橙=隧道可达、红=离线、灰=未知。
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, this.size = 10});

  final ProbeStatus? status;
  final double size;

  static Color colorFor(BuildContext context, ProbeStatus? status) {
    switch (status) {
      case ProbeStatus.online:
        return const Color(0xFF16A34A);
      case ProbeStatus.tunnelOnly:
        return const Color(0xFFF59E0B);
      case ProbeStatus.offline:
        return const Color(0xFFDC2626);
      case null:
        return Theme.of(context).colorScheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorFor(context, status),
        shape: BoxShape.circle,
      ),
    );
  }
}
