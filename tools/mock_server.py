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
from pathlib import Path

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Bags mock alert server")

# In-memory stores. The real server needs a database; this deliberately does not.
_detections: list[dict] = []
_car_locations: dict[str, dict] = {}
_car_tokens: dict[str, str] = {}

# How far from an obstruction a car still wants to hear about it.
ALERT_RADIUS_M = 2000

# Pushing is optional: without the service account key the server still records
# everything, it just cannot deliver alerts. That keeps the app's upload path
# testable without any Firebase credentials present.
_KEY_PATH = Path(__file__).parent / "serviceAccountKey.json"
_messaging = None

if _KEY_PATH.exists():
    try:
        import firebase_admin
        from firebase_admin import credentials, messaging as _messaging

        firebase_admin.initialize_app(credentials.Certificate(str(_KEY_PATH)))
        print("[init] Firebase ready - alerts will be pushed")
    except Exception as error:  # noqa: BLE001 - a mock server should not die here
        print(f"[init] Firebase unavailable, alerts will not be pushed: {error}")
        _messaging = None
else:
    print(f"[init] No {_KEY_PATH.name}, alerts will not be pushed")


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


class Registration(BaseModel):
    """How to reach a given car with a push."""

    car_id: str
    fcm_token: str


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


def push_alert(token: str, detection: dict, distance_m: float) -> bool:
    """Delivers one obstruction warning to one car.

    Values are all strings because that is the only thing an FCM data payload
    carries; the app parses them back into numbers.
    """
    if _messaging is None:
        return False

    message = _messaging.Message(
        token=token,
        data={
            "id": detection["id"],
            "type": detection["type"],
            "lat": str(detection["lat"]),
            "lng": str(detection["lng"]),
            "timestamp": detection["timestamp"].isoformat(),
            "distance_m": str(round(distance_m, 1)),
        },
        # Obstruction warnings are time-critical; normal priority lets Android
        # hold them back while the device is dozing.
        android=_messaging.AndroidConfig(priority="high"),
        apns=_messaging.APNSConfig(
            headers={"apns-priority": "10"},
            payload=_messaging.APNSPayload(
                aps=_messaging.Aps(content_available=True),
            ),
        ),
    )

    try:
        _messaging.send(message)
        return True
    except Exception as error:  # noqa: BLE001
        print(f"[push] failed: {error}")
        return False


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "detections": len(_detections),
        "cars": len(_car_locations),
        "registered": len(_car_tokens),
        "push_enabled": _messaging is not None,
    }


@app.post("/register")
def register(registration: Registration) -> dict:
    """Records how to push to a car."""
    _car_tokens[registration.car_id] = registration.fcm_token
    print(f"[register] {registration.car_id[:8]}... token stored")
    return {"status": "registered"}


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

    # Warn every car close enough to care. This is the core of what the real
    # server does, and the whole reason location pings exist.
    alerted = 0
    for car_id, location in _car_locations.items():
        token = _car_tokens.get(car_id)
        if token is None:
            continue

        distance = haversine_meters(
            event.lat, event.lng, location["lat"], location["lng"]
        )
        if distance > ALERT_RADIUS_M:
            continue

        if push_alert(token, record, distance):
            alerted += 1
            print(f"[push] warned {car_id[:8]}... ({distance:.0f}m away)")

    return {"id": record["id"], "status": "recorded", "alerted": alerted}


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


@app.get("/cars")
def cars() -> dict:
    """Who the server currently knows about, for debugging."""
    return {
        car_id: {
            **location,
            "last_seen": location["last_seen"].isoformat(),
            "push_registered": car_id in _car_tokens,
        }
        for car_id, location in _car_locations.items()
    }


@app.post("/reset")
def reset() -> dict:
    """Clears everything, so a test run starts from a known state."""
    _detections.clear()
    _car_locations.clear()
    _car_tokens.clear()
    return {"status": "cleared"}


if __name__ == "__main__":
    # host="0.0.0.0" so the phone on the same Wi-Fi can reach it; binding to
    # localhost would only be reachable from this laptop.
    uvicorn.run(app, host="0.0.0.0", port=8000)
