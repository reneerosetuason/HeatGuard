"""Account-owned addresses backed by isolated monitoring records."""
import math
import secrets
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from services import db, routine_store as store
from services.mobile_accounts import AccountError

SELECT = ("SELECT l.id,p.display_name AS name,l.latitude,l.longitude,l.timezone,l.is_active "
          "FROM locations l JOIN mobile_saved_locations p ON p.location_id=l.id ")
LIMIT = 20


def public(row):
    return {"id": int(row["id"]), "name": row["name"], "latitude": float(row["latitude"]),
            "longitude": float(row["longitude"]), "timezone": row["timezone"], "is_active": bool(row["is_active"])}


def list_locations(user_id):
    return [public(row) for row in store.execute(SELECT+"WHERE p.user_id=%s AND l.is_active=1 ORDER BY l.id", (user_id,), rows=True)]


def get_location(user_id, location_id=None):
    if location_id is None:
        rows = list_locations(user_id)
        if rows:
            return rows[0]
    else:
        try:
            wanted = int(location_id)
        except (ValueError, TypeError):
            raise AccountError("This saved address was not found.", 404) from None
        row = store.execute(SELECT+"WHERE p.user_id=%s AND l.id=%s AND l.is_active=1", (user_id, wanted), one=True)
        if row:
            return public(row)
    raise AccountError("Add your first address to see its weather.", 404)


def create(user_id, *, name, latitude, longitude, timezone="Asia/Manila"):
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 120 or any(ord(c)<32 for c in name):
        raise AccountError("Enter an address name using 1 to 120 characters.")
    try:
        lat, lon = float(latitude), float(longitude)
        if isinstance(latitude, bool) or isinstance(longitude, bool) or not math.isfinite(lat) or not math.isfinite(lon) or not -90 <= lat <= 90 or not -180 <= lon <= 180:
            raise ValueError()
        if not isinstance(timezone, str) or len(timezone)>64:
            raise ValueError()
        ZoneInfo(timezone)
    except (TypeError, ValueError, ZoneInfoNotFoundError):
        raise AccountError("Choose a valid address with coordinates and a time zone.") from None
    with db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id FROM mobile_users WHERE id=%s FOR UPDATE", (user_id,))
            if not cursor.fetchone():
                raise AccountError("Sign in again.", 401)
            cursor.execute(SELECT+"WHERE p.user_id=%s AND p.display_name=%s", (user_id, name.strip()))
            existing = cursor.fetchone()
            cursor.execute("SELECT COUNT(*) AS total FROM mobile_saved_locations p JOIN locations l ON l.id=p.location_id WHERE p.user_id=%s AND l.is_active=1", (user_id,))
            total = cursor.fetchone()["total"]
            if (not existing or not existing["is_active"]) and total >= LIMIT:
                raise AccountError(f"You can save up to {LIMIT} addresses. Remove an old address first.")
            if existing:
                if existing["is_active"]:
                    return public(existing)
                location_id = existing["id"]
                cursor.execute("UPDATE locations SET latitude=%s,longitude=%s,timezone=%s,is_active=1 WHERE id=%s", (lat, lon, timezone, location_id))
            else:
                # The shared table's unique name must never collide with another
                # member's display name or change an administrator's location.
                cursor.execute("INSERT INTO locations (name,latitude,longitude,timezone,is_active) VALUES (%s,%s,%s,%s,1)", ("private:"+secrets.token_hex(16), lat, lon, timezone))
                location_id = cursor.lastrowid
                cursor.execute("INSERT INTO mobile_saved_locations (location_id,user_id,display_name,created_at) VALUES (%s,%s,%s,%s)", (location_id, user_id, name.strip(), store.utcnow()))
    return get_location(user_id, location_id)


def remove(user_id, location_id):
    with db.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT l.id FROM locations l JOIN mobile_saved_locations p ON p.location_id=l.id WHERE p.user_id=%s AND l.id=%s AND l.is_active=1 FOR UPDATE", (user_id, location_id))
            if not cursor.fetchone():
                raise AccountError("This saved address was not found.", 404)
            cursor.execute("UPDATE locations SET is_active=0 WHERE id=%s", (location_id,))
            cursor.execute("UPDATE mobile_routines SET enabled=0,revision=revision+1 WHERE user_id=%s AND location_id=%s", (user_id, location_id))
            cursor.execute("UPDATE mobile_notification_deliveries SET state='cancelled' WHERE notification_id IN (SELECT n.id FROM mobile_notifications n JOIN mobile_routines r ON r.id=n.routine_id WHERE r.user_id=%s AND r.location_id=%s) AND state IN ('pending','sending')", (user_id, location_id))
            cursor.execute("DELETE FROM mobile_notifications WHERE routine_id IN (SELECT id FROM mobile_routines WHERE user_id=%s AND location_id=%s) AND (state='preparing' OR scheduled_for>%s)", (user_id, location_id, store.utcnow()))
    # Keep the ownership marker and history, including after account deletion.


def migrate_routine_locations():
    """Copy legacy routine addresses without assigning shared locations to anyone."""
    rows = store.execute("SELECT DISTINCT r.user_id,r.location_id,l.name,l.latitude,l.longitude,l.timezone FROM mobile_routines r JOIN locations l ON l.id=r.location_id LEFT JOIN mobile_saved_locations p ON p.location_id=l.id WHERE p.location_id IS NULL", rows=True)
    for row in rows:
        saved = create(row["user_id"], name=row["name"], latitude=row["latitude"], longitude=row["longitude"], timezone=row["timezone"])
        store.execute("UPDATE mobile_routines SET location_id=%s,revision=revision+1 WHERE user_id=%s AND location_id=%s", (saved["id"], row["user_id"], row["location_id"]))
