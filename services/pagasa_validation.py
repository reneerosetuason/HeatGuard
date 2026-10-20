"""Validate HeatGuard's calculated heat index against PAGASA station data.

PAGASA publishes the Automatic Weather Station heat-index map through
PANaHON. The map page embeds a JSON array of station observations in one of
its scripts. This module extracts that public data and compares PAGASA's
reported heat index with HeatGuard's Rothfusz calculation using the same
temperature and relative humidity.
"""

from __future__ import annotations

import json
import math
from datetime import datetime, timezone

import requests

import config
from services.heat_index import HeatIndexError, calculate_heat_index_c
from services.risk import RiskClassificationError, classify_heat_index


PAGASA_HEAT_INDEX_URL = (
    "https://www.pagasa.dost.gov.ph/weather/heat-index"
)
PANAHON_HEAT_INDEX_URL = "https://www.panahon.gov.ph/heat_index.html"
STATION_MARKER = '[{"sitename":'


class PAGASAValidationError(RuntimeError):
    """Raised when PAGASA/PANaHON data cannot be fetched or parsed."""


def _parse_float(value, field_name: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise PAGASAValidationError(
            f"Invalid {field_name} in PAGASA station data"
        ) from exc
    if not math.isfinite(number):
        raise PAGASAValidationError(
            f"Non-finite {field_name} in PAGASA station data"
        )
    return number


def _find_js_string_end(text: str, start: int) -> int:
    """Return the closing quote index for a single-quoted JavaScript string."""

    index = start + 1
    escaped = False
    while index < len(text):
        character = text[index]
        if escaped:
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == "'":
            return index
        index += 1
    raise PAGASAValidationError("PAGASA station data string is not terminated")


def extract_station_data(html: str) -> list[dict]:
    """Extract and validate station observations from PANaHON HTML."""

    start = html.find(STATION_MARKER)
    if start < 0:
        raise PAGASAValidationError(
            "PANaHON page did not contain the expected station data"
        )

    if start > 0 and html[start - 1] == "'":
        end = _find_js_string_end(html, start - 1)
        raw = html[start:end]
    else:
        decoder = json.JSONDecoder()
        try:
            data, _ = decoder.raw_decode(html[start:])
        except json.JSONDecodeError as exc:
            raise PAGASAValidationError(
                "PANaHON station data is not valid JSON"
            ) from exc
        return _validate_stations(data)

    raw = raw.replace("\\'", "'")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PAGASAValidationError(
            "PANaHON station data is not valid JSON"
        ) from exc
    return _validate_stations(data)


def _validate_stations(data) -> list[dict]:
    if not isinstance(data, list) or not data:
        raise PAGASAValidationError("PANaHON station data is empty")

    stations: list[dict] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        name = str(item.get("sitename") or "").strip()
        if not name:
            continue
        try:
            latitude = _parse_float(item.get("lat"), "latitude")
            longitude = _parse_float(item.get("lng"), "longitude")
        except PAGASAValidationError:
            continue
        observations = item.get("data")
        if not isinstance(observations, list):
            continue
        stations.append(
            {
                "name": name,
                "latitude": latitude,
                "longitude": longitude,
                "data_as_of": item.get("data_as_of"),
                "observations": observations,
            }
        )

    if not stations:
        raise PAGASAValidationError(
            "PANaHON station data did not contain usable stations"
        )
    return stations


def latest_observation(station: dict) -> dict | None:
    """Return the newest usable observation for one station."""

    latest = None
    for raw in station.get("observations") or []:
        if not isinstance(raw, dict):
            continue
        observed_at = str(raw.get("observed_at") or "").strip()
        try:
            temperature_c = _parse_float(
                raw.get("temperature"), "temperature"
            )
            humidity_pct = _parse_float(raw.get("humidity"), "humidity")
            reported_heat_index = _parse_float(
                raw.get("heat_index"), "heat index"
            )
            datetime.fromisoformat(observed_at)
        except (PAGASAValidationError, ValueError):
            continue
        if not -50.0 <= temperature_c <= 60.0:
            continue
        if not 0.0 <= humidity_pct <= 100.0:
            continue
        if not -50.0 <= reported_heat_index <= 80.0:
            continue
        candidate = {
            "observed_at": observed_at,
            "temperature_c": round(temperature_c, 1),
            "humidity_pct": round(humidity_pct, 1),
            "reported_heat_index_c": round(reported_heat_index, 1),
        }
        if latest is None or candidate["observed_at"] >= latest["observed_at"]:
            latest = candidate
    return latest


def _percentage(count: int, total: int) -> float:
    return round((count / total * 100.0) if total else 0.0, 1)


def validate_stations(stations: list[dict]) -> dict:
    """Compare calculated and PAGASA-reported heat indexes."""

    comparisons: list[dict] = []
    skipped = 0
    for station in stations:
        observation = latest_observation(station)
        if observation is None:
            skipped += 1
            continue
        try:
            calculated = calculate_heat_index_c(
                observation["temperature_c"], observation["humidity_pct"]
            )
            reported_risk = classify_heat_index(
                observation["reported_heat_index_c"]
            )
            calculated_risk = classify_heat_index(calculated)
        except (HeatIndexError, RiskClassificationError):
            skipped += 1
            continue

        difference = round(calculated - observation["reported_heat_index_c"], 2)
        comparisons.append(
            {
                "station": station["name"],
                "data_as_of": station.get("data_as_of"),
                **observation,
                "calculated_heat_index_c": calculated,
                "difference_c": difference,
                "reported_risk": reported_risk["label"],
                "calculated_risk": calculated_risk["label"],
                "category_match": reported_risk["key"] == calculated_risk["key"],
            }
        )

    if not comparisons:
        raise PAGASAValidationError(
            "No PAGASA observations could be compared"
        )

    total = len(comparisons)
    differences = [item["difference_c"] for item in comparisons]
    absolute = [abs(value) for value in differences]
    squared = [value * value for value in differences]
    mape_values = [
        abs(item["difference_c"])
        / item["reported_heat_index_c"]
        * 100.0
        for item in comparisons
        if item["reported_heat_index_c"]
    ]
    category_matches = sum(
        1 for item in comparisons if item["category_match"]
    )

    confusion: dict[str, dict[str, int]] = {}
    for item in comparisons:
        reported = item["reported_risk"]
        calculated = item["calculated_risk"]
        confusion.setdefault(reported, {})
        confusion[reported][calculated] = (
            confusion[reported].get(calculated, 0) + 1
        )

    top_deviations = sorted(
        comparisons, key=lambda item: abs(item["difference_c"]), reverse=True
    )[:5]

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "name": "DOST-PAGASA / PANaHON Automatic Weather Station heat index",
            "url": PAGASA_HEAT_INDEX_URL,
            "station_data_url": PANAHON_HEAT_INDEX_URL,
        },
        "station_count": len(stations),
        "compared_station_count": total,
        "skipped_station_count": skipped,
        "metrics": {
            "mae_c": round(sum(absolute) / total, 2),
            "rmse_c": round(math.sqrt(sum(squared) / total), 2),
            "bias_c": round(sum(differences) / total, 2),
            "mape_pct": round(sum(mape_values) / len(mape_values), 2)
            if mape_values
            else None,
            "within_1c_pct": _percentage(
                sum(1 for value in absolute if value <= 1.0), total
            ),
            "within_2c_pct": _percentage(
                sum(1 for value in absolute if value <= 2.0), total
            ),
        },
        "category_agreement": {
            "matches": category_matches,
            "total": total,
            "agreement_pct": _percentage(category_matches, total),
            "confusion": confusion,
        },
        "largest_deviations": top_deviations,
        "comparisons": comparisons,
    }


def fetch_panahon_html(timeout: int | None = None) -> str:
    try:
        response = requests.get(
            PANAHON_HEAT_INDEX_URL,
            timeout=timeout or config.WEATHER_API_TIMEOUT_SECONDS,
            headers={
                "User-Agent": "HeatGuard/1.0 (college project validation)"
            },
        )
    except requests.RequestException as exc:
        raise PAGASAValidationError(
            f"PAGASA/PANaHON request failed: {exc}"
        ) from exc
    if response.status_code >= 400:
        raise PAGASAValidationError(
            f"PAGASA/PANaHON returned HTTP {response.status_code}"
        )
    return response.text


def fetch_and_validate(timeout: int | None = None) -> dict:
    return validate_stations(extract_station_data(fetch_panahon_html(timeout)))
