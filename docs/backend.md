# A backend for live times and the timetable

Status: **idea, not implemented.**

Today each copy of the app talks to the NTA directly:

- **Live times:** every minute while a board is on screen, the app downloads the whole
  GTFS-Realtime TripUpdates feed for the network (`ARDublinBus/Realtime/RealtimeClient.swift`)
  and picks out the trips it needs.
- **Timetable:** every 3 days, the app downloads the Dublin Bus GTFS zip and builds its own
  SQLite database from the CSV files (`ARDublinBus/GTFS/TimetableStore.swift`,
  `TimetableDatabaseBuilder.swift`).

This document describes moving both jobs to a small backend that we run. It builds on
option 3 of [Standalone Apple Watch app](standalone-watch-app.md#option-3-small-server-in-the-middle),
which would use the same service.

## What the app downloads today

| Data | Size | How often |
| --- | --- | --- |
| Live TripUpdates, JSON | ~3.2 MB | Up to once a minute while a board is open (the app used this until the protobuf switch). |
| Live TripUpdates, protobuf | ~0.55 MB | Same; what the app fetches now. |
| GTFS zip (Dublin Bus) | ~42 MB, ~260 MB unzipped | Every 3 days, then converted on the phone. |
| Finished SQLite database | ~15 MB | Built on the phone; never downloaded. |

The live sizes were measured on 16 November 2026 in the evening, so they'll be larger at rush
hour. Neither response is compressed by the server. An hour of watching boards costs
about 33 MB as protobuf, 190 MB as JSON.

The NTA API has no way to ask for one stop or one route. The per-stop RTPI API it replaced
was shut down in 2020.

## Live times: fetch once, serve per stop

The backend fetches the NTA feed once a minute and keeps the latest copy in memory, indexed
by stop and by trip. Apps ask only for what they show:

```
GET /v1/stops/271/departures      → the stop's next buses (timetable + live)
GET /v1/trips/{trip_id}/journey   → one bus's line, for the line screen
GET /v1/stops/271/lines           → the lines leaving a stop, for the Lines card
```

**Pros**

- Responses of a few KB instead of 0.5 MB a minute per phone: less data, battery and decoding.
- One NTA client for every user, about 1,440 requests a day whatever the number of users,
  well within the fair-usage policy. Today every installed app counts against it.
- The NTA key stays on the server instead of being compiled into the app, where it can be
  extracted.
- The departure logic (timetable + live delays, `DepartureCalculator`) lives in one place,
  and the iPhone, watch and any future app get the same answers.
- The long download that can stall on a weak mobile connection happens on a server with a
  steady connection instead.

## Timetable: build once, publish versions

The backend downloads the GTFS zip when the NTA publishes a new one, builds the SQLite
database with the same builder the app uses today, and publishes it with a version:

```
GET /v1/timetable/version   → {"version": "<feed version>-<content hash>", "size": …, "url": …}
GET /v1/timetable/<version>.sqlite.gz
```

The app checks the version on launch (and every few hours) and downloads the finished
database only when it changed: around 15 MB, likely 5–6 MB compressed, instead of 42 MB plus
a conversion on the phone.

**Pros**

- Much faster first launch, and no heavy CSV processing on phones or watches.
- The app no longer needs the zip and CSV code (`CSV.swift`, `CSVByteReader.swift`, the
  builder), only the reader.
- Every app uses the same database, so trip IDs always match what the backend serves live.

## Costs and risks

- **Running a service:** hosting, monitoring, uptime and its bills. If the backend is down,
  live times are down, unless the app falls back to the NTA directly (which needs the key in
  the app again, or users' own keys).
- **Licensing:** the static GTFS is open data, but the NTA API's terms for redistributing the
  live feed need checking before serving it to users.
- **Porting:** the builder and departure logic are Swift. Server-side Swift on Linux can reuse
  most of it, once the parts that depend on Apple frameworks (`CoreLocation` types, for
  example) are kept out of the shared code.
- **Privacy:** requests for stops reveal roughly where users are. Don't log stop requests
  with identifiers, and say so in the privacy policy.

## Suggested order

1. **Protobuf in the app** (done on the `protobuf-feed` branch): a sixth of the download, no
   server needed.
2. **Timetable service:** the simplest service (a scheduled job plus static files on a CDN)
   and the biggest win for first launch.
3. **Live per-stop service:** the endpoints above, with the app falling back to fetching the
   feed itself if the backend can't be reached.
