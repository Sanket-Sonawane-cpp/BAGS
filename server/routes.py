"""Whether a hazard lies on the road ahead of a navigating car.

Cars that are navigating send their route with each location ping, so a
hazard reported anywhere ahead on it can be pushed to them — not only to
cars within ALERT_RADIUS_M of it.
"""

from __future__ import annotations

import math
from collections.abc import Sequence

import hazards as rules
from db import haversine_meters

# A hazard's position is the reporting phone's GPS fix, routinely 10-30 m
# off, so this is wider than a road. Matches the app's own corridor
# (hazardsOnRoute in lib/features/navigation/hazard_routing.dart) plus a
# little for the app thinning the route before sending it.
ROUTE_CORRIDOR_M = 50

# A hazard reported going the same way as the route anywhere this close to
# where it sits on the route counts: right at a junction, the reporter's
# direction is the approach, and the route may already have turned.
DIRECTION_WINDOW_M = 30

_METERS_PER_DEGREE = 111_320


def distance_ahead(
    route: list[tuple[float, float]],
    car: tuple[float, float],
    hazard: tuple[float, float],
    corridor_m: float = ROUTE_CORRIDOR_M,
    headings: Sequence[float] = (),
) -> float | None:
    """Metres along `route` from `car` to `hazard`, if the hazard is on the
    route (within `corridor_m` of it), still ahead of the car, and — when
    the directions its reporters were travelling (`headings`) are known —
    reported by a car going the same way as the route there. A hazard only
    reported from the other direction may be on the far side of a divided
    road.

    Points are (lat, lng). None otherwise.
    """
    if len(route) < 2:
        return None
    hazard_along, hazard_off = _project(route, hazard)
    if hazard_off > corridor_m:
        return None
    car_along, _ = _project(route, car)
    if hazard_along <= car_along:
        return None
    if headings and not any(
        rules.same_way(direction, headings)
        for direction in _directions_around(route, hazard_along)
    ):
        return None
    return hazard_along - car_along


def _directions_around(
    route: list[tuple[float, float]], along: float
) -> list[float]:
    """The route's direction of travel (degrees clockwise from north) on
    each segment within DIRECTION_WINDOW_M of `along` metres along it."""
    directions = []
    walked = 0.0
    for a, b in zip(route, route[1:]):
        length = haversine_meters(a[0], a[1], b[0], b[1])
        start, walked = walked, walked + length
        if walked < along - DIRECTION_WINDOW_M or length == 0:
            continue
        if start > along + DIRECTION_WINDOW_M:
            break
        east = (b[1] - a[1]) * math.cos(math.radians(a[0]))
        north = b[0] - a[0]
        directions.append(math.degrees(math.atan2(east, north)) % 360)
    return directions


def _project(
    route: list[tuple[float, float]], point: tuple[float, float]
) -> tuple[float, float]:
    """(distance along the route, distance off it) of the route point nearest
    `point`.

    Each segment is flattened onto a local east/north grid around `point`,
    which is accurate to well under a metre at the scale of one road segment.
    """
    lat0, lng0 = point
    cos_lat = math.cos(math.radians(lat0))

    def local(p: tuple[float, float]) -> tuple[float, float]:
        return (
            (p[1] - lng0) * cos_lat * _METERS_PER_DEGREE,
            (p[0] - lat0) * _METERS_PER_DEGREE,
        )

    best_off = math.inf
    best_along = 0.0
    walked = 0.0
    for a, b in zip(route, route[1:]):
        ax, ay = local(a)
        bx, by = local(b)
        dx, dy = bx - ax, by - ay
        length_sq = dx * dx + dy * dy
        # Where along a->b the point's foot falls, clamped to the segment.
        t = 0.0 if length_sq == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length_sq))
        off = math.hypot(ax + t * dx, ay + t * dy)
        segment = haversine_meters(a[0], a[1], b[0], b[1])
        if off < best_off:
            best_off = off
            best_along = walked + t * segment
        walked += segment
    return best_along, best_off
