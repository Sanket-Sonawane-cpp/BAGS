import 'dart:typed_data';

import 'package:bags/features/detection/frame_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 4x2 BGRA frame: left half pure red, right half pure blue.
RawFrame _frame() {
  final bytes = Uint8List(4 * 2 * 4);
  for (var y = 0; y < 2; y++) {
    for (var x = 0; x < 4; x++) {
      final p = (y * 4 + x) * 4;
      final red = x < 2;
      bytes[p] = red ? 0 : 255; // B
      bytes[p + 1] = 0; // G
      bytes[p + 2] = red ? 255 : 0; // R
      bytes[p + 3] = 255; // A
    }
  }
  return RawFrame(
    format: RawFormat.bgra8888,
    width: 4,
    height: 2,
    bytesPerRow: 16,
    bytes: bytes,
  );
}

const _pad = 114 / 255;

void main() {
  const preprocessor = FramePreprocessor();

  test('letterbox keeps aspect ratio and pads top/bottom with grey', () {
    // 4x2 into 4x4: drawn 4x2 in rows 1-2, grey rows 0 and 3.
    final t = preprocessor.toTensor(
      _frame(),
      width: 4,
      height: 4,
      letterbox: true,
      channelsFirst: true,
    );
    double at(int channel, int x, int y) => t[channel * 16 + y * 4 + x];

    for (final y in [0, 3]) {
      for (var c = 0; c < 3; c++) {
        expect(at(c, 0, y), closeTo(_pad, 1e-6));
      }
    }
    expect(at(0, 0, 1), 1); // red on the left
    expect(at(2, 0, 1), 0);
    expect(at(0, 3, 2), 0); // blue on the right
    expect(at(2, 3, 2), 1);
  });

  test('without letterbox the frame is stretched to fill', () {
    final t = preprocessor.toTensor(
      _frame(),
      width: 4,
      height: 4,
      letterbox: false,
      channelsFirst: true,
    );
    expect(t[0], 1); // top-left red, no padding row
  });

  test('channels-last interleaves r, g, b per pixel', () {
    final t = preprocessor.toTensor(
      _frame(),
      width: 4,
      height: 2,
      letterbox: true,
      channelsFirst: false,
    );
    expect(t.sublist(0, 3), [1, 0, 0]); // first pixel red
    expect(t.sublist(9, 12), [0, 0, 1]); // fourth pixel blue
  });
}
