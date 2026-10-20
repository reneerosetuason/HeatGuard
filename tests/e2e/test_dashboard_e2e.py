"""Browser tests for the HeatGuard dashboard using Playwright."""

from __future__ import annotations

import os
import re
import threading
from contextlib import contextmanager
from datetime import datetime, timezone

import pytest

pytest.importorskip("playwright.sync_api")

from playwright.sync_api import expect  # noqa: E402
from werkzeug.serving import make_server  # noqa: E402

import config  # noqa: E402
from services import addresses as address_service
from services import dashboard as dashboard_service
from services import security
from services.risk import classify_heat_index, public_categories

pytestmark = pytest.mark.e2e

LOCATION = {
    "id": 1,
    "name": "Metro Manila",
    "latitude": 14.5995,
    "longitude": 120.9842,
    "timezone": "Asia/Manila",
}
NEW_LOCATION = {
    "id": 2,
    "name": "Barangay 1, Manila",
    "latitude": 14.5906,
    "longitude": 120.9811,
    "timezone": "Asia/Manila",
}
ADMIN_TEST_PASSWORD = "test-password-123"


def make_dashboard(location=LOCATION, locations=None):
    risk = classify_heat_index(38.1)
    return {
        "location": location,
        "locations": locations or [LOCATION],
        "last_success_at_display": "Oct 20, 2026 1:00 PM",
        "data_status": "ok",
        "status_message": "Current conditions are up to date.",
        "data_age_seconds": 120,
        "stale_after_seconds": 1800,
        "last_error": None,
        "current": {
            "temperature_c": 32.4,
            "humidity_pct": 68.0,
            "heat_index_c": 38.1,
            "observed_at_display": "Oct 20, 2026 12:50 PM",
            "fetched_at_display": "Oct 20, 2026 1:00 PM",
            "source": "open-meteo",
            "risk": risk,
        },
        "active_alert": None,
        "recommendations": risk["recommendations"],
        "alerts": [],
        "history": {"hours": 24, "points": []},
        "thresholds": public_categories(),
        "risk_source_url": config.HEAT_INDEX_SOURCE_URL,
        "disclaimer": config.SAFETY_DISCLAIMER,
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }


def _stub_services(monkeypatch):
    import app as app_module

    monkeypatch.setattr(
        dashboard_service,
        "build_dashboard",
        lambda location_id=None, hours=None: make_dashboard(),
    )
    monkeypatch.setattr(
        address_service,
        "list_regions",
        lambda: [{"code": "1300000000", "name": "National Capital Region"}],
    )
    monkeypatch.setattr(
        address_service,
        "list_provinces",
        lambda region_code: [{"code": "1300000000", "name": "Metro Manila"}],
    )
    monkeypatch.setattr(
        address_service,
        "list_cities",
        lambda province_code: [{"code": "1380600000", "name": "Manila"}],
    )
    monkeypatch.setattr(
        address_service,
        "list_barangays",
        lambda city_code: [
            {"code": "1380600001", "name": "Barangay 1"},
            {"code": "1380600002", "name": "Barangay 2"},
        ],
    )
    monkeypatch.setattr(
        address_service,
        "resolve_address",
        lambda **kwargs: {
            "name": NEW_LOCATION["name"],
            "latitude": NEW_LOCATION["latitude"],
            "longitude": NEW_LOCATION["longitude"],
            "timezone": NEW_LOCATION["timezone"],
            "region": {"code": "1300000000", "name": "National Capital Region"},
            "province": {"code": "1300000000", "name": "Metro Manila"},
            "city": {"code": "1380600000", "name": "Manila"},
            "barangay": {"code": "1380600001", "name": "Barangay 1"},
        },
    )
    monkeypatch.setattr(
        app_module,
        "_create_location_and_payload",
        lambda **kwargs: (
            NEW_LOCATION,
            make_dashboard(
                location=NEW_LOCATION, locations=[LOCATION, NEW_LOCATION]
            ),
        ),
    )

@contextmanager
def _live_server(monkeypatch, admin_password=""):
    _stub_services(monkeypatch)
    from app import create_app

    application = create_app(start_monitor=False)
    application.config.update(
        TESTING=False,
        ADMIN_PASSWORD=admin_password,
        ALLOW_LOCAL_WRITES=True,
        CSRF_ENABLED=True,
    )
    security.configure_limiters(application)

    server = make_server("127.0.0.1", 0, application, threaded=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


@pytest.fixture()
def live_server(monkeypatch):
    with _live_server(monkeypatch) as url:
        yield url


@pytest.fixture()
def admin_server(monkeypatch):
    with _live_server(monkeypatch, ADMIN_TEST_PASSWORD) as url:
        yield url


@pytest.fixture(scope="session")
def browser():
    sync_api = pytest.importorskip("playwright.sync_api")
    with sync_api.sync_playwright() as playwright:
        channel = os.getenv("PLAYWRIGHT_CHANNEL", "msedge")
        launch_options = {"headless": True}
        try:
            if channel:
                browser_instance = playwright.chromium.launch(
                    channel=channel, **launch_options
                )
            else:
                browser_instance = playwright.chromium.launch(**launch_options)
        except Exception:
            try:
                browser_instance = playwright.chromium.launch(**launch_options)
            except Exception as exc:
                pytest.skip(f"No Playwright browser is available: {exc}")
        yield browser_instance
        browser_instance.close()


@pytest.fixture()
def page(browser):
    page_instance = browser.new_page()
    page_errors = []
    console_errors = []
    page_instance.on("pageerror", lambda error: page_errors.append(str(error)))
    page_instance.on(
        "console",
        lambda message: console_errors.append(message.text)
        if message.type == "error"
        else None,
    )
    page_instance.errors = page_errors
    page_instance.console_errors = console_errors
    try:
        yield page_instance
    finally:
        page_instance.close()


def test_dashboard_loads_current_conditions(page, live_server):
    page.goto(live_server + "/", wait_until="networkidle")

    assert "Community Heat Watch" in page.title()
    assert page.locator("#headingLocation").inner_text() == "Metro Manila"
    assert page.locator("#heroHeatIndex").inner_text() == "38.1"
    assert page.locator("#metricHumidity").inner_text() == "68.0"
    assert page.locator("#heroRiskBadge").inner_text() == "Extreme Caution"
    assert page.locator("#addLocationButton").is_visible()
    assert page.errors == []
    assert page.console_errors == []


def test_add_location_through_address_picker(page, live_server):
    page.goto(live_server + "/", wait_until="networkidle")

    page.locator("#addLocationButton").click()
    page.locator("#locationModal.show").wait_for(timeout=5000)
    page.locator("#regionSelect").select_option("1300000000")

    expect(page.locator("#barangaySelect")).to_be_enabled()
    page.locator("#barangaySelect").select_option("1380600001")
    page.locator("#addressSubmit").click()

    expect(page.locator(".toast")).to_have_text(
        "Now monitoring Barangay 1, Manila."
    )
    assert page.locator("#headingLocation").inner_text() == "Barangay 1, Manila"
    assert page.locator("#locationSelect").input_value() == "2"
    assert page.errors == []
    assert page.console_errors == []


def test_admin_login_and_logout_control_writes(page, admin_server):
    page.goto(admin_server + "/", wait_until="networkidle")

    expect(page.locator(".read-only-note")).to_be_visible()
    assert page.locator("#addLocationButton").count() == 0

    page.locator(".read-only-note a").click()
    expect(page.locator("#loginTitle")).to_have_text("Admin sign in")
    expect(page.locator(".login-footnote")).to_contain_text(
        re.compile(r"Sessions expire after \d+ hours\.")
    )

    page.locator("#adminUsername").fill("admin")
    page.locator("#adminPassword").fill(ADMIN_TEST_PASSWORD)
    page.locator(".login-form button[type='submit']").click()
    page.wait_for_url(admin_server + "/")

    expect(page.locator("#addLocationButton")).to_be_visible()
    page.get_by_role("button", name="Sign out").click()
    expect(page.locator(".read-only-note")).to_be_visible()
    assert page.locator("#addLocationButton").count() == 0
    assert page.errors == []
    assert page.console_errors == []
    assert page.console_errors == []
