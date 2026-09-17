"""Throwaway mock of the alert server, for app development only.

This exists so the app's networking layer can be built and tested before the
real FastAPI server is written. It holds everything in memory and forgets it on
restart. Do not grow features here — port them to the real server instead.

It doubles as a reference for the request/response shapes the real server must
implement, since these match lib/core/models/ exactly.

Run:
    python tools/mock_server.py

Then point the app at http://<your-laptop-ip>:8000 (not localhost — the phone
needs to reach your machine over the LAN).
"""

from __future__ import annotations

import math
import uuid
from datetime import datetime, timezone

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(title="Bags mock alert server")

# In-memory stores. The real server needs a database; this deliberately does not.
_detections: list[dict] = []
_car_locations: dict[str, dict] = {}


class DetectionEvent(BaseModel):
    """Mirrors lib/core/models/detection_event.dart."""

    type: str
    confidence: float
    lat: float
    lng: float
    timestamp: datetime


class LocationPing(BaseModel):
    """Periodic 'here is where I am' report from an active car."""

    car_id: str
    lat: float
    lng: float


def haversine_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Great-circle distance between two points, in metres.

    The real server needs this same calculation to decide which cars are near a
    reported obstruction.
    """
    earth_radius_m = 6_371_000
    d_lat = math.radians(lat2 - lat1)
    d_lng = math.radians(lng2 - lng1)
    a = (
        math.sin(d_lat / 2) ** 2
        + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
        * math.sin(d_lng / 2) ** 2
    )
    return 2 * earth_radius_m * math.asin(math.sqrt(a))


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "detections": len(_detections),
        "cars": len(_car_locations),
    }


@app.post("/detection")
def post_detection(event: DetectionEvent) -> dict:
    """Receives an obstruction the app detected on-device."""
    record = event.model_dump()
    record["id"] = str(uuid.uuid4())
    record["timestamp"] = event.timestamp.astimezone(timezone.utc)
    _detections.append(record)

    print(
        f"[detection] {event.type} {event.confidence:.0%} "
        f"at {event.lat:.5f},{event.lng:.5f}"
    )

    # The real server would find nearby cars here and push them an FCM alert.
    return {"id": record["id"], "status": "recorded"}


@app.post("/location")
def post_location(ping: LocationPing) -> dict:
    """Records where a car currently is, so it can be alerted about hazards."""
    _car_locations[ping.car_id] = {
        "lat": ping.lat,
        "lng": ping.lng,
        "last_seen": datetime.now(timezone.utc),
    }
    print(f"[location] {ping.car_id} at {ping.lat:.5f},{ping.lng:.5f}")
    return {"status": "ok"}


@app.get("/alerts")
def get_alerts(lat: float, lng: float, radius_m: float = 2000) -> list[dict]:
    """Obstructions near a point, newest first.

    Real alerts arrive by FCM push, but polling this is far easier to test
    against while building the app.

    Response shape mirrors lib/core/models/alert_event.dart.
    """
    nearby = []
    for record in _detections:
        distance = haversine_meters(lat, lng, record["lat"], record["lng"])
        if distance <= radius_m:
            nearby.append(
                {
                    "id": record["id"],
                    "type": record["type"],
                    "lat": record["lat"],
                    "lng": record["lng"],
                    "timestamp": record["timestamp"].isoformat(),
                    "distance_m": round(distance, 1),
                }
            )

    nearby.sort(key=lambda a: a["timestamp"], reverse=True)
    return nearby


@app.post("/reset")
def reset() -> dict:
    """Clears everything, so a test run starts from a known state."""
    _detections.clear()
    _car_locations.clear()
    return {"status": "cleared"}


if __name__ == "__main__":
    # host="0.0.0.0" so the phone on the same Wi-Fi can reach it; binding to
    # localhost would only be reachable from this laptop.
    uvicorn.run(app, host="0.0.0.0", port=8000)
