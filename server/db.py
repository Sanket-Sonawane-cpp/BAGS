"""SQLite persistence for the real server.

A real database (not tools/mock_server.py's in-memory lists), but still a
single local file — matches docs/PROJECT_CONTEXT.md's "dev server = a laptop,
that's fine" scope. No ORM: the schema is a few small tables and the queries
are simple enough that sqlite3 directly is less to reason about than an ORM
would be.

Every detection a car reports is kept as a sighting (`detections`) of a
hazard (`hazards`): repeat reports of the same thing in the same spot are one
hazard, which is what the app is told about. hazards.py has the rules.

A connection is opened and closed per call rather than held open and shared,
so this is safe under FastAPI's threadpool (sync `def` endpoints each run on
their own thread) without any connection-pooling code to get wrong. Writes
that read before they write (deciding which hazard a sighting belongs to)
hold _lock, so two reports of a new hazard arriving together can't each
create one.
"""

from __future__ import annotations

import json
import math
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

import hazards as rules

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

-- One row per thing on the road, however many times it was reported.
CREATE TABLE IF NOT EXISTS hazards (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    -- Where it was first reported; later sightings don't move it.
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    -- Server time, so expiry and not-seen votes never compare two phones'
    -- clocks.
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL
);

-- Every report, as a sighting of a hazard.
CREATE TABLE IF NOT EXISTS detections (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    confidence REAL NOT NULL,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    -- When the reporting phone saw it.
    timestamp TEXT NOT NULL,
    hazard_id TEXT,
    -- NULL from app builds that don't send it.
    car_id TEXT,
    -- The reporting car's direction of travel, degrees clockwise from
    -- north. NULL when unknown (standing still, older app builds).
    heading REAL
);

-- Cars that drove past a hazard, detecting, without seeing it.
CREATE TABLE IF NOT EXISTS not_seen (
    hazard_id TEXT NOT NULL,
    car_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    PRIMARY KEY (hazard_id, car_id)
);
"""

_lock = threading.Lock()


def _utcnow() -> datetime:
    """The server's clock. Replaced in tests."""
    return datetime.now(timezone.utc)


def init_db() -> None:
    with _lock, _connect() as conn:
        conn.executescript(_SCHEMA)
        # Databases created before cars had a route column.
        if "route" not in _columns(conn, "cars"):
            conn.execute("ALTER TABLE cars ADD COLUMN route TEXT")
        # ...or before detections were grouped into hazards.
        detection_columns = _columns(conn, "detections")
        for column, type_ in (
            ("hazard_id", "TEXT"),
            ("car_id", "TEXT"),
            ("heading", "REAL"),
        ):
            if column not in detection_columns:
                conn.execute(f"ALTER TABLE detections ADD COLUMN {column} {type_}")
        unassigned = conn.execute(
            "SELECT id, type, lat, lng, timestamp FROM detections "
            "WHERE hazard_id IS NULL ORDER BY timestamp"
        ).fetchall()
        for row in unassigned:
            _attach(
                conn,
                row["id"],
                row["type"],
                row["lat"],
                row["lng"],
                datetime.fromisoformat(row["timestamp"]),
            )


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}


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
                _utcnow().isoformat(),
                None if route is None else json.dumps(route),
            ),
        )


def record_sighting(
    type_: str,
    confidence: float,
    lat: float,
    lng: float,
    timestamp: datetime,
    car_id: str | None,
    heading: float | None = None,
) -> dict:
    """Stores a detection as a sighting of the live hazard of the same type
    within MERGE_RADIUS_M, or of a new hazard if there's none.

    Direction doesn't split hazards: the same accident seen by cars going
    both ways is one hazard, with both directions on record.

    Returns {"hazard": the hazard as live_hazards() describes it, "new":
    whether this sighting created it, "newly_confirmed": whether this
    sighting is the one that made it trusted enough to reroute for}.
    """
    detection_id = str(uuid.uuid4())
    now = _utcnow()
    with _lock, _connect() as conn:
        conn.execute(
            "INSERT INTO detections "
            "(id, type, confidence, lat, lng, timestamp, car_id, heading) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                detection_id,
                type_,
                confidence,
                lat,
                lng,
                timestamp.astimezone(timezone.utc).isoformat(),
                car_id,
                heading,
            ),
        )
        hazard_id, before = _attach(conn, detection_id, type_, lat, lng, now)
        hazard = _live_hazards(conn, now, hazard_id)[0]
    return {
        "hazard": hazard,
        "new": before is None,
        "newly_confirmed": hazard["confirmed"]
        and not (before is not None and before["confirmed"]),
    }


def _attach(
    conn: sqlite3.Connection,
    detection_id: str,
    type_: str,
    lat: float,
    lng: float,
    seen_at: datetime,
) -> tuple[str, dict | None]:
    """Makes a stored detection a sighting of the nearest live hazard of its
    type within MERGE_RADIUS_M, or of a new hazard where it was seen.

    Returns the hazard's id, and the hazard as it was before this sighting
    (None if this created it).
    """
    candidates = [
        (haversine_meters(lat, lng, h["lat"], h["lng"]), h)
        for h in _live_hazards(conn, seen_at)
        if h["type"] == type_
    ]
    near = [(d, h) for d, h in candidates if d <= rules.MERGE_RADIUS_M]
    existing = min(near, key=lambda pair: pair[0])[1] if near else None

    stamp = seen_at.isoformat()
    if existing is None:
        hazard_id = str(uuid.uuid4())
        conn.execute(
            "INSERT INTO hazards (id, type, lat, lng, first_seen, last_seen) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (hazard_id, type_, lat, lng, stamp, stamp),
        )
    else:
        hazard_id = existing["id"]
        conn.execute(
            "UPDATE hazards SET last_seen = ? WHERE id = ?", (stamp, hazard_id)
        )
    conn.execute(
        "UPDATE detections SET hazard_id = ? WHERE id = ?", (hazard_id, detection_id)
    )
    return hazard_id, existing


def _live_hazards(
    conn: sqlite3.Connection, now: datetime, hazard_id: str | None = None
) -> list[dict]:
    """Hazards that haven't expired as of `now` (just `hazard_id`, if given),
    each with what its sightings add up to:

        id, type, lat, lng,
        last_seen: datetime of the latest sighting,
        confidence: the surest sighting's,
        reporter_ids: the different cars that reported it,
        reports: how many of them there are,
        confirmed: hazards.is_confirmed for the above,
        headings: the directions its reporters were travelling (each one's
            latest known), in whole degrees, without repeats; empty if none
            is known.
    """
    where, params = ("WHERE id = ?", (hazard_id,)) if hazard_id else ("", ())
    rows = conn.execute(
        f"SELECT id, type, lat, lng, last_seen FROM hazards {where}", params
    ).fetchall()
    where = "WHERE hazard_id = ?" if hazard_id else "WHERE hazard_id IS NOT NULL"
    sightings: dict[str, list[sqlite3.Row]] = {}
    for row in conn.execute(
        "SELECT hazard_id, car_id, confidence, heading FROM detections "
        f"{where} ORDER BY rowid",
        params,
    ):
        sightings.setdefault(row["hazard_id"], []).append(row)

    live = []
    for row in rows:
        last_seen = datetime.fromisoformat(row["last_seen"])
        if last_seen + rules.lifetime(row["type"]) <= now:
            continue
        seen = sightings.get(row["id"], [])
        # Reports from builds that don't send a car id count as one car.
        reporter_ids = {s["car_id"] or "" for s in seen}
        confidence = max((s["confidence"] for s in seen), default=0.0)
        # Oldest first, so each reporter ends on its latest direction.
        headings = {
            s["car_id"] or "": round(s["heading"]) % 360
            for s in seen
            if s["heading"] is not None
        }
        live.append(
            {
                "id": row["id"],
                "type": row["type"],
                "lat": row["lat"],
                "lng": row["lng"],
                "last_seen": last_seen,
                "confidence": confidence,
                "reporter_ids": reporter_ids,
                "reports": len(reporter_ids),
                "confirmed": rules.is_confirmed(len(reporter_ids), confidence),
                "headings": sorted(set(headings.values())),
            }
        )
    return live


def nearby_hazards(lat: float, lng: float, radius_m: float) -> list[dict]:
    """Live hazards within radius_m of a point, latest sighting first, each
    with its `distance_m` from it."""
    with _connect() as conn:
        live = _live_hazards(conn, _utcnow())

    nearby = []
    for hazard in live:
        distance = haversine_meters(lat, lng, hazard["lat"], hazard["lng"])
        if distance <= radius_m:
            nearby.append({**hazard, "distance_m": round(distance, 1)})
    nearby.sort(key=lambda h: h["last_seen"], reverse=True)
    return nearby


def record_not_seen(
    hazard_id: str, car_id: str, heading: float | None = None
) -> str | None:
    """Notes that `car_id` drove past a hazard, detecting, and didn't see it.

    Once CLEAR_VOTES different cars have, all since its last sighting, the
    hazard is deleted. Returns "cleared" then, "noted" if it stays, or None
    for a hazard that's already gone (expired, cleared, or never existed).

    A car going the other way from everyone who saw it (`heading`, its
    direction of travel) may simply have been on the far carriageway, facing
    away: its vote is "ignored".
    """
    now = _utcnow()
    with _lock, _connect() as conn:
        found = _live_hazards(conn, now, hazard_id)
        if not found:
            return None
        if heading is not None and not rules.same_way(heading, found[0]["headings"]):
            return "ignored"
        conn.execute(
            """
            INSERT INTO not_seen (hazard_id, car_id, timestamp) VALUES (?, ?, ?)
            ON CONFLICT(hazard_id, car_id) DO UPDATE SET timestamp = excluded.timestamp
            """,
            (hazard_id, car_id, now.isoformat()),
        )
        # A sighting after a vote outweighs it: the hazard was still there.
        votes = sum(
            datetime.fromisoformat(row["timestamp"]) > found[0]["last_seen"]
            for row in conn.execute(
                "SELECT timestamp FROM not_seen WHERE hazard_id = ?", (hazard_id,)
            )
        )
        if votes < rules.CLEAR_VOTES:
            return "noted"
        _delete_hazards(conn, [hazard_id])
        return "cleared"


def purge_expired() -> int:
    """Deletes hazards past their lifetime, with their sightings and votes.
    Reads already skip them; this just keeps the file from growing forever.
    Returns how many went."""
    now = _utcnow()
    with _lock, _connect() as conn:
        expired = [
            row["id"]
            for row in conn.execute("SELECT id, type, last_seen FROM hazards")
            if datetime.fromisoformat(row["last_seen"]) + rules.lifetime(row["type"])
            <= now
        ]
        _delete_hazards(conn, expired)
    return len(expired)


def _delete_hazards(conn: sqlite3.Connection, ids: list[str]) -> None:
    params = [(hazard_id,) for hazard_id in ids]
    conn.executemany("DELETE FROM not_seen WHERE hazard_id = ?", params)
    conn.executemany("DELETE FROM detections WHERE hazard_id = ?", params)
    conn.executemany("DELETE FROM hazards WHERE id = ?", params)


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


def counts() -> dict:
    with _connect() as conn:
        return {
            table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("hazards", "detections", "cars")
        }


def reset() -> None:
    with _lock, _connect() as conn:
        for table in ("not_seen", "detections", "hazards", "cars"):
            conn.execute(f"DELETE FROM {table}")
