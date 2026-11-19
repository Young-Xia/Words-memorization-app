import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmemory/ui/consolidation_icon.dart';

void main() {
  for (final filled in [false, true]) {
    testWidgets(
      'bookmark paints visible pixels without an icon font: $filled',
      (tester) async {
        final key = GlobalKey();
        await tester.pumpWidget(
          Center(
            child: RepaintBoundary(
              key: key,
              child: IconTheme(
                data: const IconThemeData(color: Colors.red, size: 32),
                child: ConsolidationIcon(filled: filled),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final pixels = await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!;
        });
        var visible = 0;
        for (var i = 3; i < pixels!.lengthInBytes; i += 4) {
          if (pixels.getUint8(i) > 100) visible++;
        }
        expect(visible, greaterThan(80));
        expect(find.byType(Icon), findsNothing);
      },
    );
  }
}
