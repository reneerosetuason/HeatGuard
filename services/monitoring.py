"""Weather monitoring, alert generation, and background scheduling."""

from __future__ import annotations

import logging
import threading
from datetime import datetime, timezone

import config
from services import db
from services.heat_index import HeatIndexError, calculate_heat_index_c
from services.risk import classify_heat_index
from services.weather import WeatherAPIError, fetch_current_weather

logger = logging.getLogger(__name__)

_cycle_lock = threading.Lock()


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def monitor_location(location: dict) -> dict:
    """Fetch, validate, calculate, store, and classify one location."""

    location_id = int(location["id"])
    attempted_at = utcnow()
    try:
        db.mark_monitoring_attempt(location_id, attempted_at)
    except Exception:
        logger.exception(
            "Could not record monitoring attempt for location %s", location_id
        )

    try:
        observation = fetch_current_weather(location)
        heat_index_c = calculate_heat_index_c(
            observation.temperature_c, observation.humidity_pct
        )
        risk = classify_heat_index(heat_index_c)
        record = db.record_reading_and_alert(
            location=location,
            observed_at=observation.observed_at,
            fetched_at=observation.fetched_at,
            temperature_c=observation.temperature_c,
            humidity_pct=observation.humidity_pct,
            heat_index_c=heat_index_c,
            risk=risk,
            source=observation.source,
            api_timezone=observation.api_timezone,
            raw_payload=observation.raw_payload,
        )
        db.mark_monitoring_success(
            location_id, observation.observed_at, utcnow()
        )
        logger.info(
            "Stored reading for %s: %.1f C, %.1f%% RH, HI %.1f C, %s%s",
            location["name"],
            observation.temperature_c,
            observation.humidity_pct,
            heat_index_c,
            risk["label"],
            " (alert created)" if record["alert_created"] else "",
        )
        return {
            "ok": True,
            "location_id": location_id,
            "observed_at": observation.observed_at,
            "temperature_c": observation.temperature_c,
            "humidity_pct": observation.humidity_pct,
            "heat_index_c": heat_index_c,
            "risk": risk,
            "alert_created": record["alert_created"],
        }
    except (WeatherAPIError, HeatIndexError, ValueError) as exc:
        message = str(exc)
        logger.warning("Monitoring failed for %s: %s", location["name"], message)
        try:
            db.mark_monitoring_error(location_id, utcnow(), message)
        except Exception:
            logger.exception(
                "Could not record monitoring error for location %s", location_id
            )
        return {
            "ok": False,
            "location_id": location_id,
            "error": message,
        }
    except Exception as exc:
        message = f"Unexpected monitoring error: {exc}"
        logger.exception("Unexpected monitoring error for %s", location["name"])
        try:
            db.mark_monitoring_error(location_id, utcnow(), message)
        except Exception:
            logger.exception(
                "Could not record monitoring error for location %s", location_id
            )
        return {
            "ok": False,
            "location_id": location_id,
            "error": message,
        }


def run_monitoring_cycle() -> list[dict]:
    """Monitor every active location once."""

    if not _cycle_lock.acquire(blocking=False):
        logger.info("Monitoring cycle already running; skipping overlap")
        return []

    results: list[dict] = []
    try:
        locations = db.get_locations(active_only=True)
        for location in locations:
            results.append(monitor_location(location))
    except Exception:
        logger.exception("Monitoring cycle could not start or complete")
    finally:
        _cycle_lock.release()
    return results


def cooldown_remaining(location_id: int) -> int:
    """Seconds left before a manual refresh should call the API again."""

    status = db.get_monitoring_status(location_id)
    if not status or not status.get("last_attempt_at"):
        return 0
    last_attempt = status["last_attempt_at"]
    if isinstance(last_attempt, str):
        try:
            last_attempt = datetime.fromisoformat(last_attempt)
        except ValueError:
            return 0
    elapsed = (utcnow() - last_attempt).total_seconds()
    remaining = config.MANUAL_REFRESH_COOLDOWN_SECONDS - elapsed
    return max(0, int(remaining))


class MonitoringScheduler:
    """Small background scheduler.

    A timer thread is sufficient for this single-process college project. It
    runs independently of any open browser tab, so alerts continue to be
    recorded while nobody is viewing the dashboard. On a multi-process
    production deployment, run exactly one scheduler process (or use a
    dedicated task queue) to avoid duplicate API calls.
    """

    def __init__(self, interval_seconds: int):
        self.interval_seconds = max(60, int(interval_seconds))
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._push_thread: threading.Thread | None = None
        self._routine_thread: threading.Thread | None = None

    @property
    def running(self) -> bool:
        return bool(
            (self._thread is not None and self._thread.is_alive())
            or (self._push_thread is not None and self._push_thread.is_alive())
            or (self._routine_thread is not None and self._routine_thread.is_alive())
        )

    def start(self) -> None:
        if self.running:
            return
        if config.MONITOR_ENABLED:
            self._thread = threading.Thread(
                target=self._run,
                name="heatguard-monitor",
                daemon=True,
            )
            self._thread.start()
            logger.info(
                "Background monitoring started (interval %ss)",
                self.interval_seconds,
            )

        from services import push_notifications

        if push_notifications.push_configured():
            self._push_thread = threading.Thread(
                target=self._run_push_notifications,
                name="heatguard-mobile-push",
                daemon=True,
            )
            self._push_thread.start()
            logger.info("Daily mobile push scheduler started")

        if config.ROUTINES_ENABLED:
            self._routine_thread = threading.Thread(target=self._run_routines, name="heatguard-routines", daemon=True)
            self._routine_thread.start()
            logger.info("Personal routine scheduler started")

    def _run_routines(self) -> None:
        from services.routine_jobs import run_due_routines
        if self._stop_event.wait(3):
            return
        while not self._stop_event.is_set():
            try:
                run_due_routines()
            except Exception as error:
                logger.warning("Routine scheduler unavailable (%s)", type(error).__name__)
            if self._stop_event.wait(60):
                break

    def _run(self) -> None:
        # Allow the web server to finish starting before the first API call.
        if self._stop_event.wait(2):
            return
        while not self._stop_event.is_set():
            try:
                run_monitoring_cycle()
            except Exception:
                logger.exception("Background monitoring cycle failed")
            if self._stop_event.wait(self.interval_seconds):
                break

    def _run_push_notifications(self) -> None:
        from services.push_notifications import run_due_notifications

        while not self._stop_event.is_set():
            try:
                run_due_notifications()
            except Exception:
                logger.exception("Daily mobile push check failed")
            if self._stop_event.wait(60):
                break

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        if self._push_thread is not None:
            self._push_thread.join(timeout=5)
        if self._routine_thread is not None:
            self._routine_thread.join(timeout=5)
        logger.info("Background monitoring stopped")


_scheduler: MonitoringScheduler | None = None
_scheduler_lock = threading.Lock()


def get_scheduler() -> MonitoringScheduler | None:
    return _scheduler


def start_scheduler() -> MonitoringScheduler | None:
    """Start the process-wide scheduler once."""

    global _scheduler
    from services import push_notifications

    if not config.MONITOR_ENABLED and not push_notifications.push_configured() and not config.ROUTINES_ENABLED:
        logger.info("Background monitoring and mobile push are disabled")
        return None
    with _scheduler_lock:
        if _scheduler is None:
            _scheduler = MonitoringScheduler(config.MONITOR_INTERVAL_SECONDS)
            _scheduler.start()
        return _scheduler
