"""Daily Web Push delivery for the installable HeatGuard app."""

from __future__ import annotations

import hashlib
import json
import logging
from datetime import date, datetime, time, timezone
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import config
from services import dashboard as dashboard_service
from services import db
from services.monitoring import monitor_location

logger = logging.getLogger(__name__)


def push_configured() -> bool:
    private_key = config.VAPID_PRIVATE_KEY or config.VAPID_PRIVATE_KEY_PATH
    return bool(
        config.VAPID_PUBLIC_KEY
        and private_key
        and config.VAPID_CLAIMS_EMAIL
    )


def endpoint_hash(endpoint: str) -> str:
    return hashlib.sha256(endpoint.encode("utf-8")).hexdigest()


def valid_push_endpoint(endpoint: str) -> bool:
    """Accept HTTPS endpoints from the major browser push services only."""

    if not isinstance(endpoint, str) or len(endpoint) > 4096:
        return False
    try:
        parsed = urlsplit(endpoint)
        host = (parsed.hostname or "").lower().rstrip(".")
        port = parsed.port
    except ValueError:
        return False
    if parsed.scheme != "https" or not host or parsed.username or parsed.password:
        return False
    if port not in (None, 443):
        return False
    return (
        host == "fcm.googleapis.com"
        or host == "web.push.apple.com"
        or host.endswith(".push.apple.com")
        or host == "push.services.mozilla.com"
        or host.endswith(".push.services.mozilla.com")
        or host.endswith(".notify.windows.com")
    )


def _private_key() -> str:
    return config.VAPID_PRIVATE_KEY_PATH or config.VAPID_PRIVATE_KEY


def _display_payload(dashboard: dict) -> dict:
    location = dashboard["location"]
    current = dashboard.get("current")
    if dashboard.get("data_status") != "ok" or not current:
        title = f"Daily weather · {location['name']}"
        body = (
            "Current heat conditions are unavailable. Check official weather "
            "advisories and do not assume conditions are safe."
        )
    else:
        risk = current["risk"]
        recommendations = dashboard.get("recommendations") or []
        recommendation = recommendations[0] if recommendations else "Stay hydrated."
        recommendation = str(recommendation).strip()
        if len(recommendation) > 130:
            recommendation = recommendation[:127].rstrip() + "..."
        title = f"Daily weather · {location['name']}"
        body = (
            f"{current['temperature_c']:.1f}°C, heat index "
            f"{current['heat_index_c']:.1f}°C ({risk['label']}). "
            f"{recommendation}"
        )

    return {
        "title": title,
        "body": body,
        "tag": "heatguard-daily",
        "url": f"/mobile/?location={int(location['id'])}",
        "location": location["name"],
    }


def _send(subscription: dict, payload: dict) -> bool:
    from pywebpush import WebPushException, webpush

    info = {
        "endpoint": subscription["endpoint"],
        "keys": {
            "p256dh": subscription["p256dh"],
            "auth": subscription["auth"],
        },
    }
    try:
        webpush(
            subscription_info=info,
            data=json.dumps(payload, ensure_ascii=False),
            vapid_private_key=_private_key(),
            vapid_claims={"sub": f"mailto:{config.VAPID_CLAIMS_EMAIL}"},
            ttl=86400,
        )
        return True
    except WebPushException as exc:
        response = getattr(exc, "response", None)
        status = getattr(response, "status_code", None)
        if status in {404, 410}:
            db.delete_mobile_push_subscription(subscription["endpoint_hash"])
            logger.info("Removed expired mobile push subscription %s", subscription["id"])
        else:
            logger.warning(
                "Mobile push failed for subscription %s (status %s): %s",
                subscription["id"],
                status,
                exc,
            )
        return False


def run_due_notifications(now_utc: datetime | None = None) -> int:
    """Send due daily notifications and return the number successfully sent."""

    if not push_configured():
        return 0

    now_utc = now_utc or datetime.now(timezone.utc)
    if now_utc.tzinfo is None:
        now_utc = now_utc.replace(tzinfo=timezone.utc)
    subscriptions = db.get_mobile_push_subscriptions()
    delivered = 0
    dashboards: dict[int, dict] = {}

    for subscription in subscriptions:
        try:
            local_now = now_utc.astimezone(ZoneInfo(subscription["timezone"]))
        except (ZoneInfoNotFoundError, ValueError, TypeError):
            logger.warning(
                "Skipping subscription %s with invalid timezone",
                subscription["id"],
            )
            continue

        notify_time = subscription["notify_time"]
        if isinstance(notify_time, str):
            try:
                notify_time = time.fromisoformat(notify_time)
            except ValueError:
                continue
        if local_now.time().replace(tzinfo=None) < notify_time:
            continue

        local_date: date = local_now.date()
        if subscription.get("last_sent_date") == local_date:
            continue
        attempted_at = now_utc.astimezone(timezone.utc).replace(tzinfo=None)
        try:
            claimed = db.claim_mobile_push_attempt(
                int(subscription["id"]), local_date, attempted_at
            )
        except db.DatabaseError:
            logger.exception("Could not claim mobile push delivery")
            continue
        if not claimed:
            continue

        location_id = int(subscription["location_id"])
        if location_id not in dashboards:
            try:
                location = db.get_location(location_id)
                if not location or not location.get("is_active"):
                    db.delete_mobile_push_subscription(
                        subscription["endpoint_hash"]
                    )
                    continue
                # Fetch fresh conditions at delivery time. If the weather
                # provider is unavailable, the dashboard marks old data stale.
                monitor_location(location)
                dashboards[location_id] = dashboard_service.build_dashboard(
                    location_id=location_id
                )
            except Exception:
                logger.exception(
                    "Could not prepare daily weather for location %s",
                    location_id,
                )
                continue

        payload = _display_payload(dashboards[location_id])
        try:
            sent = _send(subscription, payload)
        except Exception:
            logger.exception(
                "Unexpected mobile push error for subscription %s",
                subscription["id"],
            )
            continue
        if not sent:
            continue

        try:
            db.mark_mobile_push_sent(int(subscription["id"]), local_date)
        except db.DatabaseError:
            logger.exception("Could not record successful mobile push")
            continue
        delivered += 1

    return delivered
