"""Minute scheduler for per-location civil times and deduplicated reminders."""
from datetime import datetime, timedelta, timezone, time
import logging
import threading
from zoneinfo import ZoneInfo

from services import routine_advice, routine_push, routine_store as store

logger = logging.getLogger(__name__)
_cycle_lock = threading.Lock()


def occurrences(routine, now, *, upcoming=False):
    zone = ZoneInfo(routine["timezone"])
    local_now = now.replace(tzinfo=timezone.utc).astimezone(zone)
    event_clock = time.fromisoformat(store.clock(routine["routine_time"]))
    days = {int(value) for value in routine["weekdays"].split(",")}
    found = []
    for offset in range(-1, 9 if upcoming else 2):
        date = local_now.date()+timedelta(days=offset)
        if date.weekday() not in days:
            continue
        local = datetime.combine(date, event_clock, tzinfo=zone)
        event = local.astimezone(timezone.utc)
        # Nonexistent DST times are skipped. Ambiguous times use the first fold once.
        if event.astimezone(zone).replace(tzinfo=None) != local.replace(tzinfo=None):
            continue
        event = event.replace(tzinfo=None)
        if upcoming:
            if event >= now:
                found.append(event)
        elif event-timedelta(minutes=routine["remind_before_minutes"]) <= now <= event+timedelta(minutes=5):
            found.append(event)
    return sorted(found)


def run_due_routines(now=None):
    fixed_time = now is not None
    now = now or store.utcnow()
    if now.tzinfo is not None:
        now = now.astimezone(timezone.utc).replace(tzinfo=None)
    current_time = (lambda: now) if fixed_time else store.utcnow
    if not _cycle_lock.acquire(blocking=False):
        return 0
    generated = 0
    try:
        for routine in store.active_routines():
            try:
                moment = current_time()
                for event in occurrences(routine, moment):
                    claimed = store.claim_occurrence(routine, event, moment)
                    if claimed:
                        advice = routine_advice.build_advice(routine, event)
                        store.finish_occurrence(routine, *claimed, advice, current_time())
                        generated += 1
            except Exception as error:
                logger.warning("Routine %s could not be prepared (%s)", routine["id"], type(error).__name__)
        if routine_push.configured():
            for row in store.pending_deliveries(current_time()):
                moment = current_time()
                if row["event_at"] <= moment-timedelta(minutes=5):
                    continue
                claim = store.claim_delivery(row, moment)
                if claim:
                    store.finish_delivery(row, claim, routine_push.send(row, current_time()), current_time())
    finally:
        _cycle_lock.release()
    return generated
