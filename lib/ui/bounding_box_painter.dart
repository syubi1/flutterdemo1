import 'package:flutter/material.dart';
import 'package:object_detection/tflite/recognition.dart';
import 'package:object_detection/tflite/stats.dart';
import 'package:object_detection/ui/box_widget.dart';
import 'package:object_detection/ui/camera_view_singleton.dart';
import 'package:object_detection/ui/camera_view.dart';
class BoundingBoxPainter extends CustomPainter {
  final Size imageSize;
  BoundingBoxPainter(this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    double centerX = size.width / 2;
    double centerY = size.height / 2;
    double boxWidth = size.width * 0.4; // 40% of screen width
    double boxHeight = size.height * 0.4; // 40% of screen height

    double left = centerX - boxWidth / 2;
    double top = centerY - boxHeight / 2;
    double right = centerX + boxWidth / 2;
    double bottom = centerY + boxHeight / 2;

    canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
