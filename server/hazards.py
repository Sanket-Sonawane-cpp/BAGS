"""The rules for what the server believes about a reported hazard.

A car reports the same hazard many times as it drives past (the model
checks ~3 frames a second), and other cars report it again later. All of
those are sightings of one hazard, kept in db.py's `hazards` table. These
rules decide:

- which sightings are the same hazard (MERGE_RADIUS_M),
- when a hazard is trusted enough to reroute cars for (is_confirmed),
- when it's gone: it expires a while after its last sighting (lifetime),
  or sooner once cars drive past without seeing it (CLEAR_VOTES).

The app mirrors the lifetimes and the confirmation flag: see
`HazardStyle.lifetime` and `worthAvoiding` in lib/core/hazards.dart.
"""

from __future__ import annotations

from datetime import timedelta

# How long a hazard lasts after its last sighting, by type. An accident is
# usually cleared within the hour; a flood takes longer to drain; a pothole
# stays until it's repaired. Keep in sync with HazardStyle.lifetime in
# lib/core/hazards.dart.
LIFETIMES = {
    "accident": timedelta(hours=1),
    "fallen_object": timedelta(hours=1),
    "flood": timedelta(hours=6),
    "pothole": timedelta(days=7),
    # "Road is clear" — not a hazard, so only briefly interesting.
    "non_accident": timedelta(minutes=10),
}

# For a type the server doesn't know yet (a retrained model's new label).
DEFAULT_LIFETIME = timedelta(hours=2)

# Sightings of the same type this close together are one hazard. A
# sighting's position is the reporting car's GPS fix, not the hazard's: a
# car approaching an accident reports it from a string of points up the
# road, each 10-30 m off on top, so this is wider than the GPS error alone.
MERGE_RADIUS_M = 50

# A hazard reroutes cars only once this many different cars have seen it...
CONFIRM_REPORTERS = 2

# ...or one car was this sure. The model's own per-class alert thresholds
# are ~0.25-0.48, so a single report at those levels is still often wrong.
CONFIRM_CONFIDENCE = 0.8

# This many different cars driving past without seeing a hazard, with no
# new sighting since, means it's gone.
CLEAR_VOTES = 2

# Cars travelling within this of each other (degrees) are going the same
# way down a road. Each sighting keeps the reporting car's direction of
# travel: the camera faces forward, so a hazard seen by cars going one way
# may be on the far carriageway of a divided road for cars going the other.
# Generous, because a car's GPS bearing and a road's bend both wander. Keep
# in sync with sameWayDegrees in lib/core/hazards.dart.
SAME_WAY_DEGREES = 60


def lifetime(type_: str) -> timedelta:
    return LIFETIMES.get(type_, DEFAULT_LIFETIME)


def angle_between(a: float, b: float) -> float:
    """The smaller angle between two compass directions, 0-180 degrees."""
    return abs((a - b + 180) % 360 - 180)


def same_way(heading: float, headings) -> bool:
    """Whether a car travelling `heading` is going the same way as any of
    `headings`. True when there are none: with no directions known, every
    car may have seen it."""
    headings = list(headings)
    return not headings or any(
        angle_between(heading, h) <= SAME_WAY_DEGREES for h in headings
    )


def is_confirmed(reporters: int, confidence: float) -> bool:
    """Whether a hazard seen by `reporters` different cars, at best with
    `confidence`, is trusted enough to send cars a different way."""
    return reporters >= CONFIRM_REPORTERS or confidence >= CONFIRM_CONFIDENCE
