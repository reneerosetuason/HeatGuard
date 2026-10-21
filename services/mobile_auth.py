"""Authentication endpoints used by the Flutter application."""

import hashlib
import secrets

import pymysql
from flask import Blueprint, current_app, g, jsonify, request, session

import config
from services import db, email_delivery, mobile_accounts as accounts, security

blueprint = Blueprint("mobile_auth", __name__, url_prefix="/api/mobile/auth")
COOKIE_NAME = "heatguard_mobile_session"
send_limiter = security.RateLimiter(10, 3600)
login_limiter = security.RateLimiter(10, 900)
email_login_limiter = security.RateLimiter(10, 900)
verify_limiter = security.RateLimiter(30, 900)


def request_token():
    header = request.headers.get("Authorization", "")
    if header:
        kind, _, token = header.partition(" ")
        return token if kind.lower() == "bearer" else None
    return request.cookies.get(COOKIE_NAME)


def current_user():
    if not hasattr(g, "mobile_user"):
        g.mobile_user = accounts.session_user(request_token())
    return g.mobile_user


def require_account():
    try:
        if current_user():
            return None
    except (db.DatabaseError, pymysql.MySQLError):
        return jsonify(ok=False, error="The account database is temporarily unavailable."), 503
    return jsonify(ok=False, error="Sign in to access HeatGuard.", error_code="authentication_required"), 401


@blueprint.before_request
def protect_auth_forms():
    if request.method in {"GET", "OPTIONS"}:
        return None
    if not security.validate_csrf():
        return jsonify(ok=False, error="Your form expired. Please try again.", error_code="csrf_expired"), 400
    limiter = (
        send_limiter if request.endpoint in {"mobile_auth.register", "mobile_auth.resend"}
        else verify_limiter if request.endpoint == "mobile_auth.verify" else login_limiter
    )
    allowed, wait = limiter.allow(security.client_ip())
    if allowed and request.endpoint == "mobile_auth.login":
        email = accounts.normalize_email(_body().get("email"))
        allowed, wait = email_login_limiter.allow(hashlib.sha256(email.encode()).hexdigest())
    if not allowed:
        response = jsonify(ok=False, error="Too many requests. Please wait before trying again.", retry_after=wait)
        response.status_code = 429
        response.headers["Retry-After"] = str(wait)
        return response
    return None


@blueprint.errorhandler(accounts.AccountError)
def account_error(error):
    response = jsonify(ok=False, error=str(error), retry_after=error.retry_after)
    response.status_code = error.status
    if error.retry_after:
        response.headers["Retry-After"] = str(error.retry_after)
    return response


@blueprint.errorhandler(email_delivery.EmailDeliveryError)
def email_error(error):
    return jsonify(ok=False, error=str(error)), 503


@blueprint.errorhandler(db.DatabaseError)
@blueprint.errorhandler(pymysql.MySQLError)
def database_error(error):
    current_app.logger.warning("Mobile account database unavailable (%s)", type(error).__name__)
    return jsonify(ok=False, error="The account service is temporarily unavailable. Please try again later."), 503


def _body():
    body = request.get_json(silent=True) if request.is_json else request.form
    return body if hasattr(body, "get") else {}


def _signed_in(user):
    accounts.revoke_session(request_token())
    token, expires_at = accounts.create_session(user["id"])
    session.clear()
    session[security.CSRF_SESSION_KEY] = secrets.token_urlsafe(32)
    payload = {"ok": True, "user": user, "csrf_token": security.csrf_token()}
    if _body().get("device") == "native":
        payload["token"] = token
    response = jsonify(payload)
    if _body().get("device") != "native":
        response.set_cookie(
            COOKIE_NAME, token, max_age=config.MOBILE_SESSION_DAYS * 86400,
            expires=expires_at, httponly=True,
            secure=current_app.config["SESSION_COOKIE_SECURE"], samesite="Lax", path="/api/mobile",
        )
    return response


@blueprint.get("/session")
def session_status():
    user = current_user()
    response = jsonify(ok=True, user=user, csrf_token=security.csrf_token())
    if user is None and request.cookies.get(COOKIE_NAME):
        response.delete_cookie(COOKIE_NAME, path="/api/mobile")
    return response


@blueprint.post("/register")
def register():
    body = _body()
    challenge = accounts.start_registration(body.get("name"), body.get("email"), body.get("password"))
    return jsonify(ok=True, challenge=challenge, message="Check your email to finish registration."), 202


@blueprint.post("/resend")
def resend():
    return jsonify(ok=True, challenge=accounts.resend_code(_body().get("challenge_id")))


@blueprint.post("/verify")
def verify():
    body = _body()
    return _signed_in(accounts.verify_registration(body.get("challenge_id"), body.get("code")))


@blueprint.post("/login")
def login():
    body = _body()
    return _signed_in(accounts.authenticate(body.get("email"), body.get("password")))


@blueprint.post("/logout")
def logout():
    accounts.revoke_session(request_token())
    session.clear()
    session[security.CSRF_SESSION_KEY] = secrets.token_urlsafe(32)
    response = jsonify(ok=True, csrf_token=security.csrf_token())
    response.delete_cookie(COOKIE_NAME, path="/api/mobile")
    return response
