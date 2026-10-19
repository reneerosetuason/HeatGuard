"""Location search using the Open-Meteo geocoding API.

HeatGuard lets the user choose which community to monitor. This module turns a
place name (for example "Baguio City" or "Quezon City") into coordinates and an
IANA timezone so the dashboard can monitor heat conditions for that location.
The geocoding endpoint is free and does not require an API key.
"""

from __future__ import annotations

import logging
from typing import Any

import requests

import config

logger = logging.getLogger(__name__)


class GeocodingError(RuntimeError):
    """Raised when a location search cannot be completed."""


def _clean_result(item: dict[str, Any]) -> dict | None:
    try:
        latitude = float(item["latitude"])
        longitude = float(item["longitude"])
    except (KeyError, TypeError, ValueError):
        return None

    name = str(item.get("name") or "").strip()
    if not name:
        return None

    population = item.get("population")
    try:
        population = int(population) if population is not None else None
    except (TypeError, ValueError):
        population = None

    return {
        "name": name,
        "latitude": latitude,
        "longitude": longitude,
        "country": item.get("country"),
        "country_code": item.get("country_code"),
        "admin1": item.get("admin1"),
        "timezone": item.get("timezone") or "Asia/Manila",
        "population": population,
        "display_name": ", ".join(
            part
            for part in (
                name,
                item.get("admin1"),
                item.get("country"),
            )
            if part
        ),
    }


def search_locations(query: str, count: int | None = None) -> list[dict]:
    """Return candidate locations for a free-text place name."""

    query = (query or "").strip()
    if len(query) < 2:
        return []

    params = {
        "name": query,
        "count": max(1, min(int(count or config.GEOCODING_RESULT_LIMIT), 20)),
        "language": "en",
        "format": "json",
    }

    try:
        response = requests.get(
            config.OPEN_METEO_GEOCODING_URL,
            params=params,
            timeout=config.GEOCODING_TIMEOUT_SECONDS,
            headers={"User-Agent": "HeatGuard/1.0 (college project)"},
        )
    except requests.RequestException as exc:
        raise GeocodingError(f"Location search failed: {exc}") from exc

    try:
        payload = response.json()
    except ValueError as exc:
        raise GeocodingError("Location search returned a non-JSON response") from exc

    if response.status_code >= 400:
        raise GeocodingError(
            f"Location search error: {response.reason or response.status_code}"
        )

    results = payload.get("results") or []
    if not isinstance(results, list):
        raise GeocodingError("Location search returned an unexpected response")

    cleaned: list[dict] = []
    for item in results:
        if isinstance(item, dict):
            parsed = _clean_result(item)
            if parsed is not None:
                cleaned.append(parsed)
    return cleaned
