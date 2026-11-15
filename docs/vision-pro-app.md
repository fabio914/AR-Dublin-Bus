# Apple Vision Pro app: options

Status: **proposal, not implemented.**

On the iPhone, the app detects the bus pictogram on a stop flag with ARKit, reads the stop
number under it with Vision OCR on the camera frames, and floats a departures board next to
the sign. This document looks at what a visionOS version could do.

## Camera access on visionOS

- **The API exists, but it's restricted.** ARKit on visionOS has `CameraFrameProvider`, which
  returns the main camera's pixel buffers, so Vision OCR would work as it does on the iPhone.
  It's one of Apple's Enterprise APIs. It needs:
  - the `com.apple.developer.arkit.main-camera-access.allow` entitlement, which the developer
    account holder has to apply for;
  - an enterprise license file bundled with the app.

  It's meant for in-house business apps, not App Store or personal apps. Before visionOS 26 it
  also only worked in a Full Space (Immersive Space).
- **visionOS 27 doesn't change this.** In a recent forum answer, an Apple engineer said that
  running Vision on the headset's camera feed still needs the enterprise license and
  entitlement.

So with a personal developer account, the "read the stop number" step can't be done.

## What works without camera access

### Detecting the sign

ARKit's `ImageTrackingProvider` is available to every developer. It detects reference images
and returns an `ImageAnchor` with the sign's position and an estimated scale factor, like
`ARImageAnchor` on the iPhone.

- The existing `Resources/BusStopIcon.png` and its physical width (`BusStopSign.physicalWidth`,
  0.35 m) can be reused as the reference image.
- It needs an Immersive Space and the user's permission for world sensing
  (`NSWorldSensingUsageDescription`).

### Identifying the stop without OCR

Combine the detection with location. The pictogram tells us we're at a stop, and the nearest
stop within about 50 m is almost always the right one.

- The awkward case is a pair of stops on opposite sides of the road. There the panel could show
  both, or let you pick with a tap.
- Vision Pro has no GPS, so location comes from Wi-Fi or a paired iPhone. That's usually
  accurate enough in Dublin, but this needs testing outdoors.

### Showing the panel

This gets simpler than on the iPhone:

- A SwiftUI view can be attached directly in a `RealityView` (`Attachment`), with no
  `ImageRenderer` texture (`DeparturesPanelEntity`).
- `BillboardComponent` turns the panel to face you, replacing the manual billboarding code.

### Code reuse

The timetable, realtime and departure code (`GTFS/`, `Realtime/`, `Departures/`) is
platform-independent, and ZIPFoundation supports visionOS. Most of the new work is:

- a visionOS target with an immersive-space scene;
- the image tracking setup;
- the location-based stop choice.

The 2D windows (Nearby, Look up, stop board) would mostly work as they are.

## Option 1: image detection plus nearest stop (recommended)

Detect the pictogram with `ImageTrackingProvider`, pick the nearest stop from the device's
location, and float the board next to the sign.

**Pros**
- Works with a normal developer account, and could ship on the App Store.
- Reuses most of the existing code.

**Cons**
- Depends on location accuracy, which is weaker without GPS.
- Opposite-side stop pairs need a fallback: show both, or let the user choose.

## Option 2: Option 1 plus enterprise camera access for OCR

Same as Option 1, but read the stop number from `CameraFrameProvider` frames with the existing
`StopNumberReader`, as on the iPhone. Location becomes only a check.

**Pros**
- Identifies the exact stop, like the iPhone app.
- The OCR code can be reused almost unchanged.

**Cons**
- Only possible with an organisation that has been granted the enterprise entitlement and
  license.
- The result can't be distributed on the App Store.

## Option 3: no AR at all

A visionOS window with the Nearby list, like the Apple Watch app.

**Pros**
- The simplest: mostly the existing SwiftUI screens in a visionOS target.
- No Immersive Space or world-sensing permission needed.

**Cons**
- Loses the board floating at the stop, which is the point of the app.

## Comparison

| | Option 1: detection + location | Option 2: + enterprise OCR | Option 3: no AR |
| --- | --- | --- | --- |
| Board anchored to the sign | Yes | Yes | No |
| Identifies the exact stop | Usually (nearest stop) | Yes | N/A (list) |
| Needs the enterprise entitlement | No | Yes | No |
| App Store distribution | Yes | No | Yes |
| Implementation effort | Medium | Medium–high | Low |

## Recommendation

Option 1. It keeps the floating board, works with a normal developer account, and reuses the
existing timetable and realtime code. Option 2 is only worth it if enterprise access becomes
available.

## Open questions

- How accurate is Vision Pro location outdoors in Dublin, with and without a paired iPhone?
- How well does `ImageTrackingProvider` detect the pictogram outdoors and at a distance,
  compared with the iPhone?
- For opposite-side stop pairs: show both boards, or ask the user to pick?

## Sources

- [Accessing the main camera (Apple docs)](https://developer.apple.com/documentation/visionos/accessing-the-main-camera.md)
- [Building spatial experiences for business apps with enterprise APIs](https://developer.apple.com/documentation/visionos/building-spatial-experiences-for-business-apps-with-enterprise-apis.md)
- [WWDC24: Introducing enterprise APIs for visionOS](https://developer.apple.com/videos/play/wwdc2024/10139/)
- [Forum: Enterprise APIs with an individual developer account](https://developer.apple.com/forums/thread/802552)
- [Forum: Vision API (visionOS 27 answer)](https://developer.apple.com/forums/thread/831745)
