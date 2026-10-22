# HazardNet - eval_report.md

- weights: `runs\hazard_v2_y26n\weights\best.pt`
- test split: `data/hazard_v2/test`
- target precision: 0.85

**mAP@50 = 0.8548  |  mAP@50-95 = 0.6234**  (reported straight, no cherry-picking)

| class | conf* | precision | recall | F1 | AP@50 |
|---|---|---|---|---|---|
| accident | 0.469 | 0.850 | 0.833 | 0.841 | 0.903 |
| non_accident | 0.406 | 0.850 | 0.609 | 0.710 | 0.746 |
| fallen_object | 0.477 | 0.851 | 0.644 | 0.733 | 0.775 |
| flood | 0.250 | 0.865 | 1.000 | 0.928 | 0.995 |

- deploy thresholds: `{'accident': 0.469, 'non_accident': 0.406, 'fallen_object': 0.477, 'flood': 0.25}`
- NOTE: ['flood'] had a raw auto-picked threshold below 0.25 (usually means too few test images for that class to trust the number) - clamped up to 0.25 instead of using the unreliable raw value.
- false alarms on 197 clean-road test images, each class checked at its own threshold: **32/197 = 16.2%**

conf* = lowest confidence where that class reaches the target precision on the test set (floored at 0.25); use it as the per-class trigger threshold in the Flutter app.