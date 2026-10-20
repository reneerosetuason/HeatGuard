"""Tests for Philippine address lookup and address-based location creation."""

import psgc
import pytest

from app import create_app
from services import addresses, db


def _ncr():
    region = next(
        item
        for item in addresses.list_regions()
        if item["name"].startswith("National Capital")
    )
    province = addresses.list_provinces(region["code"])[0]
    cities = addresses.list_cities(province["code"])
    return region, province, cities


def _sample_hierarchy():
    region, province, cities = _ncr()
    city = next(item for item in cities if item["name"] == "Quezon City")
    barangay = addresses.list_barangays(city["code"])[0]
    return region, province, city, barangay


def test_regions_and_ncr_hierarchy():
    region, province, cities = _ncr()

    assert region["name"].startswith("National Capital")
    assert province["name"].startswith("National Capital")
    assert province["is_pseudo"] is True
    assert len(cities) == 17
    assert any(city["name"] == "Quezon City" for city in cities)
    assert all(city["kind"] in {"city", "municipality"} for city in cities)


def test_resolve_address_returns_barangay_coordinates():
    region, province, city, barangay = _sample_hierarchy()

    resolved = addresses.resolve_address(
        region["code"],
        province["code"],
        city["code"],
        barangay["code"],
    )

    assert resolved["name"].startswith(barangay["name"])
    assert resolved["full_address"].startswith(barangay["name"])
    assert resolved["full_address"].endswith("Philippines")
    assert resolved["timezone"] == "Asia/Manila"
    assert 4 < resolved["latitude"] < 22
    assert 116 < resolved["longitude"] < 127
    assert resolved["psgc_codes"] == {
        "region": region["code"],
        "province": province["code"],
        "city": city["code"],
        "barangay": barangay["code"],
    }


def test_resolve_address_rejects_city_outside_province():
    region, province, cities = _ncr()
    city = next(item for item in cities if item["name"] == "Quezon City")
    other_city = next(item for item in cities if item["code"] != city["code"])
    barangay = addresses.list_barangays(city["code"])[0]

    with pytest.raises(addresses.AddressError, match="does not belong"):
        addresses.resolve_address(
            region["code"],
            province["code"],
            other_city["code"],
            barangay["code"],
        )


def test_resolve_address_rejects_barangay_outside_city():
    region, province, cities = _ncr()
    city = next(item for item in cities if item["name"] == "Quezon City")
    other_city = next(item for item in cities if item["code"] != city["code"])
    barangay = addresses.list_barangays(other_city["code"])[0]

    with pytest.raises(addresses.AddressError, match="does not belong"):
        addresses.resolve_address(
            region["code"],
            province["code"],
            city["code"],
            barangay["code"],
        )


def test_missing_region_is_rejected():
    with pytest.raises(addresses.AddressError, match="region"):
        addresses.list_provinces(None)


def test_resolve_address_rejects_province_outside_region():
    region, _, _, barangay = _sample_hierarchy()
    other_region = next(
        item
        for item in addresses.list_regions()
        if item["code"] != region["code"]
    )
    other_province = next(
        item
        for item in addresses.list_provinces(other_region["code"])
        if not item["is_pseudo"]
    )
    _, _, city, _ = _sample_hierarchy()

    with pytest.raises(addresses.AddressError, match="region"):
        addresses.resolve_address(
            region["code"],
            other_province["code"],
            city["code"],
            barangay["code"],
        )


def test_every_psgc_barangay_resolves():
    resolved = 0
    for province in psgc.provinces:
        region = province.region
        assert region is not None
        for city in province.cities:
            if not (city.is_city or city.is_municipality):
                continue
            assert city.barangays
            for barangay in city.barangays:
                result = addresses.resolve_address(
                    region.psgc_code,
                    province.psgc_code,
                    city.psgc_code,
                    barangay.psgc_code,
                )
                assert 4 < result["latitude"] < 22
                assert 114 < result["longitude"] < 127
                assert len(result["name"]) <= addresses.MAX_LOCATION_NAME
                resolved += 1

    assert resolved == 42010


@pytest.fixture()
def client():
    app = create_app()
    app.config.update(
        TESTING=True,
        CSRF_ENABLED=False,
        ADMIN_PASSWORD="",
        ALLOW_LOCAL_WRITES=True,
    )
    with app.test_client() as test_client:
        yield test_client


def test_address_listing_routes(client):
    region, province, city, _ = _sample_hierarchy()

    regions = client.get("/api/address/regions")
    assert regions.status_code == 200
    assert regions.get_json()["ok"] is True

    provinces = client.get(
        "/api/address/provinces", query_string={"region_code": region["code"]}
    )
    assert provinces.status_code == 200
    assert provinces.get_json()["provinces"]

    cities = client.get(
        "/api/address/cities",
        query_string={"province_code": province["code"]},
    )
    assert cities.status_code == 200
    assert any(
        item["code"] == city["code"] for item in cities.get_json()["cities"]
    )

    barangays = client.get(
        "/api/address/barangays",
        query_string={"city_code": city["code"]},
    )
    assert barangays.status_code == 200
    assert barangays.get_json()["barangays"]


def test_address_listing_requires_parent_code(client):
    response = client.get("/api/address/cities")
    assert response.status_code == 400
    assert response.get_json()["ok"] is False


def test_create_location_from_address(monkeypatch, client):
    region, province, city, barangay = _sample_hierarchy()
    created = {}

    def fake_create(**kwargs):
        created.update(kwargs)
        return {
            "id": 12,
            "name": kwargs["name"],
            "latitude": kwargs["latitude"],
            "longitude": kwargs["longitude"],
            "timezone": kwargs["timezone"],
        }

    monkeypatch.setattr(db, "create_location", fake_create)
    monkeypatch.setattr("app.monitor_location", lambda item: {"ok": True})
    monkeypatch.setattr(
        "app.dashboard_service.build_dashboard",
        lambda **kwargs: {"location": created},
    )

    response = client.post(
        "/api/locations/address",
        json={
            "region_code": region["code"],
            "province_code": province["code"],
            "city_code": city["code"],
            "barangay_code": barangay["code"],
        },
    )

    assert response.status_code == 201
    body = response.get_json()
    assert body["ok"] is True
    assert body["location"]["id"] == 12
    assert body["address"]["barangay"] == barangay["name"]
    assert body["address"]["city"] == city["name"]
    assert created["name"] == body["address"]["name"]
    assert created["timezone"] == "Asia/Manila"
    assert created["latitude"] == body["address"]["latitude"]
    assert created["longitude"] == body["address"]["longitude"]


def test_create_location_from_address_rejects_non_object_json(client):
    response = client.post("/api/locations/address", json=["not", "an", "object"])
    assert response.status_code == 400
    assert response.get_json()["ok"] is False


def test_create_location_from_address_rejects_invalid_choice(client):
    response = client.post(
        "/api/locations/address",
        json={
            "region_code": "not-a-code",
            "province_code": "not-a-code",
            "city_code": "not-a-code",
            "barangay_code": "not-a-code",
        },
    )
    assert response.status_code == 400
    assert response.get_json()["ok"] is False
