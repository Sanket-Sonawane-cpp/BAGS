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
| `POST /detection` | `{type, confidence, lat, lng, timestamp}` — records a detection, then pushes it to every nearby car (within 2km) that has a known location and FCM token |
| `POST /location` | `{car_id, lat, lng, fcm_token?}` — a car's periodic "here is where I am" ping. `fcm_token` rides along here rather than a separate endpoint, so a token refresh reaches the server on the next ping automatically |
| `GET /alerts?lat&lng&radius_m` | Poll fallback — nearby detections, newest first. Same shape push delivers, for testing the alert UI without depending on push actually arriving |
| `GET /health` | `{status, fcm_ready, detections, cars}` — `fcm_ready` is false until the service account key exists |
| `POST /reset` | Clears the database, for starting a test run from a known state |

## Notes

- Still a single laptop process — no auth, no real deployment, no
  multi-replica concerns. That's deliberate; see the doc's "real cloud
  hosting is future work, not needed now."
- A car with no `fcm_token` yet (hasn't sent a ping since its FCM permission
  resolved) is silently skipped when pushing, not an error.
- `bags.db` persists across restarts, unlike the mock server's in-memory
  store. Delete the file (server stopped) or call `POST /reset` to clear it.
