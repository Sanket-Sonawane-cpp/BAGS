"""Tests for how reports become hazards and how hazards go away.

Run from the repo root:

    python -m unittest discover server

Uses a throwaway database and records pushes instead of sending them.
"""

from __future__ import annotations

import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from fastapi import HTTPException
from pydantic import ValidationError

import app
import db
import fcm
import routes

# ~0.0001° of latitude is 11 m.
HERE = (18.5, 73.8)


def _north(meters: float) -> tuple[float, float]:
    return (HERE[0] + meters / 111_320, HERE[1])


class HazardTest(unittest.TestCase):
    def setUp(self) -> None:
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self._patch(db, "DB_PATH", Path(folder.name) / "test.db")

        self.now = datetime.now(timezone.utc)
        self._patch(db, "_utcnow", lambda: self.now)

        self.pushes: list[tuple[str, dict]] = []
        self._patch(
            fcm,
            "send_alert",
            lambda token, alert: self.pushes.append((token, alert)) or True,
        )
        db.init_db()

    def _patch(self, target, name, value) -> None:
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def report(
        self,
        car: str | None,
        type_: str = "accident",
        at: tuple[float, float] = HERE,
        confidence: float = 0.6,
        heading: float | None = None,
    ) -> dict:
        return app.post_detection(
            app.DetectionIn(
                type=type_,
                confidence=confidence,
                lat=at[0],
                lng=at[1],
                timestamp=self.now,
                car_id=car,
                heading=heading,
            )
        )

    def car(self, car_id: str, at=HERE, route=None) -> None:
        db.upsert_car(car_id, at[0], at[1], f"token-{car_id}", route)

    def alerts(self) -> list[dict]:
        return app.get_alerts(HERE[0], HERE[1], 5000)

    def later(self, **delta) -> None:
        self.now += timedelta(**delta)


class MergingTest(HazardTest):
    def test_repeat_reports_are_one_hazard_pushed_once(self) -> None:
        self.car("other")
        first = self.report("reporter")
        # The same car, a few frames later and a little further up the road.
        again = self.report("reporter", at=_north(20))

        self.assertTrue(first["new"])
        self.assertFalse(again["new"])
        self.assertEqual(first["id"], again["id"])
        self.assertEqual(len(self.alerts()), 1)
        self.assertEqual(len(self.pushes), 1)
        self.assertEqual(db.counts()["detections"], 2)

    def test_different_types_or_spots_are_different_hazards(self) -> None:
        a = self.report("car", "accident")
        b = self.report("car", "flood")
        c = self.report("car", "accident", at=_north(80))
        self.assertEqual(len({a["id"], b["id"], c["id"]}), 3)


class ConfirmationTest(HazardTest):
    def test_one_report_is_unconfirmed(self) -> None:
        self.report("a")
        [alert] = self.alerts()
        self.assertFalse(alert["confirmed"])
        self.assertEqual(alert["reports"], 1)

    def test_a_second_car_confirms_it_and_it_is_pushed_again(self) -> None:
        self.car("listener")
        self.report("a")
        self.report("a")  # same car: still one reporter
        self.assertFalse(self.alerts()[0]["confirmed"])

        confirming = self.report("b")
        self.assertTrue(confirming["confirmed"])
        self.assertEqual([alert["confirmed"] for _, alert in self.pushes], [False, True])

        self.report("c")  # already confirmed: no news
        self.assertEqual(len(self.pushes), 2)
        self.assertEqual(self.alerts()[0]["reports"], 3)

    def test_one_very_sure_report_is_enough(self) -> None:
        self.assertTrue(self.report("a", confidence=0.9)["confirmed"])

    def test_reporters_are_not_pushed_their_own_hazard(self) -> None:
        self.car("a")
        self.car("b")
        self.report("a")
        self.report("b")  # confirms: pushed, but not to a or b
        self.assertEqual(self.pushes, [("token-b", self.pushes[0][1])])

    def test_only_confirmed_hazards_reach_cars_far_down_their_route(self) -> None:
        # Navigating towards HERE from 5 km south: beyond the push radius,
        # but the hazard is on its route ahead.
        start = (HERE[0] - 0.045, HERE[1])
        self.car("driver", at=start, route=[start, _north(1000)])

        self.report("a")
        self.assertEqual(self.pushes, [])

        self.report("b")
        [(token, alert)] = self.pushes
        self.assertEqual(token, "token-driver")
        self.assertAlmostEqual(alert["distance_m"], 5000, delta=50)


class ExpiryTest(HazardTest):
    def test_each_type_lasts_its_own_time_after_its_last_sighting(self) -> None:
        self.report("a", "accident")
        self.report("a", "pothole", at=_north(200))

        self.later(minutes=50)
        self.report("b", "accident")  # still there: the hour restarts
        self.later(minutes=50)
        self.assertEqual({a["type"] for a in self.alerts()}, {"accident", "pothole"})

        self.later(minutes=15)
        self.assertEqual([a["type"] for a in self.alerts()], ["pothole"])

        self.later(days=7)
        self.assertEqual(self.alerts(), [])

    def test_purge_deletes_expired_hazards_and_their_sightings(self) -> None:
        self.report("a", "accident")
        self.report("a", "pothole", at=_north(200))
        self.later(hours=2)

        self.assertEqual(db.purge_expired(), 1)
        self.assertEqual(db.counts()["hazards"], 1)
        self.assertEqual(db.counts()["detections"], 1)

    def test_an_expired_hazard_is_not_merged_into(self) -> None:
        old = self.report("a")
        self.later(hours=2)
        self.assertNotEqual(self.report("a")["id"], old["id"])


class NotSeenTest(HazardTest):
    def not_seen(self, hazard_id: str, car: str) -> str:
        return app.post_not_seen(hazard_id, app.NotSeenIn(car_id=car))["status"]

    def test_two_cars_not_seeing_it_clear_it(self) -> None:
        hazard = self.report("a")["id"]
        self.later(minutes=5)

        self.assertEqual(self.not_seen(hazard, "b"), "noted")
        self.assertEqual(self.not_seen(hazard, "b"), "noted")  # same car again
        self.assertEqual(len(self.alerts()), 1)

        self.assertEqual(self.not_seen(hazard, "c"), "cleared")
        self.assertEqual(self.alerts(), [])
        self.assertEqual(db.counts()["detections"], 0)

    def test_a_sighting_outweighs_earlier_votes(self) -> None:
        hazard = self.report("a")["id"]
        self.later(minutes=1)
        self.not_seen(hazard, "b")
        self.later(minutes=1)
        self.report("c")  # still there after all
        self.later(minutes=1)

        self.assertEqual(self.not_seen(hazard, "d"), "noted")
        self.assertEqual(self.not_seen(hazard, "e"), "cleared")

    def test_a_gone_hazard_is_404(self) -> None:
        with self.assertRaises(HTTPException) as raised:
            self.not_seen("nope", "b")
        self.assertEqual(raised.exception.status_code, 404)


class DirectionTest(HazardTest):
    def not_seen(self, hazard_id: str, car: str, heading=None) -> str:
        return app.post_not_seen(
            hazard_id, app.NotSeenIn(car_id=car, heading=heading)
        )["status"]

    def test_each_reporters_latest_direction_is_listed(self) -> None:
        self.report("a", heading=0)
        self.report("a", heading=10.4)
        self.report("b", heading=180)
        self.report("c")  # standing still: direction unknown
        [alert] = self.alerts()
        self.assertEqual(alert["headings"], [10, 180])
        self.assertEqual(alert["reports"], 3)

    def test_a_vote_from_the_other_direction_is_ignored(self) -> None:
        hazard = self.report("a", heading=0)["id"]
        self.later(minutes=1)

        self.assertEqual(self.not_seen(hazard, "b", heading=180), "ignored")
        self.assertEqual(self.not_seen(hazard, "c", heading=90), "ignored")
        self.assertEqual(self.not_seen(hazard, "d", heading=350), "noted")
        self.assertEqual(self.not_seen(hazard, "e"), "cleared")  # unknown: counts

    def test_with_no_known_direction_any_vote_counts(self) -> None:
        hazard = self.report("a")["id"]
        self.later(minutes=1)
        self.assertEqual(self.not_seen(hazard, "b", heading=180), "noted")

    def test_route_pushes_go_only_to_cars_going_the_reported_way(self) -> None:
        # Driving north towards both hazards from 5 km south.
        start = (HERE[0] - 0.045, HERE[1])
        self.car("driver", at=start, route=[start, _north(1000)])

        # Seen by cars heading south: maybe the far carriageway.
        for car in ("a", "b"):
            self.report(car, heading=180)
        self.assertEqual(self.pushes, [])

        # Seen by cars heading north, like the driver.
        for car in ("a", "b"):
            self.report(car, at=_north(500), heading=2)
        [(token, alert)] = self.pushes
        self.assertEqual((token, alert["headings"]), ("token-driver", [2]))

    def test_a_hazard_at_a_corner_counts_for_the_approach(self) -> None:
        # North, then a right turn east at HERE; reported by a car going
        # north into the corner.
        start = (HERE[0] - 0.01, HERE[1])
        route = [start, HERE, (HERE[0], HERE[1] + 0.01)]
        corner = (HERE[0], HERE[1] + 0.0002)  # just past the turn
        self.assertIsNotNone(routes.distance_ahead(route, start, corner, headings=[0]))
        self.assertIsNone(routes.distance_ahead(route, start, corner, headings=[180]))

    def test_directions_must_be_compass_degrees(self) -> None:
        with self.assertRaises(ValidationError):
            app.NotSeenIn(car_id="a", heading=400)


class MigrationTest(HazardTest):
    def test_old_detections_become_hazards(self) -> None:
        conn = sqlite3.connect(db.DB_PATH)
        conn.executescript(
            "DROP TABLE detections; DROP TABLE hazards; "
            "CREATE TABLE detections (id TEXT PRIMARY KEY, type TEXT, "
            "confidence REAL, lat REAL, lng REAL, timestamp TEXT);"
        )
        for i, at in enumerate([HERE, _north(10), _north(300)]):
            conn.execute(
                "INSERT INTO detections VALUES (?, 'accident', 0.6, ?, ?, ?)",
                (f"old{i}", at[0], at[1], self.now.isoformat()),
            )
        conn.commit()
        conn.close()

        db.init_db()
        self.assertEqual(len(self.alerts()), 2)


class ResetTest(HazardTest):
    def test_reset_clears_everything(self) -> None:
        self.car("b")
        hazard = self.report("a")["id"]
        self.later(minutes=1)
        db.record_not_seen(hazard, "b")

        app.reset()
        self.assertEqual(db.counts(), {"hazards": 0, "detections": 0, "cars": 0})


if __name__ == "__main__":
    unittest.main()
