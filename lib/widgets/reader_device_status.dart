import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Updates independently of the chapter layout; never polls in the background.
class ReaderDeviceStatus extends StatefulWidget {
  const ReaderDeviceStatus({super.key, required this.color});
  final Color color;

  @override
  State<ReaderDeviceStatus> createState() => _ReaderDeviceStatusState();
}

class _ReaderDeviceStatusState extends State<ReaderDeviceStatus>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('moe.yutro.yomiru/reader_battery');
  Timer? _timer;
  DateTime _time = DateTime.now();
  int? _battery;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  Future<void> _refresh() async {
    _timer?.cancel();
    final generation = ++_generation;
    setState(() => _time = DateTime.now());
    // Align the clock to the next minute with a safety buffer against scheduler jitter.
    final msToNextMinute =
        60000 - (DateTime.now().millisecondsSinceEpoch % 60000) + 50;
    _timer = Timer(Duration(milliseconds: msToNextMinute), _refresh);
    int? level;
    try {
      level = await _channel.invokeMethod<int>('level');
    } catch (_) {
      // Unsupported devices show an unknown battery, never a fabricated charge.
    }
    if (!mounted || generation != _generation) return;
    setState(() =>
        _battery = level == null || level < 0 ? null : level.clamp(0, 100));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    } else {
      _generation++;
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time =
        '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Semantics(
          label: _battery == null ? '电量未知' : '电量 $_battery%',
          child: SizedBox(
            width: 21,
            height: 11,
            child:
                CustomPaint(painter: _BatteryPainter(_battery, widget.color)),
          ),
        ),
        const SizedBox(width: 6),
        Text(time, style: TextStyle(fontSize: 11, color: widget.color)),
      ]),
    );
  }
}

class _BatteryPainter extends CustomPainter {
  const _BatteryPainter(this.level, this.color);
  final int? level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final body = Rect.fromLTWH(0.5, 0.5, size.width - 3, size.height - 1);
    final paint = Paint()..color = color;
    canvas.drawRRect(
        RRect.fromRectAndRadius(body, const Radius.circular(2)),
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    paint.style = PaintingStyle.fill;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(size.width - 2, size.height / 2 - 2, 2, 4),
            const Radius.circular(1)),
        paint);
    if (level == null) {
      canvas.drawRect(
          Rect.fromCenter(center: body.center, width: 5, height: 1), paint);
    } else if (level! > 0) {
      final inner = body.deflate(2);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(inner.left, inner.top, inner.width * level! / 100,
                  inner.height),
              const Radius.circular(0.5)),
          paint);
    }
  }

  @override
  bool shouldRepaint(_BatteryPainter oldDelegate) =>
      oldDelegate.level != level || oldDelegate.color != color;
}
