# HeatGuard artwork

Prepared from the logo supplied by the user. The flame, shield, thermometer,
orange/brown lettering and cream icon background form the mobile identity.

- `heatguard_logo.png`: transparent full logo for the account and startup screens.
  The compact dashboard header pairs the symbol with a two-color text wordmark.
- `heatguard_mark.png`: transparent symbol for the dashboard, launcher and
  notification icons.

Android has density-specific legacy icons, adaptive icons, Android 13 themed
icons and a monochrome notification icon. The same symbol is included in iOS
app icon assets and the Flutter web favicon and installed shortcut icons.
Opaque icon backgrounds use `#F7F4EC`.

After replacing the source PNGs, regenerate the platform sizes on Windows:

```powershell
powershell -File frontend/flutter/tool/generate_brand_icons.ps1
```

Then rebuild the app. iOS assets are included, but an iOS build requires macOS.

## Artwork preparation

The built-in `image_gen` tool was used for extraction; the PowerShell script
only packages the resulting artwork at the platform sizes.

Final symbol prompt:

> Use case: background-extraction. Asset type: app launcher icon source / existing brand symbol. Image 1 is the edit target. Isolate only the EXACT existing flame-shield-thermometer emblem above the HeatGuard text. Remove the HeatGuard wordmark and the cream background. Preserve the exact silhouette, orange flame and thermometer, brown shield and thermometer outline, proportions, stroke widths and arrangement of the supplied symbol. Produce a square transparent PNG, centered, with the emblem taking about 85 percent of the canvas height and fully visible. No lettering, no new icon, no redesign, no shadows, no extra outlines. This is faithful extraction of the user's existing symbol.

Final full-logo cleanup prompt (applied to the initial transparent extraction):

> Edit this HeatGuard logo asset to fix its opacity. Keep the existing exact emblem silhouette, wordmark lettering, layout and proportions unchanged. Remove ALL orange/brown glow, soft haze, shadows, texture and translucent pixels from around and inside the logo. The shapes and letters must be filled with SOLID, FULLY OPAQUE flat colors: warm orange #D97840 for the flame, inner thermometer and 'Heat'; brown #6B5144 for the shield, outer thermometer and 'Guard'. All negative spaces must be perfectly transparent. The result should look like a clean crisp vector-logo cutout on a transparent background, not a glowing or translucent object. Exact wordmark: HeatGuard. Do not add, remove, retype or redesign any part. Small even margin around the full mark and wordmark. Output a transparent PNG with only the actual logo forms opaque, and no colored light in the surrounding transparent space.
