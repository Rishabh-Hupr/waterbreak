# WaterBreak — design notes

Context for whoever picks this up next, human or AI. `README.md` covers *what it
does and how to run it*; this file covers *why it is built this way*, what was
deliberately left out, and where the traps are.

Written 2026-08-04, at commit `2dbfa78`.

## Origin

Asked for: a macOS desktop app that takes over the whole screen to show a
water-break reminder as a pixel-art / GIF-like animation, plus a check for
existing prior art.

A prior-art search found **nothing equivalent**. The nearest things were
unrelated: device screensavers, an Android timer overlay, and a personal Pomodoro
script. Worth redoing this search before any significant expansion — the
conclusion was "build fresh", and that could change.

## Decisions and why

**Native Swift/AppKit, no dependencies.** An always-resident background app that
covers the screen should be tiny and start instantly. Electron would have meant
tens of MB and a runtime for what is a timer plus a canvas. Cost: the pixel font
and every drawing primitive are hand-written.

**Procedural pixel art, not a GIF.** The original ask mentioned a GIF. Generating
the scene into a small RGBA buffer and upscaling it with nearest-neighbour
filtering instead means no asset to source or license, sharpness at any Retina
resolution, adaptation to any aspect ratio, and animation driven by real elapsed
time — so the countdown and the visuals cannot drift apart. Cost: visual richness
is bounded by what is reasonable to write as code. If a designed asset is ever
wanted, `BreakScene` is the seam to replace; nothing else needs to know.

**Canvas height is fixed at 180px** (`BreakScene.canvasHeight`), with width
derived from the display's aspect ratio so pixels stay square. This is the single
knob controlling how chunky everything looks. Raising it makes the art finer and
the text smaller relative to the screen; the `scale:` arguments in `drawText`
would need revisiting alongside it.

**20 fps** (`BreakView`). Deliberate — a chunky pixel scene gains nothing from 60
and this keeps a background app cheap. Not a display-linked timer, which would be
the upgrade if smoothness ever matters.

**Deterministic RNG** (`SplitMix64`, fixed seed). The star field and bubbles are
identical every launch, so the scene is reproducible and `--render` output is
comparable across changes. Reseed per break if variety is ever wanted.

**`.screenSaver` window level, one borderless window per display.** This is what
gets it above other apps, the Dock, and the menu bar. `canJoinAllSpaces` and
`fullScreenAuxiliary` in the collection behavior make it appear over full-screen
apps too. Only the *first* screen's view drives dismissal, so multi-monitor setups
fire `onDismiss` once rather than per display.

**A local key monitor, not first responder.** `NSEvent.addLocalMonitorForEvents`
proved more reliable than key routing across several borderless windows. Esc,
Return, and Space all dismiss.

**Focus restoration.** The frontmost app is captured before showing and reactivated
on dismiss, so a break doesn't cost you your place.

**The app icon is drawn in code too.** `tools/make_icon.py` generates the `.iconset`
at build time and reuses `Palette` from `PixelCanvas.swift`, so the icon and the
overlay it opens look like the same product — if that palette changes, change it
there too. Same reasoning as the scene: no binary art in the repo. PNGs are written
with stdlib `zlib`, so this needs no Python packages. Two things it settled by trying
the alternative: the droplet's taper exponent must be **below** 1 so the sides bow
outward under apparent surface tension (above 1 they cave in and it looks like a
balloon on a needle), and the 16 px icon is a separate, plainer drawing rather than a
downscale, because the highlight becomes a stray speck at that size. Note that
without `CFBundleIconFile` in `Info.plist`, an icns sitting in `Resources/` does
nothing at all.

## Break styles

Two presentation paths, chosen under **When a Break Is Due** (`BreakStyle`):

**`.lockScreen` (default).** Starts `ScreenSaverEngine`, which locks the screen.
Requested explicitly: *"the behavior should rather be to actually lock the screen
with the screensaver, and if the screen is already locked — basically I am already
taking a break — nothing happens."* The break has no fixed duration; it ends when
the user unlocks. This inverts the original design, where `breakSeconds` governed
everything.

The password prompt on return is deliberate under this model, not a wart. An
earlier version of this document argued against screensaver-triggered breaks
precisely *because* of that friction — that objection was wrong, because it assumed
a fixed-length break the user waits out. If locking *is* the break, unlocking is
just how you come back.

**`.overlay`.** The original fixed-duration pixel overlay. Still the fallback if
`ScreenSaverEngine` cannot be started, so a break is never silently skipped.

`breakSeconds` only means something for `.overlay`, so the **Break Length** menu is
hidden in lock mode rather than lying about having an effect.

## The screensaver bundle

`Saver/WaterBreakSaverView.swift` plus `build-saver.sh` put the pixel art on the
lock screen. This works where an app window cannot because `loginwindow` hosts
screensavers itself.

**Built with `swiftc`, not SwiftPM.** A `.saver` is a loadable bundle and SwiftPM
has no product type for one, so `build-saver.sh` invokes `swiftc -emit-library`
directly. It compiles the *same* `BreakScene.swift`, `PixelCanvas.swift` and
`PixelFont.swift` files as the app rather than copies, so the art cannot drift.

**`@objc(WaterBreakSaverView)` is load-bearing.** Without the explicit ObjC name
Swift mangles the class to `_TtC15WaterBreakSaver19WaterBreakSaverView`, the
`NSPrincipalClass` lookup fails, and the saver loads as a **plain black screen with
no error anywhere**. This was caught by checking `otool -ov` for the emitted class
name; it would have been painful to diagnose from the symptom.

**Layout is shared, so scene changes must be checked at both sizes.** `render` grew
a `footer:` parameter and the saver passes `nil` for both it and `remaining`, having
no fixed length. The glass is therefore anchored in the gap between the subtitle and
the countdown rather than centred — centring made the rim clip the subtitle exactly
when the countdown was absent, which is the screensaver case. Render both after any
layout edit:

```bash
./.build/release/WaterBreak --render /tmp/overlay.png   # with countdown + footer
./build-saver.sh && <load the bundle>                   # without either
```

**Verification.** The saver was checked by loading the bundle the way
`legacyScreenSaver` does — resolve `NSPrincipalClass`, instantiate, advance frames,
`cacheDisplay` into a bitmap, and assert a non-trivial fraction of sampled pixels
are non-black. That last assertion is what would catch the mangled-class black
screen. A throwaway harness did this; it is not committed, since it only mattered
while getting the bundle to load. Note 80 frames are needed to clear the one-second
fade-in — sampling at 10 frames shows a washed-out scene that looks like a color bug
but is not.

**Still unverified:** a real `loginwindow` session. The bundle loads and renders
correctly under a normal user process, but it has never been observed drawing on an
actual lock screen. Select it in System Settings and lock to confirm.

## The away state machine

The most intricate part, and the part most likely to be broken by careless edits.
Governing idea: **time away from the machine is a break already taken.**

States: normal (timer armed against an absolute date) → away (timer disarmed,
remaining time banked in `pausedRemaining`) → back.

Transitions into away: `com.apple.screenIsLocked` and
`com.apple.screensaver.didstart` (the real lock signals), `willSleep` (lid,
system sleep), `screensDidSleep` (display off), `sessionDidResignActive` (fast
user switch). Out: the corresponding unlock / didstop / didWake /
screensDidWake / become-active.

**The lock signals live on `DistributedNotificationCenter`, not `NSWorkspace`.**
This cost a real bug. The original code observed only `NSWorkspace` and assumed
that starting the screensaver would produce `screensDidSleep` or
`sessionDidResignActive`. Neither fires for a screensaver lock: `screensDidSleep`
means the *display* slept, which a running screensaver actively prevents, and
`sessionDidResignActive` is fast user switching. So a lock-screen break recorded
no absence at all, and unlocking afterwards scheduled nothing — reminders died
silently until a menu item was touched. Symptom as reported: *"I took a manual
break and when I unlocked the screen it didn't automatically do a new break
schedule."*

**`CGSessionCopyCurrentDictionary` is the ground truth**, polled rather than
pushed: `CGSSessionScreenIsLocked` is present only while locked. Consulted before
firing a break and at launch, so a break is never spent behind a screen that is
already locked. Handy while debugging, too — it is how the lock state was
confirmed live rather than inferred.

**Two independent safety nets**, because a missed notification used to be fatal
rather than merely late:

- `handleReturn` treats an unlock with *no* recorded absence as a full absence
  instead of returning early. Coming back always leaves a timer armed.
- A watchdog on the existing 20-second menu-refresh timer re-arms whenever the
  schedule is found dead (enabled, not away, no timer). If the screen is really
  locked it adopts the absence instead of arming.

On return, `handleReturn` branches on absence duration against
`awayCountsAsBreakThreshold` (the break length, floored at 60s):

- **Longer** → that absence was the break. Fresh full interval. No overlay.
- **Shorter** → resume the banked remainder, floored at 10s.

Four non-obvious constraints, each load-bearing:

1. **Duplicate away events must be collapsed.** macOS routinely posts lock and
   sleep together. Without the `guard !isAway` in `handleAway`, the second event
   overwrites `awaySince`, and a lunch break then looks like it began seconds ago
   — which resurrects the exact bug this whole mechanism exists to prevent.
2. **Absolute fire dates, not intervals.** `Timer(fireAt:)`, so drift and brief
   suspensions can't silently stretch the gap.
3. **Never arm a timer while away.** A timer can't fire during sleep and will fire
   *immediately* on resume if its date has passed. `scheduleNextBreak(in:)`
   therefore only banks the remainder when `isAway`, and `breakTimerFired`
   re-checks `!isAway` as a backstop.
4. **Tear down a visible overlay on lock**, or it lingers over the desktop when
   the user comes back.
5. **`lockedForBreak` must survive into `handleReturn`.** When *we* locked the
   screen to force a break, returning always earns a fresh interval however
   briefly the user was gone. Without it, skipping the screensaver immediately
   resumes a near-zero remainder, floors to 10s, and locks the user straight back
   out — a genuine loop. Verified by deleting the guard and watching the test drop
   to 9s.

The floors (10s on resume, 60s on the threshold) exist purely so a break never
lands the instant the screen wakes. That moment is the whole point.

## Verifying

```bash
./.build/release/WaterBreak --selftest      # away logic, 30 checks
./.build/release/WaterBreak --render o.png  # one frame to PNG, no window
./.build/release/WaterBreak --now           # one break now, then quit
```

`--selftest` posts the genuine `NSWorkspace` notifications and asserts on the
resulting schedule, so the away logic is checkable without locking the screen.
The test hooks live in an `extension AppDelegate` at the bottom of
`AppDelegate.swift`. There is no XCTest target on purpose — the package has no
dependencies and this keeps it that way.

The discriminating assertion in the long-absence case: it banks 90s, backdates the
absence 40 minutes, wakes, and expects ~2699s. Reading 90s would mean it wrongly
resumed instead of starting fresh. **Keep that asymmetry** in any rewrite; equal
values would make the test pass vacuously.

**Mutation-test any change to the away logic.** Passing tests prove nothing here
unless they fail on the broken code — that is how the notification bug was
confirmed rather than guessed at. Reverting the distributed observers must fail
"fresh interval armed after a manual break"; restoring the old `guard let
awaySince else { return }` must fail "unmatched unlock armed a fresh interval".
Note the second fix was initially *unverified*: with working observers `awaySince`
is always set, so the first test could not exercise it and the mutation survived.
It needed its own case. Expect that trap for any belt-and-braces fallback.

**What is *not* covered:** the test drives the notifications rather than the OS,
so a real hardware lid-close has never been exercised. The handlers are identical
either way, but it is an inference, not an observation. This gap is exactly what
the notification bug fell through — the handlers were fine, the events never
arrived — so prefer one real lock over another posted notification. Also unverified is the
live overlay appearance — `screencapture` failed with "could not create image from
display" because the terminal lacked Screen Recording permission. The user
confirmed by eye that it renders correctly.

## Known gaps

- **No start at login.** No `LaunchAgent`, so a reboot or logout means relaunching
  by hand (`open dist/WaterBreak.app`). This is the most obvious next task and was
  discussed but not built.
- **Not Spotlight-launchable.** `dist/` is a gitignored build output, so ⌘-Space
  won't find it. Copy to `/Applications` if that is wanted.
- **Ad-hoc signature only** (`codesign --sign -` in `build-app.sh`). Fine locally;
  distribution would need real signing and notarization.
- **No snooze / "skip this one."** Dismissal is all-or-nothing.
- **No idle detection.** Sitting at the keyboard without locking still counts as
  work, which is correct, but genuinely idling at an unlocked machine is not
  detected as a break. `CGEventSourceSecondsSinceLastEventType` would be the way.
- **No usage history or streaks.** Nothing is persisted beyond the three settings.
- **Interval and break length are fixed menu choices**, not free-form entry.

## Traps

- Editing the scheduler without re-running `--selftest` is the main risk; the away
  logic is easy to break in ways that only show up hours later, after a real lock.
- `dist/` and `.build/` are gitignored — don't expect built artifacts in a clone;
  run `./build-app.sh`.
- `LSUIElement` is what suppresses the Dock icon, set in the `Info.plist` heredoc
  *inside `build-app.sh`*, not a standalone file. Easy to miss.
- Settings persist under the `local.waterbreak` domain
  (`defaults read local.waterbreak`), but only once something has been changed
  from the defaults; an untouched install reads empty. That is expected, not a bug
  — `Settings.load()` uses `register(defaults:)`, so absent keys fall back to
  45 min / 30 s / enabled.
- `--now` quits after one break by design. If you are testing the *schedule*,
  don't use it; you'll conclude nothing is running, because nothing is.
