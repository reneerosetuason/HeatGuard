"""Tests for admin authentication, CSRF protection, and security headers."""

import pytest

from app import create_app
from services import security

REMOTE = {"REMOTE_ADDR": "203.0.113.10"}
LOCAL = {"REMOTE_ADDR": "127.0.0.1"}


@pytest.fixture()
def app():
    application = create_app()
    application.config.update(
        TESTING=True,
        SECRET_KEY="test-secret-key",
        ADMIN_USERNAME="admin",
        ADMIN_PASSWORD="correct horse battery staple",
        ALLOW_LOCAL_WRITES=True,
        CSRF_ENABLED=True,
        SESSION_COOKIE_SECURE=False,
        LOGIN_MAX_ATTEMPTS=5,
        LOGIN_WINDOW_SECONDS=900,
        WRITE_MAX_REQUESTS=60,
        WRITE_WINDOW_SECONDS=60,
    )
    security.configure_limiters(application)
    return application


@pytest.fixture()
def client(app):
    with app.test_client() as test_client:
        yield test_client


def csrf_token(client):
    client.get("/admin/login", environ_base=LOCAL)
    with client.session_transaction() as session:
        return session[security.CSRF_SESSION_KEY]


def login(client, username="admin", password="correct horse battery staple"):
    token = csrf_token(client)
    return client.post(
        "/admin/login",
        data={
            "username": username,
            "password": password,
            "csrf_token": token,
        },
        environ_base=LOCAL,
    )


@pytest.mark.parametrize(
    ("method", "path", "payload"),
    [
        (
            "post",
            "/api/locations",
            {"name": "Test", "latitude": 1, "longitude": 2},
        ),
        (
            "post",
            "/api/locations/address",
            {"region_code": "1300000000"},
        ),
        ("delete", "/api/locations/1", None),
        ("post", "/api/refresh", {"location_id": 1}),
    ],
)
def test_all_write_endpoints_require_authentication(
    client, method, path, payload
):
    response = getattr(client, method)(
        path,
        json=payload,
        environ_base=REMOTE,
    )

    assert response.status_code == 401
    assert response.get_json()["login_url"].endswith("/admin/login")


def test_remote_write_is_denied_when_no_admin_is_configured(app, client):
    app.config["ADMIN_PASSWORD"] = ""

    response = client.post(
        "/api/locations",
        json={"name": "Test", "latitude": 1, "longitude": 2},
        environ_base=REMOTE,
    )

    assert response.status_code == 403
    assert "restricted" in response.get_json()["error"]


def test_local_write_is_allowed_when_no_admin_is_configured(app, client):
    app.config.update(ADMIN_PASSWORD="", CSRF_ENABLED=False)

    response = client.post(
        "/api/locations",
        json={"name": "", "latitude": 1, "longitude": 2},
        environ_base=LOCAL,
    )

    assert response.status_code == 400
    assert "required" in response.get_json()["error"].lower()


def test_write_requires_csrf_when_enabled(app, client):
    app.config.update(ADMIN_PASSWORD="", CSRF_ENABLED=True)

    response = client.post(
        "/api/locations",
        json={"name": "Test", "latitude": 1, "longitude": 2},
        environ_base=LOCAL,
    )

    assert response.status_code == 400
    assert "Security token" in response.get_json()["error"]


def test_write_accepts_valid_csrf_token(app, client):
    app.config.update(ADMIN_PASSWORD="", CSRF_ENABLED=True)
    token = csrf_token(client)

    response = client.post(
        "/api/locations",
        json={"name": "", "latitude": 1, "longitude": 2},
        headers={"X-CSRF-Token": token},
        environ_base=LOCAL,
    )

    assert response.status_code == 400
    assert "Security token" not in response.get_json()["error"]


def test_remote_admin_can_write_after_login(client):
    assert login(client).status_code == 302
    with client.session_transaction() as session:
        token = session[security.CSRF_SESSION_KEY]

    response = client.post(
        "/api/locations",
        json={"name": "", "latitude": 1, "longitude": 2},
        headers={"X-CSRF-Token": token},
        environ_base=REMOTE,
    )

    assert response.status_code == 400
    assert "Security token" not in response.get_json()["error"]


def test_local_writes_can_be_disabled(app, client):
    app.config.update(
        ADMIN_PASSWORD="",
        ALLOW_LOCAL_WRITES=False,
        CSRF_ENABLED=False,
    )

    response = client.post(
        "/api/locations",
        json={"name": "Test", "latitude": 1, "longitude": 2},
        environ_base=LOCAL,
    )

    assert response.status_code == 403


def test_login_success_sets_hardened_session_cookie(client):
    response = login(client)

    assert response.status_code == 302
    cookie = response.headers.get("Set-Cookie", "")
    assert "HttpOnly" in cookie
    assert "SameSite=Lax" in cookie
    with client.session_transaction() as session:
        assert session[security.ADMIN_SESSION_KEY] is True


def test_login_rejects_invalid_password(client):
    response = login(client, password="wrong password")

    assert response.status_code == 401
    assert "Invalid username or password" in response.get_data(as_text=True)


def test_login_page_shows_configured_session_lifetime(app, client):
    app.config["SESSION_LIFETIME_HOURS"] = 3

    response = client.get("/admin/login", environ_base=LOCAL)

    assert response.status_code == 200
    assert "Sessions expire after 3 hours." in response.get_data(as_text=True)


@pytest.mark.parametrize(
    "next_url",
    [
        "https://evil.example",
        "//evil.example",
        "/\\evil.example",
        "/%5Cevil.example",
        "/%2F%2Fevil.example",
    ],
)
def test_login_rejects_unsafe_next_redirect(client, next_url):
    token = csrf_token(client)
    response = client.post(
        "/admin/login",
        data={
            "username": "admin",
            "password": "correct horse battery staple",
            "csrf_token": token,
            "next": next_url,
        },
        environ_base=LOCAL,
    )

    assert response.status_code == 302
    assert response.headers["Location"] == "/"


def test_login_rejects_missing_csrf(client):
    response = client.post(
        "/admin/login",
        data={"username": "admin", "password": "correct horse battery staple"},
        environ_base=LOCAL,
    )

    assert response.status_code == 400


def test_login_rate_limit_blocks_repeated_failures(app, client):
    app.config.update(LOGIN_MAX_ATTEMPTS=2)
    security.configure_limiters(app)

    assert login(client, password="wrong").status_code == 401
    assert login(client, password="wrong").status_code == 401
    blocked = login(client, password="wrong")

    assert blocked.status_code == 429
    assert int(blocked.headers["Retry-After"]) > 0


def test_logout_requires_csrf_and_clears_session(client):
    login(client)

    missing = client.post("/admin/logout", environ_base=LOCAL)
    assert missing.status_code == 400

    with client.session_transaction() as session:
        token = session[security.CSRF_SESSION_KEY]
    response = client.post(
        "/admin/logout",
        data={"csrf_token": token},
        environ_base=LOCAL,
    )

    assert response.status_code == 302
    with client.session_transaction() as session:
        assert security.ADMIN_SESSION_KEY not in session


def test_security_headers_include_csp_nonce(client):
    response = client.get("/admin/login", environ_base=LOCAL)
    csp = response.headers["Content-Security-Policy"]

    assert "default-src 'self'" in csp
    assert "nonce-" in csp
    assert "frame-ancestors 'self'" in csp
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["X-Frame-Options"] == "SAMEORIGIN"
    assert response.headers["Cache-Control"] == "no-store"
