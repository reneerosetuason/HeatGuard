"""Tests for the location-management API routes."""

import pytest

from app import create_app
from services import db


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


def test_cannot_remove_last_location(monkeypatch, client):
    monkeypatch.setattr(db, "count_active_locations", lambda: 1)
    response = client.delete("/api/locations/1")
    assert response.status_code == 400
    body = response.get_json()
    assert body["ok"] is False
    assert "must remain" in body["error"]


def test_remove_location(monkeypatch, client):
    monkeypatch.setattr(db, "count_active_locations", lambda: 3)
    monkeypatch.setattr(db, "deactivate_location", lambda location_id: True)
    response = client.delete("/api/locations/2")
    assert response.status_code == 200
    assert response.get_json() == {"ok": True, "deactivated": 2}


def test_remove_missing_location(monkeypatch, client):
    monkeypatch.setattr(db, "count_active_locations", lambda: 3)
    monkeypatch.setattr(db, "deactivate_location", lambda location_id: False)
    response = client.delete("/api/locations/999")
    assert response.status_code == 404


def test_geocode_requires_two_characters(client):
    response = client.get("/api/geocode?q=a")
    assert response.status_code == 200
    assert response.get_json()["results"] == []


def test_create_location_rejects_blank_name(client):
    response = client.post(
        "/api/locations", json={"name": "", "latitude": 1.0, "longitude": 2.0}
    )
    assert response.status_code == 400
    assert response.get_json()["ok"] is False


def test_create_location_rejects_non_string_name(client):
    response = client.post(
        "/api/locations", json={"name": 123, "latitude": 1.0, "longitude": 2.0}
    )
    assert response.status_code == 400
    assert response.get_json()["ok"] is False


def test_create_location_success(monkeypatch, client):
    location = {
        "id": 9,
        "name": "Test City",
        "latitude": 1.0,
        "longitude": 2.0,
        "timezone": "Asia/Manila",
    }
    monkeypatch.setattr(db, "create_location", lambda **kwargs: location)
    monkeypatch.setattr("app.monitor_location", lambda item: {"ok": True})
    monkeypatch.setattr(
        "app.dashboard_service.build_dashboard", lambda **kwargs: {"location": location}
    )
    response = client.post(
        "/api/locations",
        json={
            "name": "Test City",
            "latitude": 1.0,
            "longitude": 2.0,
            "timezone": "Asia/Manila",
        },
    )
    assert response.status_code == 201
    body = response.get_json()
    assert body["ok"] is True
    assert body["location"]["id"] == 9
    assert body["dashboard"]["location"]["name"] == "Test City"


def test_create_location_rejects_bad_coordinates(client):
    response = client.post(
        "/api/locations", json={"name": "Nowhere", "latitude": 999, "longitude": 2}
    )
    assert response.status_code == 400
    assert response.get_json()["ok"] is False


def test_create_location_rejects_non_object_json(client):
    response = client.post("/api/locations", json=["not", "an", "object"])
    assert response.status_code == 400
    assert response.get_json()["ok"] is False
