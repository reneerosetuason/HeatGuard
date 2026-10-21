"""Central configuration for HeatGuard.

Threshold values, monitoring locations, refresh intervals, and database
settings live here so that behaviour can be changed without editing the
application code.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


APP_NAME = "HeatGuard"
APP_SUBTITLE = (
    "Heat Index Monitoring and Early Warning System for Community Health "
    "and Climate Resilience"
)
SECRET_KEY = os.getenv("SECRET_KEY", "dev-only-change-this-secret")

# Mobile email verification. Credentials belong only on the Python server.
SMTP_HOST = os.getenv("SMTP_HOST", "smtp.gmail.com").strip()
SMTP_PORT = _env_int("SMTP_PORT", 587)
SMTP_USERNAME = os.getenv("SMTP_USERNAME", "").strip()
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
# Google displays app passwords in groups; the separators are not part of the password.
if SMTP_HOST.lower() == "smtp.gmail.com":
    SMTP_PASSWORD = "".join(SMTP_PASSWORD.split())
SMTP_FROM = os.getenv("SMTP_FROM", "").strip() or SMTP_USERNAME
SMTP_USE_SSL = _env_bool("SMTP_USE_SSL", False)
MOBILE_OTP_MINUTES = 10
MOBILE_OTP_RESEND_SECONDS = 60
MOBILE_OTP_MAX_ATTEMPTS = 5
MOBILE_OTP_MAX_SENDS_PER_HOUR = 5
MOBILE_SESSION_DAYS = 7

# Routine advice and Android push. Secrets stay on the Python server.
GROQ_API_KEY = os.getenv("GROQ_API_KEY", "").strip()
GROQ_MODEL = os.getenv("GROQ_MODEL", "openai/gpt-oss-20b").strip()
GROQ_TIMEOUT_SECONDS = 12
FIREBASE_PROJECT_ID = os.getenv("FIREBASE_PROJECT_ID", "").strip()
GOOGLE_APPLICATION_CREDENTIALS = os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
ROUTINES_ENABLED = _env_bool("ROUTINES_ENABLED", True)
ROUTINE_LIMIT_PER_USER = 20

# ---- Authentication and write protection ----
# When ADMIN_PASSWORD is set, changing HeatGuard data requires an admin login.
# Without a password, only requests from the local machine may change data.
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "")
ALLOW_LOCAL_WRITES = _env_bool("ALLOW_LOCAL_WRITES", True)
SESSION_COOKIE_SECURE = _env_bool("SESSION_COOKIE_SECURE", False)
SESSION_LIFETIME_HOURS = _env_int("SESSION_LIFETIME_HOURS", 8)
# Enable only when HeatGuard is behind a reverse proxy that overwrites
# X-Forwarded-For and X-Forwarded-Proto.
TRUST_PROXY = _env_bool("TRUST_PROXY", False)
CSRF_ENABLED = _env_bool("CSRF_ENABLED", True)
LOGIN_MAX_ATTEMPTS = _env_int("LOGIN_MAX_ATTEMPTS", 5)
LOGIN_WINDOW_SECONDS = _env_int("LOGIN_WINDOW_SECONDS", 900)
WRITE_MAX_REQUESTS = _env_int("WRITE_MAX_REQUESTS", 60)
WRITE_WINDOW_SECONDS = _env_int("WRITE_WINDOW_SECONDS", 60)
WEB_CORS_ORIGINS = tuple(
    origin.strip().rstrip("/")
    for origin in os.getenv("WEB_CORS_ORIGINS", "").split(",")
    if origin.strip()
)
WEB_CORS_PATH_METHODS = {
    "/api/address/regions": ("GET",),
    "/api/address/provinces": ("GET",),
    "/api/address/cities": ("GET",),
    "/api/address/barangays": ("GET",),
    "/api/dashboard": ("GET",),
    "/api/geocode": ("GET",),
    "/api/locations": ("GET", "POST"),
    "/api/locations/address": ("POST",),
    "/api/mobile/config": ("GET",),
    "/api/mobile/auth/session": ("GET",),
    "/api/mobile/auth/register": ("POST",),
    "/api/mobile/auth/verify": ("POST",),
    "/api/mobile/auth/resend": ("POST",),
    "/api/mobile/auth/login": ("POST",),
    "/api/mobile/auth/logout": ("POST",),
    "/api/mobile/routines": ("GET", "POST"),
    "/api/mobile/notifications": ("GET",),
    "/api/mobile/notifications/read-all": ("POST",),
    "/api/mobile/devices/register": ("POST",),
    "/api/mobile/devices/remove": ("POST",),
    "/api/mobile/login": ("POST",),
    "/api/mobile/logout": ("POST",),
    "/api/refresh": ("POST",),
}

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "127.0.0.1"),
    "port": _env_int("DB_PORT", 3306),
    "user": os.getenv("DB_USER", "root"),
    "password": os.getenv("DB_PASSWORD", ""),
    "database": os.getenv("DB_NAME", "HeatGuard"),
    "charset": "utf8mb4",
}

# ---- Optional installable mobile app push notifications ----
# The private key can be provided directly or as a PEM file path. Keep it out
# of source control; VAPID_PUBLIC_KEY is safe to serve to app clients.
VAPID_PUBLIC_KEY = os.getenv("VAPID_PUBLIC_KEY", "").strip()
VAPID_PRIVATE_KEY = os.getenv("VAPID_PRIVATE_KEY", "").strip()
VAPID_PRIVATE_KEY_PATH = os.getenv("VAPID_PRIVATE_KEY_PATH", "").strip()
VAPID_CLAIMS_EMAIL = os.getenv("VAPID_CLAIMS_EMAIL", "").strip()

# Open-Meteo is free for non-commercial use and does not require an API key.
OPEN_METEO_CURRENT_URL = "https://api.open-meteo.com/v1/forecast"
OPEN_METEO_ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
OPEN_METEO_GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"
WEATHER_API_TIMEOUT_SECONDS = _env_int("WEATHER_API_TIMEOUT_SECONDS", 12)
GEOCODING_TIMEOUT_SECONDS = _env_int("GEOCODING_TIMEOUT_SECONDS", 10)
GEOCODING_RESULT_LIMIT = _env_int("GEOCODING_RESULT_LIMIT", 8)

# Open-Meteo's current conditions are updated roughly every 15 minutes.
# Fetching every 10 minutes is responsive without excessive API traffic.
MONITOR_INTERVAL_SECONDS = _env_int("MONITOR_INTERVAL_SECONDS", 600)
MONITOR_ENABLED = _env_bool("MONITOR_ENABLED", True)
STALE_AFTER_SECONDS = _env_int("STALE_AFTER_SECONDS", 1800)
MANUAL_REFRESH_COOLDOWN_SECONDS = _env_int(
    "MANUAL_REFRESH_COOLDOWN_SECONDS", 60
)
HISTORY_DEFAULT_HOURS = _env_int("HISTORY_DEFAULT_HOURS", 24)
HISTORY_MAX_HOURS = _env_int("HISTORY_MAX_HOURS", 720)
ALERT_HISTORY_LIMIT = _env_int("ALERT_HISTORY_LIMIT", 20)

# Monitoring locations. The first entry is the dashboard default.
LOCATION_SEEDS = [
    {
        "name": "Metro Manila",
        "latitude": 14.5995,
        "longitude": 120.9842,
        "timezone": "Asia/Manila",
    },
    {
        "name": "Cebu City",
        "latitude": 10.3157,
        "longitude": 123.8854,
        "timezone": "Asia/Manila",
    },
    {
        "name": "Davao City",
        "latitude": 7.1907,
        "longitude": 125.4553,
        "timezone": "Asia/Manila",
    },
    {
        "name": "Baguio City",
        "latitude": 16.4023,
        "longitude": 120.5960,
        "timezone": "Asia/Manila",
    },
    {
        "name": "Laoag City",
        "latitude": 18.1978,
        "longitude": 120.5936,
        "timezone": "Asia/Manila",
    },
]

# PAGASA heat-index categories, converted to Celsius.
# Source: Philippine Atmospheric, Geophysical and Astronomical Services
# Administration (PAGASA) heat index classification and heat-index chart.
# https://www.pagasa.dost.gov.ph/weather/heat-index
# The lowest category (below 27 C) is added for completeness because the
# official table begins at 27 C.
HEAT_INDEX_SOURCE = (
    "PAGASA Heat Index Categories (27-32 C Caution, 33-41 C Extreme "
    "Caution, 42-51 C Danger, 52 C and above Extreme Danger)"
)
HEAT_INDEX_SOURCE_URL = "https://www.pagasa.dost.gov.ph/weather/heat-index"

RISK_CATEGORIES = [
    {
        "key": "safe",
        "label": "Low Risk",
        "short_label": "Low",
        "level": 0,
        "min_c": None,
        "max_c": 27.0,
        "color": "#1f7a5c",
        "text_color": "#ffffff",
        "icon": "shield-check",
        "summary": "Heat index is below the caution range.",
        "recommendations": [
            "Keep drinking water regularly, even if you do not feel thirsty.",
            "Monitor the dashboard for changes, especially during midday.",
            "People who are older, pregnant, or have chronic illness should take extra care.",
        ],
    },
    {
        "key": "caution",
        "label": "Caution",
        "short_label": "Caution",
        "level": 1,
        "min_c": 27.0,
        "max_c": 33.0,
        "color": "#c69214",
        "text_color": "#1c1a15",
        "icon": "thermometer-sun",
        "summary": "Fatigue is possible with prolonged exposure and activity.",
        "recommendations": [
            "Drink water regularly and avoid waiting until you are thirsty.",
            "Take rest breaks in shaded or cool areas.",
            "Reduce prolonged strenuous outdoor activity, especially at midday.",
            "Watch for heat cramps, dizziness, and unusual fatigue.",
        ],
    },
    {
        "key": "extreme_caution",
        "label": "Extreme Caution",
        "short_label": "Extreme Caution",
        "level": 2,
        "min_c": 33.0,
        "max_c": 42.0,
        "color": "#b85c0e",
        "text_color": "#ffffff",
        "icon": "exclamation-triangle",
        "summary": "Heat cramps and heat exhaustion are possible.",
        "recommendations": [
            "Limit outdoor activity and move to a cool or shaded place when possible.",
            "Drink water often and take frequent rest breaks.",
            "Schedule strenuous work or exercise for cooler parts of the day.",
            "Check on older adults, young children, and people with chronic illness.",
            "Know the signs of heat illness and seek help if symptoms worsen.",
        ],
    },
    {
        "key": "danger",
        "label": "Danger",
        "short_label": "Danger",
        "level": 3,
        "min_c": 42.0,
        "max_c": 52.0,
        "color": "#b42318",
        "text_color": "#ffffff",
        "icon": "exclamation-octagon",
        "summary": "Heat cramps or heat exhaustion are likely; heat stroke is possible.",
        "recommendations": [
            "Avoid outdoor activity during the hottest part of the day.",
            "Stay in a cool, shaded, or air-conditioned place.",
            "Drink water regularly and avoid alcohol and sugary drinks.",
            "Never leave children or pets inside a parked vehicle.",
            "Seek emergency help for confusion, fainting, or hot, dry skin.",
        ],
    },
    {
        "key": "extreme_danger",
        "label": "Extreme Danger",
        "short_label": "Extreme Danger",
        "level": 4,
        "min_c": 52.0,
        "max_c": None,
        "color": "#6e1638",
        "text_color": "#ffffff",
        "icon": "radioactive",
        "summary": "Heat stroke is imminent with continued exposure.",
        "recommendations": [
            "Do not go outdoors unless absolutely necessary.",
            "Move to the coolest available indoor space immediately.",
            "Drink water if conscious; cool the body with wet cloths and fanning.",
            "Call emergency services immediately for signs of heat stroke.",
            "Follow official PAGASA, local government, and health advisories.",
        ],
    },
]

SAFETY_DISCLAIMER = (
    "HeatGuard provides informational guidance based on weather-API data and "
    "calculated heat-index estimates. It does not replace official PAGASA or "
    "local government warnings, emergency services, or professional medical "
    "advice. When in doubt, follow official advisories."
)

# Recommendations shown when data is unavailable or stale. They deliberately
# do not imply that conditions are safe.
UNKNOWN_RECOMMENDATIONS = [
    "Current heat conditions are unavailable or stale; do not assume they are safe.",
    "Check official weather advisories before outdoor activity.",
    "If you feel dizzy, weak, or overheated, move to a cool place and seek help.",
]
