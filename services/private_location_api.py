"""Verified members manage only their own locations; shared routes retain admin checks."""
import pymysql
from flask import Blueprint, current_app, jsonify, request

from services import addresses, dashboard, db, mobile_auth, private_locations as places, security
from services.mobile_accounts import AccountError
from services.monitoring import monitor_location, cooldown_remaining

blueprint = Blueprint("private_locations", __name__, url_prefix="/api/mobile/data")


@blueprint.before_request
def protect():
    if request.method == "OPTIONS":
        return None
    denied = mobile_auth.require_account()
    if denied is not None:
        return denied
    if request.method != "GET":
        if request.content_length and request.content_length>16384:
            return jsonify(ok=False, error="The request is too large."), 413
        if not security.validate_csrf():
            return jsonify(ok=False, error="Your form expired. Please try again.", error_code="csrf_expired"), 400
        allowed, wait = security.write_limiter.allow("member:"+str(user_id()))
        if not allowed:
            response = jsonify(ok=False, error="Please wait before changing more addresses.", retry_after=wait)
            response.status_code = 429
            response.headers["Retry-After"] = str(wait)
            return response


@blueprint.errorhandler(AccountError)
def input_error(error):
    return jsonify(ok=False, error=str(error)), error.status


@blueprint.errorhandler(db.DatabaseError)
@blueprint.errorhandler(pymysql.MySQLError)
def database_error(error):
    current_app.logger.warning("Private addresses unavailable (%s)", type(error).__name__)
    return jsonify(ok=False, error="Your saved addresses are temporarily unavailable. Please try again."), 503


def user_id():
    return mobile_auth.current_user()["id"]


def body():
    data = request.get_json(silent=True) if request.is_json else request.form
    return data if hasattr(data, "get") else {}


def payload(location_id=None, hours=None):
    location = places.get_location(user_id(), location_id)
    return dashboard.build_dashboard(location_id=location["id"], hours=hours, scoped_locations=places.list_locations(user_id()))


@blueprint.get("/locations")
def locations():
    return jsonify(ok=True, locations=places.list_locations(user_id()))


@blueprint.get("/dashboard")
def current_weather():
    return jsonify(ok=True, dashboard=payload(request.args.get("location"), request.args.get("hours", type=int)))


@blueprint.post("/locations")
@blueprint.post("/locations/address")
def create():
    data = body()
    resolved = None
    if request.path.endswith("/address"):
        try:
            resolved = addresses.resolve_address(region_code=data.get("region_code"), province_code=data.get("province_code"), city_code=data.get("city_code"), barangay_code=data.get("barangay_code"))
        except addresses.AddressError as error:
            raise AccountError(str(error)) from None
        data = resolved
    location = places.create(user_id(), name=data.get("name"), latitude=data.get("latitude"), longitude=data.get("longitude"), timezone=data.get("timezone") or "Asia/Manila")
    # Initial weather collection is best effort; the saved address remains usable.
    try:
        monitor_location(location)
    except Exception as error:
        current_app.logger.warning("Initial private weather unavailable (%s)", type(error).__name__)
    return jsonify(ok=True, location=location, address=resolved, dashboard=None), 201


@blueprint.delete("/locations/<int:location_id>")
def remove(location_id):
    places.remove(user_id(), location_id)
    return jsonify(ok=True, deactivated=location_id)


@blueprint.post("/refresh")
def refresh():
    data = body()
    try:
        hours = int(data.get("hours")) if data.get("hours") is not None else None
    except (TypeError, ValueError):
        hours = None
    location = places.get_location(user_id(), data.get("location_id"))
    try:
        remaining = cooldown_remaining(location["id"])
    except db.DatabaseError:
        remaining = 0
    if remaining:
        return jsonify(ok=True, refreshed=False, retry_after_seconds=remaining, message="Weather was checked recently. Try again shortly.", dashboard=payload(location["id"], hours))
    result = monitor_location(location)
    if not result.get("ok"):
        return jsonify(ok=False, error="Weather could not be updated. Your saved address has been kept."), 502
    return jsonify(ok=True, refreshed=True, message="Weather data refreshed.", dashboard=payload(location["id"], hours))
