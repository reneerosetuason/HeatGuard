# HeatGuard

**Heat Index Monitoring and Early Warning System for Community Health and
Climate Resilience** — an information system aligned with **UN Sustainable
Development Goal 13: Climate Action**.

HeatGuard monitors temperature, relative humidity, and the calculated heat
index for a chosen community using the free **[Open-Meteo](https://open-meteo.com/)**
weather API, classifies heat risk with **PAGASA** heat-index categories, and
raises **in-dashboard alerts** with safety recommendations. It needs **no IoT
hardware, no sensor, no SMS credits, and no paid services**.

---

## 1. Features

- **Current conditions** — temperature (°C), relative humidity (%), calculated
  heat index (°C), monitoring location, last update time, and risk category.
- **In-dashboard heat alerts** — a prominent warning banner and alert cards with
  level, heat-index value, location, timestamp, and precautions. Alerts use
  icons **and** text labels, not colour alone.
- **Duplicate prevention** — a new alert is recorded only when the risk
  **category changes** (to Caution or higher). Refreshing the page does not
  create repeats; a full alert history is kept.
- **Heat-risk classification** — configurable, centralised PAGASA thresholds.
- **Historical monitoring** — charts for temperature, humidity, heat index (with
  risk bands), and recorded warning levels, over 24 hours or 7 days.
- **User-selected location** — browse all Philippine regions, provinces,
  cities/municipalities, and barangays from the official PSA PSGC list, or
  search by place name (Open-Meteo geocoding), then monitor that address.
- **Safety recommendations** — precautions per risk category, with a clear
  disclaimer that the system is informational only.
- **Data reliability** — loading indicators, API-error messages, last-updated
  timestamps, a stale-data warning, and input validation. Missing data is
  **never** shown as "safe", and forecast hours are never stored as history.
- **Background monitoring** — a scheduler thread keeps collecting and alerting
  even when no browser is open (single-process deployment).
- **Installable phone app** — the separate `mobile_app/` PWA shows local
  weather and recommendations, with an optional daily device notification.
- **Native mobile app** — the separate `mobile_flutter/` Flutter project includes
  location management, current conditions, history charts, active and recent
  alerts, recommendations, and daily Android/iOS device notifications.

---

## 2. Architecture and data flow

```
 Open-Meteo API                         MySQL database "HeatGuard"
 (temperature_2m,        ┌───────────►  locations · readings · alerts
  relative_humidity_2m)  │               monitoring_status
        │                │
        ▼                │
 validate response ─► heat-index (Rothfusz) ─► PAGASA classification
        │                                              │
        │                                              ▼
        └──────────► store reading ──────────► alert if category changed
                                                       │
                                                       ▼
                                       Flask JSON API ─► dashboard (Chart.js)
```

A background **scheduler thread** performs the fetch → validate → calculate →
classify → store → alert cycle every `MONITOR_INTERVAL_SECONDS` (default 600 s =
10 minutes, matching Open-Meteo's roughly 15-minute update cadence). The web
dashboard reads stored data from MySQL, so opening or refreshing the page never
triggers extra weather-API calls.

---

## 3. Technology

| Layer | Choice |
| --- | --- |
| Backend | Python + Flask |
| Database | MySQL 8 (`HeatGuard`) via PyMySQL |
| Weather data | Open-Meteo (current + geocoding, free, no API key) |
| Address data | PSA PSGC masterlist via the `psgc` Python package (local, no API key) |
| Frontend | HTML, CSS, JavaScript, Bootstrap 5, Bootstrap Icons |
| Charts | Chart.js |
| Alerts | In-dashboard alerts and optional daily device notifications |

> **Note on Streamlit:** this project is a Flask application with an
> HTML/JS dashboard. Streamlit is not used, so there is only one dashboard
> framework.

---

## 4. Folder structure

```
HeatGuard/
├── app.py                     # Flask app factory, routes, JSON API
├── run.py                     # Convenience launcher (app + scheduler)
├── manage.py                  # CLI: init-db, monitor-once, backfill
├── config.py                  # All settings + PAGASA thresholds (single source)
├── requirements.txt
├── .env.example               # Copy to .env and edit
├── sql/
│   └── schema.sql             # Database, tables, seed locations
├── services/
│   ├── weather.py             # Open-Meteo client + response validation
│   ├── heat_index.py          # Rothfusz heat-index calculation
│   ├── risk.py                # PAGASA risk classification
│   ├── geocoding.py           # Open-Meteo location search
│   ├── addresses.py           # PSA PSGC address lookup and coordinates
│   ├── db.py                  # MySQL access layer (readings, alerts, status)
│   ├── monitoring.py          # Monitor cycle + background scheduler
│   └── dashboard.py           # Builds the dashboard/JSON payload
├── templates/
│   ├── base.html
│   ├── dashboard.html
│   └── error.html
├── static/
│   ├── css/dashboard.css
│   └── js/dashboard.js
├── mobile_app/                # Installable PWA and browser push notifications
├── mobile_flutter/             # Native Flutter app for Android and iOS
└── tests/                     # pytest / unittest suite
```

Additional files: `services/security.py` (auth/CSRF/rate limits),
`services/pagasa_validation.py` (PAGASA comparison), `run_production.py`
(Waitress), `templates/admin_login.html`, `sql/create_app_user.sql`,
`requirements-dev.txt`, `pytest.ini`, and `.github/workflows/ci.yml`.

---

## 5. Setup

### 5.1 Prerequisites

- Python 3.10+ (developed and tested on Python 3.14)
- MySQL 8.0 server running locally (MySQL Workbench optional)

### 5.2 Install Python dependencies

```powershell
cd C:\HeatGuard
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

For the browser tests, install the development dependencies and Chromium:

```powershell
pip install -r requirements-dev.txt
python -m playwright install chromium
```

### 5.3 Configure the environment

```powershell
copy .env.example .env
```

Edit `.env` and set the database credentials:

```ini
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=root
DB_PASSWORD=your_mysql_password
DB_NAME=HeatGuard
```

Other useful settings: `MONITOR_INTERVAL_SECONDS`, `STALE_AFTER_SECONDS`,
`MONITOR_ENABLED` (set to `0` to disable the background scheduler), `HOST`,
`PORT`.

Write protection is configured separately:

- `ADMIN_PASSWORD`: set a strong password to enable remote admin sign-in.
  When empty, only requests from the machine running HeatGuard may add/remove
  locations or refresh weather.
- `ADMIN_USERNAME`: defaults to `admin`.
- `CSRF_ENABLED`: keep enabled (default `1`) for browser form/API protection.
- `ALLOW_LOCAL_WRITES`: when no admin password is set, controls whether
  loopback requests may change data.
- `SESSION_COOKIE_SECURE`: set to `1` when serving over HTTPS.
- `TRUST_PROXY`: set to `1` **only** behind a trusted reverse proxy that
  overwrites `X-Forwarded-For`/`X-Forwarded-Proto`.

For a least-privilege database account, run `sql/create_app_user.sql` once as a
MySQL administrator and use those credentials in `.env` instead of `root`.

### 5.4 Create the database (migration)

The `HeatGuard` schema is created by `sql/schema.sql`, which also seeds five
default Philippine monitoring locations. Run:

```powershell
python manage.py init-db
```

This creates the database, the `locations`, `readings`, `alerts`,
`monitoring_status`, and `mobile_push_subscriptions` tables, plus the seed locations. It is safe to run again
(`CREATE ... IF NOT EXISTS`, idempotent seeds).

> Equivalent manual command: `mysql -u root -p < sql/schema.sql`

### 5.5 Run the application

```powershell
python run.py
```

Then open <http://127.0.0.1:5000>.

Open <http://127.0.0.1:5000/mobile/> on a phone to use the installable mobile
app. For daily device notifications, configure VAPID keys and HTTPS as
described in [mobile_app/README.md](mobile_app/README.md), run
`python manage.py init-db` to create the subscription table, and enable
notifications in the app.

For the native Android/iOS client, follow [mobile_flutter/README.md](mobile_flutter/README.md).
It schedules a daily local notification using the latest weather and
recommendation downloaded by the app.

- On first start the scheduler fetches current conditions for every active
  location and stores the first readings/alerts.
- Use **Refresh now** to fetch immediately (rate-limited by
  `MANUAL_REFRESH_COOLDOWN_SECONDS`).
- Use **Add my location** to browse a Philippine address down to the barangay,
  or switch to **Search by name** to monitor another city/municipality.
- If `ADMIN_PASSWORD` is set, sign in at `/admin/login` before changing data.
  Without it, the dashboard is read-only for other machines.

For production, use Waitress instead of Flask's development server:

```powershell
python run_production.py
```

Set a random `SECRET_KEY` of at least 32 characters (placeholders are
rejected), a strong `ADMIN_PASSWORD`, the least-privilege database account,
and `SESSION_COOKIE_SECURE=1` when HTTPS is enabled.

### 5.6 Useful maintenance commands

```powershell
python manage.py monitor-once            # one collection cycle, prints results
python manage.py backfill --days 7       # fill charts with past hourly data
python manage.py backfill --days 3 --location 1
python manage.py validate-pagasa         # compare with PAGASA station data
python manage.py validate-pagasa --json  # full machine-readable report
```

`validate-pagasa` reads the public DOST-PAGASA/PANaHON Automatic Weather
Station heat-index data and compares PAGASA's reported heat index with
HeatGuard's calculation using the same temperature and humidity. It reports
MAE, RMSE, bias, percentage within 1/2 °C, and category agreement.

---

## 6. API endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | Dashboard page (server-rendered initial payload) |
| GET | `/api/dashboard?location=<id>&hours=<n>` | Dashboard JSON payload |
| GET | `/api/locations` | Active monitoring locations |
| POST | `/api/locations` | Add a location (`name`, `latitude`, `longitude`, `timezone`) |
| GET | `/api/address/regions` | PSGC regions for the address picker |
| GET | `/api/address/provinces?region_code=<code>` | Provinces and independent cities |
| GET | `/api/address/cities?province_code=<code>` | Cities and municipalities |
| GET | `/api/address/barangays?city_code=<code>` | Barangays in a city or municipality |
| POST | `/api/locations/address` | Validate a PSGC hierarchy and monitor the barangay |
| DELETE | `/api/locations/<id>` | Stop monitoring a location (soft delete) |
| GET | `/api/geocode?q=<text>` | Location search (Open-Meteo geocoding) |
| POST | `/api/refresh` | Fetch fresh weather now (`location_id`), cooldown-limited |
| GET | `/api/health` | Health check: database + scheduler status |
| GET | `/mobile/` | Installable mobile web app |
| GET | `/api/mobile/config` | Notification setup and CSRF token for the mobile app |
| POST | `/api/mobile/push/subscribe` | Save this device's daily notification settings |
| POST | `/api/mobile/push/unsubscribe` | Disable notifications for this device |
| GET/POST | `/admin/login` | Admin sign-in (required when `ADMIN_PASSWORD` is set) |
| POST | `/admin/logout` | End the admin session |

All write endpoints require the session CSRF token and are rate limited. The
monitoring-location and refresh endpoints also require an admin session when
`ADMIN_PASSWORD` is configured (or a loopback request when it is not). Mobile
push subscription endpoints are device self-service and do not require admin
sign-in.

---

## 7. Heat index and risk thresholds

### Heat index

Open-Meteo provides only temperature and relative humidity, so the heat index is
**calculated** with the **Rothfusz regression** used by the US National Weather
Service / NOAA (including the low- and high-humidity adjustments). Because it is
computed, the dashboard labels it an **API estimate**, not a sensor reading.

Reference: <https://www.weather.gov/ama/heatindex>

### PAGASA categories (`config.RISK_CATEGORIES`)

| Heat index | Category | Level | Effect |
| --- | --- | --- | --- |
| < 27 °C | Low Risk | 0 | Not in the caution range |
| 27–32 °C | Caution | 1 | Fatigue possible with prolonged exposure |
| 33–41 °C | Extreme Caution | 2 | Heat cramps and heat exhaustion possible |
| 42–51 °C | Danger | 3 | Heat exhaustion likely; heat stroke possible |
| ≥ 52 °C | Extreme Danger | 4 | Heat stroke imminent |

Source: **PAGASA Heat Index classification** —
<https://www.pagasa.dost.gov.ph/weather/heat-index>. The lowest row (below
27 °C) is added for completeness because the official table begins at 27 °C.
Thresholds and recommendations live in **one place** (`config.py`) and are never
hardcoded elsewhere.

### Alert logic (duplicate prevention)

For each location the system stores the latest reading and compares its risk
category with the previous category. An alert row is created **only when the
category changes into a warning category (Caution or higher)**. The `alerts`
table also has a unique key on `(location_id, reading_id, risk_key)` as a second
guard. Repeated refreshes of an unchanged category therefore never create
duplicate alerts.

---

## 8. Database schema (summary)

- **locations** — `id`, `name` (unique), `latitude`, `longitude`, `timezone`,
  `is_active`, `created_at`.
- **readings** — `id`, `location_id`, `observed_at` (UTC, unique with location),
  `fetched_at`, `temperature_c`, `humidity_pct`, `heat_index_c`, `risk_key`,
  `risk_label`, `source`, `api_timezone`, `raw_payload`.
- **alerts** — `id`, `location_id`, `reading_id`, `risk_key`, `risk_label`,
  `temperature_c`, `humidity_pct`, `heat_index_c`, `observed_at`,
  `generated_at`, `message`, `recommendations` (JSON).
- **monitoring_status** — per-location `last_attempt_at`, `last_success_at`,
  `last_observed_at`, `last_error_at`, `last_error_message`,
  `consecutive_failures`.
- **mobile_push_subscriptions** — per-device browser push endpoint, selected
  location, local reminder time/time zone, and last successful delivery date.

---

## 9. Testing

```powershell
# with the virtual environment activated
pytest -q
```

The pytest suite covers the heat-index calculation and validation, PAGASA
classification boundaries, Open-Meteo response validation (mocked, no network),
dashboard reliability behaviour (no-data and stale data are not treated as
safe), location-management/geocoding routes, PSGC address lookup and hierarchy
validation, address-based location creation, template rendering, admin
authentication, CSRF, rate limiting, security headers, and PAGASA/PANaHON
report parsing.

The `tests/e2e` suite drives a real Edge/Chromium browser through Playwright.
It starts an isolated local server with stubbed weather/address data, checks
the dashboard and address-picker flow, verifies that writes carry the CSRF
token, and exercises the read-only, admin sign-in, and sign-out flow. Run it
with:

```powershell
pytest -q -m e2e
```

The GitHub Actions workflow in `.github/workflows/ci.yml` installs Chromium and
runs the full suite.

---

## 10. Reliability behaviour

- Missing/invalid API values are rejected and never treated as a safe level.
- A reading older than `STALE_AFTER_SECONDS` is shown as **stale/historical**,
  never as current.
- API failures are recorded per location (`last_error_message`,
  `consecutive_failures`) and surfaced in the dashboard's Data status panel.
- Forecast hours are excluded from history; only observed hours are stored.
- The scheduler lock prevents overlapping collection cycles.

---

## 11. Limitations (college project scope)

- The data is **API-estimated**, not measured by a physical sensor; it is a
  produced/model estimate for the selected coordinates.
- HeatGuard gives **informational guidance only** and does not replace official
  PAGASA / LGU warnings or professional medical advice.
- The background scheduler runs inside the web process. For a multi-process or
  hosted deployment, run a single scheduler process (or a task queue) so that
  API calls and alerts are not duplicated.
- Daily push notifications require HTTPS, configured VAPID keys, a running
  scheduler process, and permission from the device's browser/operating system.
- There is no SMS or email notification channel.
- Address choices come from a bundled PSGC snapshot (2026-04-13). Update the
  pinned `psgc` package to pick up newly created or renamed barangays.

---

## 12. Reference

The project structure and monitoring/risk/dashboard concepts were adapted from
the MIT-licensed **[AI Heat Stress Detection](https://github.com/IndrajitDutta420/AI-Heat-Stress-Detection)**
reference system, re-implemented to use a **weather API instead of mandatory
IoT hardware**, a **MySQL** store, and **free in-dashboard alerts** instead of
SMS/paid notifications.

Philippine address names and coordinates come from the **PSA PSGC masterlist**
(2026-04-13 snapshot), bundled locally through the MIT-licensed `psgc` Python
package.

---

## 13. License

Released under the MIT License, consistent with the reference project.
