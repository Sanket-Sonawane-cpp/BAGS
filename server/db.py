"""SQLite persistence for the real server.

A real database (not tools/mock_server.py's in-memory lists), but still a
single local file — matches docs/PROJECT_CONTEXT.md's "dev server = a laptop,
that's fine" scope. No ORM: the schema is two small tables and the queries
are simple enough that sqlite3 directly is less to reason about than an ORM
would be.

A connection is opened and closed per call rather than held open and shared,
so this is safe under FastAPI's threadpool (sync `def` endpoints each run on
their own thread) without any connection-pooling code to get wrong.
"""

from __future__ import annotations

import json
import math
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

DB_PATH = Path(__file__).parent / "bags.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS cars (
    car_id TEXT PRIMARY KEY,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    fcm_token TEXT,
    updated_at TEXT NOT NULL,
    -- JSON [[lat, lng], ...] while the car is navigating, else NULL.
    route TEXT
);

CREATE TABLE IF NOT EXISTS detections (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    confidence REAL NOT NULL,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    timestamp TEXT NOT NULL
);
"""


def init_db() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)
        # Databases created before cars had a route column.
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(cars)")}
        if "route" not in columns:
            conn.execute("ALTER TABLE cars ADD COLUMN route TEXT")


@contextmanager
def _connect() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def haversine_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Great-circle distance between two points, in metres.

    Ported from tools/mock_server.py — SQLite has no built-in geo functions,
    and the dataset here is small enough (a handful of tracked cars) that
    filtering in Python after a plain SELECT is simpler than reaching for a
    spatial extension.
    """
    earth_radius_m = 6_371_000
    d_lat = math.radians(lat2 - lat1)
    d_lng = math.radians(lng2 - lng1)
    a = (
        math.sin(d_lat / 2) ** 2
        + math.cos(math.radians(lat1))
        * math.cos(math.radians(lat2))
        * math.sin(d_lng / 2) ** 2
    )
    return 2 * earth_radius_m * math.asin(math.sqrt(a))


def upsert_car(
    car_id: str,
    lat: float,
    lng: float,
    fcm_token: str | None,
    route: list[tuple[float, float]] | None = None,
) -> None:
    """Records a location ping. `route` replaces the stored one every time,
    so a ping without one (navigation ended) clears it."""
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO cars (car_id, lat, lng, fcm_token, updated_at, route)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(car_id) DO UPDATE SET
                lat = excluded.lat,
                lng = excluded.lng,
                -- A ping with no token (client hasn't got one yet) must not
                -- erase a token learned from an earlier ping.
                fcm_token = COALESCE(excluded.fcm_token, cars.fcm_token),
                updated_at = excluded.updated_at,
                route = excluded.route
            """,
            (
                car_id,
                lat,
                lng,
                fcm_token,
                datetime.now(timezone.utc).isoformat(),
                None if route is None else json.dumps(route),
            ),
        )


def insert_detection(
    type_: str, confidence: float, lat: float, lng: float, timestamp: datetime
) -> dict:
    record = {
        "id": str(uuid.uuid4()),
        "type": type_,
        "confidence": confidence,
        "lat": lat,
        "lng": lng,
        "timestamp": timestamp.astimezone(timezone.utc).isoformat(),
    }
    with _connect() as conn:
        conn.execute(
            "INSERT INTO detections (id, type, confidence, lat, lng, timestamp) "
            "VALUES (:id, :type, :confidence, :lat, :lng, :timestamp)",
            record,
        )
    return record


def cars_with_token() -> list[dict]:
    """Every car that can be pushed to, with its last position and route.

    A car with no token yet (hasn't sent a location ping since its FCM
    permission resolved) is silently skipped, not an error — it just can't
    be reached yet.
    """
    with _connect() as conn:
        rows = conn.execute(
            "SELECT car_id, lat, lng, fcm_token, updated_at, route FROM cars "
            "WHERE fcm_token IS NOT NULL"
        ).fetchall()

    return [
        {
            "car_id": row["car_id"],
            "lat": row["lat"],
            "lng": row["lng"],
            "fcm_token": row["fcm_token"],
            "updated_at": datetime.fromisoformat(row["updated_at"]),
            "route": None
            if row["route"] is None
            else [tuple(point) for point in json.loads(row["route"])],
        }
        for row in rows
    ]


def nearby_detections(lat: float, lng: float, radius_m: float) -> list[dict]:
    with _connect() as conn:
        rows = conn.execute(
            "SELECT id, type, lat, lng, timestamp FROM detections"
        ).fetchall()

    nearby = []
    for row in rows:
        distance = haversine_meters(lat, lng, row["lat"], row["lng"])
        if distance <= radius_m:
            nearby.append(
                {
                    "id": row["id"],
                    "type": row["type"],
                    "lat": row["lat"],
                    "lng": row["lng"],
                    "timestamp": row["timestamp"],
                    "distance_m": round(distance, 1),
                }
            )
    nearby.sort(key=lambda a: a["timestamp"], reverse=True)
    return nearby


def counts() -> dict:
    with _connect() as conn:
        detections = conn.execute("SELECT COUNT(*) FROM detections").fetchone()[0]
        cars = conn.execute("SELECT COUNT(*) FROM cars").fetchone()[0]
    return {"detections": detections, "cars": cars}


def reset() -> None:
    with _connect() as conn:
        conn.execute("DELETE FROM detections")
        conn.execute("DELETE FROM cars")
