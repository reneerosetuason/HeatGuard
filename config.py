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

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "127.0.0.1"),
    "port": _env_int("DB_PORT", 3306),
    "user": os.getenv("DB_USER", "root"),
    "password": os.getenv("DB_PASSWORD", ""),
    "database": os.getenv("DB_NAME", "HeatGuard"),
    "charset": "utf8mb4",
}

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
