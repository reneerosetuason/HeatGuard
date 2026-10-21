"""Verified-member routine, device registration and notification APIs."""
import pymysql
from flask import Blueprint, current_app, jsonify, request

import config
from services import db, mobile_auth, routine_advice, routine_jobs, routine_push, routine_store as store, security
from services.mobile_accounts import AccountError

blueprint = Blueprint("mobile_routines", __name__, url_prefix="/api/mobile")
write_limiter = security.RateLimiter(60, 60)
preview_limiter = security.RateLimiter(5, 60)


@blueprint.before_request
def protect():
    if request.method == "OPTIONS":
        return None
    denied = mobile_auth.require_account()
    if denied is not None:
        return denied
    if request.method != "GET":
        if request.content_length and request.content_length > 16384:
            return jsonify(ok=False, error="The request is too large."), 413
        if not security.validate_csrf():
            return jsonify(ok=False, error="Your form expired. Please try again.", error_code="csrf_expired"), 400
        limiter = preview_limiter if request.endpoint == "mobile_routines.preview" else write_limiter
        allowed, wait = limiter.allow(str(mobile_auth.current_user()["id"]))
        if not allowed:
            response = jsonify(ok=False, error="Please wait before trying again.", retry_after=wait)
            response.status_code = 429
            response.headers["Retry-After"] = str(wait)
            return response
    return None


@blueprint.errorhandler(AccountError)
def input_error(error):
    return jsonify(ok=False, error=str(error)), error.status


@blueprint.errorhandler(db.DatabaseError)
@blueprint.errorhandler(pymysql.MySQLError)
def database_error(error):
    current_app.logger.warning("Routine database unavailable (%s)", type(error).__name__)
    return jsonify(ok=False, error="Your routines are temporarily unavailable. Please try again later."), 503


def body():
    data = request.get_json(silent=True) if request.is_json else request.form
    return data if hasattr(data, "get") else {}


def user_id():
    return mobile_auth.current_user()["id"]


@blueprint.get("/routines")
def routines():
    return jsonify(ok=True, routines=store.list_routines(user_id()), push_available=routine_push.configured(),
                   ai_available=bool(config.GROQ_API_KEY), reminders_enabled=config.ROUTINES_ENABLED)


@blueprint.post("/routines")
def create():
    return jsonify(ok=True, routine=store.save_routine(user_id(), body())), 201


@blueprint.post("/routines/<int:routine_id>")
def update(routine_id):
    return jsonify(ok=True, routine=store.save_routine(user_id(), body(), routine_id))


@blueprint.delete("/routines/<int:routine_id>")
def delete(routine_id):
    store.delete_routine(user_id(), routine_id)
    return jsonify(ok=True)


@blueprint.post("/routines/<int:routine_id>/preview")
def preview(routine_id):
    routine = store.get_routine(user_id(), routine_id)
    if not routine["is_active"]:
        raise AccountError("This monitoring location is no longer active.")
    events = routine_jobs.occurrences(routine, store.utcnow(), upcoming=True)
    if not events:
        raise AccountError("No upcoming occurrence was found.")
    # Preview the next near-term occurrence. Distant forecasts return an honest unavailable message.
    return jsonify(ok=True, preview=routine_advice.build_advice(routine, events[0]), event_at=store.iso(events[0]))


@blueprint.get("/notifications")
def notifications():
    messages, unread = store.inbox(user_id())
    return jsonify(ok=True, notifications=messages, unread_count=unread)


@blueprint.post("/notifications/read-all")
def read_all():
    store.mark_read(user_id())
    return jsonify(ok=True)


@blueprint.post("/notifications/<int:notification_id>/read")
def read(notification_id):
    store.mark_read(user_id(), notification_id)
    return jsonify(ok=True)


@blueprint.post("/devices/register")
def register_device():
    data = body()
    store.register_device(user_id(), mobile_auth.request_token(), data.get("token"), data.get("platform"))
    return jsonify(ok=True)


@blueprint.post("/devices/remove")
def remove_device():
    store.remove_device(user_id(), body().get("token"))
    return jsonify(ok=True)
