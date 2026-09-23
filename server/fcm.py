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

    Data-only (no `notification` field): the app shows its own banner, not a
    system notification, and parses `message.data` into a typed AlertEvent —
    see NotificationService._emit.
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
            "distance_m": str(alert["distance_m"]),
        },
    )
    try:
        messaging.send(message)
        return True
    except Exception as error:  # noqa: BLE001 - one bad token must not break the batch
        logger.warning("Push to %s failed: %s", token, error)
        return False
