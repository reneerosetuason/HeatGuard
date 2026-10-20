# HeatGuard mobile app

This folder contains HeatGuard's installable Progressive Web App. It uses the
existing Flask weather and recommendations API and can show a daily notification
in the device notification tray while the app is closed.

## Open and install

Run the main HeatGuard server, then open `/mobile/` on the phone. For development,
`http://localhost:5000/mobile/` works on the same computer; phones and deployed
devices need an HTTPS URL for service workers and push notifications.

- **Android:** open the page in Chrome or another browser with PWA support, use
  its install/Add to Home screen action, then allow notifications in HeatGuard.
- **iPhone/iPad:** add the site to the Home Screen from Safari, open the installed
  app, and enable notifications there. Web Push requires iOS/iPadOS 16.4 or later.
  [Apple's Web Push guide](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)
  describes the Home Screen and permission requirements.
- The browser and device must permit notifications. The app asks only after the
  user presses **Enable notifications**.

Each browser/device has its own subscription and settings. Choose a monitored
location and local reminder time; the daily notification includes the latest
temperature, calculated heat index, risk category, and a recommendation. The
server checks for due reminders once a minute and fetches fresh conditions when
one is due. When current weather is unavailable, the notification says so and
directs the user to official advisories.

## Server setup for daily notifications

1. Install the project requirements, including `pywebpush`.
2. Create one VAPID key pair. From the project root, run these commands in
   PowerShell:

   ```powershell
   Push-Location mobile_app
   & ..\.venv\Scripts\vapid.exe --gen
   & ..\.venv\Scripts\vapid.exe --applicationServerKey
   Pop-Location
   ```

   On macOS/Linux, use `../.venv/bin/vapid` in place of
   `..\.venv\Scripts\vapid.exe`. Save the value printed by
   `--applicationServerKey`; it is the public application server key.
3. Set the following values in the root `.env`:

   ```ini
   VAPID_PUBLIC_KEY=the_value_printed_by_vapid
   VAPID_PRIVATE_KEY_PATH=C:\HeatGuard\mobile_app\private_key.pem
   VAPID_CLAIMS_EMAIL=admin@example.com
   SESSION_COOKIE_SECURE=1
   ```

   Use the actual path and a contact email you control. The private key file is
   ignored by Git; keep it on the server and back it up securely. Keep the same
   VAPID pair after devices subscribe. Rotating it requires users to enable
   notifications again.
4. For a new database, run `python manage.py init-db`. To add notifications to
   an existing database, apply `sql/mobile_push_subscriptions.sql` as a MySQL
   administrator (the restricted app account may not have permission to create
   tables):

   ```powershell
   mysql -u root -p HeatGuard < sql/mobile_push_subscriptions.sql
   ```

   The main `sql/schema.sql` also creates this table for fresh installs.
5. Deploy behind HTTPS, start one HeatGuard scheduler process, and open
   `/mobile/`. The app will show whether the server has push configured.

The monitor can be disabled with `MONITOR_ENABLED=0`; push scheduling still
runs if VAPID is configured, and it refreshes weather when a daily notification
is due. For multi-process hosting, run only one scheduler process to avoid
duplicate weather fetches.

## Delivery requirements

Web Push appears in the device's notification tray after the person allows it.
Delivery requires the HeatGuard server to be running, MySQL and the network to
be available, valid browser subscriptions and VAPID keys, HTTPS, and the device
to allow the browser's notifications. If the device is offline, the push service
may deliver it when the device reconnects, subject to its push service and
operating system behavior.
