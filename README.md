# Fully Tracked

A personal life and health journal that stays on this computer. No account and no API key.

## Run

Requires Node.js 22 or newer.

```bash
npm install
npm start
```

Open http://127.0.0.1:3847

Entries are stored in `data/journal.sqlite`. That folder is gitignored. Nothing private is seeded.

## Web preview

GitHub Pages serves the files in `public/` as a browser preview of this UI. The product direction is a native iOS app. The preview page loads without the local server, so saving entries needs `npm start`.

## Entries

One search box matches type names and text fields across every entry, newest first.

| Type | How it is logged | Fields |
| --- | --- | --- |
| Location | Automatic, from the browser Geolocation API | time, latitude, longitude, accuracy in meters, source `device` |
| Meal | Manual | time, what you ate |
| Water | Manual | time, milliliters |
| Bathroom | Manual | time, stool or urine, optional Bristol scale 1–7 for stool, optional note |
| Life event | Manual | time, title, description |
| Mood | Manual | time, score 1–5, optional note |
| Sleep | Manual | time, hours slept, optional note |
| Steps | Not typed. A daily total from Apple Health, source `apple-health` | day, step count |

Every entry has a stable id, a type, when it happened (`occurredAt`), and when it was saved (`savedAt`).

## Location

Check-ins default to every 30 minutes. The interval cannot be shorter than 5 minutes, and the server refuses location saves closer together than that. This is not a second-by-second track.

Location tracking is always on. It is the default, it is remembered, and it starts by itself whenever the app runs. The first reading asks for location permission once. After that, check-ins repeat on the interval with no extra taps and no typed coordinates.

The check-in timer is not paused when the tab is in the background. While the app is running it requests a screen wake lock so the page is less likely to be suspended. A fully quit browser has no GPS. This app does not record check-ins after the browser process is gone, and it does not run a background service to do that. No check-in is invented.

## Charts

Days are this computer's local calendar. Switch between the last 7 days and the last 30 days, including today. A chart is empty when that range has none of its entries.

- **Water:** daily total milliliters
- **Meals:** daily count, not calories
- **Mood:** daily average of the 1–5 scores
- **Sleep:** daily hours, adding together every sleep entry logged that day
- **Steps:** daily step count from Apple Health. A day with no stored total is left blank. This page does not draw a sample number.

Days in a range that has some data but nothing on that day show 0 for water and meals. Mood and sleep leave a gap, because no score or no logged sleep is not a zero.

The steps chart stays empty until a real daily total is stored. This browser cannot read HealthKit, and the app will not invent a count or label a sample as Apple Health.

## Apple Health steps

HealthKit does not run in this browser or on this Linux machine. The web page only shows step totals that were actually saved. Until then, the trends screen says why it is empty.

To record real steps you need an iOS app with the HealthKit capability. The app's entitlement is `com.apple.developer.healthkit`. Its Info.plist needs `NSHealthShareUsageDescription`, explaining that the app reads the user's own steps. The user must allow read access to Steps in the system prompt. The app reads with `HKStatisticsCollectionQuery`, asking for the cumulative step sum for each day. It does not request write access. Background delivery is out of scope.

The read happens once each time that iOS app opens, then about every 30 minutes while it stays open. It is not a second-by-second stream, and it stops when the app is closed. The web page asks its reader on that same schedule and always gets "not available" here, without saving anything.

`health/steps-reader.js` states that contract. It does not query HealthKit.

## Map

Leaflet with OpenStreetMap tiles, which needs no API key. Each marker is one stored device check-in. There is no way to drop a pin by hand. The map area is empty until a check-in exists.

Map images for the area on screen are loaded from OpenStreetMap. The journal itself stays in the local database.
