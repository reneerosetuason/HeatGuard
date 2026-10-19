from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest
import requests

from services.weather import (
    WeatherAPIError,
    fetch_current_weather,
    fetch_past_observations,
)

LOCATION = {
    "id": 1,
    "name": "Metro Manila",
    "latitude": 14.5995,
    "longitude": 120.9842,
    "timezone": "Asia/Manila",
}

PH_TIMEZONE = timezone(timedelta(hours=8))


class FakeResponse:
    def __init__(self, payload, status_code=200, reason="OK"):
        self._payload = payload
        self.status_code = status_code
        self.reason = reason

    def json(self):
        return self._payload


def current_payload(local_time=None, temperature=32.1, humidity=76):
    local_time = local_time or datetime.now(PH_TIMEZONE)
    return {
        "latitude": LOCATION["latitude"],
        "longitude": LOCATION["longitude"],
        "timezone": "Asia/Manila",
        "utc_offset_seconds": 28800,
        "current": {
            "time": local_time.strftime("%Y-%m-%dT%H:%M"),
            "interval": 900,
            "temperature_2m": temperature,
            "relative_humidity_2m": humidity,
        },
    }


@patch("services.weather.requests.get")
def test_fetch_current_weather_validates_and_converts_time(mock_get):
    local_now = datetime.now(PH_TIMEZONE)
    mock_get.return_value = FakeResponse(current_payload(local_now))

    observation = fetch_current_weather(LOCATION)

    assert observation.temperature_c == 32.1
    assert observation.humidity_pct == 76.0
    assert observation.source == "open-meteo"
    assert observation.api_timezone == "Asia/Manila"
    expected_utc = local_now.replace(tzinfo=PH_TIMEZONE).astimezone(
        timezone.utc
    ).replace(tzinfo=None)
    assert abs((observation.observed_at - expected_utc).total_seconds()) < 60
    assert observation.fetched_at.tzinfo is None


@patch("services.weather.requests.get")
def test_missing_current_block_is_rejected(mock_get):
    mock_get.return_value = FakeResponse({"timezone": "Asia/Manila"})
    with pytest.raises(WeatherAPIError, match="current conditions"):
        fetch_current_weather(LOCATION)


@patch("services.weather.requests.get")
def test_invalid_humidity_is_rejected(mock_get):
    mock_get.return_value = FakeResponse(current_payload(humidity=140))
    with pytest.raises(WeatherAPIError, match="Humidity"):
        fetch_current_weather(LOCATION)


@patch("services.weather.requests.get")
def test_missing_temperature_is_rejected(mock_get):
    payload = current_payload()
    payload["current"].pop("temperature_2m")
    mock_get.return_value = FakeResponse(payload)
    with pytest.raises(WeatherAPIError, match="temperature"):
        fetch_current_weather(LOCATION)


@patch("services.weather.requests.get")
def test_future_observation_is_rejected(mock_get):
    future = datetime.now(PH_TIMEZONE) + timedelta(hours=3)
    mock_get.return_value = FakeResponse(current_payload(future))
    with pytest.raises(WeatherAPIError, match="future"):
        fetch_current_weather(LOCATION)


@patch("services.weather.requests.get")
def test_api_error_payload_is_rejected(mock_get):
    mock_get.return_value = FakeResponse(
        {"error": True, "reason": "Latitude is invalid"}, status_code=400
    )
    with pytest.raises(WeatherAPIError, match="Latitude is invalid"):
        fetch_current_weather(LOCATION)


@patch("services.weather.requests.get")
def test_network_failure_is_wrapped(mock_get):
    mock_get.side_effect = requests.ConnectionError("offline")
    with pytest.raises(WeatherAPIError, match="request failed"):
        fetch_current_weather(LOCATION)


@patch("services.weather.requests.get")
def test_past_history_excludes_future_forecast_hours(mock_get):
    now = datetime.now(PH_TIMEZONE).replace(minute=0, second=0, microsecond=0)
    past = now - timedelta(hours=2)
    future = now + timedelta(hours=2)
    payload = {
        "timezone": "Asia/Manila",
        "utc_offset_seconds": 28800,
        "hourly": {
            "time": [
                past.strftime("%Y-%m-%dT%H:%M"),
                future.strftime("%Y-%m-%dT%H:%M"),
            ],
            "temperature_2m": [31.0, 33.0],
            "relative_humidity_2m": [70.0, 60.0],
        },
    }
    mock_get.return_value = FakeResponse(payload)

    observations = fetch_past_observations(LOCATION, days=7)

    assert len(observations) == 1
    assert observations[0]["temperature_c"] == 31.0
    assert observations[0]["source"] == "open-meteo-historical"
    assert observations[0]["observed_at"] <= datetime.now(
        timezone.utc
    ).replace(tzinfo=None)
