"""Deliver registration codes through an authenticated TLS SMTP connection."""

import logging
import smtplib
import ssl
from email.message import EmailMessage

import config

logger = logging.getLogger(__name__)


class EmailDeliveryError(RuntimeError):
    pass


def smtp_configured() -> bool:
    return all((config.SMTP_HOST, config.SMTP_USERNAME, config.SMTP_PASSWORD, config.SMTP_FROM))


def send_verification_code(email: str, name: str, code: str) -> None:
    if not smtp_configured():
        raise EmailDeliveryError("Email verification is not configured on the server yet.")
    message = EmailMessage()
    message["Subject"] = "Your HeatGuard verification code"
    message["From"] = config.SMTP_FROM
    message["To"] = email
    message.set_content(
        f"Hello {name},\n\n"
        f"Your HeatGuard verification code is:\n\n{code}\n\n"
        f"This code expires in {config.MOBILE_OTP_MINUTES} minutes. "
        "Enter it in the HeatGuard app to finish creating your account.\n\n"
        "Do not share this code. If you did not request an account, ignore this email.\n\n"
        "The HeatGuard team"
    )
    context = ssl.create_default_context()
    try:
        if config.SMTP_USE_SSL:
            transport = smtplib.SMTP_SSL(
                config.SMTP_HOST, config.SMTP_PORT,
                timeout=15, context=context,
            )
        else:
            transport = smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT, timeout=15)
        with transport as server:
            if not config.SMTP_USE_SSL:
                server.ehlo()
                server.starttls(context=context)
                server.ehlo()
            server.login(config.SMTP_USERNAME, config.SMTP_PASSWORD)
            server.send_message(message)
    except (smtplib.SMTPException, OSError) as exc:
        # Never log messages, OTPs, credentials, or the SMTP server's auth response.
        logger.warning("Verification email delivery failed (%s)", type(exc).__name__)
        raise EmailDeliveryError(
            "We could not send your verification email. Please try again later."
        ) from exc
