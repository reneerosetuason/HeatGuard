"""Presentation helpers for the dashboard and JSON API."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import config
from services import db, risk as risk_service

UTC = timezone.utc


def _naive_utc(value: datetime | str | None) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _iso_utc(value: datetime | str | None) -> str | None:
    parsed = _naive_utc(value)
    return parsed.isoformat().replace("+00:00", "Z") if parsed else None


def _local_time(value: datetime | str | None, timezone_name: str) -> datetime:
    parsed = _naive_utc(value) or datetime.now(UTC)
    try:
        zone = ZoneInfo(timezone_name or "UTC")
    except (ZoneInfoNotFoundError, ValueError):
        zone = UTC
    return parsed.astimezone(zone)


def _format_local(
    value: datetime | str | None,
    timezone_name: str,
    *,
    include_date: bool = True,
) -> str:
    local = _local_time(value, timezone_name)
    if include_date:
        return local.strftime("%b %d, %Y %I:%M %p").replace(" 0", " ")
    return local.strftime("%I:%M %p").lstrip("0")


def _as_float(value) -> float | None:
    if value is None:
        return None
    try:
        return round(float(value), 1)
    except (TypeError, ValueError):
        return None


def _weather_scene(latest: dict, timezone_name: str, now: datetime, *, stale: bool) -> str:
    """Choose only the dashboard artwork; never infer rain from heat or humidity."""
    is_day = 6 <= _local_time(now, timezone_name).hour < 18
    if not stale:
        payload = latest.get("raw_payload")
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except (ValueError, TypeError):
                payload = None
        current = payload.get("current") if isinstance(payload, dict) else None
        if isinstance(current, dict):
            if current.get("is_day") in (0, 1):
                is_day = bool(current["is_day"])
            code = current.get("weather_code")
            precipitation = current.get("precipitation")
            rain_codes = {51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99}
            if isinstance(code, (int, float)) and code in rain_codes:
                return "rain"
            if isinstance(precipitation, (int, float)) and not isinstance(precipitation, bool) and 0 < precipitation <= 1000:
                return "rain"
    return "sun" if is_day else "moon"


def _risk_payload(category: dict | None, *, last_known: bool = False) -> dict | None:
    if category is None:
        return None
    return {
        "key": category["key"],
        "label": category["label"],
        "short_label": category["short_label"],
        "level": category["level"],
        "color": category["color"],
        "text_color": category["text_color"],
        "icon": category["icon"],
        "summary": category["summary"],
        "recommendations": list(category.get("recommendations", [])),
        "last_known": last_known,
    }


def resolve_location(location_id: int | str | None = None) -> dict:
    locations = db.get_locations(active_only=True)
    if not locations:
        raise LookupError("No active monitoring locations are configured")
    if location_id is None:
        return locations[0]
    try:
        wanted = int(location_id)
    except (TypeError, ValueError):
        return locations[0]
    for location in locations:
        if int(location["id"]) == wanted:
            return location
    return locations[0]


def get_locations() -> list[dict]:
    return db.get_locations(active_only=True)


def _serialize_alert(alert: dict | None, timezone_name: str) -> dict | None:
    if alert is None:
        return None
    return {
        "id": int(alert["id"]),
        "risk_key": alert["risk_key"],
        "risk_label": alert["risk_label"],
        "temperature_c": _as_float(alert.get("temperature_c")),
        "humidity_pct": _as_float(alert.get("humidity_pct")),
        "heat_index_c": _as_float(alert.get("heat_index_c")),
        "observed_at": _iso_utc(alert.get("observed_at")),
        "observed_at_display": _format_local(
            alert.get("observed_at"), timezone_name
        ),
        "generated_at": _iso_utc(alert.get("generated_at")),
        "generated_at_display": _format_local(
            alert.get("generated_at"), timezone_name
        ),
        "message": alert.get("message", ""),
        "recommendations": alert.get("recommendations") or [],
    }


def _downsample(points: list[dict], max_points: int = 600) -> list[dict]:
    if len(points) <= max_points:
        return points
    bucket_size = (len(points) + max_points - 1) // max_points
    reduced: list[dict] = []
    for start in range(0, len(points), bucket_size):
        bucket = points[start : start + bucket_size]
        latest = bucket[-1]
        reduced.append(
            {
                "observed_at": latest["observed_at"],
                "label": latest.get("label"),
                "temperature_c": round(
                    sum(p["temperature_c"] for p in bucket) / len(bucket), 1
                ),
                "humidity_pct": round(
                    sum(p["humidity_pct"] for p in bucket) / len(bucket), 1
                ),
                "heat_index_c": round(
                    sum(p["heat_index_c"] for p in bucket) / len(bucket), 1
                ),
                "risk_key": latest["risk_key"],
                "max_risk_key": max(
                    (p["risk_key"] for p in bucket),
                    key=lambda key: (risk_service.get_category(key) or {"level": -1})[
                        "level"
                    ],
                ),
            }
        )
    return reduced


def _history_payload(location_id: int, timezone_name: str, hours: int) -> dict:
    now = datetime.now(UTC)
    since = now - timedelta(hours=hours)
    rows = db.get_readings_since(location_id, since.replace(tzinfo=None))

    points: list[dict] = []
    for row in rows:
        category = risk_service.get_category(row["risk_key"])
        points.append(
            {
                "observed_at": _iso_utc(row["observed_at"]),
                "label": _format_local(
                    row["observed_at"],
                    timezone_name,
                    include_date=hours > 24,
                ),
                "temperature_c": _as_float(row["temperature_c"]),
                "humidity_pct": _as_float(row["humidity_pct"]),
                "heat_index_c": _as_float(row["heat_index_c"]),
                "risk_key": row["risk_key"],
                "risk_label": row["risk_label"],
                "risk_level": category["level"] if category else None,
            }
        )

    points = _downsample(points)
    for point in points:
        max_key = point.pop("max_risk_key", None)
        key = max_key or point["risk_key"]
        point["risk_key"] = key
        category = risk_service.get_category(key)
        point["risk_level"] = category["level"] if category else None
        point["risk_label"] = category["label"] if category else key

    return {
        "hours": hours,
        "points": points,
        "count": len(points),
        "since": _iso_utc(since),
        "until": _iso_utc(now),
    }


def build_dashboard(
    location_id: int | str | None = None, hours: int | None = None,
    *, scoped_locations: list[dict] | None = None
) -> dict:
    locations = get_locations() if scoped_locations is None else scoped_locations
    if not locations:
        raise LookupError("No active monitoring locations are configured")

    location = resolve_location(location_id) if scoped_locations is None else next(
        (item for item in locations if str(item["id"]) == str(location_id)), locations[0])
    selected_id = int(location["id"])
    timezone_name = location.get("timezone") or "Asia/Manila"
    now = datetime.now(UTC)

    requested_hours = int(hours or config.HISTORY_DEFAULT_HOURS)
    requested_hours = max(1, min(requested_hours, config.HISTORY_MAX_HOURS))

    latest = db.get_latest_reading(selected_id)
    status = db.get_monitoring_status(selected_id) or {}
    alerts = db.get_recent_alerts(selected_id, config.ALERT_HISTORY_LIMIT)
    history = _history_payload(selected_id, timezone_name, requested_hours)

    last_success = status.get("last_success_at")
    last_attempt = status.get("last_attempt_at")
    last_error_at = status.get("last_error_at")
    last_error_message = status.get("last_error_message")

    current_payload = None
    effective_risk = None
    data_status = "no_data"
    age_seconds = None
    observed_at = None

    if latest:
        observed_at = _naive_utc(latest["observed_at"])
        age_seconds = max(0, int((now - observed_at).total_seconds()))
        is_stale = age_seconds > config.STALE_AFTER_SECONDS
        data_status = "stale" if is_stale else "ok"

        stored_risk = risk_service.get_category(latest["risk_key"])
        if stored_risk is None:
            stored_risk = risk_service.classify_heat_index(
                float(latest["heat_index_c"])
            )

        current_payload = {
            "observed_at": _iso_utc(latest["observed_at"]),
            "observed_at_display": _format_local(
                latest["observed_at"], timezone_name
            ),
            "fetched_at": _iso_utc(latest["fetched_at"]),
            "fetched_at_display": _format_local(
                latest["fetched_at"], timezone_name
            ),
            "temperature_c": _as_float(latest["temperature_c"]),
            "humidity_pct": _as_float(latest["humidity_pct"]),
            "heat_index_c": _as_float(latest["heat_index_c"]),
            "risk": _risk_payload(stored_risk, last_known=is_stale),
            "source": latest.get("source") or "open-meteo",
            "is_stale": is_stale,
            "weather_scene": _weather_scene(latest, timezone_name, now, stale=is_stale),
        }
        if not is_stale:
            effective_risk = stored_risk

    active_alert = None
    if data_status == "ok" and effective_risk and effective_risk["level"] >= 1:
        alert = db.get_latest_alert_for_risk(selected_id, effective_risk["key"])
        if alert:
            active_alert = _serialize_alert(alert, timezone_name)
        else:
            active_alert = {
                "id": None if latest is None else int(latest["id"]),
                "risk_key": effective_risk["key"],
                "risk_label": effective_risk["label"],
                "temperature_c": current_payload["temperature_c"],
                "humidity_pct": current_payload["humidity_pct"],
                "heat_index_c": current_payload["heat_index_c"],
                "observed_at": current_payload["observed_at"],
                "observed_at_display": current_payload["observed_at_display"],
                "generated_at": current_payload["fetched_at"],
                "generated_at_display": current_payload["fetched_at_display"],
                "message": (
                    f"{effective_risk['label']} heat index of "
                    f"{current_payload['heat_index_c']:.1f} C in "
                    f"{location['name']}."
                ),
                "recommendations": effective_risk["recommendations"],
            }

    if effective_risk is not None:
        recommendations = list(effective_risk.get("recommendations", []))
    else:
        recommendations = list(config.UNKNOWN_RECOMMENDATIONS)

    if last_error_at and last_error_message:
        api_error = {
            "message": last_error_message,
            "at": _iso_utc(last_error_at),
            "at_display": _format_local(last_error_at, timezone_name),
            "is_after_last_success": (
                _naive_utc(last_error_at) is not None
                and _naive_utc(last_success) is not None
                and _naive_utc(last_error_at) > _naive_utc(last_success)
            ),
        }
    else:
        api_error = None

    if data_status == "ok":
        status_message = "Weather data is current."
    elif data_status == "stale":
        status_message = (
            "The latest reading is older than "
            f"{config.STALE_AFTER_SECONDS // 60} minutes. It is shown as "
            "historical data only; current conditions are unknown."
        )
    else:
        status_message = (
            "No validated weather reading is available yet. Missing data is "
            "not treated as a safe heat level."
        )

    return {
        "generated_at": _iso_utc(now),
        "generated_at_display": _format_local(now, timezone_name),
        "app_name": config.APP_NAME,
        "location": {
            "id": selected_id,
            "name": location["name"],
            "latitude": location["latitude"],
            "longitude": location["longitude"],
            "timezone": timezone_name,
        },
        "locations": [
            {
                "id": int(item["id"]),
                "name": item["name"],
                "timezone": item.get("timezone"),
            }
            for item in locations
        ],
        "data_status": data_status,
        "status_message": status_message,
        "current": current_payload,
        "active_alert": active_alert,
        "alerts": [_serialize_alert(alert, timezone_name) for alert in alerts],
        "recommendations": recommendations,
        "disclaimer": config.SAFETY_DISCLAIMER,
        "history": history,
        "thresholds": risk_service.public_categories(),
        "risk_source": config.HEAT_INDEX_SOURCE,
        "risk_source_url": config.HEAT_INDEX_SOURCE_URL,
        "heat_index_source": (
            "Calculated from Open-Meteo temperature and relative humidity "
            "using the NWS/NOAA Rothfusz heat-index equation."
        ),
        "last_success_at": _iso_utc(last_success),
        "last_success_at_display": _format_local(last_success, timezone_name),
        "last_attempt_at": _iso_utc(last_attempt),
        "last_attempt_at_display": _format_local(last_attempt, timezone_name),
        "last_error": api_error,
        "data_age_seconds": age_seconds,
        "stale_after_seconds": config.STALE_AFTER_SECONDS,
        "monitor_interval_seconds": config.MONITOR_INTERVAL_SECONDS,
        "monitor_enabled": config.MONITOR_ENABLED,
    }
