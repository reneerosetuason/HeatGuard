"""FCM HTTP v1 delivery using private server-side service-account credentials."""
import logging
from pathlib import Path
import threading

import requests

import config

logger = logging.getLogger(__name__)
_credentials = None
_lock = threading.Lock()


def configured():
    return bool(config.FIREBASE_PROJECT_ID and config.GOOGLE_APPLICATION_CREDENTIALS and Path(config.GOOGLE_APPLICATION_CREDENTIALS).is_file())


def access_token():
    global _credentials
    from google.oauth2 import service_account
    from google.auth.transport.requests import Request
    with _lock:
        if _credentials is None:
            _credentials = service_account.Credentials.from_service_account_file(
                config.GOOGLE_APPLICATION_CREDENTIALS, scopes=["https://www.googleapis.com/auth/firebase.messaging"])
            if _credentials.project_id != config.FIREBASE_PROJECT_ID:
                _credentials = None
                raise ValueError("Firebase project mismatch")
        if not _credentials.valid:
            transport = Request()
            def bounded_request(*args, **kwargs):
                kwargs["timeout"] = 10
                return transport(*args, **kwargs)
            _credentials.refresh(bounded_request)
        return _credentials.token


def send(row, now):
    if not configured():
        return "retry"
    remaining = max(0, int((row["event_at"]-now).total_seconds())+300)
    if remaining == 0:
        return "failed"
    try:
        token = access_token()
        response = requests.post(f"https://fcm.googleapis.com/v1/projects/{config.FIREBASE_PROJECT_ID}/messages:send",
            headers={"Authorization": "Bearer " + token}, timeout=10, json={"message": {
                "token": row["token"], "notification": {"title": row["title"], "body": row["body"]},
                "data": {"type": "routine_reminder", "notification_id": str(row["id"]), "routine_id": str(row["routine_id"]), "account_id": str(row["user_id"])},
                "android": {"priority": "high", "ttl": f"{remaining}s", "notification": {
                    "channel_id": "heatguard_routines", "tag": f"heatguard-routine-{row['id']}",
                    "icon": "ic_stat_heatguard"}},
            }})
        if response.ok:
            return "sent"
        try:
            details = response.json().get("error", {}).get("details", [])
            if any(detail.get("errorCode") == "UNREGISTERED" for detail in details):
                return "unregistered"
        except (ValueError, AttributeError, TypeError):
            pass
        logger.warning("Routine push rejected (HTTP %s)", response.status_code)
        return "failed" if response.status_code == 400 else "retry"
    except Exception as error:
        # Credential paths, tokens, provider response bodies and private keys are never logged.
        logger.warning("Routine push unavailable (%s)", type(error).__name__)
        return "retry"
