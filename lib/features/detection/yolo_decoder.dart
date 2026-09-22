import 'dart:math' as math;

/// One decoded, post-NMS detection from a YOLO-style output tensor.
class YoloDetection {
  const YoloDetection({
    required this.classIndex,
    required this.confidence,
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
  });

  final int classIndex;
  final double confidence;

  /// Box center and size, normalized to 0.0-1.0 of the input frame.
  final double centerX;
  final double centerY;
  final double width;
  final double height;
}

/// Decodes a raw YOLO detection-head output into boxes.
///
/// Follows the Ultralytics YOLOv8 export convention: one output tensor of
/// `4 + numClasses` attributes (box `cx, cy, w, h`, then one score per
/// class — no separate objectness score, unlike YOLOv5) per anchor.
///
/// The tensor can come out as `[attributes, anchors]` or
/// `[anchors, attributes]` depending on how the ONNX→TFLite conversion
/// ordered it; [decode] is told which via [attributesFirst] rather than
/// this class guessing, since [InferenceService] already has to inspect the
/// tensor's shape to size its buffers and is the right place to decide that
/// once, not per frame.
class YoloDecoder {
  const YoloDecoder({this.scoreThreshold = 0.25, this.iouThreshold = 0.45});

  /// Minimum per-class score for a box to be considered a candidate at all,
  /// before NMS. Kept low relative to [DetectionPipeline.confidenceThreshold]
  /// so NMS has real candidates to pick the best box from.
  final double scoreThreshold;

  /// Boxes of the same class overlapping more than this (IoU) are treated
  /// as duplicates of one object; only the highest-confidence one survives.
  final double iouThreshold;

  /// [values] is the output tensor's data, already dequantized to real
  /// scores/coordinates and flattened in row-major order.
  List<YoloDetection> decode({
    required List<double> values,
    required int numAttributes, // 4 + numClasses
    required int numAnchors,
    required bool attributesFirst,
    required int inputWidth,
    required int inputHeight,
  }) {
    final numClasses = numAttributes - 4;
    if (numClasses <= 0) return const [];

    double at(int attribute, int anchor) => attributesFirst
        ? values[attribute * numAnchors + anchor]
        : values[anchor * numAttributes + attribute];

    // Candidate generation: best-scoring class per anchor, thresholded.
    final candidates = <YoloDetection>[];
    for (var a = 0; a < numAnchors; a++) {
      var bestClass = 0;
      var bestScore = at(4, a);
      for (var c = 1; c < numClasses; c++) {
        final score = at(4 + c, a);
        if (score > bestScore) {
          bestScore = score;
          bestClass = c;
        }
      }
      if (bestScore < scoreThreshold) continue;

      candidates.add(
        YoloDetection(
          classIndex: bestClass,
          confidence: bestScore,
          centerX: at(0, a),
          centerY: at(1, a),
          width: at(2, a),
          height: at(3, a),
        ),
      );
    }

    if (candidates.isEmpty) return const [];

    // Ultralytics exports put box coordinates in input-pixel space
    // (0-inputWidth/Height), not normalized 0-1 — detect which this is
    // rather than assume, since the conversion step can change it.
    final looksNormalized = candidates.every(
      (d) => d.centerX <= 1.5 && d.centerY <= 1.5,
    );
    final normalized = looksNormalized
        ? candidates
        : [
            for (final d in candidates)
              YoloDetection(
                classIndex: d.classIndex,
                confidence: d.confidence,
                centerX: d.centerX / inputWidth,
                centerY: d.centerY / inputHeight,
                width: d.width / inputWidth,
                height: d.height / inputHeight,
              ),
          ];

    return _nms(normalized);
  }

  List<YoloDetection> _nms(List<YoloDetection> candidates) {
    final byClass = <int, List<YoloDetection>>{};
    for (final d in candidates) {
      (byClass[d.classIndex] ??= []).add(d);
    }

    final kept = <YoloDetection>[];
    for (final boxes in byClass.values) {
      final remaining = List<YoloDetection>.from(boxes)
        ..sort((a, b) => b.confidence.compareTo(a.confidence));
      while (remaining.isNotEmpty) {
        final best = remaining.removeAt(0);
        kept.add(best);
        remaining.removeWhere((d) => _iou(best, d) > iouThreshold);
      }
    }
    return kept;
  }

  double _iou(YoloDetection a, YoloDetection b) {
    final aLeft = a.centerX - a.width / 2;
    final aRight = a.centerX + a.width / 2;
    final aTop = a.centerY - a.height / 2;
    final aBottom = a.centerY + a.height / 2;
    final bLeft = b.centerX - b.width / 2;
    final bRight = b.centerX + b.width / 2;
    final bTop = b.centerY - b.height / 2;
    final bBottom = b.centerY + b.height / 2;

    final interWidth = math.max(
      0.0,
      math.min(aRight, bRight) - math.max(aLeft, bLeft),
    );
    final interHeight = math.max(
      0.0,
      math.min(aBottom, bBottom) - math.max(aTop, bTop),
    );
    final intersection = interWidth * interHeight;

    final aArea = math.max(0.0, aRight - aLeft) * math.max(0.0, aBottom - aTop);
    final bArea = math.max(0.0, bRight - bLeft) * math.max(0.0, bBottom - bTop);
    final union = aArea + bArea - intersection;

    return union <= 0 ? 0 : intersection / union;
  }
}
