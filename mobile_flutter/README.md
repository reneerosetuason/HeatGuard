# HeatGuard Mobile

The Flutter project is kept in this folder. It provides the HeatGuard dashboard on Android and iOS, with a Flutter Web build for a Chrome preview.

## Features

- Switch between monitored locations and add a place by search or by selecting a Philippine address.
- Stop monitoring a location while keeping its stored history on the server.
- View the current temperature, humidity, heat index, risk level, active alert, and safety recommendations.
- Browse stored history over 24 hours or 7 days, with selectable heat index, temperature, humidity, and risk charts.
- Review recent heat alerts, data freshness, update errors, and the weather and PAGASA heat-index sources.
- Refresh weather data, pull to refresh, and automatically reload the dashboard while the app is open.
- Schedule a daily Android or iOS notification with the latest loaded weather and a safety recommendation.

Location changes and manual refresh use the same authorization and CSRF protections as the web dashboard. When administrator authentication is enabled, sign in from the app before making changes. When it is not enabled, server-side local-host write restrictions still apply.

## Run on an emulator

From this folder, install packages and run the app:

```powershell
flutter pub get
flutter run --dart-define=HEATGUARD_API_BASE_URL=http://10.0.2.2:5000
```

`10.0.2.2` is the Android emulator address for the development computer. For the iOS simulator, use `http://127.0.0.1:5000` instead:

```powershell
flutter run --dart-define=HEATGUARD_API_BASE_URL=http://127.0.0.1:5000
```

## Preview in Chrome

Configure the Flask server to allow the local Flutter preview origin, then start HeatGuard from the repository root:

```powershell
$env:WEB_CORS_ORIGINS = 'http://localhost:7357'
python run.py
```

From this folder, run the Flutter app in Chrome:

```powershell
flutter run -d chrome --web-hostname localhost --web-port 7357 --dart-define=HEATGUARD_API_BASE_URL=http://localhost:5000
```

To preview a compiled web build instead, run `flutter build web --release`, then serve `build/web` on port 7357. Device notifications are available in the Android and iOS apps; the browser preview explains that they are unavailable in Chrome.

The app has a server settings menu for changing and saving the API address. On a physical phone, use a reachable HeatGuard server address. For a local Flask server, bind it to `0.0.0.0` and use the computer's LAN IP, such as `http://192.168.1.20:5000`. The phone and computer must be on the same network, and the firewall must allow that port. Use HTTPS for a deployed server.

## Daily notification behavior

The app downloads the weather and recommendations from `/api/dashboard`, then stores that message in the operating system's local notification scheduler. Android and iOS can deliver it every day while the app is closed; Android also reschedules it after a device reboot. The scheduled message contains the most recently downloaded reading. Opening the app or refreshing the dashboard updates the next daily message. The app asks for notification permission on first launch; the user can change the daily time or pause the reminder in the dashboard.

## Server requirements

The HeatGuard Flask server must be running and reachable from the device. It must provide the dashboard, locations, geocoding, and address lookup API routes used by the features above. Configure at least one monitored location in HeatGuard before opening the mobile app.

The Android manifest permits cleartext HTTP for local development. Use an HTTPS server for deployment and disable cleartext traffic before publishing a production build.
