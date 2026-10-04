"""Pushes alerts to phones via Firebase Cloud Messaging.

Server -> phone is a normal outbound HTTPS call through the Firebase Admin
SDK; Firebase handles actual delivery. No socket held open to any phone, no
delivery-retry logic to write here — see docs/PROJECT_CONTEXT.md's "Alerts
use FCM, not raw WebSockets" decision.
"""

from __future__ import annotations

import logging
from pathlib import Path

import firebase_admin
from firebase_admin import credentials, messaging

logger = logging.getLogger("bags.fcm")

SERVICE_ACCOUNT_PATH = Path(__file__).parent / "serviceAccountKey.json"

_ready = False

# Must match the channel MainActivity.kt creates. It is high importance, so
# the alert pops up over whatever the driver has open (e.g. a maps app).
ANDROID_CHANNEL_ID = "hazard_alerts"

# Mirrors the labels in lib/core/hazards.dart. `non_accident` is left out on
# purpose: it means "road is clear", which isn't worth interrupting a driver
# for, so it stays a silent data-only push.
HAZARD_LABELS = {
    "accident": "Accident",
    "fallen_object": "Fallen object",
    "flood": "Flood",
    "pothole": "Pothole",
}


def init_fcm() -> bool:
    """Initializes the Admin SDK if a service account key is present.

    Deliberately non-fatal when it isn't: /detection and /location still
    need to work for local dev (recording detections, testing the location
    ping) even before anyone has plugged in Firebase credentials. Only the
    actual push attempt fails until this file exists.
    """
    global _ready
    if not SERVICE_ACCOUNT_PATH.exists():
        logger.warning(
            "%s not found — FCM pushes will be skipped (logged, not sent). "
            "Get one from Firebase console -> Project settings -> Service "
            "accounts -> Generate new private key, and save it there.",
            SERVICE_ACCOUNT_PATH,
        )
        _ready = False
        return False

    if not firebase_admin._apps:  # avoid double-init on a dev auto-reload
        firebase_admin.initialize_app(credentials.Certificate(str(SERVICE_ACCOUNT_PATH)))
    _ready = True
    return True


def is_ready() -> bool:
    return _ready


def send_alert(token: str, alert: dict) -> bool:
    """Sends one alert to one device. Returns whether it actually sent.

    Every value in a data payload must be a string — the FCM wire format
    doesn't carry numbers or nested objects — matching
    AlertEvent.fromJson's lenient parsing on the Dart side, which was
    written for exactly this reason.

    Hazards also carry a `notification` block, so the OS shows it when the
    app is backgrounded or killed — a data-only push there only reaches
    handleBackgroundMessage, which can't show UI. In the foreground Android
    doesn't display it; the app gets onMessage and shows its own banner.
    Either way the app parses `message.data` into a typed AlertEvent — see
    NotificationService._emit.
    """
    if not _ready:
        logger.info("[fcm skipped, no credentials] would push %s to %s", alert, token)
        return False

    message = messaging.Message(
        token=token,
        data={
            "id": str(alert["id"]),
            "type": str(alert["type"]),
            "lat": str(alert["lat"]),
            "lng": str(alert["lng"]),
            "timestamp": str(alert["timestamp"]),
            "confirmed": "true" if alert.get("confirmed", True) else "false",
            "reports": str(alert.get("reports", 1)),
            "distance_m": str(alert["distance_m"]),
        },
        **_visible_notification(alert),
    )
    try:
        messaging.send(message)
        return True
    except Exception as error:  # noqa: BLE001 - one bad token must not break the batch
        logger.warning("Push to %s failed: %s", token, error)
        return False


def _visible_notification(alert: dict) -> dict:
    """The Message kwargs that make an alert show up as a system notification.

    Empty for non-hazard classes, which then stay data-only.
    """
    label = HAZARD_LABELS.get(alert["type"])
    if label is None:
        return {}

    distance = float(alert["distance_m"])
    # Same rounding as formatDistance in lib/core/hazards.dart.
    if distance >= 1000:
        distance_text = f"{distance / 1000:.1f} km"
    else:
        distance_text = f"{round(distance / 10) * 10} m"

    # One unconfirmed report is often a false alarm (see hazards.py), and
    # says so; it's pushed again once confirmed, replacing this one.
    confirmed = alert.get("confirmed", True)
    return {
        "notification": messaging.Notification(
            title=f"{label} ahead" if confirmed else f"Possible {label.lower()} ahead",
            body=f"Reported {distance_text} from you"
            + ("" if confirmed else " · unconfirmed"),
        ),
        "android": messaging.AndroidConfig(
            # Normal priority gets held back while the phone dozes, which
            # could deliver the alert after the driver has already passed it.
            priority="high",
            notification=messaging.AndroidNotification(
                channel_id=ANDROID_CHANNEL_ID,
                # One notification per hazard: a repeat push for the same
                # detection replaces the earlier one instead of stacking.
                tag=str(alert["id"]),
            ),
        ),
    }
