import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';

/// Pixel formats [FramePreprocessor] can read.
enum RawFormat { nv21, bgra8888 }

/// Plain-data copy of a [CameraImage] — just bytes and ints, so it can be
/// sent to a background isolate (see [InferenceService.run]).
class RawFrame {
  const RawFrame({
    required this.format,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.bytes,
  });

  /// NV21 is fundamentally one contiguous buffer (Y rows, then interleaved
  /// VU rows) rather than genuinely separate planes the way YUV_420_888 is —
  /// on Android (camera_android_camerax) that arrives as a single
  /// `image.planes[0]` holding everything; assuming a Y/UV plane split once
  /// crashed every frame with a `RangeError` reading a nonexistent
  /// `planes[1]`.
  factory RawFrame.fromCamera(CameraImage image) {
    final format = switch (image.format.group) {
      ImageFormatGroup.nv21 => RawFormat.nv21,
      ImageFormatGroup.bgra8888 => RawFormat.bgra8888,
      _ => throw UnsupportedError(
        'Unsupported camera format ${image.format.group}. '
        'CameraService only requests bgra8888 (iOS) or nv21 (Android).',
      ),
    };
    final plane = image.planes[0];
    return RawFrame(
      format: format,
      width: image.width,
      height: image.height,
      bytesPerRow: plane.bytesPerRow,
      bytes: plane.bytes,
    );
  }

  final RawFormat format;
  final int width;
  final int height;
  final int bytesPerRow;
  final Uint8List bytes;
}

/// Turns a raw camera frame into the float tensor a model's input expects.
///
/// Colour conversion, resizing and tensor layout happen in one pass over the
/// *output* pixels, so the cost depends on the model's input size, not the
/// camera's — no intermediate full-size RGB image is ever built. Sampling is
/// nearest-neighbour: at 3fps on a phone CPU the difference from bilinear
/// isn't worth the extra per-pixel work.
class FramePreprocessor {
  const FramePreprocessor();

  /// Ultralytics' letterbox fill colour; the model was trained seeing this
  /// grey in padded borders, so padding with anything else skews it.
  static const double _padValue = 114 / 255;

  /// RGB pixels of [frame] scaled into a [width]x[height] tensor, normalized
  /// to 0.0-1.0.
  ///
  /// [letterbox] keeps the frame's aspect ratio and pads the rest with grey,
  /// the way YOLO detectors are trained; without it the frame is stretched
  /// to fill (fine for the placeholder classifier). [channelsFirst] writes
  /// planar NCHW (all R, then all G, then all B) instead of interleaved NHWC.
  Float32List toTensor(
    RawFrame frame, {
    required int width,
    required int height,
    required bool letterbox,
    required bool channelsFirst,
  }) {
    var drawWidth = width;
    var drawHeight = height;
    if (letterbox) {
      final scale = math.min(width / frame.width, height / frame.height);
      drawWidth = (frame.width * scale).round();
      drawHeight = (frame.height * scale).round();
    }
    final padX = (width - drawWidth) ~/ 2;
    final padY = (height - drawHeight) ~/ 2;

    final pixels = width * height;
    final out = Float32List(pixels * 3);
    final bytes = frame.bytes;
    final stride = frame.bytesPerRow;
    final uvStart = stride * frame.height; // NV21 only

    for (var y = 0; y < height; y++) {
      final dy = y - padY;
      final inRows = dy >= 0 && dy < drawHeight;
      final sy = inRows ? dy * frame.height ~/ drawHeight : 0;

      for (var x = 0; x < width; x++) {
        final dx = x - padX;
        double r, g, b;

        if (!inRows || dx < 0 || dx >= drawWidth) {
          r = g = b = _padValue;
        } else {
          final sx = dx * frame.width ~/ drawWidth;
          if (frame.format == RawFormat.nv21) {
            // BT.601; NV21 interleaves V before U at half resolution.
            final luma = bytes[sy * stride + sx].toDouble();
            final uv = uvStart + (sy >> 1) * stride + (sx & ~1);
            final v = bytes[uv] - 128.0;
            final u = bytes[uv + 1] - 128.0;
            r = (luma + 1.402 * v).clamp(0, 255) / 255;
            g = (luma - 0.344136 * u - 0.714136 * v).clamp(0, 255) / 255;
            b = (luma + 1.772 * u).clamp(0, 255) / 255;
          } else {
            final p = sy * stride + sx * 4;
            b = bytes[p] / 255;
            g = bytes[p + 1] / 255;
            r = bytes[p + 2] / 255;
          }
        }

        final i = y * width + x;
        if (channelsFirst) {
          out[i] = r;
          out[pixels + i] = g;
          out[2 * pixels + i] = b;
        } else {
          out[i * 3] = r;
          out[i * 3 + 1] = g;
          out[i * 3 + 2] = b;
        }
      }
    }
    return out;
  }
}
