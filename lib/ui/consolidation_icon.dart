import 'package:flutter/material.dart';

/// A bookmark drawn as a path, independent of bundled icon font glyphs.
class ConsolidationIcon extends StatelessWidget {
  const ConsolidationIcon({super.key, this.filled = false, this.size});

  final bool filled;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final color = (theme.color ?? Colors.black).withValues(
      alpha: theme.opacity ?? 1,
    );
    final dimension = size ?? theme.size ?? 24;
    return SizedBox.square(
      dimension: dimension,
      child: CustomPaint(painter: _BookmarkPainter(color, filled)),
    );
  }
}

class _BookmarkPainter extends CustomPainter {
  const _BookmarkPainter(this.color, this.filled);

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * .25, size.height * .13)
      ..lineTo(size.width * .75, size.height * .13)
      ..quadraticBezierTo(
        size.width * .8,
        size.height * .13,
        size.width * .8,
        size.height * .18,
      )
      ..lineTo(size.width * .8, size.height * .88)
      ..lineTo(size.width * .5, size.height * .7)
      ..lineTo(size.width * .2, size.height * .88)
      ..lineTo(size.width * .2, size.height * .18)
      ..quadraticBezierTo(
        size.width * .2,
        size.height * .13,
        size.width * .25,
        size.height * .13,
      )
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = size.width / 12
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _BookmarkPainter oldDelegate) =>
      color != oldDelegate.color || filled != oldDelegate.filled;
}
