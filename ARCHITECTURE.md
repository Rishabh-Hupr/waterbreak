# WaterBreak — Architecture Diagrams

WaterBreak is a menu-bar macOS app (Swift/AppKit, no third-party deps) that reminds you to
take water breaks at fixed intervals by taking over every display with a procedurally-drawn
animated pixel-art scene. The scene is rendered into a small RGBA buffer (fixed 180px logical
height) and upscaled with nearest-neighbour filtering — no image assets.

The repo builds **two products** from largely shared source:

- **App target** (`WaterBreak`, SwiftPM `.executableTarget`) — the resident menu-bar scheduler.
- **Screensaver target** (`WaterBreak.saver`, loadable bundle) — a `ScreenSaverView` that draws
  the same scene on the lock screen. Built separately with `swiftc -emit-library` (SwiftPM has
  no `.saver` product type).

Central idea (see `DESIGN.md`): **time away from the machine counts as a break already taken.**

> Naming note for readers: `BreakPresenter.swift` does **not** contain a `BreakPresenter` type —
> it holds `enum BreakStyle` and `enum ScreenSaver`.

---

## 1. Component & ownership graph

Solid arrows = "owns / holds a reference"; dashed = "reads from / uses". Files shared between
the two build products are highlighted.

```mermaid
graph TD
    subgraph entry["main.swift"]
        MAIN["top-level flag dispatch<br/>--render / --selftest / --now → GUI"]
    end

    subgraph appdel["AppDelegate.swift"]
        AD["AppDelegate<br/>scheduler + away state machine"]
        SI["NSStatusItem (💧)"]
        SCHED["scheduleTimer (one-shot)"]
        REFRESH["menuRefreshTimer (20s watchdog)"]
    end

    subgraph settings["Settings.swift"]
        ST["Settings (struct)<br/>UserDefaults: interval,<br/>breakSeconds, enabled, style"]
    end

    subgraph presenter["BreakPresenter.swift"]
        BS_ENUM["enum BreakStyle<br/>{lockScreen, overlay}"]
        SS["enum ScreenSaver<br/>start() → launches<br/>ScreenSaverEngine.app"]
    end

    subgraph overlay["OverlayController.swift"]
        OC["OverlayController<br/>windows + views + keyMonitor"]
        OW["OverlayWindow<br/>(.screenSaver level)"]
    end

    subgraph view["BreakView.swift"]
        BV["BreakView (NSView)<br/>20fps Timer → tick/draw"]
    end

    subgraph scene["BreakScene.swift ★shared"]
        SC["BreakScene (struct)<br/>render(...) → CGImage<br/>Stars + Bubbles + SplitMix64"]
    end

    subgraph canvas["PixelCanvas.swift ★shared"]
        PC["PixelCanvas (struct)<br/>RGBA buffer + primitives<br/>PixelColor / Palette"]
    end

    subgraph font["PixelFont.swift ★shared"]
        PF["PixelFont<br/>5×7 bitmap glyphs"]
    end

    subgraph saver["Saver/WaterBreakSaverView.swift"]
        SV["WaterBreakSaverView<br/>(ScreenSaverView)<br/>animateOneFrame()"]
    end

    subgraph selftest["SelfTest.swift"]
        SLT["SelfTest.run()<br/>~30 checks"]
    end

    MAIN --> AD
    MAIN -.-> SLT

    AD --> SI
    AD --> SCHED
    AD --> REFRESH
    AD --> OC
    AD --> ST
    AD -.startScreenSaver = .-> SS
    ST -.style: BreakStyle.-> BS_ENUM
    AD -.switch(style).-> BS_ENUM

    OC --> OW
    OC --> BV
    OC -. "onDismiss → AppDelegate" .-> AD
    BV --> SC
    SC --> PC
    PC -.text.-> PF

    SV --> SC
    SLT -.drives.-> AD

    classDef shared fill:#1b3a4b,stroke:#4fc3f7,color:#e0f7ff;
    class SC,PC,PF shared;
```

The **★shared** files (`BreakScene`, `PixelCanvas`, `PixelFont`) are compiled into *both* the
app and the screensaver (see `build-saver.sh` `SHARED_SOURCES`) — not copied. The saver uses
**none** of `AppDelegate`, `OverlayController`, `BreakView`, `Settings`, or `BreakPresenter`.

---

## 2. App launch sequence

```mermaid
sequenceDiagram
    participant OS as macOS / AppKit
    participant M as main.swift
    participant AD as AppDelegate
    participant OC as OverlayController

    M->>M: parse flags (--render / --selftest / --now)
    M->>OS: NSApplication.shared, policy .accessory
    M->>AD: set delegate, application.run()
    OS->>AD: applicationDidFinishLaunching(_:)
    AD->>OC: set overlay.onDismiss = { runOnceAndQuit ? terminate : scheduleNextBreak + refreshMenu }
    alt --now (runOnceAndQuit)
        AD->>OC: show(duration: breakSeconds) and return
    else normal
        AD->>AD: setUpStatusItem() + refreshMenu() (💧)
        AD->>AD: observeSessionChanges() (NSWorkspace + DistributedNotificationCenter)
        alt screenIsLocked
            AD->>AD: handleAway()
        else enabled
            AD->>AD: scheduleNextBreak()
        end
        AD->>AD: menuRefreshTimer (20s): healScheduleIfStalled() + refreshMenu()
    end
```

---

## 3. Break scheduling → firing → display

```mermaid
sequenceDiagram
    participant T as scheduleTimer
    participant AD as AppDelegate
    participant SS as ScreenSaver.start
    participant OC as OverlayController
    participant BV as BreakView

    Note over AD: scheduleNextBreak(in:) arms one-shot<br/>Timer at absolute nextBreakAt
    T->>AD: breakTimerFired()
    AD->>AD: guard enabled && !isAway; re-check screenIsLocked
    AD->>AD: startBreak()
    alt style == .lockScreen (default)
        AD->>SS: startScreenSaver()
        alt success
            SS-->>AD: lockedForBreak = true (lock routes via handleAway)
        else failure (fallback)
            AD->>OC: show(duration: breakSeconds)
        end
    else style == .overlay
        AD->>OC: show(duration: breakSeconds)
    end
    Note over OC: one OverlayWindow + BreakView per NSScreen,<br/>first view.onFinished → dismiss(); key monitor for Esc/Return/Space
    OC->>BV: startAnimating() (20fps)
    loop each frame
        BV->>BV: tick() → needsDisplay → draw()
        BV->>BV: scene.render(...) → PixelCanvas → CGImage → blit nearest-neighbour
    end
    Note over BV: elapsed >= duration OR key pressed
    BV->>OC: onFinished → dismiss()
    OC->>AD: onDismiss → scheduleNextBreak() + refreshMenu()
```

---

## 4. Away state machine (lock / sleep / return)

"Time away counts as a break." Lock and sleep both route to `handleAway`; the return handler
decides whether the time away *was* the break.

```mermaid
stateDiagram-v2
    [*] --> Scheduled: scheduleNextBreak() arms timer at nextBreakAt
    Scheduled --> Breaking: breakTimerFired() → startBreak()
    Breaking --> Scheduled: overlay dismissed → onDismiss

    Scheduled --> Away: handleAway()<br/>(lock / sleep / screensaver start)
    Breaking --> Away: handleAway() dismisses overlay
    note right of Away
        awaySince recorded
        pausedRemaining banked from nextBreakAt
        scheduleTimer invalidated
    end note

    Away --> Scheduled: handleReturn()<br/>lockedForBreak OR away ≥ threshold<br/>→ fresh interval
    Away --> Scheduled: handleReturn()<br/>short away → resume pausedRemaining

    Scheduled --> Scheduled: menuRefreshTimer (20s)<br/>healScheduleIfStalled() re-arms if dead
```

Notifications wired in `observeSessionChanges()`:
- **Away**: `sessionDidResignActive`, `willSleep`, `screensDidSleep` (NSWorkspace) +
  `com.apple.screenIsLocked`, `com.apple.screensaver.didstart` (DistributedNotificationCenter).
- **Return**: the matching return notifications + `com.apple.screenIsUnlocked`,
  `com.apple.screensaver.didstop`.

`handleAway()` guards `!isAway` so a combined lock+sleep collapses into one. `handleReturn()`
starts a fresh interval when `lockedForBreak` or the away duration ≥ the break-length threshold
(floored 60s); otherwise it resumes the banked `pausedRemaining` (floored 10s).

---

## 5. Screensaver target (separate, no scheduler)

```mermaid
sequenceDiagram
    participant Host as legacyScreenSaver / loginwindow
    participant SV as WaterBreakSaverView
    participant SC as BreakScene (shared)

    Host->>SV: load .saver bundle, resolve NSPrincipalClass = WaterBreakSaverView
    Host->>SV: init(frame:isPreview:) → animationTimeInterval = 1/20
    loop host-driven, 1/20s
        Host->>SV: animateOneFrame() → elapsed += , needsDisplay
        SV->>SC: draw() → scene.render(remaining: nil, footer: nil)
        SC-->>SV: CGImage → blit over black
    end
    Note over SV: no timers, no scheduling, no settings —<br/>OS ends it on user input
```

The `@objc(WaterBreakSaverView)` name is load-bearing: `build-saver.sh` writes it as
`NSPrincipalClass` in the saver's `Info.plist`, and the OS uses that to instantiate the view.
