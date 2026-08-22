# Spike 6 & 7 — the notch HUD

- **Spike 6 (stable HUD geometry without private APIs):** partial — the public API surface is
  confirmed and the geometry is implemented and unit-tested; visual verification on hardware
  remains.
- **Spike 7 (`NSPanel` across Spaces and full screen):** pending.

This is the part of the product with no prior art to lean on. A capability grep across the three
comparable Swift projects returned zero uses of `safeAreaInsets`, `auxiliaryTopLeftArea`,
`NSPanel`, or `canJoinAllSpaces`; they are all menu-bar-item apps.

## Hypothesis

A HUD can be positioned around the notch using only public AppKit API, without claiming to
modify hardware, without blocking the menu bar, and with a complete experience on Macs that have
no notch.

## Method

Confirmed the public API surface in AppKit documentation, then implemented the geometry as pure
functions over a plain `ScreenDescription` struct so it can be tested without a display.

## Result

### macOS provides exactly enough public API

- `NSScreen.safeAreaInsets` (macOS 12+): `.top > 0` identifies a notched display.
- `NSScreen.auxiliaryTopLeftArea` / `.auxiliaryTopRightArea` (macOS 12+): the unobscured
  rectangles either side of the camera housing. The notch is the gap between them:

```
notchRect.x      = auxiliaryTopLeftArea.maxX
notchRect.width  = auxiliaryTopRightArea.minX - auxiliaryTopLeftArea.maxX
notchRect.y      = screen.frame.maxY - safeAreaInsets.top
notchRect.height = safeAreaInsets.top
```

There is no public equivalent of the Dynamic Island, and the product must not claim to be one.
What we build is a HUD positioned *around* the notch.

### Not blocking the menu bar falls out of the geometry

The spec requires that the HUD not impede menu bar clicks. Rather than juggling
`ignoresMouseEvents`, the compact HUD is confined to the notch rect — a region the menu bar
cannot place items in anyway. That turns a behavioural requirement into a geometric invariant,
and it is asserted directly as a test: the compact frame must not intersect either auxiliary
area. The expanded state grows *downward*, below the menu bar, into ordinary screen space.

### Panel configuration

```swift
styleMask          = [.borderless, .nonactivatingPanel]
isFloatingPanel    = true
level              = .statusBar
collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
hidesOnDeactivate  = false
```

`.nonactivatingPanel` is what stops the HUD stealing focus. `.canJoinAllSpaces` is what lets it
follow the user between Spaces, and `.fullScreenAuxiliary` lets it appear over a full-screen app.

### Macs without a notch get a complete experience, not a degraded one

On a non-notched display the `NSStatusItem` is the primary surface and carries the full session
list; the floating pill is opt-in. The spec requires this explicitly, and it also covers external
monitors attached to a notched laptop, where the built-in display is notched and the external one
is not.

### A constraint discovered from prior art

`idonecc/Coding-Done-Alert` documents that on macOS 26 (Tahoe), `UNUserNotificationCenter` does
not deliver from an unsigned bundle — it fails *silently*. That is a notification concern rather
than a HUD one, but it lands here because it changes what a contributor must do to see the app
work at all: a local build needs at least an ad-hoc signed `.app`, or nothing appears and there
is no error to debug. It belongs in `CONTRIBUTING.md` and in the Diagnostics screen.

## Limitations

- **Spike 7 is not done.** `canJoinAllSpaces` is a long-standing, still-public collection
  behaviour, but Tahoe regressed enough Space-related behaviour elsewhere that it must be
  verified rather than assumed.
- Visual verification (against the real notch, on a real 14-inch display, at several scale
  factors) has not happened. The geometry is correct by test; whether it *looks* right is not
  something a unit test can tell us.
- Menu bar hiding, resolution changes, and display hot-plug need exercising on hardware.

## Architectural decision

1. **All geometry lives in `CodeStatusCore` as pure functions** over a plain `ScreenDescription`
   struct, not against `NSScreen`. The core target stays AppKit-free and the hardest logic is
   testable with no display attached.
2. **The compact HUD is confined to the notch rect**, making "does not block the menu bar" a
   geometric invariant rather than an event-handling promise.
3. **`NSStatusItem` is a peer surface, not a fallback.** It is the primary interface on
   non-notched Macs and is always present as a recovery path.
4. **Re-layout on `didChangeScreenParametersNotification` and `activeSpaceDidChangeNotification`**,
   and honour `accessibilityDisplayShouldReduceMotion`.
5. **No private API, no Accessibility, no pixel reading** — for the HUD or anything else.

## V1 impact

- Acceptance criteria 5, 6, and 15 depend on this spike; 15 (a complete experience on Macs
  without a notch) is satisfied by design rather than by a fallback.
- Spike 7 remains open and must be closed before the HUD can be called done. If
  `canJoinAllSpaces` proves unreliable on 26.x, the honest degradation is that the HUD appears
  on the active Space only, and the capability matrix says so.
