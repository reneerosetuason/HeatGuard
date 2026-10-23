# HeatGuard code cheat sheet

All paths are relative to `C:\HeatGuard`. Click a filename to open it. The Python backend lives in the project root and `services/`; the Flutter frontend lives in `frontend/flutter/`.

## Start with these files

| If you want to find or change… | Open | What to look for |
| --- | --- | --- |
| Groq's reminder prompt | [services/routine_advice.py](../services/routine_advice.py) | `groq_tip()` → the `system` message in `messages`. This tells the model how to write the reminder. |
| Activity, local time, and location supplied to AI | [services/routine_advice.py](../services/routine_advice.py) | `activity_context()`; `forecast()` supplies weather near the activity time. |
| Advice when AI fails or returns unsuitable text | [services/routine_advice.py](../services/routine_advice.py) | `basic_tip()` supplies activity-aware fallback advice; `build_advice()` combines the result and forecast information. |
| When reminders are prepared and sent | [services/routine_jobs.py](../services/routine_jobs.py) | `occurrences()`, `run_due_routines()`, `dispatch_due_notifications()`, and the preparation/delivery interval constants. |
| Sending a notification through Firebase | [services/routine_push.py](../services/routine_push.py) | `access_token()` authenticates the backend; `send()` constructs and sends the FCM HTTP v1 payload. |
| Main mobile screens | [frontend/flutter/lib/screens/dashboard_screen.dart](../frontend/flutter/lib/screens/dashboard_screen.dart) | Dashboard state, selected location, Today, Trends, Safety, Settings, and daily reminder controls. |
| App colors and styling | [frontend/flutter/lib/theme/heatguard_theme.dart](../frontend/flutter/lib/theme/heatguard_theme.dart) | `HeatGuardColors` and `buildHeatGuardTheme()`. |

## Python backend

| File | Responsibility |
| --- | --- |
| [app.py](../app.py) | Creates/configures Flask, registers mobile API blueprints, and defines shared and legacy web routes. Start with `create_app()`. |
| [run.py](../run.py) | Starts the development backend. Run from the project root with `.\.venv\Scripts\python.exe run.py`. |
| [run_production.py](../run_production.py) | Starts the Waitress production server entry point. |
| [config.py](../config.py) | Loads environment settings and defines defaults, external API settings, heat-risk categories, and standard safety recommendations. |
| [.env](../.env) | Local settings: database, host/port, SMTP, Groq key/model, Firebase project, and service-account path. The values stay on the backend. |
| [.env.example](../.env.example) | Configuration template and setting names. |
| [requirements.txt](../requirements.txt) | Backend Python package dependencies. |
| [manage.py](../manage.py) | Command-line database setup/migrations, one-off monitoring, history backfill, and PAGASA comparison. |

### Weather, heat index, and addresses

| File | Responsibility |
| --- | --- |
| [services/weather.py](../services/weather.py) | Open-Meteo current/history requests and weather-data validation. `fetch_current_weather()` fetches current conditions. |
| [services/heat_index.py](../services/heat_index.py) | The heat-index calculation. Start with `calculate_heat_index_c()`. |
| [services/risk.py](../services/risk.py) | Maps calculated heat index to the configured PAGASA categories. Start with `classify_heat_index()`; category definitions live in `config.py`. |
| [services/dashboard.py](../services/dashboard.py) | Builds dashboard JSON, history, freshness, alerts, and the sun/moon/rain scene. Start with `build_dashboard()` and `_weather_scene()`. |
| [services/monitoring.py](../services/monitoring.py) | Fetches and saves weather periodically, manages collection status, and starts the scheduler loops. Start with `monitor_location()` and `MonitoringScheduler`. |
| [services/geocoding.py](../services/geocoding.py) | Searches place names through Open-Meteo geocoding. |
| [services/addresses.py](../services/addresses.py) | Philippine region/province/city/barangay selections and resolving an address to a weather location. |
| [services/private_locations.py](../services/private_locations.py) | Private saved-address ownership, creation, removal, and routine-location migration. |
| [services/private_location_api.py](../services/private_location_api.py) | Mobile dashboard, private address, and refresh HTTP endpoints under `/api/mobile/data`. |
| [services/pagasa_validation.py](../services/pagasa_validation.py) | Optional comparison against published PAGASA station inputs/heat indices, used by `manage.py validate-pagasa`. |

### Accounts and notifications

| File | Responsibility |
| --- | --- |
| [services/mobile_auth.py](../services/mobile_auth.py) | Registration, OTP verification, login, session, and logout HTTP routes under `/api/mobile/auth`. |
| [services/mobile_accounts.py](../services/mobile_accounts.py) | Account rules: password hashing, OTP generation/expiry/attempt limits, verification, and session creation/revocation. |
| [services/email_delivery.py](../services/email_delivery.py) | Gmail/SMTP connection and verification-email content. Start with `send_verification_code()`. |
| [services/security.py](../services/security.py) | Shared CSRF protection, rate limiting, and legacy web administrator access helpers. Mobile account rules are in the two files above. |
| [services/routine_api.py](../services/routine_api.py) | HTTP routes for routine CRUD, previews, inbox/read state, and phone registration/removal under `/api/mobile`. |
| [services/routine_store.py](../services/routine_store.py) | Routine validation and database operations, inbox entries, device tokens, occurrence claims, delivery retries, and completion timestamps. |
| [services/routine_advice.py](../services/routine_advice.py) | Forecast context, Groq prompt/request, response validation, fallback advice, and final reminder title/body. |
| [services/routine_jobs.py](../services/routine_jobs.py) | Finds due occurrences, prepares advice ahead of time, and dispatches ready reminders separately. |
| [services/routine_push.py](../services/routine_push.py) | Backend OAuth credentials and FCM delivery. |
| [services/push_notifications.py](../services/push_notifications.py) | Separate legacy browser/PWA push implementation. Android routine FCM uses `routine_push.py`. |

Routine reminder flow: `routine_jobs.py` → `routine_advice.py` → `routine_store.py` → `routine_push.py` → Android. The saved inbox item is exposed through `routine_api.py`.

## Flutter frontend

Paths in this table start inside `frontend/flutter/lib/`.

| File | Responsibility |
| --- | --- |
| [main.dart](../frontend/flutter/lib/main.dart) | Flutter entry point, app title/theme, and opening `AuthGate`. |
| [screens/auth_gate.dart](../frontend/flutter/lib/screens/auth_gate.dart) | Opens authentication or the dashboard according to the current session. |
| [screens/auth_screen.dart](../frontend/flutter/lib/screens/auth_screen.dart) | Login, registration, email-code verification forms, and server-address dialog. |
| [services/mobile_auth_controller.dart](../frontend/flutter/lib/services/mobile_auth_controller.dart) | Authentication state, secure native session storage, restoring login, sign-out, and changing servers. |
| [screens/dashboard_screen.dart](../frontend/flutter/lib/screens/dashboard_screen.dart) | Today, Trends, Safety, Settings, navigation, selected address, refresh, daily reminder settings, and weather artwork. `_HeatIllustrationPainter` draws the weather scene; `_scheduleDailyReminder()` supplies the selected location's content. |
| [screens/location_manager_sheet.dart](../frontend/flutter/lib/screens/location_manager_sheet.dart) | Add-address interface, Philippine address dropdowns, and place search. |
| [screens/routines_screen.dart](../frontend/flutter/lib/screens/routines_screen.dart) | Routine list/editor, activity/time/day/location fields, preview advice, and the enable/pause phone-notification button. |
| [widgets/notification_sidebar.dart](../frontend/flutter/lib/widgets/notification_sidebar.dart) | Bell, notification history/sidebar, unread indicators, and read actions. |
| [widgets/history_chart_card.dart](../frontend/flutter/lib/widgets/history_chart_card.dart) | Interactive weather-history charts. |
| [theme/heatguard_theme.dart](../frontend/flutter/lib/theme/heatguard_theme.dart) | Shared colors, text styles, and component styling. |
| [widgets/heatguard_brand.dart](../frontend/flutter/lib/widgets/heatguard_brand.dart) | Reusable logo, mark, and wordmark widgets. |
| [services/heatguard_api.dart](../frontend/flutter/lib/services/heatguard_api.dart) | HTTP client, backend requests, authentication headers/CSRF, API error handling, and server URL defaults. |
| [services/routines_controller.dart](../frontend/flutter/lib/services/routines_controller.dart) | Routine/inbox state, unread counts, merging remote and local history, and push registration/reconnection. |
| [services/routine_push_service.dart](../frontend/flutter/lib/services/routine_push_service.dart) | Firebase initialization, Android notification permission, FCM token retrieval/refresh, incoming messages, and notification taps. |
| [services/daily_notification_service.dart](../frontend/flutter/lib/services/daily_notification_service.dart) | Schedules/cancels the local daily device reminder; `_titleFor()` and `_bodyFor()` create its text from the loaded dashboard. |
| [services/daily_reminder_history.dart](../frontend/flutter/lib/services/daily_reminder_history.dart) | Stores due daily reminders and read state locally per account/server and reconciles occurrences when the app returns. |
| [models/heatguard_models.dart](../frontend/flutter/lib/models/heatguard_models.dart) | Dart models for dashboard, locations, readings, alerts, history, and address search. |
| [models/routine_models.dart](../frontend/flutter/lib/models/routine_models.dart) | Dart models for routines and notification entries. |
| [models/mobile_account.dart](../frontend/flutter/lib/models/mobile_account.dart) | Dart models for accounts and pending registration challenges. |

The daily device reminder follows the selected saved address and uses its last loaded weather. Routine notifications use the server's forecast/Groq/FCM workflow. The app uses saved locations rather than continuous GPS tracking.

## Database files

| File | Responsibility |
| --- | --- |
| [services/db.py](../services/db.py) | MySQL connections plus shared location, weather-reading, alert, and monitoring queries. Account/routine/private-address queries also live in their respective service files. |
| [sql/schema.sql](../sql/schema.sql) | Complete database schema, including mobile accounts, routines, inbox, delivery tracking, and private address tables. |
| [sql/mobile_routines.sql](../sql/mobile_routines.sql) | Routine, notification, device-registration, and delivery table definitions used by the routine migration. |
| [sql/mobile_locations.sql](../sql/mobile_locations.sql) | Private saved-address ownership table used by the location migration. |

Database setup commands live in `manage.py`. The current checkout includes account table definitions in `schema.sql`; `init-mobile-auth` supports extracting them when the separate older `mobile_accounts.sql` file is absent.

## Firebase, branding, and build files

| File/location | Responsibility |
| --- | --- |
| [frontend/flutter/pubspec.yaml](../frontend/flutter/pubspec.yaml) | Flutter packages, app version, and bundled image assets. Run `flutter pub get` in this folder after changing dependencies. |
| [frontend/flutter/android/app/google-services.json](../frontend/flutter/android/app/google-services.json) | Android Firebase client configuration. |
| File referenced by `GOOGLE_APPLICATION_CREDENTIALS` in `.env` | Private Firebase service-account JSON used by Python to authenticate FCM requests. |
| [frontend/flutter/android/app/src/main/AndroidManifest.xml](../frontend/flutter/android/app/src/main/AndroidManifest.xml) | Android permissions, activities, notification channel metadata, and launcher icon references. |
| [frontend/flutter/assets/branding/heatguard_logo.png](../frontend/flutter/assets/branding/heatguard_logo.png) | Full in-app logo image. |
| [frontend/flutter/assets/branding/heatguard_mark.png](../frontend/flutter/assets/branding/heatguard_mark.png) | Compact in-app logo mark. |
| `frontend/flutter/android/app/src/main/res/mipmap-*` | Android launcher icon resources shown on the phone home screen/app drawer. |
| [frontend/flutter/build/app/outputs/flutter-apk/app-debug.apk](../frontend/flutter/build/app/outputs/flutter-apk/app-debug.apk) | Generated Android debug APK. |

## Tests and presentation references

| File/location | What it helps explain |
| --- | --- |
| [tests/test_routine_personalization.py](../tests/test_routine_personalization.py) | AI receives activity/time/location/weather context; unsuitable responses use fallback advice. |
| [tests/test_routine_timing.py](../tests/test_routine_timing.py) | Preparation and delivery timing behavior. |
| [tests/test_mobile_auth.py](../tests/test_mobile_auth.py) | Registration, verification, sessions, and access-control behavior. |
| [tests/test_private_locations.py](../tests/test_private_locations.py) | Account ownership and private locations. |
| [tests/test_heat_index.py](../tests/test_heat_index.py), [tests/test_risk.py](../tests/test_risk.py) | Heat-index calculation and risk categories. |
| [frontend/flutter/test/daily_reminder_history_test.dart](../frontend/flutter/test/daily_reminder_history_test.dart) | Daily reminder history and account/server isolation. |
| [frontend/flutter/test/routine_connection_test.dart](../frontend/flutter/test/routine_connection_test.dart) | Phone notification connection behavior. |
| [docs/PRESENTATION_NOTES.md](PRESENTATION_NOTES.md) | Architecture, APIs, user journey, limitations, and panel questions. |
| [docs/PRESENTATION_READINESS.md](PRESENTATION_READINESS.md) | Dated validation results and demonstration checklist. |
| [frontend/flutter/README.md](../frontend/flutter/README.md) | Flutter setup and running instructions. |

Backend changes take effect after restarting the backend. Flutter code/asset changes require reloading or rebuilding the app; a new installed APK requires a build and installation. Changing Flutter code does not require database changes unless the schema also changes.
