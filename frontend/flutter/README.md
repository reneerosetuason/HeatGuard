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
- Save personal recurring routines, preview weather advice, and receive Android Firebase push reminders with optional Groq personalization.
- Open the notification bell for a persistent sidebar inbox, unread counts, and mark-as-read controls.

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

The Firebase packages require iOS 15 or later. The iOS deployment settings match that minimum; native iOS builds require macOS/Xcode and have not been validated on this Windows workspace.

## Weather reminders for personal routines

The calendar icon in the dashboard opens **My routines**. Add an activity, a monitored weather location, its local time, repeat days, and a reminder lead time (up to two hours). Each verified account can save 20 routines. Activities use the selected location's IANA time zone. Editing, pausing, and deleting routines require only the owning account, without administrator access.

From the repository root, install the backend dependency and apply the additive migration:

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe manage.py init-mobile-routines
```

New installations using the full `sql/schema.sql` already include these tables. Existing monitored locations, readings, and accounts are preserved. Add these settings to the server's root `.env`, then restart `run.py`:

```ini
GROQ_API_KEY=your-groq-key
GROQ_MODEL=openai/gpt-oss-20b
FIREBASE_PROJECT_ID=your-firebase-project-id
GOOGLE_APPLICATION_CREDENTIALS=C:/Users/your-user/.heatguard/firebase-service-account.json
ROUTINES_ENABLED=1
```

Keep the downloaded Firebase Admin service-account JSON at the private path above. It must belong to the same Firebase project as `android/app/google-services.json`. The Admin JSON and Groq key stay on the Python server; never place them in Flutter assets or source control. The client `google-services.json` is the Android Firebase configuration and does not replace the private Admin JSON.

Run Flutter packages with `flutter pub get`, rebuild the Android app, sign in, and choose **My routines → Enable phone notifications**. Allow Android notification permission. Firebase push requires a device/emulator with Google Play services and network access. The Python API and its scheduler must remain running. For a physical phone, run the API on a reachable LAN address and configure the app's API address accordingly; use HTTPS for a deployed API.

The scheduler checks every minute. Around the chosen reminder time it retrieves the Open-Meteo hourly forecast for the activity, calculates its heat index, and adds factual safety guidance. Groq may add a short preparation tip using the activity label and forecast; account email, account password, and device tokens are never sent to Groq. If Groq fails, weather guidance is still delivered. If the forecast fails, the message clearly says weather could not be checked. Forecasts are never saved as measured history. Reminders are informational and may be delayed by network or phone settings.

Each occurrence is saved once in the account's inbox, with retry work tracked separately for Android delivery. The bell opens the latest 100 notifications; mark individual messages or all messages read. Past messages remain after deleting a routine. Signing out revokes the device registration, and expired sessions stop push until the user signs in again. A server outage can catch up a reminder until five minutes after the activity; older missed reminders are skipped.

**Chrome preview:** routines, previews, and the sidebar work while signed in, with inbox refresh every 30 seconds. This implementation sends remote push on Android. Browser background push would additionally require a Firebase Web app, VAPID key, and service worker; iOS remote push would require Firebase iOS/APNs setup. The existing daily local notification is independent of routine reminders.

To check delivery, add a routine a few minutes ahead on today's weekday, select **0 minutes before**, keep the API running, and background the Android app. Check both the phone notification and bell inbox. **Preview reminder** generates sample wording without saving or sending a notification.

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

For a physical Android phone:

1. Connect the phone and computer to the same Wi-Fi network.
2. Set `HOST=0.0.0.0` in the root `.env` and restart the Python API. The Windows launcher respects this setting.
3. Run `ipconfig` on the computer and find the Wi-Fi **IPv4 Address**.
4. On the phone, open `http://YOUR_COMPUTER_IP:5000/api/health` in its browser. It should return JSON with `database: "ok"`. If it cannot load, check the API process, Windows Firewall, and Wi-Fi client isolation.
5. In the app's sign-in screen, tap the top-right **Server settings** icon, enter `http://YOUR_COMPUTER_IP:5000`, and tap **Save**. If already signed in, use **Settings → HeatGuard server**. The saved address takes precedence over build-time defaults.

`localhost` and `127.0.0.1` on a phone refer to the phone itself. `10.0.2.2` works for the Android emulator. `0.0.0.0` is the server's listening address; use the computer's actual LAN IP in the phone app. If DHCP later changes the computer's IP, update the saved app address. The computer and API must stay on for local testing.

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
