# Code review fixes

Issues found in a review of the whole codebase (November 2026), and their status.
Each fix is one commit on the `review-fixes` branch.

## Bugs

- [x] **1. Stuck "Downloading…" banner.** When the background refresh of a stale timetable
  fails (for example offline), the phase stays at `.downloading` until the app is relaunched,
  which also disables "Download latest timetable" in Settings. (`TimetableStore`)
- [x] **2. Stale live data shown as live.** After a failed fetch, `RealtimeClient` keeps
  returning its cached feed for the rest of the throttle window however old it is, and the
  footer says "Live · updated" with the current time instead of the feed's time.
- [x] **3. Boards list buses that terminate at the stop.** A trip's final call is an arrival
  only; nobody can board it. (`StaticTimetable.calls`)
- [x] **4. Orphaned staging folders.** If the app is killed while the timetable is being
  prepared, about 260 MB of CSV files stay in Application Support (and in backups) forever.
- [x] **5. Watch shows departed buses and hides failures.** Past departures stay at "Due",
  and a failed refresh is invisible while an older answer is on screen.
- [x] **6. Duplicate departure IDs on loop routes.** A trip calling twice at the same stop
  produces two rows with the same ID.
- [x] **7. Build number setting is ignored.** `CURRENT_PROJECT_VERSION` and
  `MARKETING_VERSION` in `project.yml` don't reach the Info.plists.

## AR session

- [x] **8. Fall back when the compass or location is unavailable.** The session always asks
  for `.gravityAndHeading`; if that fails, sign scanning should keep working without the
  nearby-stop labels. *Builds, but still needs checking on a device with location denied.*
- [x] **9. Pause AR under full-screen sheets.** Camera, tracking, OCR and GPS keep running
  while Nearby, Map, Look up or Settings cover the camera view. *Builds, but still needs
  checking on a device.*

## Network and performance

- [x] **10. Don't re-download an unchanged timetable.** Compare the feed's `ETag` before
  fetching 40 MB every three days, and skip the background refresh in Low Data Mode.
- [x] **11. Settings "Save" bypasses the realtime throttle.** Saving without changing the key
  still clears the cache and refetches the feed.
- [x] **12. Board query loads every call at the stop.** Restrict it to the time window in SQL.
- [ ] **13. Route badges run a join per stop.** Store each stop's routes in a `stop_routes`
  table when the database is built (schema version 2; also drops the unused
  `trips.direction` column).
- [ ] **14. Timetable swap isn't atomic, and refreshes can overlap.** Replace the folder in
  one step, and make a manual refresh wait for a background one.

## Housekeeping

- [ ] **15. API key in the binary rather than Info.plist.** A pre-build script generates a
  git-ignored Swift file from `NTA_API_KEY`, with the key stored as scrambled bytes.
  (Obscurity, not security: a determined person can still recover it.)
- [ ] **16. Share duplicated code with the watch app.** Colours, ETA text and the distance
  formatter exist twice.
- [ ] **17. Remove unused code.** `StopBoard.hasLiveData`, `RealtimeSnapshot.tripCount`
  (tests only), `GeoAlignment.coordinate(of:)` (tests only).

## Later

Not done on this branch:

- **Continuous integration.** A GitHub Actions job running `xcodegen generate` and
  `xcodebuild test`.
- **Protobuf realtime feed.** The whole-network feed is fetched as JSON every minute; the
  protobuf form is much smaller but needs a decoder dependency.
- **Strict concurrency.** Turn on `SWIFT_STRICT_CONCURRENCY: complete` and work through the
  `@unchecked Sendable` and `assumeIsolated` uses, towards Swift 6 mode.
- **Dynamic Type.** The boards use fixed font sizes, which suits the AR texture but not the
  same views in sheets.
- **Tests for `ProgressDownloader` and the watch connection**, which need network or
  WatchConnectivity stubs.
