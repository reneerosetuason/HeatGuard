"""HeatGuard Flask application factory and routes."""

from __future__ import annotations

import logging
import os
import re
import secrets
from datetime import timedelta
from logging.handlers import RotatingFileHandler
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from flask import (
    Flask,
    g,
    jsonify,
    make_response,
    redirect,
    render_template,
    request,
    send_from_directory,
    url_for,
)
from werkzeug.middleware.proxy_fix import ProxyFix

import config
from services import addresses as address_service
from services import dashboard as dashboard_service
from services import db
from services import geocoding as geocoding_service
from services import push_notifications as push_service
from services import security
from services import mobile_auth
from services import routine_api
from services.monitoring import (
    cooldown_remaining,
    get_scheduler,
    monitor_location,
    start_scheduler,
)

logger = logging.getLogger(__name__)

WEB_FRONTEND_DIR = config.BASE_DIR / "frontend" / "web"
MOBILE_WEB_APP_DIR = WEB_FRONTEND_DIR / "mobile_app"


def _create_location_and_payload(
    *, name: str, latitude, longitude, timezone: str
) -> tuple[dict, dict | None]:
    """Create a location, collect its first reading, and build its dashboard."""

    location = db.create_location(
        name=name,
        latitude=latitude,
        longitude=longitude,
        timezone=timezone,
    )
    # Best-effort: fetch current conditions so the new location starts
    # monitoring and an alert is evaluated right away.
    try:
        monitor_location(location)
    except Exception:
        logger.exception("Initial monitoring failed for new location")

    payload = None
    try:
        payload = dashboard_service.build_dashboard(
            location_id=location["id"]
        )
    except db.DatabaseError:
        payload = None
    return location, payload


def _location_json(location: dict) -> dict:
    return {
        "id": int(location["id"]),
        "name": location["name"],
        "latitude": location["latitude"],
        "longitude": location["longitude"],
        "timezone": location["timezone"],
    }


def _request_data():
    """Return a dict-like request body, falling back to form data."""

    if request.is_json:
        data = request.get_json(silent=True)
        return data if isinstance(data, dict) else {}
    return request.form


def _safe_next_path(next_url: str, fallback: str) -> str:
    """Allow only local absolute paths for post-login redirects."""

    candidate = (next_url or "").strip()
    if (
        not candidate.startswith("/")
        or candidate.startswith("//")
        or "\\" in candidate
        or "%" in candidate
        or any(ord(character) < 32 for character in candidate)
    ):
        return fallback
    parsed = urlsplit(candidate)
    if parsed.scheme or parsed.netloc:
        return fallback
    return candidate


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


def _is_local_preview_origin(origin: str) -> bool:
    """Accept strict loopback origins only for requests to a loopback API."""

    if not security.is_loopback():
        return False
    if urlsplit(request.host_url).hostname not in {"localhost", "127.0.0.1", "::1"}:
        return False
    if not re.fullmatch(
        r"https?://(?:localhost|127\.0\.0\.1|\[::1\])(?::[0-9]{1,5})?",
        origin,
    ):
        return False
    try:
        port = urlsplit(origin).port
    except ValueError:
        return False
    return port is None or 1 <= port <= 65535


def create_app(
    start_monitor: bool = False, *, allow_local_web_preview: bool = False
) -> Flask:
    app = Flask(
        __name__,
        template_folder=str(WEB_FRONTEND_DIR / "templates"),
        static_folder=str(WEB_FRONTEND_DIR / "static"),
    )
    app.config.update(
        SECRET_KEY=config.SECRET_KEY,
        JSON_SORT_KEYS=False,
        START_MONITOR=start_monitor,
        ALLOW_LOCAL_WEB_PREVIEW=allow_local_web_preview,
        ADMIN_USERNAME=config.ADMIN_USERNAME,
        ADMIN_PASSWORD=config.ADMIN_PASSWORD,
        ALLOW_LOCAL_WRITES=config.ALLOW_LOCAL_WRITES,
        CSRF_ENABLED=config.CSRF_ENABLED,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=config.SESSION_COOKIE_SECURE,
        SESSION_LIFETIME_HOURS=config.SESSION_LIFETIME_HOURS,
        PERMANENT_SESSION_LIFETIME=timedelta(
            hours=config.SESSION_LIFETIME_HOURS
        ),
        LOGIN_MAX_ATTEMPTS=config.LOGIN_MAX_ATTEMPTS,
        LOGIN_WINDOW_SECONDS=config.LOGIN_WINDOW_SECONDS,
        WRITE_MAX_REQUESTS=config.WRITE_MAX_REQUESTS,
        WRITE_WINDOW_SECONDS=config.WRITE_WINDOW_SECONDS,
    )
    if config.TRUST_PROXY:
        app.wsgi_app = ProxyFix(
            app.wsgi_app, x_for=1, x_proto=1, x_host=1
        )
    security.configure_limiters(app)
    _configure_logging(app)

    protected_write_endpoints = {
        "api_create_location",
        "api_create_location_from_address",
        "api_delete_location",
        "api_refresh",
    }

    @app.before_request
    def security_before_request():
        g.csp_nonce = secrets.token_urlsafe(16)
        if (
            app.config.get("START_MONITOR")
            and get_scheduler() is None
            and (config.MONITOR_ENABLED or push_service.push_configured() or config.ROUTINES_ENABLED)
        ):
            start_scheduler()

        endpoint = request.endpoint
        # Browser CORS preflights must reach the response hook so it can add
        # the configured origin/method headers. OPTIONS never changes data;
        # the actual write request below still requires auth and CSRF.
        if request.method == "OPTIONS":
            return None
        if endpoint and endpoint.startswith("mobile_data_"):
            denied = mobile_auth.require_account()
            if denied is not None:
                return denied
        if endpoint == "admin_logout":
            if not security.is_admin():
                return redirect(url_for("index"))
            if not security.validate_csrf():
                return "Invalid CSRF token.", 400
            return None
        if endpoint not in protected_write_endpoints:
            return None

        if not security.can_write():
            status = 401 if security.admin_configured() else 403
            return (
                jsonify(
                    {
                        "ok": False,
                        "error": security.auth_required_message(),
                        "login_url": url_for("admin_login"),
                    }
                ),
                status,
            )
        if not security.validate_csrf():
            return (
                jsonify(
                    {
                        "ok": False,
                        "error": (
                            "Security token missing or expired. "
                            "Reload the dashboard and try again."
                        ),
                    }
                ),
                400,
            )
        allowed, retry_after = security.check_write_rate_limit()
        if not allowed:
            response = jsonify(
                {
                    "ok": False,
                    "error": "Too many change requests. Please wait and try again.",
                }
            )
            response.status_code = 429
            response.headers["Retry-After"] = str(retry_after)
            return response
        return None

    @app.context_processor
    def inject_security_context():
        return {
            "csrf_token": security.csrf_token(),
            "csp_nonce": getattr(g, "csp_nonce", ""),
            "can_write": security.can_write(),
            "is_admin": security.is_admin(),
            "admin_configured": security.admin_configured(),
            "session_lifetime_hours": app.config["SESSION_LIFETIME_HOURS"],
        }

    @app.after_request
    def security_headers(response):
        nonce = getattr(g, "csp_nonce", "")
        origin = request.headers.get("Origin", "")
        cors_path = request.path
        if cors_path.startswith("/api/mobile/data/"):
            cors_path = "/api/" + cors_path.removeprefix("/api/mobile/data/")
        cors_methods = config.WEB_CORS_PATH_METHODS.get(cors_path, ())
        if re.fullmatch(r"/api/mobile/routines/\d+", cors_path):
            cors_methods = ("POST", "DELETE")
        if re.fullmatch(r"/api/mobile/routines/\d+/preview|/api/mobile/notifications/\d+/read", cors_path):
            cors_methods = ("POST",)
        if re.fullmatch(r"/api/locations/\d+", cors_path):
            cors_methods = ("DELETE",)
        requested_method = request.headers.get(
            "Access-Control-Request-Method", ""
        ).upper()
        cors_method_allowed = request.method in cors_methods or (
            request.method == "OPTIONS" and requested_method in cors_methods
        )
        cors_origin_allowed = origin in config.WEB_CORS_ORIGINS or (
            app.config["ALLOW_LOCAL_WEB_PREVIEW"]
            and _is_local_preview_origin(origin)
        )
        if cors_origin_allowed and cors_method_allowed:
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Credentials"] = "true"
            response.headers["Access-Control-Allow-Methods"] = ", ".join(
                cors_methods
            )
            if request.method == "OPTIONS":
                response.headers["Access-Control-Allow-Headers"] = (
                    "Accept, Content-Type, X-CSRF-Token, Authorization"
                )
                response.headers["Access-Control-Max-Age"] = "600"
            vary_values = {
                value.strip()
                for value in response.headers.get("Vary", "").split(",")
                if value.strip()
            }
            vary_values.add("Origin")
            if request.method == "OPTIONS":
                vary_values.update(
                    {"Access-Control-Request-Headers", "Access-Control-Request-Method"}
                )
            response.headers["Vary"] = ", ".join(sorted(vary_values))
        if request.endpoint != "static":
            response.headers.setdefault("Cache-Control", "no-store")
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "same-origin")
        response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
        response.headers.setdefault(
            "Permissions-Policy",
            "geolocation=(), microphone=(), camera=()",
        )
        response.headers.setdefault(
            "Content-Security-Policy",
            (
                "default-src 'self'; "
                f"script-src 'self' 'nonce-{nonce}' https://cdn.jsdelivr.net; "
                "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
                "font-src 'self' https://cdn.jsdelivr.net data:; "
                "img-src 'self' data:; "
                "connect-src 'self'; "
                "object-src 'none'; "
                "base-uri 'self'; "
                "form-action 'self'; "
                "frame-ancestors 'self'"
            ),
        )
        if request.is_secure:
            response.headers.setdefault(
                "Strict-Transport-Security",
                "max-age=31536000; includeSubDomains",
            )
        return response

    @app.route("/admin/login", methods=["GET", "POST"])
    def admin_login():
        if request.method == "GET":
            if security.is_admin():
                return redirect(url_for("index"))
            return render_template(
                "admin_login.html",
                app_name=config.APP_NAME,
                app_subtitle=config.APP_SUBTITLE,
                not_configured=not security.admin_configured(),
                error=None,
                next_url=request.args.get("next", ""),
            )

        if not security.validate_csrf():
            return (
                render_template(
                    "admin_login.html",
                    app_name=config.APP_NAME,
                    app_subtitle=config.APP_SUBTITLE,
                    not_configured=not security.admin_configured(),
                    error="The login form expired. Please try again.",
                    next_url=request.form.get("next", ""),
                ),
                400,
            )

        username = request.form.get("username", "")
        allowed, retry_after = security.check_login_rate_limit(username)
        if not allowed:
            response = make_response(
                render_template(
                    "admin_login.html",
                    app_name=config.APP_NAME,
                    app_subtitle=config.APP_SUBTITLE,
                    not_configured=not security.admin_configured(),
                    error="Too many sign-in attempts. Please wait and try again.",
                    next_url=request.form.get("next", ""),
                ),
                429,
            )
            response.headers["Retry-After"] = str(retry_after)
            return response

        if not security.authenticate(
            username, request.form.get("password", "")
        ):
            app.logger.warning(
                "Failed admin login from %s", security.client_ip()
            )
            return (
                render_template(
                    "admin_login.html",
                    app_name=config.APP_NAME,
                    app_subtitle=config.APP_SUBTITLE,
                    not_configured=not security.admin_configured(),
                    error="Invalid username or password.",
                    next_url=request.form.get("next", ""),
                ),
                401,
            )

        security.login_admin()
        app.logger.info("Admin login from %s", security.client_ip())
        next_url = _safe_next_path(
            request.form.get("next", ""), url_for("index")
        )
        return redirect(next_url)

    @app.route("/admin/logout", methods=["POST"])
    def admin_logout():
        security.logout_admin()
        return redirect(url_for("index"))

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

    @app.route("/api/address/regions")
    def api_address_regions():
        return jsonify({"ok": True, "regions": address_service.list_regions()})

    @app.route("/api/address/provinces")
    def api_address_provinces():
        try:
            provinces = address_service.list_provinces(
                request.args.get("region_code")
            )
        except address_service.AddressError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 400
        return jsonify({"ok": True, "provinces": provinces})

    @app.route("/api/address/cities")
    def api_address_cities():
        try:
            cities = address_service.list_cities(
                request.args.get("province_code")
            )
        except address_service.AddressError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 400
        return jsonify({"ok": True, "cities": cities})

    @app.route("/api/address/barangays")
    def api_address_barangays():
        try:
            barangays = address_service.list_barangays(
                request.args.get("city_code")
            )
        except address_service.AddressError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 400
        return jsonify({"ok": True, "barangays": barangays})

    @app.route("/api/locations/address", methods=["POST"])
    def api_create_location_from_address():
        body = _request_data()
        try:
            resolved = address_service.resolve_address(
                region_code=body.get("region_code"),
                province_code=body.get("province_code"),
                city_code=body.get("city_code"),
                barangay_code=body.get("barangay_code"),
            )
        except address_service.AddressError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 400

        try:
            location, payload = _create_location_and_payload(
                name=resolved["name"],
                latitude=resolved["latitude"],
                longitude=resolved["longitude"],
                timezone=resolved["timezone"],
            )
        except ValueError as exc:
            return jsonify({"ok": False, "error": str(exc)}), 400
        except db.DatabaseError as exc:
            app.logger.exception("Could not create address location")
            return jsonify({"ok": False, "error": str(exc)}), 503

        return (
            jsonify(
                {
                    "ok": True,
                    "location": _location_json(location),
                    "address": resolved,
                    "dashboard": payload,
                }
            ),
            201,
        )

    @app.route("/api/locations", methods=["POST"])
    def api_create_location():
        body = _request_data()
        raw_name = body.get("name")
        raw_timezone = body.get("timezone")
        name = raw_name.strip() if isinstance(raw_name, str) else ""
        timezone_name = (
            raw_timezone.strip()
            if isinstance(raw_timezone, str) and raw_timezone.strip()
            else "Asia/Manila"
        )
        try:
            location, payload = _create_location_and_payload(
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

        return (
            jsonify(
                {
                    "ok": True,
                    "location": _location_json(location),
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
        body = _request_data()
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

    @app.route("/mobile")
    @app.route("/mobile/")
    def mobile_app():
        return send_from_directory(MOBILE_WEB_APP_DIR, "index.html")

    @app.route("/mobile/<path:filename>")
    def mobile_asset(filename: str):
        return send_from_directory(MOBILE_WEB_APP_DIR, filename)

    @app.route("/mobile/manifest.webmanifest")
    def mobile_manifest():
        return send_from_directory(
            MOBILE_WEB_APP_DIR,
            "manifest.webmanifest",
            mimetype="application/manifest+json",
        )

    @app.route("/service-worker.js")
    def mobile_service_worker():
        response = make_response(
            send_from_directory(
                MOBILE_WEB_APP_DIR, "service-worker.js", max_age=0
            )
        )
        response.headers["Service-Worker-Allowed"] = "/"
        response.headers["Cache-Control"] = "no-cache"
        return response

    @app.route("/api/mobile/config")
    def api_mobile_config():
        return jsonify(
            {
                "ok": True,
                "push_enabled": push_service.push_configured(),
                "vapid_public_key": config.VAPID_PUBLIC_KEY,
                "csrf_token": security.csrf_token(),
                "can_write": security.can_write(),
                "admin_configured": security.admin_configured(),
                "is_admin": security.is_admin(),
            }
        )

    @app.route("/api/mobile/login", methods=["POST"])
    def api_mobile_login():
        if not security.validate_csrf():
            return jsonify({"ok": False, "error": "Security token expired. Reload and try again."}), 400
        if not security.admin_configured():
            return jsonify({"ok": False, "error": "Administrator sign-in is not configured on this server."}), 403

        body = _request_data()
        username = body.get("username", "")
        allowed, retry_after = security.check_login_rate_limit(username)
        if not allowed:
            response = jsonify({"ok": False, "error": "Too many sign-in attempts. Please wait and try again."})
            response.status_code = 429
            response.headers["Retry-After"] = str(retry_after)
            return response

        if not security.authenticate(username, body.get("password", "")):
            app.logger.warning("Failed mobile admin login from %s", security.client_ip())
            return jsonify({"ok": False, "error": "Invalid username or password."}), 401

        security.login_admin()
        app.logger.info("Mobile admin login from %s", security.client_ip())
        return jsonify(
            {
                "ok": True,
                "csrf_token": security.csrf_token(),
                "can_write": security.can_write(),
                "admin_configured": security.admin_configured(),
                "is_admin": security.is_admin(),
            }
        )

    @app.route("/api/mobile/logout", methods=["POST"])
    def api_mobile_logout():
        if not security.is_admin():
            return jsonify({"ok": False, "error": "No administrator session is active."}), 401
        if not security.validate_csrf():
            return jsonify({"ok": False, "error": "Security token expired. Reload and try again."}), 400
        security.logout_admin()
        return jsonify(
            {
                "ok": True,
                "csrf_token": security.csrf_token(),
                "can_write": security.can_write(),
                "admin_configured": security.admin_configured(),
                "is_admin": security.is_admin(),
            }
        )

    def mobile_write_guard():
        if not security.validate_csrf():
            return jsonify({"ok": False, "error": "Security token expired. Reload the app and try again."}), 400
        allowed, retry_after = security.check_write_rate_limit()
        if not allowed:
            response = jsonify(
                {"ok": False, "error": "Too many requests. Please wait and try again."}
            )
            response.status_code = 429
            response.headers["Retry-After"] = str(retry_after)
            return response
        return None

    @app.route("/api/mobile/push/subscribe", methods=["POST"])
    def api_mobile_push_subscribe():
        denied = mobile_write_guard()
        if denied is not None:
            return denied
        if not push_service.push_configured():
            return jsonify(
                {
                    "ok": False,
                    "error": "Daily notifications are not configured on this server yet.",
                }
            ), 503

        body = _request_data()
        subscription = body.get("subscription")
        keys = subscription.get("keys") if isinstance(subscription, dict) else None
        endpoint = subscription.get("endpoint") if isinstance(subscription, dict) else None
        p256dh = keys.get("p256dh") if isinstance(keys, dict) else None
        auth = keys.get("auth") if isinstance(keys, dict) else None
        if (
            not push_service.valid_push_endpoint(endpoint)
            or not isinstance(p256dh, str)
            or not 20 <= len(p256dh) <= 200
            or not isinstance(auth, str)
            or not 16 <= len(auth) <= 100
        ):
            return jsonify({"ok": False, "error": "The browser notification subscription is invalid."}), 400

        try:
            location_id = int(body.get("location_id"))
        except (TypeError, ValueError):
            return jsonify({"ok": False, "error": "Choose a weather location."}), 400
        try:
            location = db.get_location(location_id)
        except Exception:
            app.logger.exception("Could not validate mobile push location")
            return jsonify({"ok": False, "error": "The weather database is unavailable."}), 503
        if not location or not location.get("is_active"):
            return jsonify({"ok": False, "error": "That weather location is unavailable."}), 400

        notify_time = body.get("notify_time")
        if not isinstance(notify_time, str) or not re.fullmatch(r"\d{2}:\d{2}", notify_time):
            return jsonify({"ok": False, "error": "Choose a valid daily reminder time."}), 400
        try:
            hour, minute = (int(part) for part in notify_time.split(":"))
            if hour > 23 or minute > 59:
                raise ValueError
        except ValueError:
            return jsonify({"ok": False, "error": "Choose a valid daily reminder time."}), 400

        timezone_name = body.get("timezone")
        if not isinstance(timezone_name, str) or len(timezone_name) > 64:
            return jsonify({"ok": False, "error": "The device timezone is invalid."}), 400
        try:
            ZoneInfo(timezone_name)
        except (ZoneInfoNotFoundError, ValueError):
            return jsonify({"ok": False, "error": "The device timezone is invalid."}), 400

        try:
            db.save_mobile_push_subscription(
                endpoint_hash=push_service.endpoint_hash(endpoint),
                endpoint=endpoint,
                p256dh=p256dh,
                auth=auth,
                location_id=location_id,
                notify_time=notify_time,
                timezone_name=timezone_name,
            )
        except Exception:
            app.logger.exception("Could not save mobile push subscription")
            return jsonify(
                {
                    "ok": False,
                    "error": "Could not save notification settings. Make sure the database schema is up to date.",
                }
            ), 503
        return jsonify({"ok": True, "message": "Daily weather notifications are enabled."})

    @app.route("/api/mobile/push/unsubscribe", methods=["POST"])
    def api_mobile_push_unsubscribe():
        denied = mobile_write_guard()
        if denied is not None:
            return denied
        body = _request_data()
        endpoint = body.get("endpoint")
        if not push_service.valid_push_endpoint(endpoint):
            return jsonify({"ok": False, "error": "The browser notification subscription is invalid."}), 400
        try:
            db.delete_mobile_push_subscription(push_service.endpoint_hash(endpoint))
        except Exception:
            app.logger.exception("Could not remove mobile push subscription")
            return jsonify({"ok": False, "error": "The notification database is unavailable."}), 503
        return jsonify({"ok": True, "message": "Daily notifications are off on this device."})

    app.register_blueprint(mobile_auth.blueprint)
    app.register_blueprint(routine_api.blueprint)
    mobile_routes = [
        ("/dashboard", "api_dashboard", ["GET"]),
        ("/locations", "api_locations", ["GET"]),
        ("/geocode", "api_geocode", ["GET"]),
        ("/address/regions", "api_address_regions", ["GET"]),
        ("/address/provinces", "api_address_provinces", ["GET"]),
        ("/address/cities", "api_address_cities", ["GET"]),
        ("/address/barangays", "api_address_barangays", ["GET"]),
        ("/locations", "api_create_location", ["POST"]),
        ("/locations/address", "api_create_location_from_address", ["POST"]),
        ("/locations/<int:location_id>", "api_delete_location", ["DELETE"]),
        ("/refresh", "api_refresh", ["POST"]),
    ]
    for path, view_name, methods in mobile_routes:
        endpoint_name = "mobile_data_" + view_name
        app.add_url_rule(
            "/api/mobile/data" + path, endpoint=endpoint_name,
            view_func=app.view_functions[view_name], methods=methods,
        )
        if view_name in protected_write_endpoints:
            protected_write_endpoints.add(endpoint_name)
    return app


app = create_app(
    start_monitor=True, allow_local_web_preview=__name__ == "__main__"
)


if __name__ == "__main__":
    start_scheduler()
    app.run(
        host=os.getenv("HOST", "127.0.0.1"),
        port=int(os.getenv("PORT", "5000")),
        debug=False,
        use_reloader=False,
    )
