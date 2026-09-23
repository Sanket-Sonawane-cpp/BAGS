import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'frame_preprocessor.dart';
import 'yolo_decoder.dart';

/// CPU threads the interpreter uses regardless of which delegate (if any)
/// ends up handling the graph. 4 rather than tflite_flutter examples' usual
/// 2: low-end octa-core chipsets (e.g. the Redmi Note 8's Snapdragon 665)
/// have the headroom, and CPU-only is exactly the slow path this matters
/// most for — the delegate fallback chain below means CPU often *is* what
/// actually runs.
const int _interpreterThreads = 4;

/// Shape of the loaded model's output, detected from its output tensor's
/// rank at load time rather than configured — see [InferenceService.load].
enum ModelKind {
  /// One score per class, e.g. `[1, numClasses]`. What the bundled
  /// placeholder model is.
  classifier,

  /// Boxes + per-box class scores, e.g. `[1, 4 + numClasses, numAnchors]`.
  /// The shape a YOLO export (`best.onnx` → `.tflite`) produces.
  detector,
}

/// Result of running the model on a single frame — whichever obstruction
/// (or background class, for a classifier) it's most confident about.
///
/// A detector's box geometry is used internally for NMS ([YoloDecoder]) and
/// discarded after: [DetectionEvent] has no bounding-box fields, only what
/// this class carries.
class ClassificationResult {
  const ClassificationResult({
    required this.classIndex,
    required this.label,
    required this.confidence,
  });

  final int classIndex;

  /// [InferenceService.labels] entry for [classIndex], or `class_<index>`
  /// when no label list was supplied — expected until the ML team publishes
  /// their label set.
  final String label;

  /// 0.0-1.0. Dequantized already if the model's output tensor is int8/uint8.
  final double confidence;
}

/// Loads a `.tflite` model and runs it against camera frames.
///
/// Deliberately generic: it reads the input/output shapes, quantization,
/// and whether the model is a [ModelKind.classifier] or
/// [ModelKind.detector] off the model itself rather than hardcoding them,
/// so swapping the model in `assets/models/` needs no changes here — only
/// [labels] might, once the ML team's label set is known. ONNX exports
/// (e.g. `best.onnx`) must be converted to `.tflite` first — see
/// `tools/convert_to_tflite.py`; this class only loads the TFLite format.
class InferenceService {
  InferenceService({
    required this.modelAsset,
    this.labels,
    this.decoder = const YoloDecoder(),
  });

  /// Asset path of the `.tflite` model, e.g.
  /// `assets/models/placeholder_classifier.tflite`.
  final String modelAsset;

  /// Label for each output class index, in order. When absent, detections
  /// are reported as `class_<index>`.
  final List<String>? labels;

  /// Box decode + NMS for [ModelKind.detector] models. Unused for a
  /// classifier.
  final YoloDecoder decoder;

  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;
  final FramePreprocessor _preprocessor = const FramePreprocessor();

  /// Set only if [_createInterpreter] ends up on the explicit GPU delegate
  /// rung (rung 2) — owns native resources the interpreter doesn't take
  /// ownership of, so it has to be deleted separately in [dispose].
  Delegate? _delegate;

  late int _inputWidth;
  late int _inputHeight;
  late TensorType _inputType;
  late QuantizationParams _inputParams;

  late TensorType _outputType;
  late List<int> _outputShape;
  late int _outputElements;
  late QuantizationParams _outputParams;
  late ModelKind kind;

  bool get isLoaded => _isolateInterpreter != null;

  /// Loads the model, trying progressively more conservative delegate
  /// options until one actually works — see [_createInterpreter].
  Future<void> load() async {
    final interpreter = await _createInterpreter();
    _interpreter = interpreter;

    final input = interpreter.getInputTensor(0);
    final inputShape = input.shape; // [1, height, width, 3]
    _inputHeight = inputShape[1];
    _inputWidth = inputShape[2];
    _inputType = input.type;
    _inputParams = input.params;

    final output = interpreter.getOutputTensor(0);
    _outputType = output.type;
    _outputShape = output.shape;
    _outputElements = Tensor.computeNumElements(_outputShape);
    _outputParams = output.params;

    // rank 2 -> [1, numClasses] (classifier). rank 3 -> boxes + per-class
    // scores per anchor (detector) — see ModelKind.
    kind = _outputShape.length >= 3 ? ModelKind.detector : ModelKind.classifier;

    // Inference runs on a background isolate so a slow frame never drops the
    // camera preview or blocks touch input on the main isolate.
    _isolateInterpreter = await IsolateInterpreter.create(
      address: interpreter.address,
    );
  }

  /// Three rungs, each tried only if the previous one failed to even create
  /// an interpreter (not just "ran slow") — see [_tryCreate]'s doc comment
  /// for why that's a real failure mode here, not a hypothetical one:
  ///
  /// 1. NNAPI (Android) / Metal (iOS) — tflite_flutter's built-in delegate
  ///    switches, no manual pointer lifecycle needed. The doc's "GPU/NNAPI/
  ///    CoreML delegate on" requirement, cheapest to try.
  /// 2. Android's GPU delegate ([GpuDelegateV2]), tried explicitly — a
  ///    different native code path than NNAPI. NNAPI routes through the
  ///    device's HAL and can reject ops its vendor driver doesn't support
  ///    (confirmed: what failed on a Redmi Note 8 against this converted
  ///    YOLO graph); the GPU delegate runs its own OpenGL/OpenCL compute
  ///    shaders and often has different — sometimes better — coverage for
  ///    conv-heavy nets. Unproven on this specific model/device; if it also
  ///    fails to create, rung 3 still catches it.
  /// 3. CPU only, [_interpreterThreads] threads — always works, just the
  ///    slowest. What actually ran on the Redmi Note 8 before this existed.
  Future<Interpreter> _createInterpreter() async {
    final nnapiOrMetal = await _tryCreate(
      InterpreterOptions()
        ..threads = _interpreterThreads
        ..useNnApiForAndroid = true
        ..useMetalDelegateForIOS = true,
    );
    if (nnapiOrMetal != null) return nnapiOrMetal;

    if (Platform.isAndroid) {
      final delegate = GpuDelegateV2();
      final gpu = await _tryCreate(
        InterpreterOptions()
          ..threads = _interpreterThreads
          ..addDelegate(delegate),
      );
      if (gpu != null) {
        _delegate = delegate; // kept alive for dispose() to delete later
        return gpu;
      }
      delegate.delete(); // this rung failed — nothing left holding it
    }

    return Interpreter.fromAsset(
      modelAsset,
      options: InterpreterOptions()..threads = _interpreterThreads,
    );
  }

  /// Null on failure rather than rethrowing, so [_createInterpreter] can
  /// fall through to the next rung.
  ///
  /// Deliberately catches everything, not `on Exception`: the native
  /// failure mode when a delegate rejects a model's op set is an
  /// [ArgumentError] (an [Error], not an [Exception]) from quiver's
  /// checkArgument, thrown well below any typed Dart catch — confirmed by
  /// an actual crash log, not a hypothetical.
  Future<Interpreter?> _tryCreate(InterpreterOptions options) async {
    try {
      return await Interpreter.fromAsset(modelAsset, options: options);
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return null;
    }
  }

  /// Runs the model on one camera frame.
  ///
  /// Returns null when nothing crossed the decoder's own threshold — only
  /// possible for [ModelKind.detector]; a classifier always has a top class,
  /// even if it's background (see [DetectionPipeline]'s class-0 convention).
  Future<ClassificationResult?> run(CameraImage frame) async {
    final isolateInterpreter = _isolateInterpreter;
    if (isolateInterpreter == null) {
      throw StateError('Call load() before run().');
    }

    final decoded = _preprocessor.decode(frame);
    final normalized = _preprocessor.toNormalizedFloats(
      decoded,
      width: _inputWidth,
      height: _inputHeight,
    );

    final inputBytes = _packInput(normalized);
    final outputBytes = Uint8List(
      _outputElements * _bytesPerElement(_outputType),
    );

    await isolateInterpreter.run(inputBytes, outputBytes);

    final scores = _dequantizeAll(
      outputBytes,
      _outputType,
      _outputParams,
      _outputElements,
    );

    return kind == ModelKind.detector
        ? _parseDetector(scores)
        : _parseClassifier(scores);
  }

  /// Converts normalized 0-1 floats to whatever byte layout the input tensor
  /// actually wants.
  Uint8List _packInput(Float32List normalized) {
    switch (_inputType) {
      case TensorType.float32:
        return normalized.buffer.asUint8List();
      case TensorType.uint8:
        final bytes = Uint8List(normalized.length);
        for (var i = 0; i < normalized.length; i++) {
          bytes[i] = _quantize(normalized[i], _inputParams).clamp(0, 255);
        }
        return bytes;
      case TensorType.int8:
        final bytes = Uint8List(normalized.length);
        final view = ByteData.view(bytes.buffer);
        for (var i = 0; i < normalized.length; i++) {
          view.setInt8(
            i,
            _quantize(normalized[i], _inputParams).clamp(-128, 127),
          );
        }
        return bytes;
      default:
        throw UnsupportedError(
          'Unsupported input tensor type $_inputType. This placeholder '
          'pipeline only handles float32/uint8/int8 image inputs.',
        );
    }
  }

  /// Affine quantization: quantized = real / scale + zero_point.
  ///
  /// Assumes the model was trained on inputs normalized to 0-1, which holds
  /// for the bundled placeholder and most MobileNet/YOLO exports. If the
  /// real model expects a different range (commonly -1 to 1), adjust the
  /// normalization this reads from ([FramePreprocessor.toNormalizedFloats])
  /// or this formula — not the rest of the pipeline.
  int _quantize(double normalizedValue, QuantizationParams params) {
    final scale = params.scale == 0 ? 1.0 : params.scale;
    return (normalizedValue / scale + params.zeroPoint).round();
  }

  ClassificationResult _parseClassifier(List<double> scores) {
    var bestIndex = 0;
    var bestScore = scores[0];
    for (var i = 1; i < scores.length; i++) {
      if (scores[i] > bestScore) {
        bestScore = scores[i];
        bestIndex = i;
      }
    }
    return _toResult(bestIndex, bestScore);
  }

  /// [_outputShape] is `[1, dimA, dimB]`. Ultralytics' `4 + numClasses` is
  /// always far smaller than the anchor count (which runs into the
  /// thousands), so whichever dimension is smaller is taken as the
  /// attribute axis rather than assuming a fixed axis order — the
  /// ONNX→TFLite conversion step can transpose it.
  ClassificationResult? _parseDetector(List<double> scores) {
    final dimA = _outputShape[1];
    final dimB = _outputShape[2];
    final attributesFirst = dimA <= dimB;
    final numAttributes = attributesFirst ? dimA : dimB;
    final numAnchors = attributesFirst ? dimB : dimA;

    final detections = decoder.decode(
      values: scores,
      numAttributes: numAttributes,
      numAnchors: numAnchors,
      attributesFirst: attributesFirst,
      inputWidth: _inputWidth,
      inputHeight: _inputHeight,
    );
    if (detections.isEmpty) return null;

    final best = detections.reduce(
      (a, b) => b.confidence > a.confidence ? b : a,
    );
    return _toResult(best.classIndex, best.confidence);
  }

  ClassificationResult _toResult(int classIndex, double confidence) {
    final labelList = labels;
    return ClassificationResult(
      classIndex: classIndex,
      label: labelList != null && classIndex < labelList.length
          ? labelList[classIndex]
          : 'class_$classIndex',
      confidence: confidence,
    );
  }

  List<double> _dequantizeAll(
    Uint8List bytes,
    TensorType type,
    QuantizationParams params,
    int count,
  ) {
    final view = ByteData.view(bytes.buffer);
    return switch (type) {
      TensorType.float32 => List.generate(
          count,
          (i) => view.getFloat32(i * 4, Endian.little),
        ),
      TensorType.uint8 => List.generate(
          count,
          (i) => params.scale == 0
              ? bytes[i] / 255.0
              : (bytes[i] - params.zeroPoint) * params.scale,
        ),
      TensorType.int8 => List.generate(count, (i) {
          final raw = view.getInt8(i);
          return params.scale == 0
              ? raw / 127.0
              : (raw - params.zeroPoint) * params.scale;
        }),
      _ => throw UnsupportedError('Unsupported output tensor type $type.'),
    };
  }

  int _bytesPerElement(TensorType type) => switch (type) {
        TensorType.float32 => 4,
        TensorType.uint8 || TensorType.int8 => 1,
        _ => throw UnsupportedError('Unsupported tensor type $type.'),
      };

  Future<void> dispose() async {
    await _isolateInterpreter?.close();
    _interpreter?.close();
    _delegate?.delete(); // only set if _createInterpreter used the GPU rung
    _isolateInterpreter = null;
    _interpreter = null;
    _delegate = null;
  }
}
