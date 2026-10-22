# YOLO11n - eval_report.md

- weights: `runs\hazard_v2_y11n\weights\best.pt`
- test split: `data/hazard_v2/test`
- target precision: 0.85

**mAP@50 = 0.8446  |  mAP@50-95 = 0.6138**

| class | conf* | precision | recall | F1 | AP@50 |
|---|---|---|---|---|---|
| accident | 0.542 | 0.851 | 0.792 | 0.820 | 0.875 |
| non_accident | 0.404 | 0.850 | 0.610 | 0.711 | 0.734 |
| fallen_object | 0.406 | 0.851 | 0.663 | 0.746 | 0.775 |
| flood | 0.250 | 0.866 | 1.000 | 0.928 | 0.995 |

- deploy thresholds: `{'accident': 0.542, 'non_accident': 0.404, 'fallen_object': 0.406, 'flood': 0.25}`
- NOTE: ['flood'] raw threshold was below 0.25 - clamped up.
- false alarms on 197 clean-road test images: **37/197 = 18.8%**