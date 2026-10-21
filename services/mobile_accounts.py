"""Verified mobile accounts, hashed OTPs, and revocable opaque sessions."""

from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import re
import secrets

from flask import current_app
from werkzeug.security import check_password_hash, generate_password_hash

import config
from services import db, email_delivery

_DUMMY_PASSWORD_HASH = generate_password_hash(secrets.token_urlsafe(32))


class AccountError(ValueError):
    def __init__(self, message, status=400, *, retry_after=None):
        super().__init__(message)
        self.status = status
        self.retry_after = retry_after


def utcnow():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def normalize_email(value):
    if not isinstance(value, str):
        raise AccountError("Enter a valid email address.")
    email = value.strip().lower()
    if len(email) > 254 or email.count("@") != 1:
        raise AccountError("Enter a valid email address.")
    local, domain = email.split("@")
    labels = domain.split(".")
    if (
        not 1 <= len(local) <= 64
        or not re.fullmatch(r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]+", local)
        or local.startswith(".") or local.endswith(".") or ".." in local
        or len(labels) < 2
        or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels)
    ):
        raise AccountError("Enter a valid email address.")
    return email


def public_user(row):
    return {"id": row["id"], "email": row["email"], "name": row["display_name"], "email_verified": True}


def _code_hash(challenge_id, code):
    return hmac.new(
        current_app.config["SECRET_KEY"].encode("utf-8"),
        f"heatguard-registration:{challenge_id}:{code}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def _challenge_result(row):
    return {
        "challenge_id": row["challenge_id"], "email": row["email"],
        "expires_in": config.MOBILE_OTP_MINUTES * 60,
        "resend_after": config.MOBILE_OTP_RESEND_SECONDS,
    }


def _send_limits(previous, now):
    if previous and previous["resend_after"] > now:
        wait = max(1, int((previous["resend_after"] - now).total_seconds()) + 1)
        raise AccountError(f"Wait {wait} seconds before requesting another code.", 429, retry_after=wait)
    if previous and previous["send_window_started_at"] > now - timedelta(hours=1):
        if previous["send_count"] >= config.MOBILE_OTP_MAX_SENDS_PER_HOUR:
            raise AccountError("Too many verification emails. Please try again in an hour.", 429, retry_after=3600)
        return previous["send_count"] + 1, previous["send_window_started_at"]
    return 1, now


def start_registration(name, email, password):
    email = normalize_email(email)
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80 or any(ord(c) < 32 for c in name):
        raise AccountError("Enter your name using 1 to 80 characters.")
    if not isinstance(password, str) or not 12 <= len(password) <= 128:
        raise AccountError("Use a password with 12 to 128 characters.")
    if not email_delivery.smtp_configured():
        raise email_delivery.EmailDeliveryError("Email verification is not configured on the server yet.")
    password_hash = generate_password_hash(password)
    now = utcnow()
    row = {
        "challenge_id": secrets.token_urlsafe(32), "email": email,
        "display_name": name.strip(), "password_hash": password_hash,
    }
    code = f"{secrets.randbelow(1_000_000):06d}"
    with db.connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM mobile_registration_challenges WHERE created_at<%s", (now - timedelta(days=1),))
            cur.execute("SELECT id FROM mobile_users WHERE email = %s", (email,))
            if cur.fetchone():
                raise AccountError("Unable to register this email. Try signing in instead.", 409)
            cur.execute("SELECT * FROM mobile_registration_challenges WHERE email = %s FOR UPDATE", (email,))
            previous = cur.fetchone()
            count, window = _send_limits(previous, now)
            values = (
                row["challenge_id"], row["display_name"], password_hash,
                _code_hash(row["challenge_id"], code),
                now + timedelta(minutes=config.MOBILE_OTP_MINUTES),
                now + timedelta(seconds=config.MOBILE_OTP_RESEND_SECONDS), count, window, now, email,
            )
            if previous:
                cur.execute(
                    "UPDATE mobile_registration_challenges SET challenge_id=%s, display_name=%s, "
                    "password_hash=%s, code_hash=%s, code_expires_at=%s, attempts=0, "
                    "resend_after=%s, send_count=%s, send_window_started_at=%s, created_at=%s WHERE email=%s",
                    values,
                )
            else:
                cur.execute(
                    "INSERT INTO mobile_registration_challenges (challenge_id, display_name, password_hash, "
                    "code_hash, code_expires_at, resend_after, send_count, send_window_started_at, created_at, email) "
                    "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)", values,
                )
            # A failed delivery rolls back the challenge, preserving any previous valid code.
            email_delivery.send_verification_code(email, row["display_name"], code)
    return _challenge_result(row)


def resend_code(challenge_id):
    if not isinstance(challenge_id, str) or not 20 <= len(challenge_id) <= 64:
        raise AccountError("Start registration again to request a code.")
    now = utcnow()
    with db.connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM mobile_registration_challenges WHERE challenge_id=%s FOR UPDATE", (challenge_id,))
            row = cur.fetchone()
            if not row or row["created_at"] < now - timedelta(days=1):
                raise AccountError("This registration has expired. Please create your account again.")
            count, window = _send_limits(row, now)
            code = f"{secrets.randbelow(1_000_000):06d}"
            cur.execute(
                "UPDATE mobile_registration_challenges SET code_hash=%s, code_expires_at=%s, attempts=0, "
                "resend_after=%s, send_count=%s, send_window_started_at=%s WHERE challenge_id=%s",
                (_code_hash(challenge_id, code), now + timedelta(minutes=config.MOBILE_OTP_MINUTES),
                 now + timedelta(seconds=config.MOBILE_OTP_RESEND_SECONDS), count, window, challenge_id),
            )
            email_delivery.send_verification_code(row["email"], row["display_name"], code)
    return _challenge_result(row)


def verify_registration(challenge_id, code):
    if not isinstance(challenge_id, str) or not isinstance(code, str) or not re.fullmatch(r"[0-9]{6}", code):
        raise AccountError("Enter the six-digit code from your email.")
    now = utcnow()
    wrong_code = False
    with db.connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM mobile_registration_challenges WHERE challenge_id=%s FOR UPDATE", (challenge_id,))
            row = cur.fetchone()
            if not row:
                raise AccountError("This code is no longer valid. Start registration again.")
            if row["code_expires_at"] <= now:
                raise AccountError("Your code has expired. Request a new code.")
            if row["attempts"] >= config.MOBILE_OTP_MAX_ATTEMPTS:
                raise AccountError("Too many incorrect attempts. Request a new code.", 429)
            if not hmac.compare_digest(row["code_hash"], _code_hash(challenge_id, code)):
                cur.execute("UPDATE mobile_registration_challenges SET attempts=attempts+1 WHERE challenge_id=%s", (challenge_id,))
                wrong_code = True
            else:
                cur.execute(
                    "INSERT INTO mobile_users (email, display_name, password_hash, email_verified_at, created_at) "
                    "VALUES (%s,%s,%s,%s,%s)",
                    (row["email"], row["display_name"], row["password_hash"], now, now),
                )
                row["id"] = cur.lastrowid
                cur.execute("DELETE FROM mobile_registration_challenges WHERE challenge_id=%s", (challenge_id,))
    # Incorrect attempts must commit before the error is returned.
    if wrong_code:
        raise AccountError("That code is incorrect. Check your email and try again.")
    return public_user(row)


def authenticate(email, password):
    email = normalize_email(email)
    if not isinstance(password, str) or len(password) > 128:
        raise AccountError("Email or password is incorrect.", 401)
    with db.connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM mobile_users WHERE email=%s", (email,))
            row = cur.fetchone()
    valid = check_password_hash(row["password_hash"] if row else _DUMMY_PASSWORD_HASH, password)
    if not row or not valid or not row["email_verified_at"]:
        raise AccountError("Email or password is incorrect. Complete email verification before signing in.", 401)
    return public_user(row)


def create_session(user_id):
    token = secrets.token_urlsafe(32)
    now = utcnow()
    expires_at = now + timedelta(days=config.MOBILE_SESSION_DAYS)
    with db.connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM mobile_user_sessions WHERE expires_at<=%s", (now,))
            cur.execute(
                "INSERT INTO mobile_user_sessions (token_hash,user_id,expires_at,created_at) VALUES (%s,%s,%s,%s)",
                (hashlib.sha256(token.encode()).hexdigest(), user_id, expires_at, now),
            )
    return token, expires_at


def session_user(token):
    if not isinstance(token, str) or not 32 <= len(token) <= 100:
        return None
    with db.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT u.id,u.email,u.display_name FROM mobile_users u JOIN mobile_user_sessions s "
                "ON u.id=s.user_id WHERE s.token_hash=%s AND s.expires_at>%s AND u.email_verified_at IS NOT NULL",
                (hashlib.sha256(token.encode()).hexdigest(), utcnow()),
            )
            row = cur.fetchone()
    return public_user(row) if row else None


def revoke_session(token):
    if not isinstance(token, str) or not 32 <= len(token) <= 100:
        return
    with db.connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM mobile_user_sessions WHERE token_hash=%s", (hashlib.sha256(token.encode()).hexdigest(),))
