"""MySQL access layer for HeatGuard."""

from __future__ import annotations

import json
import logging
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Any, Iterator

import pymysql
from pymysql.cursors import DictCursor

import config

logger = logging.getLogger(__name__)


class DatabaseError(RuntimeError):
    """Raised when a database operation cannot be completed."""


def _connect():
    try:
        return pymysql.connect(
            host=config.DB_CONFIG["host"],
            port=config.DB_CONFIG["port"],
            user=config.DB_CONFIG["user"],
            password=config.DB_CONFIG["password"],
            database=config.DB_CONFIG["database"],
            charset=config.DB_CONFIG["charset"],
            cursorclass=DictCursor,
            autocommit=False,
        )
    except pymysql.MySQLError as exc:
        raise DatabaseError(f"Cannot connect to MySQL: {exc}") from exc


@contextmanager
def connection() -> Iterator[Any]:
    conn = _connect()
    try:
        yield conn
    except Exception:
        conn.rollback()
        raise
    else:
        conn.commit()
    finally:
        conn.close()


def _as_dict(row: dict | None) -> dict | None:
    if row is None:
        return None
    return dict(row)


def check_connection() -> bool:
    try:
        with connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1 AS ok")
                return bool(cur.fetchone())
    except (DatabaseError, pymysql.MySQLError):
        logger.exception("Database health check failed")
        return False


def get_locations(active_only: bool = True) -> list[dict]:
    sql = (
        "SELECT id, name, latitude, longitude, timezone, is_active "
        "FROM locations"
    )
    params: tuple[Any, ...] = ()
    if active_only:
        sql += " WHERE is_active = 1"
    sql += " ORDER BY id"
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()
    for row in rows:
        row["latitude"] = float(row["latitude"])
        row["longitude"] = float(row["longitude"])
    return rows


def get_location(location_id: int) -> dict | None:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, name, latitude, longitude, timezone, is_active "
                "FROM locations WHERE id = %s",
                (location_id,),
            )
            row = cur.fetchone()
    if row:
        row["latitude"] = float(row["latitude"])
        row["longitude"] = float(row["longitude"])
    return _as_dict(row)


def count_active_locations() -> int:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS total FROM locations WHERE is_active = 1")
            row = cur.fetchone()
    return int(row["total"]) if row else 0


def create_location(
    *,
    name: str,
    latitude: float,
    longitude: float,
    timezone: str = "Asia/Manila",
) -> dict:
    """Add a user-provided monitoring location.

    Locations are keyed by name, so adding an existing name updates its
    coordinates and reactivates it instead of creating a duplicate.
    """

    clean_name = (name or "").strip()[:120]
    if not clean_name:
        raise ValueError("A location name is required")
    try:
        lat = float(latitude)
        lon = float(longitude)
    except (TypeError, ValueError) as exc:
        raise ValueError("Latitude and longitude must be numeric") from exc
    if not -90.0 <= lat <= 90.0 or not -180.0 <= lon <= 180.0:
        raise ValueError("Latitude or longitude is outside the valid range")
    clean_timezone = (timezone or "Asia/Manila").strip()[:64] or "Asia/Manila"

    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO locations "
                "(name, latitude, longitude, timezone, is_active) "
                "VALUES (%s, %s, %s, %s, 1) "
                "ON DUPLICATE KEY UPDATE "
                "latitude = VALUES(latitude), "
                "longitude = VALUES(longitude), "
                "timezone = VALUES(timezone), "
                "is_active = 1",
                (clean_name, lat, lon, clean_timezone),
            )
            cur.execute(
                "SELECT id, name, latitude, longitude, timezone, is_active "
                "FROM locations WHERE name = %s",
                (clean_name,),
            )
            row = cur.fetchone()
    result = _as_dict(row) or {}
    if result:
        result["latitude"] = float(result["latitude"])
        result["longitude"] = float(result["longitude"])
    return result


def deactivate_location(location_id: int) -> bool:
    """Soft-delete a location so its history is preserved."""

    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE locations SET is_active = 0 WHERE id = %s",
                (location_id,),
            )
            changed = cur.rowcount
    return bool(changed)


def save_mobile_push_subscription(
    *,
    endpoint_hash: str,
    endpoint: str,
    p256dh: str,
    auth: str,
    location_id: int,
    notify_time: str,
    timezone_name: str,
) -> None:
    """Create or update one browser/device's daily notification settings."""

    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO mobile_push_subscriptions "
                "(endpoint_hash, endpoint, p256dh, auth, location_id, "
                "notify_time, timezone, created_at, updated_at) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, UTC_TIMESTAMP(), "
                "UTC_TIMESTAMP()) "
                "ON DUPLICATE KEY UPDATE "
                "last_sent_date = CASE WHEN location_id <> VALUES(location_id) "
                "OR notify_time <> VALUES(notify_time) "
                "OR timezone <> VALUES(timezone) THEN NULL ELSE last_sent_date END, "
                "last_attempt_at = CASE WHEN location_id <> VALUES(location_id) "
                "OR notify_time <> VALUES(notify_time) "
                "OR timezone <> VALUES(timezone) THEN NULL ELSE last_attempt_at END, "
                "endpoint = VALUES(endpoint), p256dh = VALUES(p256dh), "
                "auth = VALUES(auth), location_id = VALUES(location_id), "
                "notify_time = VALUES(notify_time), timezone = VALUES(timezone), "
                "updated_at = UTC_TIMESTAMP()",
                (
                    endpoint_hash,
                    endpoint,
                    p256dh,
                    auth,
                    location_id,
                    notify_time,
                    timezone_name,
                ),
            )


def get_mobile_push_subscriptions() -> list[dict]:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, endpoint_hash, endpoint, p256dh, auth, location_id, "
                "TIME_FORMAT(notify_time, '%H:%i:%s') AS notify_time, "
                "timezone, last_sent_date, last_attempt_at "
                "FROM mobile_push_subscriptions ORDER BY id"
            )
            rows = cur.fetchall()
    return [dict(row) for row in rows]


def claim_mobile_push_attempt(
    subscription_id: int, local_date, attempted_at: datetime
) -> bool:
    """Claim a due delivery and throttle retries after a failed push."""

    retry_before = attempted_at.replace(microsecond=0) - timedelta(minutes=15)
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE mobile_push_subscriptions SET last_attempt_at = %s "
                "WHERE id = %s AND (last_sent_date IS NULL OR last_sent_date < %s) "
                "AND (last_attempt_at IS NULL OR last_attempt_at <= %s)",
                (attempted_at.replace(microsecond=0), subscription_id,
                 local_date, retry_before),
            )
            return cur.rowcount == 1


def mark_mobile_push_sent(subscription_id: int, local_date) -> None:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE mobile_push_subscriptions SET last_sent_date = %s, "
                "updated_at = UTC_TIMESTAMP() WHERE id = %s",
                (local_date, subscription_id),
            )


def delete_mobile_push_subscription(endpoint_hash: str) -> bool:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "DELETE FROM mobile_push_subscriptions WHERE endpoint_hash = %s",
                (endpoint_hash,),
            )
            return cur.rowcount > 0


def get_latest_reading(location_id: int) -> dict | None:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT r.*, l.name AS location_name "
                "FROM readings r "
                "JOIN locations l ON l.id = r.location_id "
                "WHERE r.location_id = %s "
                "ORDER BY r.observed_at DESC, r.id DESC LIMIT 1",
                (location_id,),
            )
            row = cur.fetchone()
    return _as_dict(row)


def get_readings_since(location_id: int, since_utc: datetime) -> list[dict]:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, observed_at, fetched_at, temperature_c, "
                "humidity_pct, heat_index_c, risk_key, risk_label, source "
                "FROM readings "
                "WHERE location_id = %s AND observed_at >= %s "
                "ORDER BY observed_at ASC",
                (location_id, since_utc),
            )
            rows = cur.fetchall()
    return [dict(row) for row in rows]


def get_recent_alerts(location_id: int, limit: int = 20) -> list[dict]:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, location_id, reading_id, risk_key, risk_label, "
                "temperature_c, humidity_pct, heat_index_c, observed_at, "
                "generated_at, message, recommendations "
                "FROM alerts WHERE location_id = %s "
                "ORDER BY generated_at DESC, id DESC LIMIT %s",
                (location_id, limit),
            )
            rows = cur.fetchall()
    result: list[dict] = []
    for row in rows:
        item = dict(row)
        raw = item.get("recommendations")
        if isinstance(raw, str):
            try:
                item["recommendations"] = json.loads(raw)
            except json.JSONDecodeError:
                item["recommendations"] = []
        elif raw is None:
            item["recommendations"] = []
        result.append(item)
    return result


def get_latest_alert_for_risk(
    location_id: int, risk_key: str
) -> dict | None:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, risk_key, risk_label, temperature_c, humidity_pct, "
                "heat_index_c, observed_at, generated_at, message, "
                "recommendations "
                "FROM alerts WHERE location_id = %s AND risk_key = %s "
                "ORDER BY generated_at DESC, id DESC LIMIT 1",
                (location_id, risk_key),
            )
            row = cur.fetchone()
    if row is None:
        return None
    item = dict(row)
    raw = item.get("recommendations")
    if isinstance(raw, str):
        try:
            item["recommendations"] = json.loads(raw)
        except json.JSONDecodeError:
            item["recommendations"] = []
    return item


def get_monitoring_status(location_id: int) -> dict | None:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM monitoring_status WHERE location_id = %s",
                (location_id,),
            )
            row = cur.fetchone()
    return _as_dict(row)


def record_reading_and_alert(
    *,
    location: dict,
    observed_at: datetime,
    fetched_at: datetime,
    temperature_c: float,
    humidity_pct: float,
    heat_index_c: float,
    risk: dict,
    source: str,
    api_timezone: str | None,
    raw_payload: dict | None,
) -> dict:
    """Store a reading and create an alert only when the category changes.

    The latest reading is locked while the new observation is written. An
    alert is created when the risk category changes into a warning category
    (Caution or higher) or when the first observed category is already a
    warning. Repeated refreshes of an unchanged category therefore do not
    create duplicate alerts.
    """
    location_id = int(location["id"])
    # MySQL DATETIME columns in this schema store whole seconds. Normalising
    # here also makes the follow-up SELECT match the inserted row.
    observed_at = observed_at.replace(microsecond=0)
    fetched_at = fetched_at.replace(microsecond=0)
    alert_created = False
    reading_id: int | None = None
    previous_risk_key: str | None = None

    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, risk_key, observed_at FROM readings "
                "WHERE location_id = %s "
                "ORDER BY observed_at DESC, id DESC LIMIT 1 FOR UPDATE",
                (location_id,),
            )
            previous = cur.fetchone()
            if previous:
                previous_risk_key = previous["risk_key"]

            payload_json = (
                json.dumps(raw_payload, ensure_ascii=True, default=str)
                if raw_payload is not None
                else None
            )
            cur.execute(
                "INSERT INTO readings "
                "(location_id, observed_at, fetched_at, temperature_c, "
                "humidity_pct, heat_index_c, risk_key, risk_label, source, "
                "api_timezone, raw_payload) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                "ON DUPLICATE KEY UPDATE "
                "fetched_at = VALUES(fetched_at), "
                "temperature_c = VALUES(temperature_c), "
                "humidity_pct = VALUES(humidity_pct), "
                "heat_index_c = VALUES(heat_index_c), "
                "risk_key = VALUES(risk_key), "
                "risk_label = VALUES(risk_label), "
                "source = VALUES(source), "
                "api_timezone = VALUES(api_timezone), "
                "raw_payload = VALUES(raw_payload)",
                (
                    location_id,
                    observed_at,
                    fetched_at,
                    temperature_c,
                    humidity_pct,
                    heat_index_c,
                    risk["key"],
                    risk["label"],
                    source,
                    api_timezone,
                    payload_json,
                ),
            )

            cur.execute(
                "SELECT id FROM readings WHERE location_id = %s "
                "AND observed_at = %s",
                (location_id, observed_at),
            )
            row = cur.fetchone()
            reading_id = (
                int(row["id"])
                if row
                else int(cur.lastrowid) if cur.lastrowid else None
            )

            category_changed = previous_risk_key != risk["key"]
            should_alert = (
                category_changed
                and int(risk["level"]) >= 1
                and reading_id is not None
            )

            if should_alert:
                message = (
                    f"{risk['label']} heat index of {heat_index_c:.1f} C "
                    f"in {location['name']}."
                )
                cur.execute(
                    "INSERT IGNORE INTO alerts "
                    "(location_id, reading_id, risk_key, risk_label, "
                    "temperature_c, humidity_pct, heat_index_c, observed_at, "
                    "generated_at, message, recommendations) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                    (
                        location_id,
                        reading_id,
                        risk["key"],
                        risk["label"],
                        temperature_c,
                        humidity_pct,
                        heat_index_c,
                        observed_at,
                        datetime.now(timezone.utc).replace(tzinfo=None),
                        message,
                        json.dumps(
                            risk.get("recommendations", []), ensure_ascii=True
                        ),
                    ),
                )
                alert_created = cur.rowcount == 1

    return {
        "reading_id": reading_id,
        "alert_created": alert_created,
        "previous_risk_key": previous_risk_key,
    }


def insert_historical_readings(location_id: int, rows: list[dict]) -> int:
    """Insert backfilled history without generating alert events."""

    if not rows:
        return 0
    values = [
        (
            location_id,
            row["observed_at"],
            row["fetched_at"],
            row["temperature_c"],
            row["humidity_pct"],
            row["heat_index_c"],
            row["risk_key"],
            row["risk_label"],
            row.get("source", "open-meteo-historical"),
            row.get("api_timezone"),
            None,
        )
        for row in rows
    ]
    with connection() as conn:
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT IGNORE INTO readings "
                "(location_id, observed_at, fetched_at, temperature_c, "
                "humidity_pct, heat_index_c, risk_key, risk_label, source, "
                "api_timezone, raw_payload) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                values,
            )
            inserted = cur.rowcount
    return int(inserted or 0)


def mark_monitoring_attempt(location_id: int, attempted_at: datetime) -> None:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO monitoring_status "
                "(location_id, last_attempt_at, updated_at) "
                "VALUES (%s, %s, %s) "
                "ON DUPLICATE KEY UPDATE "
                "last_attempt_at = VALUES(last_attempt_at), "
                "updated_at = VALUES(updated_at)",
                (location_id, attempted_at, attempted_at),
            )


def mark_monitoring_success(
    location_id: int, observed_at: datetime, succeeded_at: datetime
) -> None:
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO monitoring_status "
                "(location_id, last_attempt_at, last_success_at, "
                "last_observed_at, last_error_message, consecutive_failures, "
                "updated_at) "
                "VALUES (%s, %s, %s, %s, NULL, 0, %s) "
                "ON DUPLICATE KEY UPDATE "
                "last_attempt_at = VALUES(last_attempt_at), "
                "last_success_at = VALUES(last_success_at), "
                "last_observed_at = VALUES(last_observed_at), "
                "last_error_message = NULL, "
                "consecutive_failures = 0, "
                "updated_at = VALUES(updated_at)",
                (location_id, succeeded_at, succeeded_at, observed_at,
                 succeeded_at),
            )


def mark_monitoring_error(
    location_id: int, failed_at: datetime, message: str
) -> None:
    message = (message or "Unknown monitoring error")[:2000]
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO monitoring_status "
                "(location_id, last_attempt_at, last_error_at, "
                "last_error_message, consecutive_failures, updated_at) "
                "VALUES (%s, %s, %s, %s, 1, %s) "
                "ON DUPLICATE KEY UPDATE "
                "last_attempt_at = VALUES(last_attempt_at), "
                "last_error_at = VALUES(last_error_at), "
                "last_error_message = VALUES(last_error_message), "
                "consecutive_failures = consecutive_failures + 1, "
                "updated_at = VALUES(updated_at)",
                (location_id, failed_at, failed_at, message, failed_at),
            )
