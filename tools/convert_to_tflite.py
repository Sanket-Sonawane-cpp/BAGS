"""Converts a YOLO ONNX export (e.g. Ultralytics' `best.onnx`) to the
`.tflite` format this app's InferenceService loads.

Not part of the app itself — a one-off dev tool the ML pair (or whoever has
the trained weights) runs locally, once per model drop, on a machine with
the actual weights and enough disk/RAM for TensorFlow. The app only ever
sees the `.tflite` file this produces.

Why this step exists: tflite_flutter (this app's inference runtime) only
loads the TFLite flatbuffer format, not ONNX. See docs/PROJECT_CONTEXT.md —
ML inference stays on-device, tflite_flutter was chosen for its GPU/NNAPI/
CoreML delegate support, and that only works with `.tflite`.

Setup (once):
    pip install onnx2tf onnx onnxsim onnxruntime tensorflow

Usage:
    # Float32 (larger, no calibration data needed — good for a first check
    # that the pipeline runs end to end):
    python tools/convert_to_tflite.py best.onnx

    # Int8-quantized (what docs/PROJECT_CONTEXT.md's battery/perf section
    # actually calls for) — point --calibration-images at 100-500 real
    # sample frames from the target domain (dashcam-ish road footage). Too
    # few, or images unlike what the camera actually sees, quietly produces
    # a working-but-inaccurate quantized model rather than an error, so this
    # directory matters more than it looks like it should:
    python tools/convert_to_tflite.py best.onnx --calibration-images ./calib_images --quantize

Either way, the result lands in assets/models/ ready for
lib/features/detection/detection_providers.dart's `placeholderModelAsset` to
be pointed at it — see this script's own final printed step.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS_MODELS = REPO_ROOT / "assets" / "models"


def run(cmd: list[str]) -> None:
    print(f"$ {' '.join(cmd)}")
    subprocess.run(cmd, check=True)


def build_calibration_npy(images_dir: Path, input_hw: tuple[int, int]) -> Path:
    """Preprocesses a folder of sample images into the .npy array onnx2tf's
    `-cind` wants: normalized 0-1, resized, stacked into one array.

    onnx2tf's calibration input takes a path to a saved numpy array, not a
    folder of images — this is the missing conversion step in between.
    """
    import numpy as np
    from PIL import Image

    paths = sorted(
        p
        for p in images_dir.iterdir()
        if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"}
    )
    if not paths:
        sys.exit(f"No images found in {images_dir}")

    height, width = input_hw
    arrays = []
    for p in paths:
        img = Image.open(p).convert("RGB").resize((width, height))
        arrays.append(np.asarray(img, dtype=np.float32) / 255.0)

    calib = np.stack(arrays, axis=0)  # [N, height, width, 3]
    out_path = images_dir.parent / f"{images_dir.name}_calib.npy"
    np.save(out_path, calib)
    print(f"Built calibration array {calib.shape} -> {out_path}")
    return out_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("onnx_path", type=Path, help="Path to best.onnx")
    parser.add_argument(
        "--output-name",
        default="obstruction_detector.tflite",
        help="Filename to write into assets/models/ (default: %(default)s)",
    )
    parser.add_argument(
        "--quantize",
        action="store_true",
        help="Produce an int8-quantized model instead of float32. Needs "
        "--calibration-images.",
    )
    parser.add_argument(
        "--calibration-images",
        type=Path,
        default=None,
        help="Directory of representative sample images, required with "
        "--quantize. 100-500 images from the real target domain, not "
        "random/ImageNet images.",
    )
    parser.add_argument(
        "--input-hw",
        type=int,
        nargs=2,
        metavar=("HEIGHT", "WIDTH"),
        default=(640, 640),
        help="Model input size, height then width (default: %(default)s, "
        "matching best.onnx's embedded imgsz).",
    )
    args = parser.parse_args()

    if not args.onnx_path.exists():
        sys.exit(f"{args.onnx_path} does not exist")
    if args.quantize and not args.calibration_images:
        sys.exit("--quantize needs --calibration-images <dir>")
    if args.calibration_images and not args.calibration_images.is_dir():
        sys.exit(f"{args.calibration_images} is not a directory")

    work_dir = REPO_ROOT / "build" / "onnx2tf_out"
    work_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable,
        "-m",
        "onnx2tf",
        "-i",
        str(args.onnx_path),
        "-o",
        str(work_dir),
        "-osd",  # only keep the saved_model/tflite outputs, not every
        # intermediate format onnx2tf can emit
    ]
    if args.quantize:
        # Input tensor name below ("images") is Ultralytics' default; adjust
        # if `python -m onnx2tf -i <onnx>` (dry run) reports a different one
        # for this export.
        calib_npy = build_calibration_npy(
            args.calibration_images, args.input_hw
        )
        cmd += [
            "-oiqt",  # output integer-quantized tflite
            "-cind",
            "images",
            str(calib_npy),
            "[[[[0,0,0]]]]",
            "[[[[1,1,1]]]]",  # mean/std of 0/1 = no-op: build_calibration_npy
            # already normalized to 0-1, matching FramePreprocessor
        ]
    run(cmd)

    produced = sorted(work_dir.glob("*.tflite"))
    if not produced:
        sys.exit(
            f"onnx2tf did not produce a .tflite file in {work_dir} — check "
            "its output above for the actual error."
        )
    # onnx2tf always emits float32 and float16 variants alongside whatever
    # was asked for; pick the one actually asked for by name rather than the
    # first match, since 'float16' sorts before 'float32' alphabetically.
    # float16 here is TFLite's weight-only fp16 (smaller file, same float32
    # input/output tensors) — skipped by default since InferenceService's
    # generic tensor-type handling was only exercised against float32/uint8/
    # int8 activations; revisit if the extra size ever matters.
    wanted = "integer_quant" if args.quantize else "float32"
    chosen = next((p for p in produced if wanted in p.name), produced[0])

    ASSETS_MODELS.mkdir(parents=True, exist_ok=True)
    destination = ASSETS_MODELS / args.output_name
    shutil.copyfile(chosen, destination)

    print(f"\nWrote {destination} ({destination.stat().st_size / 1e6:.1f} MB)")
    print(
        "\nNext: point placeholderModelAsset in "
        "lib/features/detection/detection_providers.dart at "
        f"'assets/models/{args.output_name}', add it under pubspec.yaml's "
        "assets (assets/models/ is already a whole-directory entry, so this "
        "alone is enough), and pass the real class list as `labels:` to "
        "InferenceService in that same file."
    )


if __name__ == "__main__":
    main()
