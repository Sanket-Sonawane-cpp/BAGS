import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Turns a raw camera frame into the exact tensor bytes an interpreter's
/// input expects.
///
/// Two things have to match whatever `.tflite` model is loaded, and neither
/// is hardcoded here — [InferenceService] reads both off the model's input
/// tensor at load time and passes them in: the spatial size to resize to,
/// and whether pixels should be raw bytes (quantized int8/uint8 models) or
/// normalized floats (float32 models).
class FramePreprocessor {
  const FramePreprocessor();

  /// Decodes [image] into an RGB [img.Image].
  ///
  /// This is the expensive step — a plane-by-plane pixel conversion — so
  /// [DetectionPipeline] only calls it for frames it has decided to run
  /// inference on, not every frame the camera produces.
  img.Image decode(CameraImage image) {
    return switch (image.format.group) {
      ImageFormatGroup.bgra8888 => _fromBgra8888(image),
      ImageFormatGroup.nv21 => _fromNv21(image),
      _ => throw UnsupportedError(
          'Unsupported camera format ${image.format.group}. '
          'CameraService only requests bgra8888 (iOS) or nv21 (Android).',
        ),
    };
  }

  img.Image _fromBgra8888(CameraImage image) {
    return img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.planes[0].bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
  }

  /// NV21: one full-resolution Y plane, then one half-resolution plane with
  /// V and U bytes interleaved. Converted with the standard BT.601 formula.
  ///
  /// NV21 is fundamentally one contiguous buffer (Y rows, then interleaved
  /// VU rows) rather than genuinely separate planes the way YUV_420_888 is —
  /// on Android (camera_android_camerax) that arrives here as a single
  /// `image.planes[0]` holding everything, not the Y/UV split this used to
  /// assume; that assumption crashed every frame with a `RangeError` reading
  /// a nonexistent `planes[1]`.
  img.Image _fromNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final bytes = image.planes[0].bytes;
    final yRowStride = image.planes[0].bytesPerRow;
    final ySize = yRowStride * height;
    // The VU section immediately follows Y in the same buffer, at half
    // resolution; its row stride matches Y's (no separate metadata for it
    // since it isn't a separate plane).
    final uvRowStride = yRowStride;

    final out = img.Image(width: width, height: height, numChannels: 3);
    for (var y = 0; y < height; y++) {
      final yRow = y * yRowStride;
      final uvRow = ySize + (y >> 1) * uvRowStride;
      for (var x = 0; x < width; x++) {
        final yValue = bytes[yRow + x].toDouble();
        final uvIndex = uvRow + (x & ~1);
        // NV21 interleaves V before U.
        final v = bytes[uvIndex] - 128.0;
        final u = bytes[uvIndex + 1] - 128.0;

        final r = (yValue + 1.402 * v).clamp(0, 255);
        final g = (yValue - 0.344136 * u - 0.714136 * v).clamp(0, 255);
        final b = (yValue + 1.772 * u).clamp(0, 255);

        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  /// Resizes [decoded] to [width]x[height] and returns RGB pixels normalized
  /// to 0.0-1.0, interleaved (r, g, b, r, g, b, ...).
  ///
  /// Deliberately stops at floats in 0-1 rather than the interpreter's exact
  /// input byte layout: whether the model wants those floats as-is or
  /// quantized to uint8/int8 is a property of the model, not the camera
  /// frame, so [InferenceService] does that packing once it knows which.
  Float32List toNormalizedFloats(
    img.Image decoded, {
    required int width,
    required int height,
  }) {
    final resized = img.copyResize(decoded, width: width, height: height);

    final floats = Float32List(width * height * 3);
    var i = 0;
    for (final pixel in resized) {
      floats[i++] = pixel.r / 255.0;
      floats[i++] = pixel.g / 255.0;
      floats[i++] = pixel.b / 255.0;
    }
    return floats;
  }
}
