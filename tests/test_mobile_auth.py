"""Exercise real account SQL and HTTP flows against an isolated test database."""

from contextlib import contextmanager
from datetime import datetime, timedelta
import sqlite3

import pytest

from app import create_app
from services import db, email_delivery, mobile_accounts as accounts, mobile_auth, security


class Cursor:
    def __init__(self, connection):
        self.cursor = connection.cursor()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.cursor.close()

    def execute(self, sql, values=()):
        self.cursor.execute(sql.replace("%s", "?").replace(" FOR UPDATE", "").replace("INSERT IGNORE", "INSERT OR IGNORE"), values)

    def fetchone(self):
        row = self.cursor.fetchone()
        return dict(row) if row else None

    def fetchall(self):
        return [dict(row) for row in self.cursor.fetchall()]

    @property
    def rowcount(self):
        return self.cursor.rowcount

    @property
    def lastrowid(self):
        return self.cursor.lastrowid


class Connection:
    def __init__(self, connection):
        self.connection = connection

    def cursor(self):
        return Cursor(self.connection)


@pytest.fixture()
def state(monkeypatch):
    sqlite3.register_adapter(datetime, lambda value: value.isoformat(" "))
    sqlite3.register_converter("DATETIME", lambda value: datetime.fromisoformat(value.decode()))
    database = sqlite3.connect(":memory:", detect_types=sqlite3.PARSE_DECLTYPES)
    database.row_factory = sqlite3.Row
    database.executescript("""
        CREATE TABLE mobile_users (
            id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, display_name TEXT,
            password_hash TEXT, email_verified_at DATETIME, created_at DATETIME);
        CREATE TABLE mobile_registration_challenges (
            challenge_id TEXT PRIMARY KEY, email TEXT UNIQUE, display_name TEXT,
            password_hash TEXT, code_hash TEXT, code_expires_at DATETIME,
            attempts INTEGER DEFAULT 0, resend_after DATETIME,
            send_count INTEGER, send_window_started_at DATETIME, created_at DATETIME);
        CREATE TABLE mobile_user_sessions (
            token_hash TEXT PRIMARY KEY, user_id INTEGER,
            expires_at DATETIME, created_at DATETIME);
    """)

    @contextmanager
    def connection():
        try:
            yield Connection(database)
            database.commit()
        except Exception:
            database.rollback()
            raise

    monkeypatch.setattr(db, "connection", connection)
    monkeypatch.setattr(email_delivery, "smtp_configured", lambda: True)
    emails = []
    monkeypatch.setattr(email_delivery, "send_verification_code", lambda email, name, code: emails.append((email, name, code)))
    monkeypatch.setattr(mobile_auth, "send_limiter", security.RateLimiter(10, 3600))
    monkeypatch.setattr(mobile_auth, "login_limiter", security.RateLimiter(10, 900))
    monkeypatch.setattr(mobile_auth, "email_login_limiter", security.RateLimiter(10, 900))
    monkeypatch.setattr(mobile_auth, "verify_limiter", security.RateLimiter(30, 900))
    application = create_app(allow_local_web_preview=True)
    application.config.update(TESTING=True, SECRET_KEY="a-long-random-test-secret-for-account-tests", ADMIN_PASSWORD="admin-test", CSRF_ENABLED=True)
    yield application.test_client(), database, emails
    database.close()


def post(client, action, **data):
    csrf = client.get("/api/mobile/auth/session").json["csrf_token"]
    return client.post("/api/mobile/auth/" + action, data={"csrf_token": csrf, **data})


def register(client):
    return post(client, "register", name="Alex", email="  ALEX@example.com ", password="a good long password")


def verify(client, emails, challenge, device="native"):
    return post(client, "verify", challenge_id=challenge["challenge_id"], code=emails[-1][2], device=device)


def test_no_account_or_dashboard_access_until_email_is_verified(state):
    client, database, emails = state
    response = register(client)
    assert response.status_code == 202
    challenge = response.json["challenge"]
    assert challenge["email"] == "alex@example.com"
    assert emails[0][0] == "alex@example.com"
    assert len(emails[0][2]) == 6 and emails[0][2].isdigit()
    assert database.execute("SELECT COUNT(*) FROM mobile_users").fetchone()[0] == 0
    pending = database.execute("SELECT * FROM mobile_registration_challenges").fetchone()
    assert pending["password_hash"].startswith("scrypt:")
    assert pending["code_hash"] != emails[0][2]
    assert emails[0][2] not in response.get_data(as_text=True)
    assert post(client, "login", email="alex@example.com", password="a good long password").status_code == 401
    assert client.get("/api/mobile/data/dashboard").status_code == 401
    assert client.get("/api/mobile/data/locations").json["error_code"] == "authentication_required"

    result = verify(client, emails, challenge)
    assert result.status_code == 200
    assert result.json["user"]["email_verified"] is True
    assert database.execute("SELECT COUNT(*) FROM mobile_users").fetchone()[0] == 1
    assert database.execute("SELECT COUNT(*) FROM mobile_registration_challenges").fetchone()[0] == 0
    assert database.execute("SELECT token_hash FROM mobile_user_sessions").fetchone()[0] != result.json["token"]
    assert verify(client, emails, challenge).status_code == 400


def test_wrong_codes_commit_attempts_and_lock_out_after_five(state):
    client, database, emails = state
    challenge = register(client).json["challenge"]
    wrong = f"{(int(emails[0][2]) + 1) % 1_000_000:06d}"
    for _ in range(5):
        assert post(client, "verify", challenge_id=challenge["challenge_id"], code=wrong).status_code == 400
    assert database.execute("SELECT attempts FROM mobile_registration_challenges").fetchone()[0] == 5
    assert verify(client, emails, challenge).status_code == 429
    assert database.execute("SELECT COUNT(*) FROM mobile_users").fetchone()[0] == 0


def test_expired_code_cannot_create_an_account(state, monkeypatch):
    client, database, emails = state
    challenge = register(client).json["challenge"]
    future = accounts.utcnow() + timedelta(minutes=11)
    monkeypatch.setattr(accounts, "utcnow", lambda: future)
    response = verify(client, emails, challenge)
    assert response.status_code == 400
    assert "expired" in response.json["error"]
    assert database.execute("SELECT COUNT(*) FROM mobile_users").fetchone()[0] == 0


def test_resend_has_cooldown_and_invalidates_previous_code(state, monkeypatch):
    client, database, emails = state
    codes = iter([123456, 234567])
    monkeypatch.setattr(accounts.secrets, "randbelow", lambda _: next(codes))
    challenge = register(client).json["challenge"]
    assert post(client, "resend", challenge_id=challenge["challenge_id"]).status_code == 429
    assert len(emails) == 1
    future = accounts.utcnow() + timedelta(seconds=61)
    monkeypatch.setattr(accounts, "utcnow", lambda: future)
    assert post(client, "resend", challenge_id=challenge["challenge_id"]).status_code == 200
    assert len(emails) == 2
    assert post(client, "verify", challenge_id=challenge["challenge_id"], code="123456").status_code == 400
    assert verify(client, emails, challenge).status_code == 200


def test_email_limit_applies_across_restarted_registrations(state, monkeypatch):
    client, database, emails = state
    start = accounts.utcnow()
    for index in range(5):
        monkeypatch.setattr(accounts, "utcnow", lambda index=index: start + timedelta(seconds=61 * index))
        assert register(client).status_code == 202
    monkeypatch.setattr(accounts, "utcnow", lambda: start + timedelta(seconds=61 * 5))
    assert register(client).status_code == 429
    assert len(emails) == 5


def test_failed_email_delivery_rolls_back_registration(state, monkeypatch):
    client, database, _ = state
    def fail(*_):
        raise email_delivery.EmailDeliveryError("Email could not be sent.")
    monkeypatch.setattr(email_delivery, "send_verification_code", fail)
    assert register(client).status_code == 503
    assert database.execute("SELECT COUNT(*) FROM mobile_registration_challenges").fetchone()[0] == 0
    assert database.execute("SELECT COUNT(*) FROM mobile_users").fetchone()[0] == 0


def test_native_session_is_authenticated_expiring_and_revocable(state, monkeypatch):
    client, database, emails = state
    challenge = register(client).json["challenge"]
    token = verify(client, emails, challenge).json["token"]
    headers = {"Authorization": "Bearer " + token}
    assert client.get("/api/mobile/auth/session", headers=headers).json["user"]["email_verified"] is True
    monkeypatch.setattr(db, "get_locations", lambda **_: [])
    assert client.get("/api/mobile/data/locations", headers=headers).status_code == 200
    csrf = client.get("/api/mobile/auth/session", headers=headers).json["csrf_token"]
    assert client.post("/api/mobile/auth/logout", data={"csrf_token": csrf}, headers=headers).status_code == 200
    assert client.get("/api/mobile/data/locations", headers=headers).status_code == 401
    token = post(client, "login", email="alex@example.com", password="a good long password", device="native").json["token"]
    future = accounts.utcnow() + timedelta(days=8)
    monkeypatch.setattr(accounts, "utcnow", lambda: future)
    assert client.get("/api/mobile/data/locations", headers={"Authorization": "Bearer " + token}).status_code == 401


def test_browser_uses_http_only_cookie_and_logout_blocks_access(state, monkeypatch):
    client, _, emails = state
    challenge = register(client).json["challenge"]
    result = verify(client, emails, challenge, device="web")
    assert "token" not in result.json
    cookie = next(value for value in result.headers.getlist("Set-Cookie") if value.startswith(mobile_auth.COOKIE_NAME))
    assert "HttpOnly" in cookie and "SameSite=Lax" in cookie
    monkeypatch.setattr(db, "get_locations", lambda **_: [])
    assert client.get("/api/mobile/data/locations").status_code == 200
    assert post(client, "logout").status_code == 200
    assert client.get("/api/mobile/data/locations").status_code == 401


def test_missing_csrf_and_password_mismatch_cannot_authenticate(state):
    client, _, emails = state
    assert client.post("/api/mobile/auth/register", data={}).status_code == 400
    challenge = register(client).json["challenge"]
    assert verify(client, emails, challenge).status_code == 200
    assert post(client, "login", email="alex@example.com", password="incorrect password", device="native").status_code == 401


@pytest.mark.parametrize("email", ["invalid", "a\r\nbcc:x@example.com", "a@localhost", ".a@example.com", "a..b@example.com"])
def test_invalid_registration_input_sends_no_email(state, email):
    client, _, emails = state
    assert post(client, "register", name="Alex", email=email, password="a good long password").status_code == 400
    assert not emails


def test_mobile_preflight_supports_bearer_authentication(state):
    client, _, _ = state
    result = client.options("/api/mobile/data/dashboard", headers={
        "Origin": "http://localhost:50518", "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "Authorization",
    })
    assert result.status_code == 200
    assert "Authorization" in result.headers["Access-Control-Allow-Headers"]
    assert result.headers["Access-Control-Allow-Origin"] == "http://localhost:50518"


def test_correct_password_does_not_unlock_an_unverified_database_user(state):
    client, database, emails = state
    challenge = register(client).json["challenge"]
    token = verify(client, emails, challenge).json["token"]
    database.execute("UPDATE mobile_users SET email_verified_at=NULL")
    database.commit()
    assert post(client, "login", email="alex@example.com", password="a good long password").status_code == 401
    assert client.get("/api/mobile/data/locations", headers={"Authorization": "Bearer " + token}).status_code == 401


def test_login_attempts_are_limited_per_email_across_different_ips(state):
    client, _, _ = state
    for index in range(10):
        csrf = client.get("/api/mobile/auth/session").json["csrf_token"]
        result = client.post("/api/mobile/auth/login", data={
            "email": "alex@example.com", "password": "incorrect password", "csrf_token": csrf,
        }, environ_base={"REMOTE_ADDR": f"203.0.113.{index+1}"})
        assert result.status_code == 401
    csrf = client.get("/api/mobile/auth/session").json["csrf_token"]
    result = client.post("/api/mobile/auth/login", data={
        "email": "alex@example.com", "password": "incorrect password", "csrf_token": csrf,
    }, environ_base={"REMOTE_ADDR": "203.0.113.100"})
    assert result.status_code == 429


def test_member_logout_and_login_clear_previous_administrator_access(state):
    client, _, emails = state
    challenge = register(client).json["challenge"]
    assert verify(client, emails, challenge, device="web").status_code == 200
    with client.session_transaction() as browser_session:
        browser_session[security.ADMIN_SESSION_KEY] = True
    assert post(client, "logout").status_code == 200
    assert client.get("/api/mobile/config").json["is_admin"] is False
    with client.session_transaction() as browser_session:
        browser_session[security.ADMIN_SESSION_KEY] = True
    assert post(client, "login", email="alex@example.com", password="a good long password", device="web").status_code == 200
    assert client.get("/api/mobile/config").json["is_admin"] is False


def test_smtp_uses_starttls_and_an_authenticated_sender(monkeypatch):
    calls = []
    class Transport:
        def __init__(self, host, port, timeout):
            calls.append(("connect", host, port))
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
        def ehlo(self):
            calls.append("ehlo")
        def starttls(self, context):
            calls.append("tls")
        def login(self, username, password):
            calls.append("login")
        def send_message(self, message):
            calls.append("send")
            assert message["To"] == "alex@example.com"
            assert "123456" in message.get_content()
    for key, value in {"SMTP_HOST": "smtp.gmail.com", "SMTP_PORT": 587, "SMTP_USERNAME": "sender@example.com", "SMTP_PASSWORD": "test-app-password", "SMTP_FROM": "sender@example.com", "SMTP_USE_SSL": False}.items():
        monkeypatch.setattr(email_delivery.config, key, value)
    monkeypatch.setattr(email_delivery.smtplib, "SMTP", Transport)
    email_delivery.send_verification_code("alex@example.com", "Alex", "123456")
    assert calls.index("tls") < calls.index("login") < calls.index("send")
