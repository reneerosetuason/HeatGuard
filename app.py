"""HeatGuard Flask application factory and routes."""

from __future__ import annotations

import logging
import os
from logging.handlers import RotatingFileHandler

from flask import Flask, jsonify, render_template, request

import config
from services import dashboard as dashboard_service
from services import db
from services import geocoding as geocoding_service
from services.monitoring import (
    cooldown_remaining,
    get_scheduler,
    monitor_location,
    start_scheduler,
)

logger = logging.getLogger(__name__)


def _configure_logging(app: Flask) -> None:
    if app.testing:
        return
    level = logging.INFO
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s [%(name)s] %(message)s"
    )
    root = logging.getLogger()
    if not root.handlers:
        logging.basicConfig(level=level, format=formatter._fmt)
    logs_dir = config.BASE_DIR / "logs"
    logs_dir.mkdir(exist_ok=True)
    file_handler = RotatingFileHandler(
        logs_dir / "heatguard.log",
        maxBytes=1_000_000,
        backupCount=3,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)
    file_handler.setLevel(level)
    if not any(
        isinstance(handler, RotatingFileHandler)
        for handler in root.handlers
    ):
        root.addHandler(file_handler)
    app.logger.setLevel(level)


def create_app(start_monitor: bool = False) -> Flask:
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=config.SECRET_KEY,
        JSON_SORT_KEYS=False,
        START_MONITOR=start_monitor,
    )
    _configure_logging(app)

    @app.before_request
    def ensure_background_monitor():
        if (
            app.config.get("START_MONITOR")
            and config.MONITOR_ENABLED
            and get_scheduler() is None
        ):
            start_scheduler()

    @app.after_request
    def security_headers(response):
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "same-origin")
        response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
        return response

    @app.route("/")
    def index():
        location_id = request.args.get("location")
        hours = request.args.get("hours", type=int)
        try:
            initial_data = dashboard_service.build_dashboard(
                location_id=location_id, hours=hours
            )
        except LookupError as exc:
            return _render_setup_error(str(exc))
        except db.DatabaseError as exc:
            app.logger.exception("Dashboard database error")
            return _render_setup_error(
                "HeatGuard could not read the MySQL database.",
                details=str(exc),
            )
        except Exception as exc:
            app.logger.exception("Dashboard failed to render")
            return _render_setup_error(
                "HeatGuard could not load the dashboard.",
                details=str(exc),
            )
        return render_template(
            "dashboard.html",
            initial_data=initial_data,
            app_name=config.APP_NAME,
            app_subtitle=config.APP_SUBTITLE,
        )

    @app.route("/api/dashboard")
    def api_dashboard():
        location_id = request.args.get("location") or request.args.get(
            "location_id"
        )
        hours = request.args.get("hours", type=int)
        try:
            payload = dashboard_service.build_dashboard(
                location_id=location_id, hours=hours
            )
        except LookupError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 404
        except db.DatabaseError as exc:
            app.logger.exception("Dashboard API database error")
            return (
                jsonify(
                    {
                        "ok": False,
                        "error": "The database is unavailable.",
                        "details": str(exc),
                    }
                ),
                503,
            )
        except Exception as exc:
            app.logger.exception("Dashboard API failed")
            return jsonify({"ok": False, "error": str(exc)}), 500
        return jsonify({"ok": True, "dashboard": payload})

    @app.route("/api/locations")
    def api_locations():
        try:
            locations = dashboard_service.get_locations()
        except db.DatabaseError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 503
        return jsonify(
            {
                "ok": True,
                "locations": [
                    {
                        "id": int(item["id"]),
                        "name": item["name"],
                        "latitude": item["latitude"],
                        "longitude": item["longitude"],
                        "timezone": item["timezone"],
                    }
                    for item in locations
                ],
            }
        )

    @app.route("/api/geocode")
    def api_geocode():
        query = (request.args.get("q") or "").strip()
        if len(query) < 2:
            return jsonify({"ok": True, "results": []})
        try:
            results = geocoding_service.search_locations(query)
        except geocoding_service.GeocodingError as exc:
            app.logger.warning("Location search failed: %s", exc)
            return jsonify({"ok": False, "error": str(exc)}), 502
        return jsonify({"ok": True, "results": results})

    @app.route("/api/locations", methods=["POST"])
    def api_create_location():
        body = request.get_json(silent=True) or request.form
        raw_name = body.get("name")
        raw_timezone = body.get("timezone")
        name = raw_name.strip() if isinstance(raw_name, str) else ""
        timezone_name = (
            raw_timezone.strip()
            if isinstance(raw_timezone, str) and raw_timezone.strip()
            else "Asia/Manila"
        )
        try:
            location = db.create_location(
                name=name,
                latitude=body.get("latitude"),
                longitude=body.get("longitude"),
                timezone=timezone_name,
            )
        except ValueError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 400
        except db.DatabaseError as exc:
            app.logger.exception("Could not create location")
            return jsonify({"ok": False, "error": str(exc)}), 503

        # Best-effort: fetch current conditions so the new location starts
        # monitoring and an alert is evaluated right away.
        try:
            monitor_location(location)
        except Exception:
            app.logger.exception("Initial monitoring failed for new location")

        payload = None
        try:
            payload = dashboard_service.build_dashboard(
                location_id=location["id"]
            )
        except db.DatabaseError:
            payload = None

        return (
            jsonify(
                {
                    "ok": True,
                    "location": {
                        "id": int(location["id"]),
                        "name": location["name"],
                        "latitude": location["latitude"],
                        "longitude": location["longitude"],
                        "timezone": location["timezone"],
                    },
                    "dashboard": payload,
                }
            ),
            201,
        )

    @app.route("/api/locations/<int:location_id>", methods=["DELETE"])
    def api_delete_location(location_id: int):
        try:
            if db.count_active_locations() <= 1:
                return (
                    jsonify(
                        {
                            "ok": False,
                            "error": "At least one monitoring location must remain.",
                        }
                    ),
                    400,
                )
            removed = db.deactivate_location(location_id)
        except db.DatabaseError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 503
        if not removed:
            return jsonify({"ok": False, "error": "Location not found."}), 404
        return jsonify({"ok": True, "deactivated": location_id})

    @app.route("/api/refresh", methods=["POST"])
    def api_refresh():
        body = request.get_json(silent=True) or {}
        location_id = body.get("location_id") or request.form.get("location_id")
        hours = body.get("hours")
        try:
            hours = int(hours) if hours is not None else None
        except (TypeError, ValueError):
            hours = None
        try:
            location = dashboard_service.resolve_location(location_id)
        except LookupError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 404
        except db.DatabaseError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 503

        try:
            remaining = cooldown_remaining(int(location["id"]))
        except db.DatabaseError:
            remaining = 0

        if remaining > 0:
            try:
                payload = dashboard_service.build_dashboard(
                    location_id=location["id"], hours=hours
                )
            except db.DatabaseError as exc:
                return jsonify({"ok": False, "error": str(exc)}), 503
            return (
                jsonify(
                    {
                        "ok": True,
                        "refreshed": False,
                        "message": (
                            "Weather data was checked recently. Please wait "
                            f"{remaining} seconds before refreshing again."
                        ),
                        "retry_after_seconds": remaining,
                        "dashboard": payload,
                    }
                ),
                200,
            )

        result = monitor_location(location)
        try:
            payload = dashboard_service.build_dashboard(
                location_id=location["id"], hours=hours
            )
        except db.DatabaseError as exc:
            payload = None
            result["error"] = f"{result.get('error', '')} {exc}".strip()

        if not result.get("ok"):
            return (
                jsonify(
                    {
                        "ok": False,
                        "message": result.get("error", "Weather update failed."),
                        "dashboard": payload,
                    }
                ),
                502,
            )

        return jsonify(
            {
                "ok": True,
                "refreshed": True,
                "message": "Weather data refreshed.",
                "alert_created": result.get("alert_created", False),
                "dashboard": payload,
            }
        )

    @app.route("/api/health")
    @app.route("/health")
    def health():
        database_ok = db.check_connection()
        scheduler = get_scheduler()
        detail = {
            "status": "ok" if database_ok else "degraded",
            "database": "ok" if database_ok else "unavailable",
            "monitor_enabled": config.MONITOR_ENABLED,
            "scheduler_running": bool(scheduler and scheduler.running),
            "monitor_interval_seconds": config.MONITOR_INTERVAL_SECONDS,
            "stale_after_seconds": config.STALE_AFTER_SECONDS,
        }
        return jsonify(detail), 200 if database_ok else 503

    def _render_setup_error(message: str, details: str | None = None):
        return (
            render_template(
                "error.html",
                app_name=config.APP_NAME,
                message=message,
                details=details,
                db_name=config.DB_CONFIG["database"],
            ),
            503,
        )

    return app


app = create_app(start_monitor=True)


if __name__ == "__main__":
    start_scheduler()
    app.run(
        host=os.getenv("HOST", "127.0.0.1"),
        port=int(os.getenv("PORT", "5000")),
        debug=False,
        use_reloader=False,
    )
