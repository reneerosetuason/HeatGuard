"""Prepare advice ahead of time and deliver reminders independently when due."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone, time
import logging
import threading
from zoneinfo import ZoneInfo

from services import routine_advice, routine_push, routine_store as store

logger = logging.getLogger(__name__)
_cycle_lock = threading.Lock()
_delivery_lock = threading.Lock()
PREPARE_AHEAD_SECONDS = 90
CHECK_INTERVAL_SECONDS = 5
DELIVERY_INTERVAL_SECONDS = 1


def occurrences(routine, now, *, upcoming=False, prepare_ahead_seconds=0):
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
        elif event-timedelta(minutes=routine["remind_before_minutes"], seconds=prepare_ahead_seconds) <= now <= event+timedelta(minutes=5):
            found.append(event)
    return sorted(found)


def _clock(now):
    if now is None:
        return store.utcnow
    if now.tzinfo is not None:
        now = now.astimezone(timezone.utc).replace(tzinfo=None)
    return lambda: now


def _work(function, items, parallel):
    if parallel:
        with ThreadPoolExecutor(max_workers=4, thread_name_prefix="routine-worker") as pool:
            return list(pool.map(function, items))
    return [function(item) for item in items]


def dispatch_due_notifications(now=None, *, parallel=False):
    """Never wait for weather or AI generation before sending ready reminders."""
    if not routine_push.configured() or not _delivery_lock.acquire(blocking=False):
        return 0
    current_time = _clock(now)
    def deliver(row):
        try:
            moment = current_time()
            if row["event_at"] <= moment-timedelta(minutes=5):
                return 0
            claim = store.claim_delivery(row, moment)
            if not claim:
                return 0
            result = routine_push.send(row, moment)
            completed = current_time()
            store.finish_delivery(row, claim, result, completed)
            if result == "sent" and row.get("scheduled_for"):
                logger.info("Routine notification %s accepted by FCM %.1fs after scheduled time", row["id"], (completed-row["scheduled_for"]).total_seconds())
            return int(result == "sent")
        except Exception as error:
            logger.warning("Routine delivery unavailable (%s)", type(error).__name__)
            return 0
    try:
        return sum(_work(deliver, store.pending_deliveries(current_time()), parallel))
    finally:
        _delivery_lock.release()


def run_due_routines(now=None, *, deliver=True, parallel=False):
    current_time = _clock(now)
    if not _cycle_lock.acquire(blocking=False):
        return 0
    def prepare(routine):
        generated = 0
        try:
            moment = current_time()
            for event in occurrences(routine, moment, prepare_ahead_seconds=PREPARE_AHEAD_SECONDS):
                claimed = store.claim_occurrence(routine, event, moment)
                if claimed:
                    advice = routine_advice.build_advice(routine, event)
                    store.finish_occurrence(routine, *claimed, advice, current_time())
                    generated += 1
        except Exception as error:
            logger.warning("Routine %s could not be prepared (%s)", routine["id"], type(error).__name__)
        return generated
    try:
        if deliver:
            dispatch_due_notifications(now, parallel=parallel)
        generated = sum(_work(prepare, store.active_routines(), parallel))
        if deliver:
            dispatch_due_notifications(now, parallel=parallel)
    finally:
        _cycle_lock.release()
    return generated
