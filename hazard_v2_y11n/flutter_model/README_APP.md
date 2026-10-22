# YOLO11n - Flutter app package

Trained on `hazard_v2`, same settings as YOLO26n. Best checkpoint: epoch 71.
Test split: **mAP50 0.8446 | mAP50-95 0.6138**. See `../eval_report.md`.

## Files
| file | status | use |
|---|---|---|
| `model.onnx` | verified against PyTorch (max raw diff 0.0032, detections match) | Flutter via an ONNX Runtime plugin |
| `model.torchscript` | verified against PyTorch (max raw diff 0.0020) | pytorch_mobile fallback |
| `model.tflite` | **not produced** - Ultralytics LiteRT export does not run on Windows ("LiteRT export only supported on Linux x86 and macOS"). Needs Linux/WSL. | for the `ultralytics_yolo` plugin |
| `labels.txt` | 4 classes, same order as YOLO26n | class id -> name |
| `metadata.json` | measured I/O shapes, thresholds, verification results | read by the app / for reference |

## Input (measured)
- Shape `[1, 3, 640, 640]` float32, **NCHW**, **RGB**, values 0-1.
- **Letterbox**: resize with aspect ratio kept, pad to 640x640 with grey (114,114,114). Do NOT stretch.
  - `scale = min(640/w, 640/h)`, `nw = round(w*scale)`, `nh = round(h*scale)`
  - `padX = (640-nw)/2`, `padY = (640-nh)/2`

## Output (measured): `[1, 8, 8400]`, raw, NMS NOT applied
For each of the 8400 columns `i`:
- rows 0-3 = `cx, cy, w, h` in 640x640 input pixels
- rows 4-7 = scores for `accident, non_accident, fallen_object, flood` (already 0-1, no sigmoid needed)

App decode steps:
1. For each column: `cls = argmax(rows 4-7)`, `conf = max(rows 4-7)`.
2. Keep only columns where `conf >= deploy_conf[cls]` (below).
3. Box: `x1 = cx - w/2`, `y1 = cy - h/2`, `x2 = cx + w/2`, `y2 = cy + h/2`.
4. **NMS per class, IoU 0.6** (YOLO11 has no NMS-free head - this step is required).
5. Back to camera pixels: `X = (x - padX) / scale`, `Y = (y - padY) / scale`.

## Per-class alert thresholds (from test split, precision >= 0.85)
| class | deploy_conf |
|---|---|
| accident | 0.542 |
| non_accident | 0.404 |
| fallen_object | 0.406 |
| flood | 0.25 (clamped floor) |

False alarms on 197 clean-road test images at these thresholds: 37/197 = 18.8%.

## Differences from the YOLO26n package
- Thresholds are different (accident 0.542 vs 0.469). Use YOLO11n's own values.
- Raw ONNX output needs NMS. YOLO11n has no NMS-free option.
- No `.tflite` yet (see table above).
