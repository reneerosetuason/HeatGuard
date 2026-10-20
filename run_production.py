"""Production entry point for HeatGuard using the Waitress WSGI server."""

from __future__ import annotations

import logging
import os
import sys

from waitress import serve

import config
from app import create_app
from services.monitoring import start_scheduler

logger = logging.getLogger(__name__)

INSECURE_SECRET_KEYS = {
    "dev-only-change-this-secret",
    "change-me-to-a-random-string",
}


def _is_secure_secret(value: str) -> bool:
    return len(value or "") >= 32 and value not in INSECURE_SECRET_KEYS


def main() -> int:
    if not _is_secure_secret(config.SECRET_KEY):
        print(
            "ERROR: Set a strong random SECRET_KEY (at least 32 characters) "
            "in .env before production.",
            file=sys.stderr,
        )
        return 1
    if not config.ADMIN_PASSWORD:
        print(
            "WARNING: ADMIN_PASSWORD is not set. Remote changes will be denied; "
            "only the HeatGuard host can modify monitoring data.",
            file=sys.stderr,
        )

    app = create_app(start_monitor=True)
    start_scheduler()

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "5000"))
    print(f"HeatGuard listening on http://{host}:{port}")
    serve(
        app,
        host=host,
        port=port,
        threads=int(os.getenv("WAITRESS_THREADS", "4")),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
