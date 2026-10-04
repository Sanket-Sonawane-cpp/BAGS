# Bags alert server

The real server described in `docs/PROJECT_CONTEXT.md`. Persists to a local
SQLite file (`bags.db`, gitignored) and pushes alerts via Firebase Cloud
Messaging. Same port and same three main endpoints as `tools/mock_server.py`
(the throwaway dev stub) — swapping which one is running needs no app-side
config change.

## Setup

```
pip install -r server/requirements.txt
```

Get a Firebase Admin service account key: **Firebase console → Project
settings → Service accounts → Generate new private key**. Save the
downloaded file as `server/serviceAccountKey.json` (gitignored — it's a real
credential, never commit it).

Without that file the server still starts and `/detection`/`/location` still
work — pushes are just logged instead of sent, so app-side work isn't
blocked on getting Firebase console access.

## Run

```
python server/app.py
```

Then point the app at `http://<your-laptop-ip>:8000` (not `localhost` — the
phone needs to reach your machine over the LAN; find the IP with `ipconfig`
/ `ifconfig`, and note it changes whenever DHCP reassigns it).

## Endpoints

| | |
|---|---|
| `POST /detection` | `{type, confidence, lat, lng, timestamp, car_id?}` — records a sighting of a hazard (see below). Pushes the hazard to nearby cars (within 2km) when it's first reported, and again when it becomes confirmed; confirmed hazards also go to cars navigating a route that passes them |
| `POST /location` | `{car_id, lat, lng, fcm_token?, route?}` — a car's periodic "here is where I am" ping. `fcm_token` rides along here rather than a separate endpoint, so a token refresh reaches the server on the next ping automatically |
| `GET /alerts?lat&lng&radius_m` | Live hazards nearby, most recently seen first: `{id, type, lat, lng, timestamp, confirmed, reports, distance_m}`. Same shape push delivers. The app syncs with this, which is how it learns a hazard is gone |
| `POST /hazards/{id}/not-seen` | `{car_id}` — the car drove past the hazard with detection running and didn't see it. 404 if the hazard is already gone |
| `GET /health` | `{status, fcm_ready, hazards, detections, cars}` — `fcm_ready` is false until the service account key exists |
| `POST /reset` | Clears every hazard and car, for starting a test run from a known state |

## Hazards

Rules and their numbers are in `hazards.py`.

- **One hazard, many sightings.** Reports of the same type within 50 m of a
  live hazard are sightings of it, not new hazards. A car driving past an
  accident reports it several times a second; other cars are only pushed it
  once.
- **Confirmed** once 2 different cars reported it, or one did with
  confidence ≥ 0.8. Only confirmed hazards that block the road (accident,
  fallen object, flood) reroute cars; until then the app shows them faded,
  as a warning.
- **Expiry**, counted from the last sighting: accident and fallen object
  1 h, flood 6 h, pothole 7 days, anything else 2 h. Expired hazards stop
  being listed straight away and are deleted every 10 minutes.
- **Cleared** once 2 different cars drive past it, detecting, without
  seeing it, and nobody has seen it since. The app sends those votes by
  itself (`lib/features/detection/clearance_watcher.dart`), only for types
  its model can detect.

## Tests

```
python -m unittest discover server
```

Uses a throwaway database and records pushes instead of sending them.

## Notes

- Still a single laptop process — no auth, no real deployment, no
  multi-replica concerns. That's deliberate; see the doc's "real cloud
  hosting is future work, not needed now."
- A car with no `fcm_token` yet (hasn't sent a ping since its FCM permission
  resolved) is silently skipped when pushing, not an error.
- `bags.db` persists across restarts, unlike the mock server's in-memory
  store. Delete the file (server stopped) or call `POST /reset` to clear it.
