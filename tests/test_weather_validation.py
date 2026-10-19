"""Tests for Open-Meteo response validation (no network calls)."""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import requests  # noqa: E402
from services import weather  # noqa: E402

LOCATION = {"latitude": 14.5995, "longitude": 120.9842, "timezone": "Asia/Manila"}
OFFSET_HOURS = 8


class _FakeResponse:
    def __init__(self, payload, status_code=200, reason="OK"):
        self._payload = payload
        self.status_code = status_code
        self.reason = reason

    def json(self):
        return self._payload


class _BadJsonResponse:
    status_code = 200
    reason = "OK"

    def json(self):
        raise ValueError("not json")


def make_payload(temp=32.0, humidity=70.0, minutes_ago=10):
    local = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
    local = local.astimezone(timezone(timedelta(hours=OFFSET_HOURS)))
    return {
        "latitude": 14.6,
        "longitude": 120.98,
        "timezone": "Asia/Manila",
        "utc_offset_seconds": OFFSET_HOURS * 3600,
        "current": {
            "time": local.strftime("%Y-%m-%dT%H:%M"),
            "interval": 900,
            "temperature_2m": temp,
            "relative_humidity_2m": humidity,
        },
    }


class ValidResponseTests(unittest.TestCase):
    def test_parses_valid_payload(self):
        with mock.patch.object(
            weather.requests, "get", return_value=_FakeResponse(make_payload())
        ):
            observation = weather.fetch_current_weather(LOCATION)

        self.assertAlmostEqual(observation.temperature_c, 32.0, places=1)
        self.assertAlmostEqual(observation.humidity_pct, 70.0, places=1)
        self.assertEqual(observation.source, "open-meteo")
        self.assertEqual(observation.api_timezone, "Asia/Manila")
        self.assertIsNone(observation.observed_at.tzinfo)  # stored as naive UTC

        drift = abs(
            (observation.observed_at - datetime.now(timezone.utc).replace(tzinfo=None))
            .total_seconds()
        )
        self.assertLess(drift, 3600)


class InvalidResponseTests(unittest.TestCase):
    def _fetch(self, payload, status_code=200):
        with mock.patch.object(
            weather.requests,
            "get",
            return_value=_FakeResponse(payload, status_code=status_code),
        ):
            return weather.fetch_current_weather(LOCATION)

    def test_missing_current_block(self):
        with self.assertRaises(weather.WeatherAPIError):
            self._fetch({"latitude": 14.6, "longitude": 120.98})

    def test_temperature_none(self):
        with self.assertRaises(weather.WeatherAPIError):
            self._fetch(make_payload(temp=None))

    def test_temperature_out_of_range(self):
        with self.assertRaises(weather.WeatherAPIError):
            self._fetch(make_payload(temp=999.0))

    def test_humidity_out_of_range(self):
        with self.assertRaises(weather.WeatherAPIError):
            self._fetch(make_payload(humidity=150.0))

    def test_api_error_payload(self):
        with self.assertRaises(weather.WeatherAPIError):
            self._fetch({"error": True, "reason": "bad request"}, status_code=400)

    def test_future_observation(self):
        payload = make_payload(minutes_ago=-240)  # four hours in the future
        with self.assertRaises(weather.WeatherAPIError):
            self._fetch(payload)

    def test_excessively_old_observation(self):
        payload = make_payload(minutes_ago=600)  # ten hours old (> 6 h limit)
        with self.assertRaises(weather.WeatherAPIError):
            self._fetch(payload)

    def test_non_json_response(self):
        with mock.patch.object(
            weather.requests, "get", return_value=_BadJsonResponse()
        ):
            with self.assertRaises(weather.WeatherAPIError):
                weather.fetch_current_weather(LOCATION)

    def test_request_exception(self):
        with mock.patch.object(
            weather.requests, "get", side_effect=requests.RequestException("boom")
        ):
            with self.assertRaises(weather.WeatherAPIError):
                weather.fetch_current_weather(LOCATION)


if __name__ == "__main__":
    unittest.main()
