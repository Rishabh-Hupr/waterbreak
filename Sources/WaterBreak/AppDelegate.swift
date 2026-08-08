import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// When true the app shows one break immediately and quits when it ends —
    /// used by `--now` for demos and screenshots.
    var runOnceAndQuit = false

    private var settings = Settings.load()
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem?
    private var scheduleTimer: Timer?
    private var nextBreakAt: Date?
    private var menuRefreshTimer: Timer?

    /// Starts the screensaver. Indirected so `--selftest` can exercise the break
    /// logic without actually locking the session.
    var startScreenSaver: () -> Bool = ScreenSaver.start
    /// Reports how many times `startScreenSaver` ran; supplied by `--selftest`.
    var screenSaverStartCount: () -> Int = { 0 }

    /// Set while the screen is locked or the machine is asleep. Holds how much of
    /// the interval was left, so a brief absence resumes where it left off.
    private var pausedRemaining: TimeInterval?
    /// When the current absence began, used to decide whether being away counted
    /// as the break itself.
    private var awaySince: Date?
    /// True when *we* caused the lock by starting a break. Returning from one of
    /// those always earns a fresh interval, however briefly the user was gone —
    /// otherwise skipping the screensaver quickly would resume a near-zero
    /// remainder and lock them straight back out.
    private var lockedForBreak = false
    private var isAway: Bool { awaySince != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            if self.runOnceAndQuit {
                NSApp.terminate(nil)
                return
            }
            self.scheduleNextBreak()
            self.refreshMenu()
        }

        if runOnceAndQuit {
            overlay.show(duration: settings.breakSeconds)
            return
        }

        setUpStatusItem()
        observeSessionChanges()
        // Adopt the session's current state before arming anything: launching
        // behind a locked screen means the user is away already, and the unlock
        // notification will start the first interval.
        if Self.screenIsLocked {
            handleAway()
        } else if settings.enabled {
            scheduleNextBreak()
        }
        // Keeps the "next break in N min" line in the menu honest, and doubles as
        // the watchdog that revives a stalled schedule.
        let refresh = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.healScheduleIfStalled()
            self?.refreshMenu()
        }
        RunLoop.main.add(refresh, forMode: .common)
        menuRefreshTimer = refresh
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "💧"
        item.menu = NSMenu()
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let status: String
        if !settings.enabled {
            status = "Reminders paused"
        } else if isAway {
            status = "Paused while away"
        } else if let nextBreakAt {
            let minutes = max(0, Int(nextBreakAt.timeIntervalSinceNow / 60.0).advanced(by: 1))
            status = "Next break in \(minutes) min"
        } else {
            status = "Next break not scheduled"
        }
        let statusEntry = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusEntry.isEnabled = false
        menu.addItem(statusEntry)
        menu.addItem(.separator())

        menu.addItem(withTitleAndAction: "Take a Break Now", target: self, action: #selector(takeBreakNow))
        menu.addItem(
            withTitleAndAction: settings.enabled ? "Pause Reminders" : "Resume Reminders",
            target: self,
            action: #selector(toggleEnabled)
        )
        menu.addItem(.separator())

        let intervalMenu = NSMenu()
        for choice in Settings.intervalChoices {
            let entry = NSMenuItem(
                title: "Every \(choice) minutes",
                action: #selector(selectInterval(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.tag = choice
            entry.state = settings.intervalMinutes == choice ? .on : .off
            intervalMenu.addItem(entry)
        }
        let intervalEntry = NSMenuItem(title: "Reminder Interval", action: nil, keyEquivalent: "")
        intervalEntry.submenu = intervalMenu
        menu.addItem(intervalEntry)

        let styleMenu = NSMenu()
        let styleLabels: [(BreakStyle, String)] = [
            (.lockScreen, "Lock screen (screensaver)"),
            (.overlay, "Overlay only"),
        ]
        for (style, label) in styleLabels {
            let entry = NSMenuItem(title: label, action: #selector(selectStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.rawValue
            entry.state = settings.style == style ? .on : .off
            styleMenu.addItem(entry)
        }
        let styleEntry = NSMenuItem(title: "When a Break Is Due", action: nil, keyEquivalent: "")
        styleEntry.submenu = styleMenu
        menu.addItem(styleEntry)

        // Break length only means anything for the overlay; a lock-screen break
        // lasts until the user comes back and unlocks.
        if settings.style == .overlay {
            let breakMenu = NSMenu()
            for choice in Settings.breakChoices {
                let label = choice < 60 ? "\(choice) seconds" : "\(choice / 60) minute\(choice >= 120 ? "s" : "")"
                let entry = NSMenuItem(title: label, action: #selector(selectBreakLength(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = choice
                entry.state = settings.breakSeconds == choice ? .on : .off
                breakMenu.addItem(entry)
            }
            let breakEntry = NSMenuItem(title: "Break Length", action: nil, keyEquivalent: "")
            breakEntry.submenu = breakMenu
            menu.addItem(breakEntry)
        }

        menu.addItem(.separator())
        menu.addItem(withTitleAndAction: "Quit WaterBreak", target: self, action: #selector(quit), keyEquivalent: "q")
    }

    // MARK: - Actions

    @objc private func takeBreakNow() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        nextBreakAt = nil
        startBreak()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = BreakStyle(rawValue: raw) else { return }
        settings.style = style
        settings.save()
        refreshMenu()
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        settings.save()
        if settings.enabled {
            scheduleNextBreak()
        } else {
            scheduleTimer?.invalidate()
            scheduleTimer = nil
            nextBreakAt = nil
        }
        refreshMenu()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        settings.intervalMinutes = sender.tag
        settings.save()
        if settings.enabled {
            scheduleNextBreak()
        }
        refreshMenu()
    }

    @objc private func selectBreakLength(_ sender: NSMenuItem) {
        settings.breakSeconds = sender.tag
        settings.save()
        refreshMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Scheduling

    private func scheduleNextBreak() {
        scheduleNextBreak(in: TimeInterval(settings.intervalMinutes * 60))
    }

    /// Arms the break timer to fire `interval` seconds from now.
    ///
    /// While away (locked or asleep) we only record the remaining time — arming a
    /// timer then would be pointless, since it cannot fire during sleep and would
    /// fire instantly on return.
    private func scheduleNextBreak(in interval: TimeInterval) {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard settings.enabled else { return }

        if isAway {
            pausedRemaining = interval
            nextBreakAt = nil
            return
        }

        let target = Date().addingTimeInterval(interval)
        nextBreakAt = target
        pausedRemaining = nil

        // Fire against an absolute date rather than an interval, so clock drift
        // and short suspensions don't quietly stretch the gap.
        let timer = Timer(fireAt: target, interval: 0, target: self, selector: #selector(breakTimerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    @objc private func breakTimerFired() {
        scheduleTimer = nil
        nextBreakAt = nil
        // Guard against a timer that slipped through while we were away. If the
        // user is already locked they are already on a break, so there is
        // nothing to do — handleReturn will schedule afresh when they come back.
        guard settings.enabled, !isAway else { return }
        // Ask the session directly as well as trusting `isAway`. Launching while
        // the screen is already locked arms a timer with no absence recorded, and
        // firing then would start a screensaver behind the lock screen and burn
        // the break on nobody.
        if Self.screenIsLocked {
            handleAway()
            return
        }
        startBreak()
    }

    /// Presents a break in whichever style is configured.
    private func startBreak() {
        switch settings.style {
        case .lockScreen:
            // Locking *is* the break: the screensaver takes the screen, the
            // session locks, and the break lasts until the user unlocks. The
            // away handlers then treat that as the break having been taken.
            if startScreenSaver() {
                // Nothing more to schedule here. Starting the screensaver will
                // produce a screensDidSleep / sessionDidResignActive event,
                // which routes into handleAway and suspends the countdown.
                lockedForBreak = true
                refreshMenu()
            } else {
                // Never silently skip a break if the engine will not start.
                overlay.show(duration: settings.breakSeconds)
            }
        case .overlay:
            overlay.show(duration: settings.breakSeconds)
        }
    }

    // MARK: - Lock and sleep

    /// Time away that counts as having taken the break outright. A little longer
    /// than the break itself, so merely glancing away doesn't reset the clock.
    private var awayCountsAsBreakThreshold: TimeInterval {
        max(TimeInterval(settings.breakSeconds), 60)
    }

    private func observeSessionChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        // Fast user switching. Despite the name this is *not* a screen-lock signal
        // on modern macOS — see the distributed notifications below.
        workspace.addObserver(self, selector: #selector(handleAway), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(handleReturn), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        // Lid close / system sleep and wake.
        workspace.addObserver(self, selector: #selector(handleAway), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(handleReturn), name: NSWorkspace.didWakeNotification, object: nil)
        // Display sleep is a decent proxy for stepping away too.
        workspace.addObserver(self, selector: #selector(handleAway), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(handleReturn), name: NSWorkspace.screensDidWakeNotification, object: nil)

        // The actual lock/unlock signals. These are the ones that fire for a
        // screensaver-induced lock, and none of the NSWorkspace notifications
        // above do: `screensDidSleep` means the *display* slept, which a running
        // screensaver prevents, and `sessionDidResignActive` is fast user
        // switching. Without these, starting a break never registered as going
        // away, so unlocking afterwards scheduled nothing at all.
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributed.addObserver(self, selector: #selector(handleAway), name: NSNotification.Name(name), object: nil)
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            distributed.addObserver(self, selector: #selector(handleReturn), name: NSNotification.Name(name), object: nil)
        }
    }

    /// Whether the login session reports the screen as locked right now.
    ///
    /// Polled ground truth, used to recover if a lock or unlock notification is
    /// ever missed. The key is only present while locked, so absence means
    /// unlocked rather than unknown.
    static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Re-arms the schedule if it has somehow been left dead — reminders enabled,
    /// nobody away, and yet no timer armed. Cheap to check and it means a single
    /// missed notification degrades into a late break rather than a silent stop.
    private func healScheduleIfStalled() {
        guard settings.enabled, !isAway, scheduleTimer == nil, !runOnceAndQuit else { return }
        // A genuinely locked screen is an absence we failed to observe; adopt it
        // rather than arming a timer that would fire behind the lock screen.
        if Self.screenIsLocked {
            handleAway()
            return
        }
        scheduleNextBreak()
    }

    /// Locked, slept, or screens off: bank the remaining time and stop the timer.
    @objc private func handleAway() {
        guard !isAway else { return }  // Lock and sleep often arrive together.
        awaySince = Date()

        if let nextBreakAt {
            pausedRemaining = max(0, nextBreakAt.timeIntervalSinceNow)
        }
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        nextBreakAt = nil

        // If a break is on screen, tear it down — nobody is watching, and it must
        // not linger over the desktop when the user returns.
        if overlay.isVisible {
            overlay.dismiss()
        }
        refreshMenu()
    }

    /// Back at the machine. A long absence *was* the break, so start a fresh
    /// interval; a brief one just resumes the countdown.
    @objc private func handleReturn() {
        // A return without a recorded absence used to bail out here, which left
        // the schedule permanently dead whenever an away event was missed. Treat
        // it as a full absence instead: coming back should always leave a timer
        // armed, and erring towards a fresh interval never fires a break in the
        // user's face.
        let awayDuration = awaySince.map { Date().timeIntervalSince($0) } ?? .infinity
        self.awaySince = nil

        guard settings.enabled else {
            refreshMenu()
            return
        }

        if lockedForBreak || awayDuration >= awayCountsAsBreakThreshold {
            // Either that absence was the break, or we locked the screen to make
            // it happen. Both earn a clean interval.
            lockedForBreak = false
            scheduleNextBreak()
        } else {
            // Resume the banked remainder, with a small floor so a break never
            // lands the instant the screen comes back.
            let remaining = max(pausedRemaining ?? TimeInterval(settings.intervalMinutes * 60), 10)
            scheduleNextBreak(in: remaining)
        }
        pausedRemaining = nil
        refreshMenu()
    }
}

// MARK: - Test hooks
//
// Small seams so `--selftest` can drive the scheduler without a menu bar or a
// real lock event. Not used by the shipping paths.
extension AppDelegate {
    var testInterval: Int {
        get { settings.intervalMinutes }
        set { settings.intervalMinutes = newValue }
    }

    var testBreakSeconds: Int {
        get { settings.breakSeconds }
        set { settings.breakSeconds = newValue }
    }

    var testStyle: BreakStyle {
        get { settings.style }
        set { settings.style = newValue }
    }

    /// Fires the break timer as if its date had arrived.
    func fireBreakTimerForTesting() {
        breakTimerFired()
    }

    /// Invokes the "Take a Break Now" menu action.
    func takeBreakNowForTesting() {
        takeBreakNow()
    }

    /// Runs one tick of the watchdog that revives a stalled schedule.
    func healScheduleForTesting() {
        healScheduleIfStalled()
    }

    /// Starts observing session changes and arms the first break, skipping the
    /// menu-bar setup that a headless test cannot use.
    func startScheduleForTesting() {
        settings.enabled = true
        observeSessionChanges()
        scheduleNextBreak()
    }

    /// Seconds until the armed break, or nil when nothing is armed.
    var secondsUntilNextBreak: TimeInterval? {
        nextBreakAt?.timeIntervalSinceNow
    }

    var screenSaverStartsForTesting: Int { screenSaverStartCount() }
    var isAwayForTesting: Bool { isAway }
    var awaySinceForTesting: Date? { awaySince }
    var hasArmedTimerForTesting: Bool { scheduleTimer != nil }
    var overlayVisibleForTesting: Bool { overlay.isVisible }

    /// Pretends the current absence started `seconds` further in the past.
    func backdateAwayForTesting(by seconds: TimeInterval) {
        guard let awaySince else { return }
        self.awaySince = awaySince.addingTimeInterval(-seconds)
    }

    func setPausedRemainingForTesting(_ seconds: TimeInterval) {
        pausedRemaining = seconds
    }
}

private extension NSMenu {
    func addItem(withTitleAndAction title: String, target: AnyObject, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        addItem(item)
    }
}
