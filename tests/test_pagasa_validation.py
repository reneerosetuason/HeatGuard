"""Tests for PAGASA/PANaHON heat-index validation."""

import json
import math

import pytest

from services.heat_index import calculate_heat_index_c
from services.pagasa_validation import (
    PAGASAValidationError,
    extract_station_data,
    latest_observation,
    validate_stations,
)


def station(name, observed_at, temperature, humidity, heat_index):
    return {
        "sitename": name,
        "lat": "14.5",
        "lng": "121.0",
        "data": [
            {
                "observed_at": observed_at,
                "heat_index": heat_index,
                "temperature": str(temperature),
                "humidity": str(humidity),
            }
        ],
        "data_as_of": "Oct 20, 2026, 1PM",
    }


def embedded_html(stations):
    payload = json.dumps(stations, separators=(",", ":"))
    return f"<script>var data=['{payload}','next'];</script>"


def test_extracts_embedded_station_json():
    stations = [station("Science Garden", "2026-10-20 13:00:00", 32, 70, 39)]
    html = embedded_html(stations)

    parsed = extract_station_data(html)

    assert parsed[0]["name"] == "Science Garden"
    assert parsed[0]["latitude"] == 14.5
    assert parsed[0]["data_as_of"] == "Oct 20, 2026, 1PM"


def test_rejects_page_without_station_data():
    with pytest.raises(PAGASAValidationError):
        extract_station_data("<html><body>No station data</body></html>")


def test_latest_observation_skips_invalid_rows():
    item = {
        "name": "Test Station",
        "observations": [
            {
                "observed_at": "2026-10-20 12:00:00",
                "temperature": "31",
                "humidity": "60",
                "heat_index": "35",
            },
            {
                "observed_at": "2026-10-20 13:00:00",
                "temperature": None,
                "humidity": "70",
                "heat_index": "38",
            },
            {
                "observed_at": "2026-10-20 14:00:00",
                "temperature": "32",
                "humidity": "70",
                "heat_index": "39",
            },
        ],
    }

    latest = latest_observation(item)

    assert latest["observed_at"] == "2026-10-20 14:00:00"
    assert latest["temperature_c"] == 32.0


def test_validation_metrics_and_category_agreement():
    calculated = calculate_heat_index_c(32, 70)
    stations = [
        {
            "name": "Exact Station",
            "latitude": 1.0,
            "longitude": 2.0,
            "data_as_of": "1PM",
            "observations": [
                {
                    "observed_at": "2026-10-20 13:00:00",
                    "temperature_c": 32,
                    "humidity_pct": 70,
                    "reported_heat_index_c": calculated,
                }
            ],
        },
        {
            "name": "Two Degrees Off",
            "latitude": 1.0,
            "longitude": 2.0,
            "data_as_of": "1PM",
            "observations": [
                {
                    "observed_at": "2026-10-20 13:00:00",
                    "temperature_c": 32,
                    "humidity_pct": 70,
                    "reported_heat_index_c": calculated + 2,
                }
            ],
        },
    ]
    for item in stations:
        observation = item["observations"][0]
        observation["temperature"] = observation.pop("temperature_c")
        observation["humidity"] = observation.pop("humidity_pct")
        observation["heat_index"] = observation.pop("reported_heat_index_c")

    report = validate_stations(stations)

    assert report["compared_station_count"] == 2
    assert report["metrics"]["mae_c"] == 1.0
    assert report["metrics"]["rmse_c"] == pytest.approx(
        round(math.sqrt(2), 2)
    )
    assert report["metrics"]["bias_c"] == -1.0
    assert report["metrics"]["within_1c_pct"] == 50.0
    assert report["metrics"]["within_2c_pct"] == 100.0
    assert report["category_agreement"]["total"] == 2


def test_validation_requires_comparable_observations():
    with pytest.raises(PAGASAValidationError):
        validate_stations(
            [
                {
                    "name": "Empty Station",
                    "latitude": 1.0,
                    "longitude": 2.0,
                    "observations": [],
                }
            ]
        )
