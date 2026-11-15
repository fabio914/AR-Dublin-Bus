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
- **Nearby:** uses your location to list the stops within 600 m, nearest first, each with its
  next buses, plus a merged "Next buses" list across all of them.
- **Look up:** shows the board for any stop number you type.
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

On first launch the app downloads the Dublin Bus timetable (about 42 MB), so the first board
takes a little longer.

### Trying it in the Simulator

ARKit isn't available in the Simulator, but **Nearby** and **Look up** are. To pretend you're on
O'Connell Street:

```sh
xcrun simctl location booted set 53.348596,-6.259485
```

Then open Nearby, or look up stop 271.

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
  launch and refreshed every 3 days. `stop_times.txt` (about 200 MB) is memory-mapped and
  searched for the stops needed instead of being parsed in full. Several stops are found in a
  single pass.
- **Live data:** the NTA GTFS-Realtime API (`/gtfsr/v2/TripUpdates?format=json`). Delays are
  applied following GTFS-Realtime rules: an exact stop match first, otherwise the delay is
  carried forward from an earlier stop. Cancelled trips and skipped stops are marked, buses that
  have already passed are dropped, and added trips are included. The network-wide feed is
  fetched at most once a minute.

### 4. Showing the board

A SwiftUI view is rendered with `ImageRenderer` into an unlit RealityKit texture. The panel hangs
below the pictogram and turns to face you.

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
| `ARDublinBus/GTFS` | Timetable download, storage and lookup. |
| `ARDublinBus/Realtime` | GTFS-Realtime client and models. |
| `ARDublinBus/Departures` | Merges timetable and live data into boards. |
| `ARDublinBus/UI` | SwiftUI screens: AR view, Nearby, Look up, stop board. |
| `ARDublinBus/Watch` | Answers requests from the watch app. |
| `ARDublinBusWatch` | The watchOS app. |
| `Shared` | Code used by both apps: location and watch messages. |
| `ARDublinBusTests` | Unit tests. |
| `Config` | Build settings; `Secrets.xcconfig` holds your own values. |
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
| `TEST_RUNNER_GTFS_DIR` | An extracted Dublin Bus GTFS folder. |
| `TEST_RUNNER_REALTIME_JSON` | A saved `TripUpdates?format=json` response. |
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

## Data

Timetable and live data come from the [National Transport Authority](https://developer.nationaltransport.ie).
Check the NTA's terms of use before distributing an app built on this data.

## License

Released under the MIT License. See [LICENSE](LICENSE).
