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

import asyncio
import logging
from contextlib import asynccontextmanager, suppress
from datetime import datetime, timedelta, timezone

import uvicorn
from fastapi import FastAPI, HTTPException
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

# How often expired hazards are deleted. Reads already skip them, so this
# is only housekeeping.
PURGE_INTERVAL = timedelta(minutes=10)


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.init_db()
    fcm.init_fcm()
    purger = asyncio.create_task(_purge_periodically())
    yield
    purger.cancel()
    with suppress(asyncio.CancelledError):
        await purger


async def _purge_periodically() -> None:
    while True:
        purged = await asyncio.to_thread(db.purge_expired)
        if purged:
            logger.info("[purge] %d expired hazard(s) deleted", purged)
        await asyncio.sleep(PURGE_INTERVAL.total_seconds())


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


class NotSeenIn(BaseModel):
    """A car drove past a hazard with detection running and didn't see it."""

    car_id: str


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "fcm_ready": fcm.is_ready(), **db.counts()}


@app.post("/detection")
def post_detection(event: DetectionIn) -> dict:
    """Receives an obstruction the app detected on-device, as a sighting of
    a hazard (see hazards.py).

    Other cars are pushed the hazard when it's first reported, and again
    when it becomes confirmed — not on every repeat sighting, which a car
    driving past sends several of a second.
    """
    outcome = db.record_sighting(
        event.type,
        event.confidence,
        event.lat,
        event.lng,
        event.timestamp,
        event.car_id,
    )
    hazard = outcome["hazard"]
    logger.info(
        "[detection] %s %.0f%% at %.5f,%.5f: %s hazard %s (%d car(s)%s)",
        event.type,
        event.confidence * 100,
        event.lat,
        event.lng,
        "new" if outcome["new"] else "seen again,",
        hazard["id"][:8],
        hazard["reports"],
        ", confirmed" if hazard["confirmed"] else "",
    )

    pushed = 0
    if outcome["new"] or outcome["newly_confirmed"]:
        pushed = _push(hazard)

    return {
        "id": hazard["id"],
        "status": "recorded",
        "new": outcome["new"],
        "confirmed": hazard["confirmed"],
        "pushed": pushed,
    }


def _push(hazard: dict) -> int:
    """Pushes `hazard` to every car that should hear about it but didn't
    report it (they already saw it on their own screens). Returns how many
    pushes went out."""
    pushed = 0
    for car in db.cars_with_token():
        if car["car_id"] in hazard["reporter_ids"]:
            continue
        distance = _alert_distance(car, hazard)
        if distance is None:
            continue
        if fcm.send_alert(car["fcm_token"], _alert(hazard, distance)):
            pushed += 1
    return pushed


def _alert(hazard: dict, distance_m: float) -> dict:
    """A hazard as the app sees it — lib/core/models/alert_event.dart."""
    return {
        "id": hazard["id"],
        "type": hazard["type"],
        "lat": hazard["lat"],
        "lng": hazard["lng"],
        # The latest sighting, so "reported 2 min ago" means the hazard was
        # still there 2 minutes ago.
        "timestamp": hazard["last_seen"].isoformat(),
        "confirmed": hazard["confirmed"],
        "reports": hazard["reports"],
        "distance_m": round(distance_m, 1),
    }


def _alert_distance(car: dict, hazard: dict) -> float | None:
    """How far `car` is from `hazard`, if it should be told.

    Within ALERT_RADIUS_M: the straight-line distance. Further away, only if
    the hazard is confirmed (only those reroute cars) and the car is
    navigating a route that reaches it: the distance along that route. None
    otherwise.
    """
    lat, lng = hazard["lat"], hazard["lng"]
    straight = db.haversine_meters(lat, lng, car["lat"], car["lng"])
    if straight <= ALERT_RADIUS_M:
        return straight
    if not hazard["confirmed"]:
        return None
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
    """Live hazards near a point, most recently seen first.

    Real alerts arrive by push, but polling this is a useful fallback — a
    catch-up fetch when the app starts mid-journey, and how the app learns
    a hazard is gone (expired or cleared): it stops being listed. Response
    shape mirrors lib/core/models/alert_event.dart.
    """
    return [
        _alert(hazard, hazard["distance_m"])
        for hazard in db.nearby_hazards(lat, lng, radius_m)
    ]


@app.post("/hazards/{hazard_id}/not-seen")
def post_not_seen(hazard_id: str, report: NotSeenIn) -> dict:
    """A car drove past a hazard, detecting, without seeing it. Enough of
    these with no new sighting (hazards.CLEAR_VOTES) delete the hazard;
    apps drop it at their next sync."""
    status = db.record_not_seen(hazard_id, report.car_id)
    if status is None:
        raise HTTPException(404, "No such hazard (cleared or expired)")
    logger.info("[not seen] hazard %s by %s: %s", hazard_id[:8], report.car_id, status)
    return {"status": status}


@app.post("/reset")
def reset() -> dict:
    """Clears every hazard and car, so a test run starts from a known
    state."""
    db.reset()
    return {"status": "cleared"}


if __name__ == "__main__":
    # host="0.0.0.0" so the phone on the same Wi-Fi can reach it; binding to
    # localhost would only be reachable from this laptop.
    uvicorn.run(app, host="0.0.0.0", port=8000)
