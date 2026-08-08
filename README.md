# WaterBreak

A macOS menu-bar app that takes over every screen at regular intervals with an
animated pixel-art water-break reminder.

Native Swift/AppKit, zero dependencies. The scene is drawn procedurally into a
small pixel buffer and upscaled with nearest-neighbour filtering, so there are no
GIF or image assets to ship and it looks sharp at any resolution.

See `DESIGN.md` for why it is built this way, the away-state machine, and known
gaps — read that before making changes.

## Build and launch

```bash
./build-app.sh          # produces dist/WaterBreak.app
open dist/WaterBreak.app
```

Launching is silent: no Dock icon, no window, just the 💧 in the menu bar. Check
it took with `pgrep -f 'WaterBreak.app'`; stop it with `pkill -f 'WaterBreak.app'`
or Quit from the menu.

Spotlight, Raycast and Finder search won't find the app, since `dist/` is a
gitignored build output and none of them index one. To make it launchable by name:

```bash
cp -R dist/WaterBreak.app /Applications/
mdimport /Applications/WaterBreak.app      # reindex now rather than eventually
```

It must be a copy, not a symlink — Spotlight does not index an app through one.

The app icon is a pixel-art droplet drawn by `tools/make_icon.py` at build time,
using the same palette as the break scene. No binary art is committed.

A 💧 icon appears in the menu bar. There is no Dock icon (`LSUIElement`).

## Menu

- **Take a Break Now** — show the overlay immediately
- **Pause / Resume Reminders**
- **Reminder Interval** — 20 / 30 / 45 / 60 / 90 minutes (default 45)
- **Break Length** — 20s / 30s / 1m / 2m (default 30s)
- **Quit**

Settings persist in `UserDefaults`.

## The break screen

Covers all attached displays at `.screenSaver` window level, so it sits above
other apps, the Dock, and the menu bar. It shows:

- a gradient night sky with a twinkling star field
- a glass of water whose fill level breathes, with a wavy surface and rising bubbles
- a calm animated sea along the bottom
- the message, and a countdown of the remaining break time

Dismiss with **Esc**, **Return**, or **Space**; it also dismisses itself when the
countdown reaches zero. Focus returns to whichever app you were using.

## How a break is presented

**Lock screen (default).** When a break is due the system screensaver starts,
which locks the screen. The break lasts until you come back and unlock —
walking away *is* the break, so there is no fixed 30-second window and no
"dismiss" to reach for. Unlocking starts a fresh interval.

Because your Mac locks on screensaver, you will type your password coming back.
That is the intended cost: it makes the break real rather than something you
reflexively dismiss.

**Overlay only.** The original behavior — the pixel scene drawn over your desktop
for a fixed number of seconds, dismissed with Esc. No locking, no password. Choose
it under **When a Break Is Due**; **Break Length** then becomes meaningful and
appears in the menu.

## Pixel art on the lock screen

The scene also ships as a screensaver, which is what gets it onto the lock screen —
`loginwindow` hosts screensavers itself, so a `.saver` bundle can draw there even
though no ordinary app window can.

```bash
./build-saver.sh        # produces dist/WaterBreak.saver
./install-saver.sh      # copies it to ~/Library/Screen Savers
```

Then pick it in **System Settings → Screen Saver → WaterBreak**. If it does not
appear, or shows black, quit and reopen System Settings — the list is cached per
launch.

Once selected, a lock-screen break shows your pixel art rather than whatever
Apple screensaver was configured, and the same art appears whenever the Mac idles.

The saver shares `BreakScene.swift`, `PixelCanvas.swift` and `PixelFont.swift`
with the app — compiled from the same files, not copied — so the art cannot drift
between the two. It omits the countdown and the dismissal hint, since a screensaver
has no fixed length and ends on input rather than on a keypress.

## Lock and sleep

Time away from the machine counts as a break already taken.

On lock, system sleep, or display sleep the countdown is suspended and the
remaining time is banked. Nothing is drawn while away — an app window cannot
appear above the login window in any case, since that runs in a separate secure
session.

On unlock or wake:

- **Away longer than the break length** — that absence *was* the break. A fresh
  full interval starts. Notably, no overlay appears the instant you sit down.
- **Away briefly** — the banked remainder resumes, with a 10-second floor so a
  break never lands the moment the screen comes back.

Unlocking always leaves the next break scheduled, including after a manual
"Take a Break Now". A watchdog re-arms the timer if it is ever found stopped, so
a missed lock or unlock event makes a break late rather than cancelling
reminders altogether.

Duplicate events are collapsed, since macOS commonly posts lock and sleep
together and either alone would otherwise reset the away clock. A break already
on screen when you lock is torn down, so it cannot linger over the desktop.

Timers fire against an absolute target date rather than a relative interval, so
clock drift and short suspensions don't quietly stretch the gap.

## Flags

```bash
.build/release/WaterBreak --now              # show one break, then quit
.build/release/WaterBreak --render out.png   # dump a single frame to PNG, no window
.build/release/WaterBreak --selftest         # exercise the lock/sleep scheduler
```

`--render` is the quickest way to iterate on the visuals without waiting for a
schedule or covering your screen.

`--selftest` posts the real `NSWorkspace` lock/sleep/wake notifications and
asserts on the resulting schedule, so the away logic can be checked without
actually locking the screen. There is no test target because the package has no
dependencies.

## Not handled

The app does not start at login — there is no `LaunchAgent`, so it needs
relaunching after a reboot or logout.

## Layout

| File | Role |
| --- | --- |
| `main.swift` | entry point, flag handling |
| `AppDelegate.swift` | menu bar, settings menu, break scheduling |
| `OverlayController.swift` | one borderless full-screen window per display |
| `BreakView.swift` | animation clock, scaled blit |
| `BreakScene.swift` | the scene itself — sky, stars, glass, water, sea, text |
| `PixelCanvas.swift` | RGBA pixel buffer, drawing primitives, palette |
| `PixelFont.swift` | 5x7 bitmap font |
| `Settings.swift` | `UserDefaults` persistence |
| `SelfTest.swift` | `--selftest` checks for the lock/sleep scheduler |
| `BreakPresenter.swift` | break styles, screensaver launching |
| `Saver/WaterBreakSaverView.swift` | screensaver front-end for the same scene |
| `tools/make_icon.py` | draws the app icon as pixel art; run by `build-app.sh` |

## Prior art

Searched for existing work before writing this — no equivalent turned up. The
nearest things were unrelated: device screensavers, an Android timer overlay, and
a personal Pomodoro script.

## Licence

**MIT** — see `LICENSE`. There are no third-party assets to account for: the
artwork is drawn procedurally in code and the font is a hand-plotted bitmap.
