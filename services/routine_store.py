"""Account-scoped routines, durable inbox, and leased delivery work."""
from datetime import datetime, time, timedelta, timezone
import hashlib
import json
import re
import secrets
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import config
from services import db
from services.mobile_accounts import AccountError


def utcnow():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def iso(value):
    return value.isoformat(timespec="seconds") + "Z" if value else None


def clock(value):
    if isinstance(value, timedelta):
        seconds = int(value.total_seconds())
        return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}"
    return value.strftime("%H:%M") if isinstance(value, time) else str(value)[:5]


def execute(sql, values=(), *, rows=False, one=False):
    with db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(sql, values)
            if rows:
                return cursor.fetchall()
            if one:
                return cursor.fetchone()
            return cursor.rowcount


def public_routine(row):
    return {**{key: row[key] for key in ["id", "title", "location_id", "timezone", "remind_before_minutes"]},
            "location_name": row["location_name"], "time": clock(row["routine_time"]),
            "weekdays": [int(day) for day in row["weekdays"].split(",")], "enabled": bool(row["enabled"])}


ROUTINE_SELECT = "SELECT r.*, l.name AS location_name, l.latitude, l.longitude, l.is_active FROM mobile_routines r JOIN locations l ON l.id=r.location_id "


def list_routines(user_id):
    return [public_routine(row) for row in execute(ROUTINE_SELECT + "WHERE r.user_id=%s ORDER BY r.routine_time,r.id", (user_id,), rows=True)]


def get_routine(user_id, routine_id):
    row = execute(ROUTINE_SELECT + "WHERE r.id=%s AND r.user_id=%s", (routine_id, user_id), one=True)
    if not row:
        raise AccountError("This routine was not found.", 404)
    return row


def integer(value, minimum, maximum):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)):
        raise AccountError("Enter a valid routine time and location.")
    value = int(value)
    if not minimum <= value <= maximum:
        raise AccountError("The routine settings are outside the supported range.")
    return value


def validate(data):
    title = data.get("title")
    if not isinstance(title, str) or not 1 <= len(title.strip()) <= 80 or any(ord(char) < 32 for char in title):
        raise AccountError("Enter an activity name using 1 to 80 characters.")
    event_time = data.get("time")
    if not isinstance(event_time, str) or not re.fullmatch(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]", event_time):
        raise AccountError("Choose a valid activity time.")
    days = data.get("weekdays")
    if isinstance(days, str):
        days = days.split(",")
    if not isinstance(days, list) or not 1 <= len(days) <= 7:
        raise AccountError("Choose at least one day of the week.")
    days = sorted(set(integer(day, 0, 6) for day in days))
    zone = data.get("timezone")
    try:
        if not isinstance(zone, str) or len(zone) > 64:
            raise ValueError()
        ZoneInfo(zone)
    except (ZoneInfoNotFoundError, ValueError):
        raise AccountError("Choose a valid time zone.") from None
    enabled = data.get("enabled", True)
    if enabled not in (True, False, "true", "false", "1", "0", 0, 1):
        raise AccountError("Choose whether this routine is enabled.")
    return (title.strip(), integer(data.get("location_id"), 1, 2**31-1), event_time,
            ",".join(map(str, days)), zone, integer(data.get("remind_before_minutes", 15), 0, 120),
            enabled in (True, "true", "1", 1))


def save_routine(user_id, data, routine_id=None):
    values = validate(data)
    now = utcnow()
    with db.connection() as connection:
        with connection.cursor() as cursor:
            # Serialize the per-account limit as well as simultaneous creates.
            cursor.execute("SELECT id FROM mobile_users WHERE id=%s FOR UPDATE", (user_id,))
            if not cursor.fetchone():
                raise AccountError("Sign in again.", 401)
            cursor.execute("SELECT id FROM locations WHERE id=%s AND is_active=1", (values[1],))
            if not cursor.fetchone():
                raise AccountError("Select an active monitoring location.")
            if routine_id is None:
                cursor.execute("SELECT COUNT(*) AS total FROM mobile_routines WHERE user_id=%s", (user_id,))
                if cursor.fetchone()["total"] >= config.ROUTINE_LIMIT_PER_USER:
                    raise AccountError(f"You can save up to {config.ROUTINE_LIMIT_PER_USER} routines.")
                cursor.execute("INSERT INTO mobile_routines (title,location_id,routine_time,weekdays,timezone,remind_before_minutes,enabled,user_id,created_at,updated_at) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)", (*values, user_id, now, now))
                routine_id = cursor.lastrowid
            else:
                cursor.execute("UPDATE mobile_routines SET title=%s,location_id=%s,routine_time=%s,weekdays=%s,timezone=%s,remind_before_minutes=%s,enabled=%s,updated_at=%s,revision=revision+1 WHERE id=%s AND user_id=%s", (*values, now, routine_id, user_id))
                if not cursor.rowcount:
                    raise AccountError("This routine was not found.", 404)
                cursor.execute("UPDATE mobile_notification_deliveries SET state='cancelled' WHERE notification_id IN (SELECT id FROM mobile_notifications WHERE routine_id=%s AND user_id=%s) AND state IN ('pending','sending')", (routine_id, user_id))
    return public_routine(get_routine(user_id, routine_id))


def delete_routine(user_id, routine_id):
    if not execute("DELETE FROM mobile_routines WHERE id=%s AND user_id=%s", (routine_id, user_id)):
        raise AccountError("This routine was not found.", 404)


def inbox(user_id):
    rows = execute("SELECT id,routine_id,event_at,title,body,weather_json,ai_generated,read_at,created_at FROM mobile_notifications WHERE user_id=%s AND state='ready' ORDER BY created_at DESC,id DESC LIMIT 100", (user_id,), rows=True)
    unread = execute("SELECT COUNT(*) AS total FROM mobile_notifications WHERE user_id=%s AND state='ready' AND read_at IS NULL", (user_id,), one=True)["total"]
    return [{"id": row["id"], "routine_id": row["routine_id"], "event_at": iso(row["event_at"]),
             "title": row["title"], "body": row["body"], "weather": json.loads(row["weather_json"]) if isinstance(row["weather_json"], str) else row["weather_json"],
             "ai_generated": bool(row["ai_generated"]), "read": row["read_at"] is not None, "created_at": iso(row["created_at"])} for row in rows], unread


def mark_read(user_id, notification_id=None):
    if notification_id is not None and not execute("SELECT id FROM mobile_notifications WHERE id=%s AND user_id=%s AND state='ready'", (notification_id, user_id), one=True):
        raise AccountError("This notification was not found.", 404)
    execute("UPDATE mobile_notifications SET read_at=%s WHERE user_id=%s AND state='ready' AND read_at IS NULL" + (" AND id=%s" if notification_id is not None else ""), (utcnow(), user_id, *((notification_id,) if notification_id is not None else ())))


def register_device(user_id, session_token, token, platform):
    if platform != "android" or not isinstance(token, str) or not 20 <= len(token) <= 4096 or not re.fullmatch(r"[A-Za-z0-9:_\-.]+", token):
        raise AccountError("This device could not register for notifications.")
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    session_hash = hashlib.sha256(session_token.encode()).hexdigest()
    with db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id FROM mobile_users WHERE id=%s FOR UPDATE", (user_id,))
            cursor.fetchone()
            cursor.execute("SELECT COUNT(*) AS total FROM mobile_push_devices WHERE user_id=%s AND token_hash<>%s", (user_id, token_hash))
            if cursor.fetchone()["total"] >= 10:
                raise AccountError("Too many notification devices. Sign out of an older device first.")
            cursor.execute("SELECT user_id,session_hash FROM mobile_push_devices WHERE token_hash=%s FOR UPDATE", (token_hash,))
            existing = cursor.fetchone()
            if existing and existing["user_id"] == user_id and existing["session_hash"] == session_hash:
                cursor.execute("UPDATE mobile_push_devices SET updated_at=%s WHERE token_hash=%s", (utcnow(), token_hash))
                return
            # Remove old work before transferring an app instance between accounts.
            cursor.execute("DELETE FROM mobile_notification_deliveries WHERE token_hash=%s", (token_hash,))
            cursor.execute("DELETE FROM mobile_push_devices WHERE token_hash=%s", (token_hash,))
            cursor.execute("INSERT INTO mobile_push_devices (token_hash,token,user_id,session_hash,platform,updated_at) VALUES (%s,%s,%s,%s,%s,%s)", (token_hash, token, user_id, session_hash, platform, utcnow()))


def remove_device(user_id, token):
    if isinstance(token, str):
        execute("DELETE FROM mobile_push_devices WHERE token_hash=%s AND user_id=%s", (hashlib.sha256(token.encode()).hexdigest(), user_id))


def active_routines():
    return execute(ROUTINE_SELECT + "JOIN mobile_users u ON u.id=r.user_id WHERE r.enabled=1 AND l.is_active=1 AND u.email_verified_at IS NOT NULL", rows=True)


def claim_occurrence(routine, event_at, now):
    # MySQL DATETIME stores whole seconds; use the same value for insert and lookup.
    event_at = event_at.replace(microsecond=0)
    claim = secrets.token_hex(16)
    with db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("INSERT IGNORE INTO mobile_notifications (user_id,routine_id,event_at,body,created_at) VALUES (%s,%s,%s,'',%s)", (routine["user_id"], routine["id"], event_at, now))
            cursor.execute("UPDATE mobile_notifications SET claim_token=%s,lease_until=%s WHERE routine_id=%s AND event_at=%s AND state='preparing' AND (lease_until IS NULL OR lease_until<%s)", (claim, now+timedelta(minutes=2), routine["id"], event_at, now))
            if not cursor.rowcount:
                return None
            cursor.execute("SELECT id FROM mobile_notifications WHERE routine_id=%s AND event_at=%s", (routine["id"], event_at))
            return cursor.fetchone()["id"], claim


def finish_occurrence(routine, notification_id, claim, advice, now):
    with db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT revision,enabled FROM mobile_routines WHERE id=%s FOR UPDATE", (routine["id"],))
            current = cursor.fetchone()
            if not current or not current["enabled"] or current["revision"] != routine["revision"]:
                cursor.execute("DELETE FROM mobile_notifications WHERE id=%s AND claim_token=%s AND state='preparing'", (notification_id, claim))
                return
            cursor.execute("UPDATE mobile_notifications SET state='ready',title=%s,body=%s,weather_json=%s,ai_generated=%s,lease_until=NULL WHERE id=%s AND claim_token=%s AND state='preparing'", (advice["title"], advice["body"], json.dumps(advice["weather"]), advice["ai_generated"], notification_id, claim))
            if not cursor.rowcount:
                return
            cursor.execute("INSERT IGNORE INTO mobile_notification_deliveries (notification_id,token_hash,next_attempt_at) SELECT %s,d.token_hash,%s FROM mobile_push_devices d JOIN mobile_user_sessions s ON s.token_hash=d.session_hash WHERE d.user_id=%s AND s.user_id=d.user_id AND s.expires_at>%s", (notification_id, now, routine["user_id"], now))


def pending_deliveries(now):
    return execute("SELECT n.id,n.user_id,n.routine_id,n.title,n.body,n.event_at,d.token,d.token_hash,d.session_hash,q.attempts FROM mobile_notification_deliveries q JOIN mobile_notifications n ON n.id=q.notification_id JOIN mobile_push_devices d ON d.token_hash=q.token_hash JOIN mobile_user_sessions s ON s.token_hash=d.session_hash JOIN mobile_routines r ON r.id=n.routine_id JOIN mobile_users u ON u.id=n.user_id WHERE q.state IN ('pending','sending') AND q.attempts<5 AND q.next_attempt_at<=%s AND (q.lease_until IS NULL OR q.lease_until<%s) AND n.state='ready' AND n.user_id=d.user_id AND s.user_id=n.user_id AND s.expires_at>%s AND u.email_verified_at IS NOT NULL AND r.enabled=1 AND n.event_at>%s ORDER BY q.next_attempt_at LIMIT 50", (now, now, now, now-timedelta(minutes=5)), rows=True)


def claim_delivery(row, now):
    claim = secrets.token_hex(16)
    changed = execute("UPDATE mobile_notification_deliveries SET state='sending',attempts=attempts+1,lease_until=%s,claim_token=%s WHERE notification_id=%s AND token_hash=%s AND state IN ('pending','sending') AND attempts<5 AND (lease_until IS NULL OR lease_until<%s)", (now+timedelta(minutes=2), claim, row["id"], row["token_hash"], now))
    return claim if changed else None


def finish_delivery(row, claim, result, now):
    if result == "unregistered":
        execute("DELETE FROM mobile_push_devices WHERE token_hash=%s AND session_hash=%s AND user_id=%s", (row["token_hash"], row["session_hash"], row["user_id"]))
        return
    state = "sent" if result == "sent" else "failed" if result == "failed" or row["attempts"] >= 4 else "pending"
    execute("UPDATE mobile_notification_deliveries SET state=%s,lease_until=NULL,next_attempt_at=%s WHERE notification_id=%s AND token_hash=%s AND claim_token=%s", (state, now+timedelta(seconds=min(900, 60*2**row["attempts"])), row["id"], row["token_hash"], claim))
