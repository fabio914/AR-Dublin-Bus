# ARDublinBus

Point your iPhone at a Dublin bus stop and see the next buses float beside the sign.

ARDublinBus is an iOS app built with ARKit, RealityKit and SwiftUI. It recognises the bus
pictogram on a Transport for Ireland (TFI) stop flag, reads the stop number printed under it,
and shows a live departures board anchored to the sign. It also lists stops near you, looks up
any stop by number, and includes an Apple Watch app.

> This is an independent hobby project. It is not affiliated with or endorsed by Transport for
> Ireland, the National Transport Authority or Dublin Bus.

## Features

- **AR departures board:** recognises the stop flag, reads its number (for example "Stop 271"
  on O'Connell St Lower), and floats a board with the next buses next to it. The board turns
  to face you and refreshes every 15 seconds.
- **Stops around you in AR:** the stops within 400 m float as labels over their real positions,
  with name, number, routes and distance. Tap one to see its board. Uses Apple's location anchors
  where available, and GPS + compass elsewhere (sharpened by recognising a stop sign).
- **Nearby:** uses your location to list the stops within 600 m, nearest first, each with its
  next buses, plus a merged "Next buses" list across all of them.
- **Search:** search by stop number or name. Matching stops are listed as you type, with the
  routes that call at each. Names match regardless of case, accents and apostrophes, and the
  abbreviations in stop names are understood ("oconnell street lower" finds "O'Connell St Lwr").
- **Intro:** the first launch downloads the timetable, with a retry if it fails, and offers to
  set the NTA API key. Later launches go straight to the tabs once the timetable is open.
- **Map:** the first tab. Every bus stop on a map, clustered when zoomed out. Tap a stop to see
  its board in a half-height sheet, with the map still usable behind it. The AR button in the
  navigation bar opens the camera view.
- **Line view:** tap a bus on any board (Map, Nearby or Search) to see its route on a map and
  every stop it calls at, with live times, the stop you picked it from highlighted, and the stops
  it has already passed greyed out.
- **Apple Watch:** shows the stops near you as pages you swipe between, each with its next buses
  and live ETAs.
- **Live times:** uses the NTA's GTFS-Realtime feed when you provide an API key, and falls back
  to timetable times otherwise.

## Requirements

- A recent Xcode (tested with Xcode 27), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An iPhone with iOS 18 or later. AR needs a real device; the Simulator can run everything else.
- Optional: an Apple Watch with watchOS 10 or later.
- Optional, but needed for live times: a free API key from the
  [NTA developer portal](https://developer.nationaltransport.ie), subscribed to GTFS-R.

## Getting started

1. Copy the settings template. The copy is git-ignored, so your values stay out of the repo:

   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```

2. Edit `Config/Secrets.xcconfig` and set:
   - `APP_BUNDLE_IDENTIFIER`: a bundle ID you own, such as `com.yourname.ARDublinBus`. The watch
     app uses this ID with `.watchkitapp` appended.
   - `DEVELOPMENT_TEAM`: your Apple developer team ID.
   - `NTA_API_KEY`: your NTA key. You can leave it empty and paste the key into the app's
     Settings screen instead, which stores it in the Keychain.
3. Generate the Xcode project. `ARDublinBus.xcodeproj` is git-ignored, so run this again after
   pulling changes to `project.yml` or adding files:

   ```sh
   xcodegen generate
   ```

4. Open `ARDublinBus.xcodeproj`, select the `ARDublinBus` scheme and run it on your iPhone. The
   watch app is embedded in the iPhone app and installs with it.

On first launch the app downloads the Dublin Bus timetable (about 42 MB) and converts it into a
local database, so the first board takes a little longer.

### Trying it in the Simulator

ARKit isn't available in the Simulator, but the **Map**, **Nearby** and **Search** tabs are. To pretend you're on
O'Connell Street:

```sh
xcrun simctl location booted set 53.348596,-6.259485
```

Then open the Map or Nearby, or search for stop 271.

## How it works

### 1. Detecting the sign

`ARWorldTrackingConfiguration` looks for `ARDublinBus/Resources/BusStopIcon.png`, the white bus
on the green panel at the top of every TFI stop flag. The NTA doesn't publish this artwork, so
the reference image was cut from a photo of a stop flag, perspective-corrected and cleaned into
two tones. ARKit's `automaticImageScaleEstimationEnabled` corrects the assumed physical width of
0.35 m (`BusStopSign.physicalWidth`).

### 2. Reading the stop number

The "Stop 271" line sits just below the pictogram. The app:

1. projects that part of the sign into the camera image;
2. rectifies it with `CIPerspectiveCorrection`;
3. reads it with Vision (`VNRecognizeTextRequest`);
4. accepts a number once it has been read twice and exists in the timetable.

If the tight crop keeps failing, a wider region is read as well. From that region, only a number
after "Stop" (or the Irish "Stad") is accepted, so route numbers aren't mistaken for the stop.

### 3. Fetching departures

- **Timetable:** the NTA's Dublin Bus GTFS feed (`GTFS_Dublin_Bus.zip`) is downloaded on first
  launch and refreshed every 3 days. `TimetableDatabaseBuilder` converts its ~260 MB of CSV files
  into a SQLite database of about 15 MB, and the CSV files are then deleted. See
  [The timetable database](#the-timetable-database).
- **Live data:** the NTA GTFS-Realtime API (`/gtfsr/v2/TripUpdates?format=protobuf`). Delays are
  applied following GTFS-Realtime rules: an exact stop match first, otherwise the delay is
  carried forward from an earlier stop. Cancelled trips and skipped stops are marked, buses that
  have already passed are dropped, and added trips are included. The network-wide feed is
  fetched at most once a minute.

### 4. Showing the board

A SwiftUI view is rendered with `ImageRenderer` into an unlit RealityKit texture. The panel hangs
below the pictogram and turns to face you.

### The timetable database

Building it takes about 2 seconds in an optimised build (around 9 seconds in a Debug build) and
happens once per download, in the background.

- **Trip patterns:** most trips repeat another trip's stops with the same gaps between them,
  starting at a different time. So the 3.9 million rows of `stop_times.txt` become 7,193 patterns
  (`pattern_stops`, about 390,000 rows), and each trip stores its pattern and start time. A stop's
  calls are found by joining its patterns with the trips that use them, in a couple of
  milliseconds.
- **Shapes:** the 1,263 route shapes in `shapes.txt` (52 MB) have only 333 distinct geometries.
  Each is stored once, as a compact blob of coordinate differences rounded to about 1 m.
- **Map queries:** stops have an SQLite R-tree index (`stops_index`), so the map loads only the
  stops in the visible area.
- **Route badges:** the routes calling at each stop are stored once (`stop_routes`), for search
  results and AR labels.
- **Versioning:** the database records its schema version. If an app update changes the schema,
  the timetable is downloaded and built again.

Stops, routes and the service calendar are small and kept in memory; trips, calls and shapes are
read from the database when needed (`StaticTimetable`).

### Stops in AR

`ARStopsController` fetches the stops within 400 m (R-tree query, re-run after you move 40 m)
and places a label over each, in one of two ways:

- **Location anchors:** at launch, `ARGeoTrackingConfiguration.checkAvailability(at:)` checks
  whether Apple supports geo tracking where you are. If so, the session switches to geo tracking,
  and once it has matched your surroundings against Apple Maps, each stop becomes an
  `ARGeoAnchor` at ground level. Positions are accurate to a metre or two.
- **GPS + compass** (everywhere else, and while geo tracking is still localising): the session is
  aligned with gravity and heading, so x points east and z south. `GeoAlignment` works out where
  the AR origin is on the map by averaging recent GPS fixes against where the camera was at each
  fix, weighted by accuracy, then converts each stop's coordinates to metres. Expect several
  metres of error. When a sign is recognised, its stop's mapped position replaces the GPS
  estimate, which pulls every label into place.

If geo tracking turns out not to work (unsupported here, or the session fails), the app falls
back to GPS + compass for the rest of the run. The line under the status badge shows which mode
is in use. Labels can be switched off in Settings.

### Apple Watch

The timetable is too large for the watch, so it stays on the iPhone. The watch sends its
location over WatchConnectivity (`Shared/WatchMessages.swift`). `WatchResponder` on the iPhone
replies with the nearby boards, waking the iPhone app in the background if needed. The iPhone
must be nearby and must have downloaded the timetable at least once. The watch caches the last
answer so the app opens with something to show.

## Project layout

| Path | Contents |
| --- | --- |
| `ARDublinBus/AR` | Sign detection, the AR session and the floating panel. |
| `ARDublinBus/OCR` | Stop number reading and parsing. |
| `ARDublinBus/GTFS` | Timetable download, the SQLite timetable database and its lookups. |
| `ARDublinBus/Realtime` | GTFS-Realtime client and models. |
| `ARDublinBus/Departures` | Merges timetable and live data into boards and trip journeys. |
| `ARDublinBus/Map` | The clustered map of stops (`MKMapView`). |
| `ARDublinBus/UI` | SwiftUI screens: the intro, the tab bar, AR view, Nearby, Search, stop board, line view. |
| `ARDublinBus/Watch` | Answers requests from the watch app. |
| `ARDublinBusWatch` | The watchOS app. |
| `Shared` | Code used by both apps: location and watch messages. |
| `ARDublinBusTests` | Unit tests. |
| `Config` | Build settings; `Secrets.xcconfig` holds your own values. |
| `Generated` | Written at build time and git-ignored: your API key, compiled into the app in scrambled form. |
| `docs` | Design notes and proposals. |

## Tests

```sh
xcodebuild test -project ARDublinBus.xcodeproj -scheme ARDublinBus \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Use any available iPhone simulator as the destination. The tests use a small built-in timetable.
Some extra checks run against real data when these environment variables are set:

| Variable | Value |
| --- | --- |
| `TEST_RUNNER_GTFS_DIR` | An extracted Dublin Bus GTFS folder. The tests build the database from it and compare it with `stop_times.txt`. |
| `TEST_RUNNER_REALTIME_JSON` | A saved `TripUpdates?format=json` response. |
| `TEST_RUNNER_REALTIME_PROTOBUF` | The same feed saved as `TripUpdates?format=protobuf`, fetched within seconds of the JSON. The tests check that both decode to the same updates. |
| `TEST_RUNNER_SIGN_PHOTO` | An upright photo of a stop flag. |
| `TEST_RUNNER_SIGN_QUAD` | Corners of the "Stop …" line in that photo, in pixels: `tlx,tly,trx,try,brx,bry,blx,bly`. |
| `TEST_RUNNER_SIGN_STOP` | The stop number on the photo. |
| `TEST_RUNNER_RENDER_DIR` | A folder to save PNG renders of the panel. |

## Tuning on a real sign

- `BusStopSign.physicalWidth`: measure the green panel's width for better first placement.
- `BusStopSign.stopNumberRegion`: where the stop number sits relative to the pictogram.
- `ARCoordinator.layoutPanel`: where the board floats relative to the sign.

## Ideas

- [Standalone Apple Watch app](docs/standalone-watch-app.md): options for using the watch
  without the iPhone nearby.
- [Apple Vision Pro app](docs/vision-pro-app.md): what's possible on visionOS, where camera
  frames are restricted.
- [A backend for live times and the timetable](docs/backend.md): fetch the NTA feed once and
  serve each stop's live times, and build the timetable database once for every app.

## Data

Timetable and live data come from the [National Transport Authority](https://developer.nationaltransport.ie).
Check the NTA's terms of use before distributing an app built on this data.

## License

Released under the MIT License. See [LICENSE](LICENSE).
