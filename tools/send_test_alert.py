"""Sends a test obstruction alert to one phone, standing in for the server.

The real server will do exactly this when it finds cars near a reported
obstruction, so this doubles as reference code for that push logic.

Setup (once):
    1. Firebase console -> Project settings -> Service accounts
    2. "Generate new private key" -> save as tools/serviceAccountKey.json
       (gitignored: unlike google-services.json this is a real credential and
       must never be committed)

Usage:
    python tools/send_test_alert.py <fcm-token>
    python tools/send_test_alert.py <fcm-token> --type debris --distance 120
"""

from __future__ import annotations

import argparse
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import firebase_admin
from firebase_admin import credentials, messaging

KEY_PATH = Path(__file__).parent / "serviceAccountKey.json"


def send_alert(token: str, obstruction: str, distance_m: float, lat: float, lng: float) -> str:
    if not KEY_PATH.exists():
        sys.exit(
            f"Missing {KEY_PATH}.\n"
            "Firebase console -> Project settings -> Service accounts -> "
            "Generate new private key, and save it there."
        )

    firebase_admin.initialize_app(credentials.Certificate(str(KEY_PATH)))

    # Data-only: every value must be a string, which is why AlertEvent.fromJson
    # on the app side parses numbers leniently rather than casting them.
    message = messaging.Message(
        token=token,
        data={
            "id": str(uuid.uuid4()),
            "type": obstruction,
            "lat": str(lat),
            "lng": str(lng),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "distance_m": str(distance_m),
        },
        android=messaging.AndroidConfig(
            # Obstruction warnings are time-critical: normal priority lets
            # Android defer delivery while the device is dozing.
            priority="high",
        ),
        apns=messaging.APNSConfig(
            # Data-only messages on iOS need this flag or they are not
            # delivered to a backgrounded app at all.
            headers={"apns-priority": "10"},
            payload=messaging.APNSPayload(
                aps=messaging.Aps(content_available=True),
            ),
        ),
    )

    return messaging.send(message)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("token", help="FCM token, copied from the app's Alerts screen")
    parser.add_argument("--type", default="pothole", help="obstruction class")
    parser.add_argument("--distance", type=float, default=340, help="metres ahead")
    parser.add_argument("--lat", type=float, default=19.0760)
    parser.add_argument("--lng", type=float, default=72.8777)
    args = parser.parse_args()

    message_id = send_alert(args.token, args.type, args.distance, args.lat, args.lng)
    print(f"Sent: {message_id}")
    print(f"Expect a banner reading '{args.distance:.0f} m ahead / {args.type.upper()}'")


if __name__ == "__main__":
    main()
