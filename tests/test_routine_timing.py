"""Reminders become visible and eligible for push at their scheduled local time."""
from datetime import timedelta
import threading

import pytest

from services import private_locations, routine_advice as advice
from services import routine_jobs as jobs, routine_push as push, routine_store as store
from tests.test_mobile_auth import state
from tests.test_routines import setup, create, form, request, DEVICE, MESSAGE, NOW


def prepare(setup, monkeypatch, *, device=True):
    identifier = create(setup)
    if device:
        request(setup, "POST", "devices/register", data={"token": DEVICE, "platform": "android"})
    monkeypatch.setattr(advice, "build_advice", lambda *_: MESSAGE)
    early = NOW-timedelta(seconds=90)
    monkeypatch.setattr(store, "utcnow", lambda: early)
    assert jobs.run_due_routines(early-timedelta(seconds=1)) == 0
    assert jobs.run_due_routines(early, deliver=False) == 1
    return identifier, early


def test_prepared_advice_does_not_appear_or_send_early(setup, monkeypatch):
    _, early = prepare(setup, monkeypatch)
    row = setup[1].execute("SELECT * FROM mobile_notifications").fetchone()
    assert row["scheduled_for"] == NOW
    assert row["prepared_at"] == early
    assert store.inbox(1) == ([], 0)
    assert request(setup, "POST", f"notifications/{row['id']}/read").status_code == 404
    assert not store.pending_deliveries(NOW-timedelta(microseconds=1))
    assert jobs.run_due_routines(early+timedelta(seconds=5), deliver=False) == 0
    monkeypatch.setattr(store, "utcnow", lambda: NOW)
    assert store.inbox(1)[1] == 1
    assert store.inbox(1)[0][0]["scheduled_for"] == NOW.isoformat()+"Z"
    monkeypatch.setattr(push, "configured", lambda: True)
    sent = []
    monkeypatch.setattr(push, "send", lambda row, now: sent.append(now) or "sent")
    assert jobs.dispatch_due_notifications(NOW) == 1
    assert sent == [NOW]
    assert setup[1].execute("SELECT sent_at FROM mobile_notification_deliveries").fetchone()[0] == NOW
    assert jobs.dispatch_due_notifications(NOW+timedelta(seconds=1)) == 0


@pytest.mark.parametrize("action", ["edit", "pause", "delete", "remove_address"])
def test_changing_future_reminder_removes_prepared_advice(setup, monkeypatch, action):
    identifier, _ = prepare(setup, monkeypatch)
    if action in ("edit", "pause"):
        store.save_routine(1, form(title="Sleep", enabled=action != "pause"), identifier)
    elif action == "delete":
        store.delete_routine(1, identifier)
    else:
        private_locations.remove(1, 1)
    assert setup[1].execute("SELECT COUNT(*) FROM mobile_notifications").fetchone()[0] == 0
    assert not store.pending_deliveries(NOW)
    if action == "edit":
        assert jobs.run_due_routines(NOW, deliver=False) == 1
        assert setup[1].execute("SELECT COUNT(*) FROM mobile_notifications").fetchone()[0] == 1


def test_device_enabled_after_preparation_gets_upcoming_reminder(setup, monkeypatch):
    prepare(setup, monkeypatch, device=False)
    assert setup[1].execute("SELECT COUNT(*) FROM mobile_notification_deliveries").fetchone()[0] == 0
    request(setup, "POST", "devices/register", data={"token": DEVICE, "platform": "android"})
    assert not store.pending_deliveries(NOW-timedelta(seconds=1))
    assert len(store.pending_deliveries(NOW)) == 1
    request(setup, "POST", "devices/register", data={"token": DEVICE, "platform": "android"})
    assert len(store.pending_deliveries(NOW)) == 1


def test_new_routine_due_now_is_not_delayed_until_next_scan(setup, monkeypatch):
    create(setup)
    monkeypatch.setattr(advice, "build_advice", lambda *_: MESSAGE)
    assert jobs.run_due_routines(NOW, deliver=False) == 1
    assert store.inbox(1)[1] == 1


def test_push_can_dispatch_while_ai_is_busy(monkeypatch):
    started, release = threading.Event(), threading.Event()
    routine = {"id": 1, "timezone": "Asia/Manila", "routine_time": "08:00",
               "weekdays": "3", "remind_before_minutes": 15}
    monkeypatch.setattr(store, "active_routines", lambda: [routine])
    monkeypatch.setattr(store, "claim_occurrence", lambda *_: (1, "claim"))
    def slow_ai(*_):
        started.set()
        assert release.wait(5)
        return MESSAGE
    monkeypatch.setattr(advice, "build_advice", slow_ai)
    monkeypatch.setattr(store, "finish_occurrence", lambda *_: None)
    monkeypatch.setattr(push, "configured", lambda: True)
    monkeypatch.setattr(store, "pending_deliveries", lambda *_: [{"id": 2, "event_at": NOW}])
    monkeypatch.setattr(store, "claim_delivery", lambda *_: "claim")
    monkeypatch.setattr(store, "finish_delivery", lambda *_: None)
    monkeypatch.setattr(push, "send", lambda *_: "sent")
    worker = threading.Thread(target=lambda: jobs.run_due_routines(NOW, deliver=False))
    worker.start()
    try:
        assert started.wait(2)
        assert jobs.dispatch_due_notifications(NOW) == 1
        assert worker.is_alive()
    finally:
        release.set()
        worker.join(timeout=5)
    assert not worker.is_alive()
