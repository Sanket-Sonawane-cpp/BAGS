"""The real alert server (see docs/PROJECT_CONTEXT.md's "Server" decision).

Unlike tools/mock_server.py, this one persists to SQLite (survives a
restart) and actually pushes to Firebase Cloud Messaging instead of only
storing detections for the app to poll. Still deliberately a single laptop
process, per the doc's "real cloud hosting is future work, not needed now" —
nothing here assumes it's the only replica or that it's behind a real
reverse proxy.

Setup:
    pip install -r server/requirements.txt

    Get a service account key: Firebase console -> Project settings ->
    Service accounts -> Generate new private key. Save it as
    server/serviceAccountKey.json (gitignored — it's a real credential).
    Without it the server still runs; pushes are just logged, not sent.

Run:
    python server/app.py

Then point the app at http://<your-laptop-ip>:8000 — same port
tools/mock_server.py used, so no app-side config changes either way.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel, Field

import db
import fcm
import routes

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("bags.server")

# How far a detection reaches. Matches tools/mock_server.py's /alerts
# default so behaviour doesn't change when swapping which server is running.
ALERT_RADIUS_M = 2000

# A navigating car's route counts for pushes only while it keeps pinging:
# one that went quiet (app killed, phone off) isn't driving it any more.
ROUTE_FRESHNESS = timedelta(minutes=2)


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.init_db()
    fcm.init_fcm()
    yield


app = FastAPI(title="Bags alert server", lifespan=lifespan)


class DetectionIn(BaseModel):
    """Mirrors lib/core/models/detection_event.dart."""

    type: str
    confidence: float
    lat: float
    lng: float
    timestamp: datetime
    # The reporting car, so it isn't pushed its own detection. Optional so
    # older app builds that don't send it still get recorded.
    car_id: str | None = None


class LocationIn(BaseModel):
    """A car's periodic "here is where I am" ping.

    fcm_token rides along on the same ping (rather than a separate
    register-token call) so a token refresh reaches the server on the very
    next ~20s ping with no extra client-side plumbing, and so every car the
    server can locate is, by construction, also a car it knows how to push
    to (once it has sent at least one ping with a token attached).
    """

    car_id: str
    lat: float
    lng: float
    fcm_token: str | None = None
    # The route being navigated, as [[lat, lng], ...]. Absent or null when
    # not navigating, which clears any route sent earlier.
    route: list[tuple[float, float]] | None = Field(default=None, max_length=5000)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "fcm_ready": fcm.is_ready(), **db.counts()}


@app.post("/detection")
def post_detection(event: DetectionIn) -> dict:
    """Receives an obstruction the app detected on-device, then pushes it to
    every other car that's near it, or navigating a route that passes it."""
    record = db.insert_detection(
        event.type, event.confidence, event.lat, event.lng, event.timestamp
    )
    logger.info(
        "[detection] %s %.0f%% at %.5f,%.5f",
        event.type,
        event.confidence * 100,
        event.lat,
        event.lng,
    )

    pushed = 0
    for car in db.cars_with_token():
        # The reporter already saw it on its own screen.
        if car["car_id"] == event.car_id:
            continue
        distance = _alert_distance(car, event.lat, event.lng)
        if distance is None:
            continue
        alert = {
            "id": record["id"],
            "type": record["type"],
            "lat": record["lat"],
            "lng": record["lng"],
            "timestamp": record["timestamp"],
            "distance_m": round(distance, 1),
        }
        if fcm.send_alert(car["fcm_token"], alert):
            pushed += 1

    return {"id": record["id"], "status": "recorded", "pushed": pushed}


def _alert_distance(car: dict, lat: float, lng: float) -> float | None:
    """How far `car` is from a hazard at lat/lng, if it should be told.

    Within ALERT_RADIUS_M: the straight-line distance. Further away, only if
    the car is navigating a route that reaches the hazard: the distance
    along that route. None otherwise.
    """
    straight = db.haversine_meters(lat, lng, car["lat"], car["lng"])
    if straight <= ALERT_RADIUS_M:
        return straight
    route = car["route"]
    fresh = datetime.now(timezone.utc) - car["updated_at"] <= ROUTE_FRESHNESS
    if not route or not fresh:
        return None
    return routes.distance_ahead(route, (car["lat"], car["lng"]), (lat, lng))


@app.post("/location")
def post_location(ping: LocationIn) -> dict:
    """Records where a car currently is (and its token, if sent), so it can
    be pushed alerts about nearby hazards."""
    db.upsert_car(ping.car_id, ping.lat, ping.lng, ping.fcm_token, ping.route)
    logger.info(
        "[location] %s at %.5f,%.5f%s",
        ping.car_id,
        ping.lat,
        ping.lng,
        f", navigating ({len(ping.route)} route points)" if ping.route else "",
    )
    return {"status": "ok"}


@app.get("/alerts")
def get_alerts(lat: float, lng: float, radius_m: float = ALERT_RADIUS_M) -> list[dict]:
    """Obstructions near a point, newest first.

    Real alerts arrive by push, but polling this is a useful fallback — a
    catch-up fetch when the app starts mid-journey, and a way to test the
    alert UI without depending on push delivery. Response shape mirrors
    lib/core/models/alert_event.dart.
    """
    return db.nearby_detections(lat, lng, radius_m)


@app.post("/reset")
def reset() -> dict:
    """Clears everything, so a test run starts from a known state."""
    db.reset()
    return {"status": "cleared"}


if __name__ == "__main__":
    # host="0.0.0.0" so the phone on the same Wi-Fi can reach it; binding to
    # localhost would only be reachable from this laptop.
    uvicorn.run(app, host="0.0.0.0", port=8000)
