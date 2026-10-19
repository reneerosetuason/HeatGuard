from datetime import datetime, timedelta, timezone

import pytest

import config
from services import dashboard as dashboard_service

LOCATION = {
    "id": 1,
    "name": "Metro Manila",
    "latitude": 14.5995,
    "longitude": 120.9842,
    "timezone": "Asia/Manila",
    "is_active": 1,
}


def make_reading(hours_ago, temperature=34.0, humidity=75.0, heat_index=43.0):
    observed = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(
        hours=hours_ago
    )
    return {
        "id": 10,
        "location_id": 1,
        "observed_at": observed,
        "fetched_at": observed + timedelta(minutes=1),
        "temperature_c": temperature,
        "humidity_pct": humidity,
        "heat_index_c": heat_index,
        "risk_key": "danger",
        "risk_label": "Danger",
        "risk_source": "open-meteo",
        "source": "open-meteo",
        "api_timezone": "Asia/Manila",
        "location_name": "Metro Manila",
    }


def patch_db(monkeypatch, reading=None, status=None, alerts=None, alerts_for_risk=None):
    history = [reading] if reading else []
    monkeypatch.setattr(
        dashboard_service.db, "get_locations", lambda active_only=True: [LOCATION]
    )
    monkeypatch.setattr(
        dashboard_service.db, "get_latest_reading", lambda location_id: reading
    )
    monkeypatch.setattr(
        dashboard_service.db,
        "get_monitoring_status",
        lambda location_id: status or {},
    )
    monkeypatch.setattr(
        dashboard_service.db,
        "get_recent_alerts",
        lambda location_id, limit=20: alerts or [],
    )
    monkeypatch.setattr(
        dashboard_service.db,
        "get_readings_since",
        lambda location_id, since: history,
    )
    monkeypatch.setattr(
        dashboard_service.db,
        "get_latest_alert_for_risk",
        lambda location_id, risk_key: alerts_for_risk,
    )


def test_no_data_is_not_classified_as_safe(monkeypatch):
    patch_db(monkeypatch)

    dashboard = dashboard_service.build_dashboard(location_id=1, hours=24)

    assert dashboard["data_status"] == "no_data"
    assert dashboard["current"] is None
    assert dashboard["active_alert"] is None
    assert dashboard["recommendations"] == config.UNKNOWN_RECOMMENDATIONS
    assert "not treated as a safe" in dashboard["status_message"]


def test_stale_reading_is_not_treated_as_current(monkeypatch):
    reading = make_reading(hours_ago=2)
    patch_db(
        monkeypatch,
        reading=reading,
        status={
            "last_success_at": reading["fetched_at"],
            "last_attempt_at": reading["fetched_at"],
        },
    )

    dashboard = dashboard_service.build_dashboard(location_id=1, hours=24)

    assert dashboard["data_status"] == "stale"
    assert dashboard["current"]["risk"]["last_known"] is True
    assert dashboard["active_alert"] is None
    assert dashboard["recommendations"] == config.UNKNOWN_RECOMMENDATIONS


def test_fresh_warning_creates_banner_fallback(monkeypatch):
    reading = make_reading(hours_ago=0.05)
    patch_db(
        monkeypatch,
        reading=reading,
        status={
            "last_success_at": reading["fetched_at"],
            "last_attempt_at": reading["fetched_at"],
        },
    )

    dashboard = dashboard_service.build_dashboard(location_id=1, hours=24)

    assert dashboard["data_status"] == "ok"
    assert dashboard["current"]["risk"]["key"] == "danger"
    assert dashboard["active_alert"] is not None
    assert dashboard["active_alert"]["risk_key"] == "danger"
    assert dashboard["recommendations"]


def test_history_points_are_returned(monkeypatch):
    reading = make_reading(hours_ago=0.1)
    patch_db(
        monkeypatch,
        reading=reading,
        status={
            "last_success_at": reading["fetched_at"],
            "last_attempt_at": reading["fetched_at"],
        },
    )

    dashboard = dashboard_service.build_dashboard(location_id=1, hours=24)

    assert dashboard["history"]["count"] == 1
    point = dashboard["history"]["points"][0]
    assert point["risk_key"] == "danger"
    assert point["risk_level"] == 3
    assert point["temperature_c"] == pytest.approx(34.0)
