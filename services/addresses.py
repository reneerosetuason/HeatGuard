"""Philippine address lookup built on the PSA PSGC masterlist.

The ``psgc`` package bundles regions, provinces, cities/municipalities, and
barangays with centroid coordinates. Keeping the data local makes the address
dropdowns fast and independent of a third-party API at request time.
"""

from __future__ import annotations

import logging
import re
from typing import Any

import psgc
from psgc.models import Barangay, City, Province, Region

logger = logging.getLogger(__name__)

TIMEZONE = "Asia/Manila"
MAX_LOCATION_NAME = 120


class AddressError(ValueError):
    """Raised when an address component is missing or inconsistent."""


_REGIONS = {region.psgc_code: region for region in psgc.regions}
_PROVINCES = {province.psgc_code: province for province in psgc.provinces}
_CITIES = {city.psgc_code: city for city in psgc.cities}
_BARANGAYS = {barangay.psgc_code: barangay for barangay in psgc.barangays}

_BY_LEVEL: dict[type, dict[str, Any]] = {
    Region: _REGIONS,
    Province: _PROVINCES,
    City: _CITIES,
    Barangay: _BARANGAYS,
}


def _lookup(code: str | None, expected_type: type, label: str) -> Any:
    value = str(code).strip() if code is not None else ""
    if not value:
        raise AddressError(f"Please select a {label}.")
    place = _BY_LEVEL[expected_type].get(value)
    if place is None:
        raise AddressError(f"The selected {label} was not found.")
    return place


def _sorted(items: list[dict]) -> list[dict]:
    return sorted(items, key=lambda item: (item["name"].casefold(), item["code"]))


def list_regions() -> list[dict]:
    return [
        {
            "code": region.psgc_code,
            "name": region.name,
        }
        for region in psgc.regions
    ]


def list_provinces(region_code: str | None) -> list[dict]:
    region = _lookup(region_code, Region, "region")
    provinces = [
        {
            "code": province.psgc_code,
            "name": province.name,
            "is_pseudo": bool(province.is_pseudo),
        }
        for province in region.provinces
    ]
    return _sorted(provinces)


def list_cities(province_code: str | None) -> list[dict]:
    province = _lookup(province_code, Province, "province or district")
    cities = [
        {
            "code": city.psgc_code,
            "name": city.name,
            "kind": "city" if city.is_city else "municipality",
        }
        for city in province.cities
        if city.is_city or city.is_municipality
    ]
    return _sorted(cities)


def list_barangays(city_code: str | None) -> list[dict]:
    city = _lookup(city_code, City, "city or municipality")
    if not (city.is_city or city.is_municipality):
        raise AddressError("The selected city or municipality is not valid.")
    barangays = [
        {
            "code": barangay.psgc_code,
            "name": barangay.name,
        }
        for barangay in city.barangays
    ]
    return _sorted(barangays)


def _parentheses_removed(value: str) -> str:
    return re.sub(r"\s*\([^)]*\)", "", value or "").strip().casefold()


def _province_label(
    province: Province,
    city: City,
    region: Region,
) -> str | None:
    """Return a province name only when it adds useful information."""

    if province.name.casefold() == region.name.casefold():
        return None
    if (
        province.is_pseudo
        and _parentheses_removed(province.name)
        == _parentheses_removed(city.name)
    ):
        return None
    return province.name


def _join_components(parts: list[str | None]) -> str:
    deduped: list[str] = []
    for part in parts:
        if not part:
            continue
        if deduped and deduped[-1].casefold() == part.casefold():
            continue
        deduped.append(part)
    return ", ".join(deduped)


def _short_name(
    barangay: Barangay,
    city: City,
    province_label: str | None,
) -> str:
    name = _join_components([barangay.name, city.name, province_label])
    if len(name) > MAX_LOCATION_NAME:
        name = name[: MAX_LOCATION_NAME - 4].rstrip(" ,") + " ..."
    return name


def _full_address(
    barangay: Barangay,
    city: City,
    province_label: str | None,
    region: Region,
) -> str:
    return _join_components(
        [barangay.name, city.name, province_label, region.name, "Philippines"]
    )


def resolve_address(
    region_code: str | None,
    province_code: str | None,
    city_code: str | None,
    barangay_code: str | None,
) -> dict:
    """Validate a PSGC hierarchy and return a monitorable location."""

    region = _lookup(region_code, Region, "region")
    province = _lookup(province_code, Province, "province or district")
    city = _lookup(city_code, City, "city or municipality")
    barangay = _lookup(barangay_code, Barangay, "barangay")

    if province.region is None or province.region.psgc_code != region.psgc_code:
        raise AddressError("The selected province does not belong to that region.")
    if city.province_code != province.psgc_code:
        raise AddressError("The selected city does not belong to that province.")
    if not (city.is_city or city.is_municipality):
        raise AddressError("The selected city or municipality is not valid.")
    if barangay_code not in {item.psgc_code for item in city.barangays}:
        raise AddressError("The selected barangay does not belong to that city.")

    coordinate = barangay.coordinate or city.coordinate
    if coordinate is None:
        logger.warning("No coordinates available for %s", barangay.psgc_code)
        raise AddressError("Coordinates are unavailable for the selected address.")
    try:
        latitude = round(float(coordinate.latitude), 6)
        longitude = round(float(coordinate.longitude), 6)
    except (TypeError, ValueError) as exc:
        raise AddressError("Coordinates are unavailable for the selected address.") from exc

    province_label = _province_label(province, city, region)
    name = _short_name(barangay, city, province_label)
    return {
        "name": name,
        "full_address": _full_address(
            barangay, city, province_label, region
        ),
        "latitude": latitude,
        "longitude": longitude,
        "timezone": TIMEZONE,
        "barangay": barangay.name,
        "city": city.name,
        "province": province.name,
        "region": region.name,
        "psgc_codes": {
            "region": region.psgc_code,
            "province": province.psgc_code,
            "city": city.psgc_code,
            "barangay": barangay.psgc_code,
        },
    }
