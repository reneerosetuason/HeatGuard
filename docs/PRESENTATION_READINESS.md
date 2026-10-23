# HeatGuard presentation readiness

Checked on October 23, 2026, using the current Windows backend and Android app over Wi-Fi. This records observed results, rather than a guarantee of provider availability or exact notification arrival times.

## Completed checks

| Area | Result |
| --- | --- |
| Python tests | All 249 passed across the main suite and a separate run of the three browser tests. The browser tests required network access to load their external assets. |
| Flutter tests | All 33 passed. |
| Flutter static analysis | No issues found. |
| Android build | A fresh debug APK built successfully and was installed on the connected phone. The app launched successfully. |
| Database | MySQL was running; required account, address, routine, inbox, device, and delivery tables and timing columns were present. |
| Backend | Health endpoint reported a working database and running scheduler. |
| Phone connection | The phone reached the backend health endpoint over Wi-Fi. USB and wireless debugging are not required for normal use. |
| Accounts and ownership | Live HTTP checks passed for native login, blocking signed-out access, and rejecting access to another account's private address and routine. |
| Private addresses and dashboard | A synthetic private address was created, fresh weather loaded, and the address was removed successfully. |
| Routines | Creating, editing, and deleting a paused test routine passed. |
| Inbox | Saving, listing, and marking a synthetic notification read passed. |
| Logout | Logout revoked the session; subsequent authenticated access was rejected. |
| Email | Gmail SMTP authenticated successfully over TLS after the App Password was corrected. The live app also completed a successful OTP-verification request. Audit scripts did not send extra emails. |
| Weather | Open-Meteo current weather, place search, and hourly forecasts responded successfully. |
| Groq | Accepted AI advice was observed for both a nighttime Sleep activity and a school trip using public synthetic Manila context. Other calls produced rejected advice or a provider error and used the activity-aware fallback. This is not a claim that every notification will use AI. |
| Firebase configuration | OAuth authentication and an FCM HTTP v1 validation-only request succeeded without sending a message. |

Synthetic HTTP test accounts and their data were removed. No existing user routines or addresses were edited during these checks.

## Physical phone notification check

A single, explicitly labeled **Presentation notification TEST** was scheduled through the real reminder scheduler for **9:25 PM, October 23, 2026 (Asia/Manila)** with the app in the background.

- Groq generated the reminder advice successfully; preparation completed **83 seconds before** the scheduled time.
- FCM accepted delivery **3 seconds after** the scheduled time. This measures server-to-FCM acceptance, not the exact time the banner appeared.
- Android notification metadata confirmed that the matching HeatGuard notification was posted while the app was in the background.
- The server inbox entry remained available after cleanup, and the user confirmed seeing **Presentation notification TEST** in the app's notification history.
- The temporary test routine and private test address were removed successfully. The saved past notification remains for demonstration, and this test cannot repeat on later days.

**Result: passed.** Local daily reminder scheduling and history were covered by the automated Flutter checks; this physical phone test exercised the remote routine workflow.

## Issues resolved during the check

- Started the stopped API and confirmed it was reachable from the phone.
- Restarted the API with external network access so weather and messaging providers could be reached.
- Confirmed Gmail authentication after the user saved the corrected App Password, then restarted the backend to load it.
- Disabled Android's **Wait for debugger** setting, which had been preventing a normal app launch.
- Installed the fresh APK and enabled the phone's remote-notification registration in **My routines**.

Hotspot follow-up on October 23: after the laptop joined the phone's hotspot, its API address changed to `http://10.226.234.213:5000`. The existing firewall rule was updated to that Wi-Fi address, limited to Python TCP port 5000 from the local subnet. The phone's browser health check succeeded; mobile sign-in and location/routine/inbox requests succeeded, and the user confirmed the dashboard loaded. This phone requires joining Wi-Fi to enable wireless debugging, so use the installed APK while it hosts the hotspot.

## Before presenting

1. Keep the computer awake, MySQL running, and one backend instance running. From `C:\HeatGuard`, the development command is `.\.venv\Scripts\python.exe run.py`; do not start a second instance while one is already running.
2. Connect the laptop to the phone's hotspot, or connect both devices to a shared Wi-Fi network. The latest checked hotspot API address is `http://10.226.234.213:5000`; the earlier shared-Wi-Fi address was `http://192.168.1.132:5000`. If the computer's LAN address changes, update the app's server setting and the address-specific firewall rule.
3. Keep internet access available for Open-Meteo, Groq, Gmail, and FCM. Open `http://YOUR_LAPTOP_IP:5000/api/health` on the phone to check the backend connection.
4. Sign in, select the intended saved address, and check the weather freshness timestamp.
5. In **My routines**, confirm the button says **Pause phone notifications**, which means remote notifications are enabled. Android must also allow HeatGuard notifications.
6. Schedule the demonstration routine at least two minutes ahead, with a reminder lead time that falls within the demonstration. Minimize the app, receive the notification, and open the bell to show its inbox entry. Avoid Android **Force stop**.
7. Keep a previous demonstration recording available if the venue's Wi-Fi or a provider is unavailable.

## Presentation boundaries

- FCM acceptance, Android posting, and a user reading a notification are separate events. Even a successful timing test does not guarantee future arrival at the exact second.
- Routine reminders use the server's forecast and Groq/fallback workflow. Local daily device reminders use the selected address's last loaded content and Android's inexact scheduling; they do not independently fetch live weather at delivery time.
- Daily reminder history records due scheduled occurrences on the device and reconciles them when the app resumes. It does not prove that Android displayed every banner.
- Weather estimates describe the selected area, not a sensor at the user's exact home. The app does not continuously track GPS.
- The checked build is an Android development APK. Public hosting, HTTPS, release signing, app-store distribution, and iOS delivery remain separate deployment work.

## APK

- Build output: [app-debug.apk](../frontend/flutter/build/app/outputs/flutter-apk/app-debug.apk)
- Download copy: [HeatGuard-update.apk](../frontend/web/static/downloads/HeatGuard-update.apk)
- On the latest checked hotspot: `http://10.226.234.213:5000/static/downloads/HeatGuard-update.apk`

See [PRESENTATION_NOTES.md](PRESENTATION_NOTES.md) for the architecture, APIs, heat-index explanation, and suggested presentation flow.
