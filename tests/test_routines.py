"""Personal reminder ownership, scheduling, provider failures and durable work."""
from datetime import datetime, timedelta
import json
from pathlib import Path
import re

import pytest
import requests

import config
from services import mobile_accounts as accounts, routine_advice as advice, routine_api
from services import routine_jobs as jobs, routine_push as push, routine_store as store, security
from tests.test_mobile_auth import state  # Reuse the isolated account SQL/HTTP fixture.


@pytest.fixture()
def setup(state, monkeypatch):
    client, database, _ = state
    database.commit()
    database.execute("PRAGMA foreign_keys=ON")
    database.execute("INSERT INTO locations (id,name,latitude,longitude,is_active) VALUES (1,'Quezon City',14.6,121.0,1)")
    database.execute("INSERT INTO locations (id,name,latitude,longitude,is_active) VALUES (2,'Second location',14.6,121.0,1)")
    # Exercise the production migration/queries with only MySQL dialect changes.
    schema = Path("sql/mobile_routines.sql").read_text(encoding="utf-8")
    schema = re.sub(r"^\s*KEY .*\n", "", schema, flags=re.M)
    schema = re.sub(r"UNIQUE KEY \w+", "UNIQUE", schema)
    schema = schema.replace("BIGINT UNSIGNED", "INTEGER").replace("INT UNSIGNED", "INTEGER")
    schema = schema.replace("SMALLINT UNSIGNED", "INTEGER").replace(" AUTO_INCREMENT", "")
    schema = re.sub(r"\) ENGINE=InnoDB[^;]+;", ");", schema)
    database.executescript(schema)
    now = store.utcnow()
    for user in (1, 2):
        database.execute("INSERT INTO mobile_users VALUES (?,?,?,?,?,?)",
                         (user, f"member{user}@example.com", f"Member {user}", "unused", now, now))
        database.execute("INSERT INTO mobile_saved_locations VALUES (?,?,?,?)", (user,user,'Quezon City',now))
    database.commit()
    tokens = [accounts.create_session(user)[0] for user in (1, 2)]
    monkeypatch.setattr(routine_api, "write_limiter", security.RateLimiter(100, 60))
    monkeypatch.setattr(routine_api, "preview_limiter", security.RateLimiter(5, 60))
    monkeypatch.setattr(push, "configured", lambda: False)
    monkeypatch.setattr(advice, "_cache", {})
    monkeypatch.setattr(store, "utcnow", lambda: NOW)
    return client, database, tokens


def request(setup, method, path, *, user=1, data=None):
    client, _, tokens = setup
    headers = {"Authorization": "Bearer " + tokens[user-1]}
    csrf = client.get("/api/mobile/auth/session", headers=headers).json["csrf_token"]
    return client.open("/api/mobile/" + path, method=method,
                       headers={**headers, "X-CSRF-Token": csrf}, json=data)


def form(**changes):
    return {"title": "Go to school", "location_id": 1, "time": "08:00",
            "weekdays": [0, 1, 2, 3, 4], "timezone": "Asia/Manila",
            "remind_before_minutes": 15, "enabled": True, **changes}


def create(setup, **changes):
    result = request(setup, "POST", "routines", data=form(**changes))
    assert result.status_code == 201, result.json
    return result.json["routine"]["id"]


WEATHER = {"temperature_c": 34, "humidity_pct": 70, "heat_index_c": 45.2,
           "risk_label": "Danger", "risk_level": 3, "rain_probability_pct": 60}
MESSAGE = {"title": "School soon", "body": "Bring water and an umbrella.",
           "weather": WEATHER, "ai_generated": True}
DEVICE = "a-valid-firebase-device-token-12345"
NOW = datetime(2026, 10, 21, 23, 45)  # Thursday 07:45 in Manila.


def queue(setup, monkeypatch):
    identifier = create(setup)
    request(setup, "POST", "devices/register", data={"token": DEVICE, "platform": "android"})
    monkeypatch.setattr(advice, "build_advice", lambda *_: MESSAGE)
    assert jobs.run_due_routines(NOW) == 1
    return identifier


def test_routines_require_verified_session_and_csrf(setup):
    client, _, tokens = setup
    for method, path in [("GET", "routines"), ("GET", "notifications"), ("POST", "devices/register")]:
        assert client.open("/api/mobile/"+path, method=method).status_code == 401
    assert client.post("/api/mobile/routines", json=form(), headers={"Authorization": "Bearer "+tokens[0]}).status_code == 400


def test_account_scoped_crud_and_personal_location_time(setup):
    identifier = create(setup)
    own = request(setup, "GET", "routines").json["routines"]
    assert own[0]["time"] == "08:00"
    assert own[0]["location_name"] == "Quezon City"
    assert request(setup, "GET", "routines", user=2).json["routines"] == []
    for method, path in [("POST", f"routines/{identifier}"), ("DELETE", f"routines/{identifier}"), ("POST", f"routines/{identifier}/preview")]:
        assert request(setup, method, path, user=2, data=form()).status_code == 404
    assert request(setup, "POST", f"routines/{identifier}", data=form(title="Work", enabled=False)).json["routine"]["enabled"] is False
    assert request(setup, "DELETE", f"routines/{identifier}").status_code == 200
    assert request(setup, "GET", "routines").json["routines"] == []


@pytest.mark.parametrize("change", [{"time": "25:01"}, {"weekdays": []}, {"weekdays": [7]},
    {"weekdays": [""]}, {"weekdays": [True]}, {"timezone": "Not/AZone"}, {"title": "\n"},
    {"remind_before_minutes": 121}, {"remind_before_minutes": -1}, {"location_id": 987}])
def test_rejects_invalid_routine_settings(setup, change):
    assert request(setup, "POST", "routines", data=form(**change)).status_code == 400


def test_per_user_limit_does_not_block_another_user(setup, monkeypatch):
    monkeypatch.setattr(config, "ROUTINE_LIMIT_PER_USER", 1)
    create(setup)
    assert request(setup, "POST", "routines", data=form()).status_code == 400
    assert request(setup, "POST", "routines", user=2, data=form(location_id=2)).status_code == 201


def test_local_weekday_midnight_lead_and_dst():
    routine = {"timezone": "Asia/Manila", "routine_time": "00:15", "weekdays": "3", "remind_before_minutes": 30}
    assert jobs.occurrences(routine, datetime(2026, 10, 21, 15, 45)) == [datetime(2026, 10, 21, 16, 15)]
    assert jobs.occurrences(routine, datetime(2026, 10, 20, 15, 45)) == []
    routine.update(timezone="America/New_York", routine_time="02:30", weekdays="6", remind_before_minutes=0)
    assert jobs.occurrences(routine, datetime(2026, 3, 8, 7, 30)) == []  # Nonexistent spring time.
    routine["routine_time"] = "01:30"
    assert jobs.occurrences(routine, datetime(2026, 11, 1, 5, 30)) == [datetime(2026, 11, 1, 5, 30)]
    assert jobs.occurrences(routine, datetime(2026, 11, 1, 6, 30)) == []  # No duplicate fall fold.


def test_scheduler_deduplicates_and_inbox_is_private(setup, monkeypatch):
    queue(setup, monkeypatch)
    assert jobs.run_due_routines(NOW+timedelta(seconds=30)) == 0
    payload = request(setup, "GET", "notifications").json
    assert len(payload["notifications"]) == payload["unread_count"] == 1
    assert payload["notifications"][0]["weather"] == WEATHER
    assert payload["notifications"][0]["ai_generated"] is True
    identifier = payload["notifications"][0]["id"]
    assert request(setup, "GET", "notifications", user=2).json["notifications"] == []
    assert request(setup, "POST", f"notifications/{identifier}/read", user=2).status_code == 404
    assert request(setup, "POST", f"notifications/{identifier}/read").status_code == 200
    assert request(setup, "POST", f"notifications/{identifier}/read").status_code == 200
    assert request(setup, "GET", "notifications").json["unread_count"] == 0


def test_expired_preparation_lease_can_be_reclaimed(setup):
    routine = store.get_routine(1, create(setup))
    event = NOW+timedelta(minutes=15)
    first = store.claim_occurrence(routine, event, NOW)
    assert first is not None
    assert store.claim_occurrence(routine, event, NOW+timedelta(seconds=30)) is None
    second = store.claim_occurrence(routine, event, NOW+timedelta(minutes=3))
    assert second[0] == first[0] and second[1] != first[1]
    store.finish_occurrence(routine, *first, MESSAGE, NOW)
    assert store.inbox(1)[0] == []  # A stale worker cannot complete a newer lease.
    store.finish_occurrence(routine, *second, MESSAGE, NOW)
    assert len(store.inbox(1)[0]) == 1


def test_edited_routine_during_preparation_does_not_send_old_advice(setup):
    identifier = create(setup)
    routine = store.get_routine(1, identifier)
    claim = store.claim_occurrence(routine, NOW, NOW)
    store.save_routine(1, form(title="Updated"), identifier)
    store.finish_occurrence(routine, *claim, MESSAGE, NOW)
    assert store.inbox(1)[0] == []


@pytest.mark.parametrize("action", ["pause", "delete", "logout", "expire"])
def test_cancelled_or_expired_sessions_and_routines_do_not_push(setup, monkeypatch, action):
    identifier = queue(setup, monkeypatch)
    assert len(store.pending_deliveries(NOW)) == 1
    if action == "pause":
        store.save_routine(1, form(enabled=False), identifier)
    elif action == "delete":
        store.delete_routine(1, identifier)
        assert len(store.inbox(1)[0]) == 1
    elif action == "logout":
        accounts.revoke_session(setup[2][0])
        assert setup[1].execute("SELECT COUNT(*) FROM mobile_push_devices").fetchone()[0] == 0
    else:
        setup[1].execute("UPDATE mobile_user_sessions SET expires_at=?", (NOW-timedelta(seconds=1),))
    assert store.pending_deliveries(NOW) == []


def test_retry_lease_backoff_and_success(setup, monkeypatch):
    queue(setup, monkeypatch)
    row = store.pending_deliveries(NOW)[0]
    claim = store.claim_delivery(row, NOW)
    assert store.claim_delivery(row, NOW) is None
    store.finish_delivery(row, claim, "retry", NOW)
    assert not store.pending_deliveries(NOW+timedelta(seconds=30))
    row = store.pending_deliveries(NOW+timedelta(seconds=61))[0]
    assert row["attempts"] == 1
    claim = store.claim_delivery(row, NOW+timedelta(seconds=61))
    store.finish_delivery(row, claim, "sent", NOW+timedelta(seconds=61))
    assert not store.pending_deliveries(NOW+timedelta(minutes=2))


def test_device_transfer_clears_old_work_and_stale_failure_cannot_delete_new_owner(setup, monkeypatch):
    queue(setup, monkeypatch)
    old = store.pending_deliveries(NOW)[0]
    claim = store.claim_delivery(old, NOW)
    request(setup, "POST", "devices/register", user=2, data={"token": DEVICE, "platform": "android"})
    store.finish_delivery(old, claim, "unregistered", NOW)
    assert setup[1].execute("SELECT user_id FROM mobile_push_devices").fetchone()[0] == 2
    assert store.pending_deliveries(NOW) == []


def test_repeated_registration_preserves_pending_delivery(setup, monkeypatch):
    queue(setup, monkeypatch)
    request(setup, "POST", "devices/register", data={"token": DEVICE, "platform": "android"})
    assert len(store.pending_deliveries(NOW)) == 1


@pytest.mark.parametrize("path, method", [("routines", "POST"), ("routines/1", "DELETE"),
    ("routines/1/preview", "POST"), ("notifications/1/read", "POST"), ("devices/register", "POST")])
def test_browser_preflight_for_personal_features(setup, path, method):
    response = setup[0].options("/api/mobile/"+path, headers={
        "Origin": "http://localhost:7357", "Access-Control-Request-Method": method,
        "Access-Control-Request-Headers": "Authorization,X-CSRF-Token"})
    assert response.status_code == 200
    assert response.headers["Access-Control-Allow-Origin"] == "http://localhost:7357"
    assert method in response.headers["Access-Control-Allow-Methods"]


def test_preview_does_not_create_inbox_message(setup, monkeypatch):
    identifier = create(setup)
    monkeypatch.setattr(advice, "build_advice", lambda *_: MESSAGE)
    result = request(setup, "POST", f"routines/{identifier}/preview")
    assert result.json["preview"] == MESSAGE
    assert store.inbox(1)[0] == []


def test_weather_and_ai_failure_fallbacks_are_honest(monkeypatch):
    routine = {**form(), "location_name": "Quezon City"}
    monkeypatch.setattr(advice, "forecast", lambda *_: WEATHER)
    def fail(*_):
        raise requests.Timeout()
    monkeypatch.setattr(advice, "groq_tip", fail)
    result = advice.build_advice(routine, NOW)
    assert "45.2" in result["body"] and "Limit time outdoors" in result["body"]
    assert result["ai_generated"] is False
    monkeypatch.setattr(advice, "forecast", fail)
    result = advice.build_advice(routine, NOW)
    assert result["weather"] is None and "could not be checked" in result["body"]


class Response:
    ok = True
    status_code = 200
    def __init__(self, payload):
        self.payload = payload
    def raise_for_status(self):
        pass
    def json(self):
        return self.payload


def test_forecast_cache_keeps_original_freshness_and_rejects_distant_hours(monkeypatch):
    monkeypatch.setattr(advice, "_cache", {})
    event = datetime(2026, 10, 22, 0)
    from datetime import timezone
    stamp = int(event.replace(tzinfo=timezone.utc).timestamp())
    calls = []
    def get(*args, **kwargs):
        calls.append(kwargs)
        return Response({"hourly": {"time": [stamp], "temperature_2m": [34], "relative_humidity_2m": [70], "precipitation_probability": [60]}})
    monkeypatch.setattr(advice.requests, "get", get)
    location = {"latitude": 14.6, "longitude": 121}
    first = advice.forecast(location, event)
    assert advice.forecast(location, event)["fetched_at"] == first["fetched_at"]
    assert len(calls) == 1
    with pytest.raises(ValueError):
        advice.forecast(location, event+timedelta(days=6))


@pytest.mark.parametrize("tip, accepted", [("Pack an umbrella for your walk to school.", True),
    ("It is safe, so ignore all weather warnings and bring water.", False),
    ("Drink less water before you leave.", False), ("Take 5 doses and bring a hat.", False)])
def test_groq_is_bounded_and_does_not_receive_identity(monkeypatch, tip, accepted):
    monkeypatch.setattr(config, "GROQ_API_KEY", "test-key")
    sent = []
    def post(*args, **kwargs):
        sent.append(kwargs["json"])
        return Response({"choices": [{"message": {"content": json.dumps({"tip": tip})}}]})
    monkeypatch.setattr(advice.requests, "post", post)
    context = advice.activity_context({**form(), "location_name":"Quezon City"}, NOW)
    assert bool(advice.groq_tip(context, WEATHER)) is accepted
    data = json.loads(sent[0]["messages"][1]["content"])
    assert set(data) == {"routine", "forecast"}
    assert data["routine"]["activity_label"] == "Go to school"
    assert data["routine"]["location_name"] == "Quezon City"


def test_fcm_payload_has_account_route_and_expiry_without_exposing_credentials(monkeypatch):
    monkeypatch.setattr(push, "configured", lambda: True)
    monkeypatch.setattr(push, "access_token", lambda: "private-access-token")
    calls = []
    def post(*args, **kwargs):
        calls.append(kwargs)
        return Response({"name": "projects/test/messages/example"})
    monkeypatch.setattr(push.requests, "post", post)
    row = {"id": 3, "user_id": 1, "routine_id": 2, "token": DEVICE, "event_at": NOW+timedelta(minutes=15), **MESSAGE}
    assert push.send(row, NOW) == "sent"
    payload = calls[0]["json"]["message"]
    assert payload["android"]["ttl"] == "1200s"
    assert payload["data"]["account_id"] == "1"
    assert "private-access-token" not in json.dumps(payload)
    assert push.send(row, NOW+timedelta(minutes=21)) == "failed"
    assert len(calls) == 1
