# HazardNet - data_report.md

- final classes: `['accident', 'non_accident', 'fallen_object', 'flood']`
- output: `data/hazard_v2`

| source | split | images | neg | dropped | noise | accident | non_accident | fallen_object | flood |
|---|---|---|---|---|---|---|---|---|---|
| btech_clean | train | 6461 | 153 | 3476 | 139 | 6983 | 2134 | 0 | 0 |
| btech_clean | val | 359 | 7 | 238 | 4 | 395 | 134 | 0 | 0 |
| btech_clean | test | 372 | 8 | 227 | 8 | 389 | 182 | 0 | 0 |
| flood_sturm | train | 596 | 0 | 0 | 0 | 0 | 0 | 0 | 596 |
| flood_sturm | val | 75 | 0 | 0 | 0 | 0 | 0 | 0 | 75 |
| flood_sturm | test | 74 | 0 | 0 | 0 | 0 | 0 | 0 | 74 |
| vehicles | train | 1200 | 3 | 0 | 66 | 0 | 9814 | 0 | 0 |
| vehicles | val | 150 | 0 | 0 | 2 | 0 | 1218 | 0 | 0 |
| vehicles | test | 150 | 0 | 0 | 5 | 0 | 1247 | 0 | 0 |
| fallen_object | train | 2819 | 392 | 1310 | 293 | 0 | 0 | 4641 | 0 |
| fallen_object | val | 333 | 35 | 169 | 29 | 0 | 0 | 558 | 0 |
| fallen_object | test | 373 | 38 | 162 | 29 | 0 | 0 | 630 | 0 |
| negatives | train | 1528 | 1528 | 0 | 0 | 0 | 0 | 0 | 0 |
| negatives | val | 153 | 153 | 0 | 0 | 0 | 0 | 0 | 0 |
| negatives | test | 16 | 16 | 0 | 0 | 0 | 0 | 0 | 0 |
| **TOTAL** | | 14659 | 2333 |  |  | 7767 | 14729 | 5829 | 745 |

## Notes

- val: moved 19 clean-road negatives out of train
- test: moved 135 clean-road negatives out of train
- Split is scene-grouped per source (`.rf.` stem); labeled-scene leakage = 0.
- `vehicle_on_fire` images dropped where they carried no other hazard.
- Degenerate boxes (w/h outside [0.006, 0.995]) removed.