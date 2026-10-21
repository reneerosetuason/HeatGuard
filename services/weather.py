"""Open-Meteo weather API client and response validation."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any

import requests

import config

logger = logging.getLogger(__name__)


class WeatherAPIError(RuntimeError):
    """Raised when weather data cannot be fetched or validated."""


@dataclass(frozen=True)
class WeatherObservation:
    temperature_c: float
    humidity_pct: float
    observed_at: datetime  # naive UTC
    fetched_at: datetime  # naive UTC
    api_timezone: str | None
    source: str
    raw_payload: dict[str, Any]


def _number(value: Any, field_name: str) -> float:
    if isinstance(value, bool) or value is None:
        raise WeatherAPIError(f"Missing or invalid {field_name} from weather API")
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise WeatherAPIError(
            f"Missing or invalid {field_name} from weather API"
        ) from exc
    return number


def _parse_observation_time(payload: dict, current: dict) -> datetime:
    raw_time = current.get("time")
    if not isinstance(raw_time, str) or not raw_time.strip():
        raise WeatherAPIError("Weather API did not return an observation time")

    try:
        parsed = datetime.fromisoformat(raw_time.replace("Z", "+00:00"))
    except ValueError as exc:
        raise WeatherAPIError("Weather API returned an invalid observation time") from exc

    if parsed.tzinfo is None:
        offset = payload.get("utc_offset_seconds")
        try:
            offset_seconds = int(offset)
        except (TypeError, ValueError) as exc:
            raise WeatherAPIError(
                "Weather API response is missing its UTC offset"
            ) from exc
        parsed = parsed.replace(
            tzinfo=timezone(timedelta(seconds=offset_seconds))
        )

    return parsed.astimezone(timezone.utc).replace(tzinfo=None)


def fetch_current_weather(location: dict) -> WeatherObservation:
    """Fetch and validate current conditions for one location."""

    params = {
        "latitude": location["latitude"],
        "longitude": location["longitude"],
        "current": "temperature_2m,relative_humidity_2m,weather_code,precipitation,is_day",
        "temperature_unit": "celsius",
        "timezone": location.get("timezone") or "auto",
        "forecast_days": 1,
    }

    try:
        response = requests.get(
            config.OPEN_METEO_CURRENT_URL,
            params=params,
            timeout=config.WEATHER_API_TIMEOUT_SECONDS,
            headers={"User-Agent": "HeatGuard/1.0 (college project)"},
        )
    except requests.RequestException as exc:
        raise WeatherAPIError(f"Weather API request failed: {exc}") from exc

    try:
        payload = response.json()
    except ValueError as exc:
        raise WeatherAPIError("Weather API returned a non-JSON response") from exc

    if response.status_code >= 400 or payload.get("error"):
        reason = payload.get("reason") or response.reason or "unknown error"
        raise WeatherAPIError(f"Weather API error: {reason}")

    current = payload.get("current")
    if not isinstance(current, dict):
        raise WeatherAPIError("Weather API response is missing current conditions")

    temperature_c = _number(
        current.get("temperature_2m"), "temperature_2m"
    )
    humidity_pct = _number(
        current.get("relative_humidity_2m"), "relative_humidity_2m"
    )

    if not -50.0 <= temperature_c <= 60.0:
        raise WeatherAPIError(
            f"Temperature value is outside the supported range: {temperature_c}"
        )
    if not 0.0 <= humidity_pct <= 100.0:
        raise WeatherAPIError(
            f"Humidity value is outside the supported range: {humidity_pct}"
        )

    observed_at = _parse_observation_time(payload, current)
    fetched_at = datetime.now(timezone.utc).replace(tzinfo=None)

    if observed_at > fetched_at + timedelta(minutes=30):
        raise WeatherAPIError("Weather API returned a future observation time")
    if fetched_at - observed_at > timedelta(hours=6):
        raise WeatherAPIError("Weather API observation is unexpectedly old")

    return WeatherObservation(
        temperature_c=round(temperature_c, 1),
        humidity_pct=round(humidity_pct, 1),
        observed_at=observed_at,
        fetched_at=fetched_at,
        api_timezone=payload.get("timezone"),
        source="open-meteo",
        raw_payload={
            "latitude": payload.get("latitude"),
            "longitude": payload.get("longitude"),
            "timezone": payload.get("timezone"),
            "utc_offset_seconds": payload.get("utc_offset_seconds"),
            "current": current,
        },
    )


def _hourly_observations_from_payload(
    payload: dict, *, source: str
) -> list[dict]:
    hourly = payload.get("hourly")
    if not isinstance(hourly, dict):
        raise WeatherAPIError("Weather API response is missing hourly data")

    times = hourly.get("time") or []
    temperatures = hourly.get("temperature_2m") or []
    humidities = hourly.get("relative_humidity_2m") or []
    if not (len(times) == len(temperatures) == len(humidities)):
        raise WeatherAPIError("Weather API arrays have inconsistent lengths")

    offset = payload.get("utc_offset_seconds", 0)
    try:
        offset_delta = timedelta(seconds=int(offset))
    except (TypeError, ValueError) as exc:
        raise WeatherAPIError("Weather API response has an invalid UTC offset") from exc

    now_utc = datetime.now(timezone.utc).replace(tzinfo=None)
    observations: list[dict] = []
    for raw_time, raw_temp, raw_humidity in zip(
        times, temperatures, humidities
    ):
        if raw_temp is None or raw_humidity is None:
            continue
        try:
            parsed = datetime.fromisoformat(str(raw_time))
            temperature_c = float(raw_temp)
            humidity_pct = float(raw_humidity)
        except (TypeError, ValueError):
            continue
        if not -50.0 <= temperature_c <= 60.0:
            continue
        if not 0.0 <= humidity_pct <= 100.0:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone(offset_delta))
        observed_at = parsed.astimezone(timezone.utc).replace(tzinfo=None)
        if observed_at > now_utc:
            # Never store future forecast hours as historical observations.
            continue
        observations.append(
            {
                "observed_at": observed_at,
                "temperature_c": round(temperature_c, 1),
                "humidity_pct": round(humidity_pct, 1),
                "api_timezone": payload.get("timezone"),
                "source": source,
            }
        )

    return observations


def fetch_past_observations(location: dict, days: int = 7) -> list[dict]:
    """Fetch historical hourly model data using Open-Meteo ``past_days``.

    The forecast endpoint also returns past hourly values when ``past_days``
    is set. HeatGuard keeps only timestamps at or before the current UTC
    time, so forecast hours are never stored as historical readings.
    """

    days = max(1, min(int(days), 92))
    params = {
        "latitude": location["latitude"],
        "longitude": location["longitude"],
        "hourly": "temperature_2m,relative_humidity_2m",
        "temperature_unit": "celsius",
        "timezone": location.get("timezone") or "auto",
        "past_days": days,
        "forecast_days": 1,
    }

    try:
        response = requests.get(
            config.OPEN_METEO_CURRENT_URL,
            params=params,
            timeout=max(config.WEATHER_API_TIMEOUT_SECONDS, 30),
            headers={"User-Agent": "HeatGuard/1.0 (college project)"},
        )
    except requests.RequestException as exc:
        raise WeatherAPIError(f"History API request failed: {exc}") from exc

    try:
        payload = response.json()
    except ValueError as exc:
        raise WeatherAPIError("History API returned a non-JSON response") from exc

    if response.status_code >= 400 or payload.get("error"):
        reason = payload.get("reason") or response.reason or "unknown error"
        raise WeatherAPIError(f"History API error: {reason}")

    return _hourly_observations_from_payload(
        payload, source="open-meteo-historical"
    )


def fetch_archive_observations(
    location: dict, start_date: date, end_date: date
) -> list[dict]:
    """Fetch historical hourly observations from the Open-Meteo archive.

    The archive is reanalysis data (an estimate), not a physical sensor
    reading. It is used only for optional chart backfilling.
    """

    params = {
        "latitude": location["latitude"],
        "longitude": location["longitude"],
        "start_date": start_date.isoformat(),
        "end_date": end_date.isoformat(),
        "hourly": "temperature_2m,relative_humidity_2m",
        "temperature_unit": "celsius",
        "timezone": location.get("timezone") or "auto",
    }

    try:
        response = requests.get(
            config.OPEN_METEO_ARCHIVE_URL,
            params=params,
            timeout=max(config.WEATHER_API_TIMEOUT_SECONDS, 30),
            headers={"User-Agent": "HeatGuard/1.0 (college project)"},
        )
    except requests.RequestException as exc:
        raise WeatherAPIError(f"Archive API request failed: {exc}") from exc

    try:
        payload = response.json()
    except ValueError as exc:
        raise WeatherAPIError("Archive API returned a non-JSON response") from exc

    if response.status_code >= 400 or payload.get("error"):
        reason = payload.get("reason") or response.reason or "unknown error"
        raise WeatherAPIError(f"Archive API error: {reason}")

    hourly = payload.get("hourly")
    if not isinstance(hourly, dict):
        raise WeatherAPIError("Archive API response is missing hourly data")

    times = hourly.get("time") or []
    temperatures = hourly.get("temperature_2m") or []
    humidities = hourly.get("relative_humidity_2m") or []
    if not (len(times) == len(temperatures) == len(humidities)):
        raise WeatherAPIError("Archive API arrays have inconsistent lengths")

    offset = payload.get("utc_offset_seconds", 0)
    try:
        offset_delta = timedelta(seconds=int(offset))
    except (TypeError, ValueError) as exc:
        raise WeatherAPIError("Archive API response has an invalid UTC offset") from exc

    observations: list[dict] = []
    for raw_time, raw_temp, raw_humidity in zip(
        times, temperatures, humidities
    ):
        if raw_temp is None or raw_humidity is None:
            continue
        try:
            parsed = datetime.fromisoformat(str(raw_time))
            temperature_c = float(raw_temp)
            humidity_pct = float(raw_humidity)
        except (TypeError, ValueError):
            continue
        if not -50.0 <= temperature_c <= 60.0:
            continue
        if not 0.0 <= humidity_pct <= 100.0:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone(offset_delta))
        observed_at = parsed.astimezone(timezone.utc).replace(tzinfo=None)
        observations.append(
            {
                "observed_at": observed_at,
                "temperature_c": round(temperature_c, 1),
                "humidity_pct": round(humidity_pct, 1),
                "api_timezone": payload.get("timezone"),
            }
        )

    return observations
