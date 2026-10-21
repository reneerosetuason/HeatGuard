"""Start the HeatGuard web application and background monitor."""

from __future__ import annotations

import os

from app import create_app
from services.monitoring import start_scheduler

app = create_app(start_monitor=True, allow_local_web_preview=True)
start_scheduler()


if __name__ == "__main__":
    app.run(
        host=os.getenv("HOST", "127.0.0.1"),
        port=int(os.getenv("PORT", "5000")),
        debug=False,
        use_reloader=False,
    )
