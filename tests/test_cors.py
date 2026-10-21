"""Browser access for Flutter previews and explicitly configured frontends."""

import pytest

import config
from app import create_app


@pytest.fixture()
def app(monkeypatch):
    monkeypatch.setattr(config, "WEB_CORS_ORIGINS", ("https://dashboard.example",))
    application = create_app(allow_local_web_preview=True)
    application.config.update(
        TESTING=True,
        SECRET_KEY="cors-test-secret",
        ADMIN_PASSWORD="test-admin-password",
        CSRF_ENABLED=True,
    )
    return application


@pytest.fixture()
def client(app):
    return app.test_client()


@pytest.mark.parametrize(
    "origin",
    [
        "http://localhost:50518",
        "http://localhost:7357",
        "http://localhost:61001",
        "http://127.0.0.1:50518",
        "http://[::1]:50518",
        "https://localhost:50518",
        "http://localhost",
    ],
)
def test_development_accepts_changing_loopback_ports(client, origin):
    response = client.get("/api/mobile/config", headers={"Origin": origin})

    assert response.status_code == 200
    assert response.headers["Access-Control-Allow-Origin"] == origin
    assert response.headers["Access-Control-Allow-Credentials"] == "true"
    assert "Origin" in response.vary


@pytest.mark.parametrize(
    "origin",
    [
        "https://untrusted.example",
        "http://localhost.untrusted.example:50518",
        "http://127.0.0.1.untrusted.example:50518",
        "http://192.168.1.5:50518",
        "http://localhost:50518/path",
        "http://localhost:50518?query=1",
        "http://localhost:50518#fragment",
        "http://user@localhost:50518",
        "http://localhost:0",
        "http://localhost:65536",
        "file://localhost:50518",
        "null",
    ],
)
def test_development_rejects_non_loopback_and_invalid_origins(client, origin):
    response = client.get("/api/mobile/config", headers={"Origin": origin})

    assert "Access-Control-Allow-Origin" not in response.headers
    assert "Access-Control-Allow-Credentials" not in response.headers


def test_remote_request_cannot_use_local_preview_access(client):
    response = client.get(
        "/api/mobile/config",
        headers={"Origin": "http://localhost:50518"},
        environ_base={"REMOTE_ADDR": "203.0.113.10"},
    )

    assert "Access-Control-Allow-Origin" not in response.headers


def test_public_api_hostname_cannot_use_local_preview_access(client):
    response = client.get(
        "/api/mobile/config",
        base_url="https://heatguard.example",
        headers={"Origin": "http://localhost:50518"},
    )

    assert "Access-Control-Allow-Origin" not in response.headers


def test_production_factory_does_not_enable_local_preview_access(monkeypatch):
    monkeypatch.setattr(config, "WEB_CORS_ORIGINS", ())
    application = create_app()
    response = application.test_client().get(
        "/api/mobile/config", headers={"Origin": "http://localhost:50518"}
    )

    assert application.config["ALLOW_LOCAL_WEB_PREVIEW"] is False
    assert "Access-Control-Allow-Origin" not in response.headers


def test_configured_frontend_remains_allowed_for_remote_clients(client):
    response = client.get(
        "/api/mobile/config",
        headers={"Origin": "https://dashboard.example"},
        environ_base={"REMOTE_ADDR": "203.0.113.10"},
    )

    assert response.headers["Access-Control-Allow-Origin"] == "https://dashboard.example"


def test_local_preview_preflight_allows_the_registered_method(client):
    response = client.options(
        "/api/locations/1",
        headers={
            "Origin": "http://localhost:50518",
            "Access-Control-Request-Method": "DELETE",
            "Access-Control-Request-Headers": "X-CSRF-Token",
        },
    )

    assert response.status_code == 200
    assert response.headers["Access-Control-Allow-Origin"] == "http://localhost:50518"
    assert response.headers["Access-Control-Allow-Methods"] == "DELETE"
    assert "X-CSRF-Token" in response.headers["Access-Control-Allow-Headers"]


def test_local_preview_preflight_rejects_unregistered_methods(client):
    response = client.options(
        "/api/mobile/config",
        headers={
            "Origin": "http://localhost:50518",
            "Access-Control-Request-Method": "DELETE",
        },
    )

    assert "Access-Control-Allow-Origin" not in response.headers


@pytest.mark.parametrize("password, expected_status", [("test-admin", 401), ("", 400)])
def test_local_preview_still_requires_admin_and_csrf_for_writes(
    app, client, password, expected_status
):
    app.config["ADMIN_PASSWORD"] = password
    response = client.post(
        "/api/refresh",
        headers={"Origin": "http://localhost:50518"},
        json={"location_id": 1},
    )

    assert response.status_code == expected_status
    assert response.get_json()["ok"] is False
    assert response.headers["Access-Control-Allow-Origin"] == "http://localhost:50518"
