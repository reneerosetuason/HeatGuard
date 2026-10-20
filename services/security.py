"""Authentication, CSRF, rate limiting, and request security helpers."""

from __future__ import annotations

import hmac
import ipaddress
import secrets
import threading
import time
from collections import deque

from flask import current_app, request, session


ADMIN_SESSION_KEY = "heatguard_admin"
CSRF_SESSION_KEY = "heatguard_csrf"
CSRF_HEADER = "X-CSRF-Token"


class RateLimiter:
    """A small in-process sliding-window limiter for a single Waitress worker."""

    def __init__(self, limit: int, window_seconds: int):
        self.limit = max(1, int(limit))
        self.window_seconds = max(1, int(window_seconds))
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str) -> tuple[bool, int]:
        now = time.monotonic()
        cutoff = now - self.window_seconds
        with self._lock:
            events = self._events.setdefault(key, deque())
            while events and events[0] <= cutoff:
                events.popleft()
            if len(events) >= self.limit:
                retry_after = max(1, int(events[0] + self.window_seconds - now))
                return False, retry_after
            events.append(now)
            if len(self._events) > 5000:
                self._prune(cutoff)
            return True, 0

    def reset(self) -> None:
        with self._lock:
            self._events.clear()

    def _prune(self, cutoff: float) -> None:
        stale = [
            key
            for key, events in self._events.items()
            if not events or events[-1] <= cutoff
        ]
        for key in stale:
            self._events.pop(key, None)


login_limiter = RateLimiter(5, 900)
write_limiter = RateLimiter(60, 60)


def configure_limiters(app) -> None:
    """Replace module limiters using settings from the application config."""

    global login_limiter, write_limiter
    login_limiter = RateLimiter(
        app.config.get("LOGIN_MAX_ATTEMPTS", 5),
        app.config.get("LOGIN_WINDOW_SECONDS", 900),
    )
    write_limiter = RateLimiter(
        app.config.get("WRITE_MAX_REQUESTS", 60),
        app.config.get("WRITE_WINDOW_SECONDS", 60),
    )


def _setting(name: str, default=None):
    return current_app.config.get(name, default)


def admin_configured() -> bool:
    return bool(str(_setting("ADMIN_PASSWORD", "") or "").strip())


def is_admin() -> bool:
    return bool(session.get(ADMIN_SESSION_KEY))


def client_ip() -> str:
    return request.remote_addr or "unknown"


def is_loopback(address: str | None = None) -> bool:
    raw = address or client_ip()
    try:
        return ipaddress.ip_address(raw).is_loopback
    except ValueError:
        return False


def can_write() -> bool:
    if admin_configured():
        return is_admin()
    return bool(_setting("ALLOW_LOCAL_WRITES", True)) and is_loopback()


def auth_required_message() -> str:
    if admin_configured():
        return "Sign in as an administrator to change monitoring data."
    if _setting("ALLOW_LOCAL_WRITES", True):
        return (
            "Monitoring changes are restricted to the HeatGuard host. "
            "Open the dashboard on the server itself or configure an admin login."
        )
    return "Monitoring changes are disabled on this HeatGuard instance."


def authenticate(username: str, password: str) -> bool:
    expected_username = str(_setting("ADMIN_USERNAME", "admin"))
    expected_password = str(_setting("ADMIN_PASSWORD", ""))
    if not expected_password:
        return False
    supplied_username = str(username or "")
    supplied_password = str(password or "")
    username_ok = hmac.compare_digest(supplied_username, expected_username)
    password_ok = hmac.compare_digest(supplied_password, expected_password)
    return username_ok and password_ok


def login_admin() -> None:
    session.clear()
    session[ADMIN_SESSION_KEY] = True
    session.permanent = True
    session[CSRF_SESSION_KEY] = secrets.token_urlsafe(32)


def logout_admin() -> None:
    session.clear()


def csrf_token() -> str:
    token = session.get(CSRF_SESSION_KEY)
    if not isinstance(token, str) or len(token) < 32:
        token = secrets.token_urlsafe(32)
        session[CSRF_SESSION_KEY] = token
    return token


def csrf_enabled() -> bool:
    return bool(_setting("CSRF_ENABLED", True))


def request_csrf_token() -> str:
    header = request.headers.get(CSRF_HEADER, "")
    if header:
        return header
    return str(request.form.get("csrf_token", "") or "")


def validate_csrf() -> bool:
    if not csrf_enabled():
        return True
    expected = session.get(CSRF_SESSION_KEY)
    supplied = request_csrf_token()
    if not isinstance(expected, str) or not supplied:
        return False
    return hmac.compare_digest(supplied, expected)


def check_login_rate_limit(username: str) -> tuple[bool, int]:
    del username
    return login_limiter.allow(client_ip())


def check_write_rate_limit() -> tuple[bool, int]:
    return write_limiter.allow(client_ip())
