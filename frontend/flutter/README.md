# HeatGuard Mobile

This Flutter project is kept in `frontend/flutter`. It provides the HeatGuard dashboard on Android and iOS, with a Flutter Web build for a Chrome preview.

## Features

- Email registration with a one-time verification code, sign-in, secure session restoration, and sign-out. A verified account is required before opening the dashboard.
- A soft teal, warm sand, and off-white theme with clear risk labels, comfortable touch targets, and support for larger text.
- Bottom navigation for **Today**, **Trends**, **Safety**, and **Settings**, with swipe navigation and reduced-motion support.
- Switch between monitored locations and add a place by search or by selecting a Philippine address.
- Stop monitoring a location while keeping its stored history on the server.
- View the current temperature, humidity, heat index, risk level, active alert, and safety recommendations.
- Browse stored history over 24 hours or 7 days, with selectable heat index, temperature, humidity, and risk charts.
- Tap or drag across a chart to inspect a reading; screen readers can increase or decrease the selected reading.
- Review recent heat alerts, data freshness, update errors, and the weather and PAGASA heat-index sources.
- Refresh weather data, pull to refresh, and automatically reload the dashboard while the app is open.
- Schedule a daily Android or iOS notification with the latest loaded weather and a safety recommendation.

Location changes and manual refresh use the same authorization and CSRF protections as the web dashboard. When administrator authentication is enabled, sign in from the app before making changes. When it is not enabled, server-side local-host write restrictions still apply.

## Account and email setup

The Flutter app opens with sign-in and registration. Registration sends a six-digit email code; the account is created and signed in only after that code is verified. Codes expire after 10 minutes, allow five incorrect attempts, and can be resent after 60 seconds. Each email can receive at most five verification emails per hour. Passwords must contain 12 to 128 characters.

From the repository root, add the account tables to an existing database:

```powershell
.\.venv\Scripts\python.exe manage.py init-mobile-auth
```

This migration adds tables without changing monitored locations or historical readings. New installations using `manage.py init-db` already include these tables.

For Gmail delivery, enable Google 2-Step Verification and create an [App Password](https://support.google.com/mail/answer/185833?hl=en). Add these settings to the root `.env`:

```ini
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USE_SSL=0
SMTP_USERNAME=your-address@gmail.com
SMTP_FROM=your-address@gmail.com
SMTP_PASSWORD=your-16-character-app-password
```

Gmail App Passwords may be pasted with or without their display spaces; the server removes those spaces for Gmail. Keep the password in the Python server's `.env`. Restart the API after changing these settings. Registration reports an error if email delivery is not configured or Gmail rejects the message; it never accepts a fake code or skips verification.

The app restores valid sessions at startup. Android and iOS keep opaque session tokens in protected device storage; the browser preview uses an HttpOnly cookie. Sessions expire after seven days, and signing out revokes the session and returns to the login screen. The app's `/api/mobile/data/*` routes require a verified, signed-in account. Existing administrator permissions still control changes to shared monitoring locations.

Android builds require API 23 or later for encrypted session storage. Use HTTPS for a deployed API and set `SESSION_COOKIE_SECURE=1` for HTTPS browser sessions. The localhost preview uses the existing HTTP development settings.

## Run on an emulator

From the repository root, enter this folder, install packages, and run the app:

```powershell
Set-Location frontend/flutter
flutter pub get
flutter run --dart-define=HEATGUARD_API_BASE_URL=http://10.0.2.2:5000
```

`10.0.2.2` is the Android emulator address for the development computer. For the iOS simulator, use `http://127.0.0.1:5000` instead:

```powershell
flutter run --dart-define=HEATGUARD_API_BASE_URL=http://127.0.0.1:5000
```

## Preview in Chrome

From `C:\HeatGuard`, run the launcher to start the Python API and Flutter together:

```powershell
.\run_mobile.ps1
```

It uses `.venv\Scripts\python.exe` directly, installs the Flutter packages, checks MySQL and the allowed browser origin, and opens the app at `http://localhost:7357`. You do not need to activate the Python venv. Keep the terminal open while using the app. Press `q` to close the preview; the launcher also stops the API if it started it. An API that was already running stays running.

For a browser preview without launching Chrome automatically, use `.\run_mobile.ps1 -WebServer` and open the printed URL yourself.

To start the two services manually instead, follow the commands below. The `run.py` development server allows Flutter previews on any local `localhost`, `127.0.0.1`, or `::1` port. This includes the random port chosen by `flutter run -d chrome`; restart the API after updating the code. Deployed servers use the explicit `WEB_CORS_ORIGINS` list.

Start HeatGuard from the repository root:

```powershell
.\.venv\Scripts\python.exe run.py
```

From the repository root, enter this folder and run the Flutter app in Chrome:

```powershell
Set-Location frontend/flutter
flutter run -d chrome --web-hostname localhost --web-port 7357 --dart-define=HEATGUARD_API_BASE_URL=http://localhost:5000
```

To preview a compiled web build instead, run `flutter build web --release`, then serve `build/web` on port 7357. Device notifications are available in the Android and iOS apps; the browser preview explains that they are unavailable in Chrome.

Open **Settings → HeatGuard server** to change and save the API address. These settings remain accessible when the server is unavailable. On a physical phone, use a reachable HeatGuard server address. For a local Flask server, bind it to `0.0.0.0` and use the computer's LAN IP, such as `http://192.168.1.20:5000`. The phone and computer must be on the same network, and the firewall must allow that port. Use HTTPS for a deployed server.

If the app says it cannot reach the server, check that `http://localhost:5000/api/health` reports `database: "ok"`, and use the **Server settings** button on the error card to check the address. The local Chrome preview uses `http://localhost:5000`; Android emulators use `http://10.0.2.2:5000`. Restart the Python server after changing `.env`.

## Check the mobile interface

From `frontend/flutter`, run `flutter analyze` and `flutter test`. The widget tests cover registration, email verification, sign-in, sign-out, session expiry, navigation, chart controls, location switching, missing and stale readings, connection settings, and small screens with larger text. They use local fixtures and do not require the API server.

To also render the four mobile screens to `build/design-previews/`, run:

```powershell
flutter test --dart-define=CAPTURE_MOBILE_PREVIEWS=true
```

These previews use test weather data.

## Daily notification behavior

The app downloads the weather and recommendations from `/api/mobile/data/dashboard`, then stores that message in the operating system's local notification scheduler. Android and iOS can deliver it every day while the app is closed; Android also reschedules it after a device reboot. The scheduled message contains the most recently downloaded reading. Opening the app or refreshing the dashboard updates the next daily message. The app asks for notification permission after sign-in; the user can change the daily time or pause the reminder in the dashboard. Signing out cancels scheduled account notifications.

## Server requirements

The HeatGuard Flask server must be running and reachable from the device. It must provide the dashboard, locations, geocoding, and address lookup API routes used by the features above. Configure at least one monitored location in HeatGuard before opening the mobile app.

The Android manifest permits cleartext HTTP for local development. Use an HTTPS server for deployment and disable cleartext traffic before publishing a production build.
