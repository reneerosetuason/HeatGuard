"""Smoke tests that the Jinja templates compile and render (no database)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import create_app  # noqa: E402
from flask import render_template  # noqa: E402

MINIMAL_DASHBOARD = {
    "location": {
        "id": 1,
        "name": "Metro Manila",
        "latitude": 14.5995,
        "longitude": 120.9842,
        "timezone": "Asia/Manila",
    },
    "locations": [{"id": 1, "name": "Metro Manila", "timezone": "Asia/Manila"}],
    "last_success_at_display": "Oct 19, 2026 6:00 PM",
    "risk_source_url": "https://www.pagasa.dost.gov.ph/weather/heat-index",
    "disclaimer": "Informational guidance only.",
}


class TemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = create_app()

    def test_templates_compile(self):
        with self.app.app_context():
            for name in ("base.html", "dashboard.html", "error.html"):
                self.app.jinja_env.get_template(name)

    def test_dashboard_renders_key_regions(self):
        with self.app.test_request_context("/"):
            html = render_template(
                "dashboard.html",
                initial_data=MINIMAL_DASHBOARD,
                app_name="HeatGuard",
                app_subtitle="Community heat watch",
            )
        self.assertIn("Community Heat Watch", html)
        self.assertIn("Add my location", html)
        self.assertIn("locationModal", html)
        self.assertIn("static/js/dashboard.js", html)

    def test_error_page_renders(self):
        with self.app.test_request_context("/"):
            html = render_template(
                "error.html",
                app_name="HeatGuard",
                message="HeatGuard could not read the database.",
                details="Access denied for user",
                db_name="HeatGuard",
            )
        self.assertIn("HeatGuard could not read the database.", html)
        self.assertIn("init-db", html)


if __name__ == "__main__":
    unittest.main()
