# Standalone Apple Watch app: options

Status: **proposal, not implemented.**

Today the watch app depends on the iPhone. The watch gets its location and sends it over
WatchConnectivity. The iPhone app builds the boards from its timetable and the realtime
feed, and replies (see `ARDublinBus/Watch/WatchResponder.swift`). Without the iPhone in
range, the watch shows the last cached answer, which expires after 15 minutes.

This document compares ways to let the watch show nearby stops and next buses on its own,
for example when the iPhone is left at home.

## Constraints

The watch can run the same Swift code as the iPhone: networking, Core Location and file
access all work on watchOS. The problem is data volume:

| Data | Size | Notes |
| --- | --- | --- |
| Dublin Bus static GTFS (`GTFS_Dublin_Bus.zip`) | ~42 MB download | Published by the NTA, refreshed every few days. |
| Unzipped files the app needs | ~210 MB | `stop_times.txt` alone is ~206 MB. |
| NTA GTFS-Realtime TripUpdates (JSON) | ~4.4 MB per fetch | Whole network (about 2,400 trips); the API has no per-stop filter. |

Also:

- The watch has much less RAM and battery than the iPhone, and possibly cellular data costs.
- Realtime trip IDs only match the static schedule they were published with, so any
  timetable copy has to be kept current.
- The NTA key must be available wherever the realtime feed is fetched.
- To install and run without the iPhone app, the watch target needs
  `WKRunsIndependentlyOfCompanionApp = true` in its Info.plist. That's a one-line change,
  needed by every option below.

## Option 1: everything on the watch

Compile the existing timetable, realtime and departure code (`GTFS/`, `Realtime/`,
`Departures/`) for watchOS too. The watch downloads the GTFS zip, extracts it, scans
`stop_times.txt` (memory-mapped, as on the iPhone) and fetches the full realtime feed itself.

**Pros**
- Least new code: mostly moving files into `Shared/`.
- Fully independent: no iPhone and no server needed.

**Cons**
- A 42 MB download and ~210 MB on disk on the watch, slow on first launch.
- Every refresh downloads ~4.4 MB of realtime data, which is costly on battery and cellular.
- Loading `trips.txt` (~80k trips) into memory is borderline on older watches.
- The NTA key has to be built into the watch app.

**Verdict:** works, but the battery and data cost make it a poor everyday experience.

## Option 2: hybrid, with a compact timetable synced from the iPhone (recommended on-device option)

The iPhone, which already has the full timetable, builds a **compact extract** and sends it
to the watch in the background with `WCSession.transferFile`:

- Scope: either all of Dublin, or the stops within a few km of places where the app has been used.
- Content: only what the boards need, meaning per-stop calls (trip, time, sequence), trips
  (route, headsign, service), routes and the service calendar, in a compact binary or SQLite
  format. Estimated at a few MB; to be measured.
- Re-sent whenever the iPhone downloads a new timetable, tagged with the feed version.

The watch then:

1. **iPhone reachable:** asks it, exactly as today (no change, cheapest for the watch).
2. **iPhone not reachable:** uses its local extract for scheduled times, and fetches the
   realtime feed directly over Wi-Fi or cellular. It fetches only when the app is opened or
   refreshed, not continuously, and shows timetable times if that fetch fails.

The NTA key would be sent from the iPhone to the watch (for example with
`updateApplicationContext`) and kept in the watch's Keychain, rather than built in.

**Pros**
- Works without the iPhone, with no server to run.
- The watch never downloads or parses the full timetable.
- Keeps today's cheap path whenever the iPhone is around.

**Cons**
- The most new code: extract format, sync, versioning, and two data paths on the watch.
- Live data without the iPhone still costs ~4.4 MB per fetch.
- The extract only covers whatever scope was chosen, and could be stale if the iPhone hasn't
  refreshed the timetable recently.

## Option 3: small server in the middle

A small hosted service (for example a serverless function or a tiny container) keeps the
static GTFS and the realtime feed up to date and exposes an endpoint such as:

```
GET /nearby?lat=53.3486&lon=-6.2595&limit=8
```

returning the same shape as `WatchNearbyResponse` (a few KB). The watch, and optionally the
iPhone app, call it directly.

**Pros**
- Best for battery, data and speed on the watch: one small request per refresh.
- Simplest watch code, and the iPhone app could use the same endpoint.
- The NTA key stays on the server and isn't shipped in apps.
- The realtime feed is fetched once per interval for all users, which suits the NTA's
  fair-usage policy.

**Cons**
- Something to host, pay for (likely within free tiers for personal use), secure and maintain.
- A new dependency: if the server is down, the app is down. The iPhone's on-device path could
  remain as a fallback.
- The server-side logic (timetable loading, realtime merge) has to be ported or shared, since
  the current implementation is Swift; a Swift server is an option.

## Comparison

| | Option 1: all on watch | Option 2: hybrid | Option 3: server |
| --- | --- | --- | --- |
| Works without iPhone | Yes | Yes | Yes |
| Needs a server | No | No | Yes |
| Watch download, first use | ~42 MB | A few MB (from iPhone) | None |
| Watch data per refresh, no iPhone | ~4.4 MB | ~4.4 MB | A few KB |
| Watch storage | ~210 MB | A few MB | Negligible |
| Implementation effort | Low–medium | High | Medium (plus hosting) |
| Ongoing maintenance | Low | Medium | Medium–high |

## Recommendation

- **On-device only:** Option 2. It keeps today's efficient iPhone path, and falls back to a
  synced compact timetable plus direct realtime fetches when the iPhone isn't around.
- **If hosting a small service is acceptable:** Option 3 gives the best watch experience and
  can serve the iPhone app too. Keeping the iPhone's on-device logic as a fallback limits the
  impact of server downtime.

## Open questions

- Timetable scope for Option 2: all of Dublin, or just areas where the app has been used?
  This needs measuring: build the extract for all stops and check its size.
- Should realtime fetches without the iPhone be allowed over cellular, or Wi-Fi only?
- For Option 3: hosting platform, and whether the iPhone app should also switch to the server.
- Does the NTA offer the realtime feed in protobuf (smaller than JSON), and how much smaller
  is it? That would reduce the cost of Options 1 and 2.
