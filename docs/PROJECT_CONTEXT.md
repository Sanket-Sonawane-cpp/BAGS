# Project Context — Obstruction Detection & Alert App

Paste this whole file into your Claude Code session so both app developers are working from the same decisions.

## What we're building
A dashcam (mounted in the car) feeds video to a mobile app. The app runs an ML model **on-device** to detect road obstructions in real time. On a detection, the app sends a small event to a backend server, which figures out which other nearby cars to warn and pushes them a real-time alert.

Team: 4 people total — 2 on the ML model, 2 on the app (us). This doc covers the app + its server integration. The model itself is the other pair's scope; we just consume its `.tflite` output.

## Architecture decisions (and why — so we don't relitigate these)

**ML inference runs on the phone, not the server.**
Avoids streaming video over cellular, avoids per-frame network latency, keeps detection working with no/poor connectivity, keeps raw video off the network entirely (only small events leave the phone). Server may later host the `.tflite` file for over-the-air model updates — not needed for v1.

**App framework: Flutter (Dart).**
Chosen over React Native and native Kotlin+Swift. Dart compiles to native ARM code (no JS runtime anywhere), so the whole app runs at native-adjacent speed — `camera` + `tflite_flutter` with GPU/NNAPI/CoreML delegates easily handles the 2-5fps inference we need. Single codebase = least total engineering surface for 2 people covering Android + iOS. Project was created with `flutter create --empty`.

**Server: Python + FastAPI.**
Matches the ML team's language. The server does **not** run inference — its jobs are:
1. `POST /detection {type, confidence, lat, lng, timestamp}` — receive a detection from a phone
2. `POST /location {car_id, lat, lng}` — receive periodic location pings (every ~15-30s) from active phones
3. On a new detection, haversine-distance-filter tracked cars to find ones nearby (e.g. within 1-2km)
4. Push an alert to those cars via **Firebase Cloud Messaging (FCM)**

**Alerts use FCM, not raw WebSockets.**
Server → phone is a normal outbound HTTPS call to Firebase's Admin SDK; Firebase handles actual delivery. No persistent socket to maintain, works across NAT/cellular, works even if the app is backgrounded.

**Dev server = a laptop, that's fine.** Local demo: phones hit the laptop's local IP. To simulate real phones on cellular reaching it: tunnel via ngrok or Cloudflare Tunnel for a public HTTPS URL. Real cloud hosting is future work, not needed now.

**Battery/perf constraints — build these in from day one, not later:**
1. Throttle inference to ~2-5fps, not every frame
2. Enable GPU/NNAPI (Android) / Core ML (iOS) delegate in `tflite_flutter` — big lever
3. Model should be small + int8-quantized (MobileNet/YOLO-nano/EfficientDet-lite class) — requirement for the ML team
4. Feed the model a downscaled frame (e.g. 224x224/320x320); camera preview UI stays high-res separately
5. Location pings every 15-30s, POST only on actual detections — no continuous streaming
6. Design UX assuming phone is plugged in while driving (like real dashcam apps)
7. iOS restricts background camera access — app must run foregrounded with screen on while driving; this is a platform constraint, not a bug

## Work split (by feature, not by platform)

**Member A — Camera & Inference** — owns `lib/features/detection/`
- Camera preview/capture (`camera` package)
- Load + run model via `tflite_flutter`, GPU/NNAPI/CoreML delegate on
- Frame throttling, preprocessing (resize/normalize)
- Outputs a stream of `DetectionEvent` for Member B to consume
- Unblocked immediately: use any placeholder `.tflite` model to build the full pipeline before the real trained model exists; swap it in later with no plumbing changes

**Member B — Location, Networking, Alerts, Map** — owns `lib/features/alerts/`
- GPS (`geolocator`) + permissions + periodic location pings
- REST calls (`http`) to post detections/locations to the server
- Push notifications (`firebase_messaging`)
- Map UI (`google_maps_flutter`) with location + alert markers
- Alert UI (banner/sound/vibration)
- Unblocked immediately: build against a throwaway mock server (`json-server` or a 2-endpoint FastAPI stub) before the real server exists

**Shared contract — write together first, before splitting:**
`lib/core/models/detection_event.dart` and `alert_event.dart` as plain Dart classes:
```
DetectionEvent { type, confidence, lat, lng, timestamp }
AlertEvent { type, confidence, lat, lng, timestamp, ...whatever the server adds e.g. distance }
```
This is the interface between our two halves — everything else can be built independently once it's agreed.

## Toolchain — match these exactly

```
Flutter 3.47.2 • channel stable • revision d3b14c8769
Dart 3.13.2
```

Everyone on the team should be on **Flutter 3.47.2 (stable)**. Check with `flutter --version`; if you're on something else, use `flutter downgrade` or install the matching version rather than working on a different one.

**Don't run `flutter upgrade` casually during the project.** The build currently emits a warning that `firebase_core` applies its own Kotlin Gradle Plugin, and that *future* Flutter versions will reject this (see gotchas below). It's harmless today, but an unplanned upgrade could turn it into a hard build failure. If we do upgrade, do it deliberately and early — never near a milestone — and verify the Android build before anyone else pulls.

## Current status
- ✅ GitHub repo created, Flutter project initialized in-place (`flutter create --empty --project-name ...`)
- ✅ Dependencies added to `pubspec.yaml`: `camera`, `tflite_flutter`, `geolocator`, `http`, `firebase_core`, `firebase_messaging`, `google_maps_flutter`, `flutter_riverpod`
- ✅ `flutter doctor` clean; Android emulator (Pixel 9) and physical-device connection (USB + wireless debugging) working
- ✅ Android debug build passing (`flutter build apk --debug`) — required a Gradle fix, see gotchas below
- ✅ Folder structure created (`lib/core/{models,services}`, `lib/features/{detection,alerts}`, `assets/models/`), `assets/models/` registered in `pubspec.yaml`
- ⬜ Not yet done: shared model classes (`DetectionEvent`/`AlertEvent`), Firebase project + config files (`google-services.json` / `GoogleService-Info.plist`), Google Maps API key, camera/location permission entries in `AndroidManifest.xml` / `Info.plist`
- ⬜ No feature code written yet in either area

## Known build gotchas (already fixed in the repo — don't re-debug these)

**"Inconsistent JVM Target Compatibility Between Java and Kotlin Tasks"**
Flutter plugins hardcode *different* Java levels in their own build files — `tflite_flutter` pins Java 11, `camera_android_camerax` pins Java 17 — while the Kotlin compiler defaults to whatever JDK runs Gradle (21 here). No single global Java/Kotlin target fixes this: forcing everything to 17 breaks `tflite_flutter`, forcing everything to 11 breaks `camera_android_camerax`.

The fix (already in `android/build.gradle.kts`) derives each module's Kotlin target from *that same module's own* Java target, so every module stays internally consistent regardless of what it pins. Don't replace it with a single global `jvmTarget` value — that's what fails.

Note it uses `tasks.withType(...).configureEach` rather than `afterEvaluate`, because the template's existing `subprojects { evaluationDependsOn(":app") }` line causes `afterEvaluate` to throw "Cannot run Project.afterEvaluate(Action) when the project is already evaluated".

**`:app:packageDebug` fails with a missing `app-metadata.properties`**
Stale intermediates left behind by an earlier failed build. Fix: `flutter clean`, then rebuild.

**"Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): firebase_core"**
Harmless on Flutter 3.47.2 — the build completes. Flutter is migrating to "Built-in Kotlin," where Flutter's Gradle plugin manages Kotlin compilation itself, and plugins applying their own KGP conflict with that model (the same root cause as the JVM-target problem above: each plugin bringing its own KGP with its own settings). The fix has to come from `firebase_core`'s maintainers, not us — there's nothing to change on our side. This is the main reason to stay pinned to 3.47.2 rather than upgrading mid-project.

**"source value 8 is obsolete"** — comes from a plugin's own config, not ours. Ignore.

## Next steps, in order
1. Both: write `DetectionEvent`/`AlertEvent` in `lib/core/models/` together (folders already exist)
2. Both: set up one shared Firebase project, pull config files for Android + iOS
3. Member A: camera preview → load placeholder model → inference loop running at 2-5fps with delegate on (garbage output is fine at this stage)
4. Member B: GPS read → test POST to mock server → one test FCM push landing on device
5. Integration checkpoint: wire Member A's `DetectionEvent` stream into Member B's `postDetection()` call, test end-to-end on a real device

## iOS testing plan (neither of us owns a Mac)
- Use **Codemagic** (free tier, Flutter-focused) for cloud macOS builds — catches iOS compile errors, no local Mac needed
- iOS Simulator can't access a camera anyway, so it's not that useful here even if we had one
- Real-device testing: need an Apple Developer account ($99/yr — unavoidable regardless of Mac ownership), then Codemagic builds/signs/publishes to TestFlight, and any iPhone (borrowed briefly, not a Mac) installs via TestFlight
- Day-to-day dev/testing happens on Android; iOS passes happen periodically via this TestFlight pipeline
