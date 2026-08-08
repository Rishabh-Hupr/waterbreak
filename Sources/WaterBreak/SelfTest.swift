import AppKit

/// Exercises the lock/sleep scheduling logic by posting the same NSWorkspace
/// notifications macOS sends, and asserting on the resulting schedule. Run with
/// `--selftest`; there is no test target since the package has no dependencies.
enum SelfTest {
    static func run() -> Never {
        var failures: [String] = []

        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("  pass: \(label)")
            } else {
                print("  FAIL: \(label)")
                failures.append(label)
            }
        }

        // A 45-minute interval with a 30-second break, matching the defaults.
        let delegate = AppDelegate()
        delegate.testInterval = 45
        delegate.testBreakSeconds = 30
        // Count screensaver starts instead of performing them; actually locking
        // the machine mid-test would be hostile and would end the run.
        var screenSaverStarts = 0
        delegate.startScreenSaver = {
            screenSaverStarts += 1
            return true
        }
        delegate.screenSaverStartCount = { screenSaverStarts }
        // The overlay path is the default style for the first block of checks.
        delegate.testStyle = .overlay
        delegate.startScheduleForTesting()

        let center = NSWorkspace.shared.notificationCenter

        print("baseline")
        let baseline = delegate.secondsUntilNextBreak
        check(baseline != nil && baseline! > 44 * 60 && baseline! <= 45 * 60,
              "break scheduled ~45 min out (got \(baseline.map { Int($0) } ?? -1)s)")
        check(!delegate.isAwayForTesting, "not away initially")

        print("\nlock (screen locked)")
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        check(delegate.isAwayForTesting, "marked away")
        check(delegate.secondsUntilNextBreak == nil, "countdown suspended, no armed target")
        check(delegate.hasArmedTimerForTesting == false, "timer disarmed while locked")

        print("\nduplicate away event (lock + sleep together)")
        let awayStamp = delegate.awaySinceForTesting
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(delegate.awaySinceForTesting == awayStamp, "second away event does not reset the away clock")

        print("\nbrief return (away well under the break length)")
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        check(!delegate.isAwayForTesting, "no longer away")
        let resumed = delegate.secondsUntilNextBreak
        // Should resume the banked remainder (~45 min), NOT restart a fresh interval
        // and NOT fire immediately.
        check(resumed != nil && resumed! > 44 * 60, "resumed banked remainder (got \(resumed.map { Int($0) } ?? -1)s)")
        check(resumed != nil && resumed! > 10, "did not fire immediately on return")

        print("\nlong return (away longer than the break counts as taken)")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        // Backdate the absence to simulate a lunch break.
        delegate.backdateAwayForTesting(by: 40 * 60)
        delegate.setPausedRemainingForTesting(90)  // only 90s was left before locking
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let afterLong = delegate.secondsUntilNextBreak
        check(afterLong != nil && afterLong! > 44 * 60,
              "fresh full interval, not the 90s remainder (got \(afterLong.map { Int($0) } ?? -1)s)")
        check(!delegate.overlayVisibleForTesting, "no break slammed on screen on return")

        print("\nlock-screen style: break due while already locked")
        delegate.testStyle = .lockScreen
        delegate.startScheduleForTesting()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        check(delegate.isAwayForTesting, "away before the break comes due")
        // Firing now simulates a timer that slipped through while locked. The user
        // is already on a break, so nothing should be presented.
        delegate.fireBreakTimerForTesting()
        check(!delegate.overlayVisibleForTesting, "no overlay while locked")
        check(delegate.screenSaverStartsForTesting == 0, "did not start the screensaver while already locked")

        print("\nlock-screen style: unlock resumes promptly")
        delegate.backdateAwayForTesting(by: 30 * 60)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        check(!delegate.isAwayForTesting, "back from the break")
        let afterUnlock = delegate.secondsUntilNextBreak
        check(afterUnlock != nil && afterUnlock! > 44 * 60,
              "fresh interval armed on unlock (got \(afterUnlock.map { Int($0) } ?? -1)s)")

        print("\nlock-screen style: due while active starts the screensaver")
        delegate.fireBreakTimerForTesting()
        check(delegate.screenSaverStartsForTesting == 1, "screensaver started once")
        check(!delegate.overlayVisibleForTesting, "no overlay in lock-screen style")

        print("\nlock-screen style: unlocking straight away does not retrigger")
        // The screensaver starting produces an away event.
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        // Bank a near-zero remainder, which is the realistic state: the break
        // fired because the interval had just elapsed. Resuming this would floor
        // to 10s and lock the user straight back out.
        delegate.setPausedRemainingForTesting(0)
        // User unlocks after only a few seconds, having skipped the break.
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        let afterQuickUnlock = delegate.secondsUntilNextBreak
        // A banked remainder of ~0 would floor to 10s and fire again immediately,
        // locking the user in a loop. A full interval is the correct outcome.
        check(afterQuickUnlock != nil && afterQuickUnlock! > 44 * 60,
              "full interval, not an immediate retrigger (got \(afterQuickUnlock.map { Int($0) } ?? -1)s)")
        check(delegate.screenSaverStartsForTesting == 1, "screensaver not restarted on unlock")

        // The regression the user actually hit: take a manual break, lock, unlock,
        // and find nothing scheduled. The lock arrives as the distributed
        // notification macOS really sends for a screensaver lock, not as one of
        // the NSWorkspace events the app used to rely on.
        print("\nmanual break then unlock schedules the next break")
        let manual = AppDelegate()
        manual.testInterval = 45
        manual.testBreakSeconds = 30
        manual.testStyle = .lockScreen
        var manualStarts = 0
        manual.startScreenSaver = {
            manualStarts += 1
            return true
        }
        manual.screenSaverStartCount = { manualStarts }
        manual.startScheduleForTesting()

        manual.takeBreakNowForTesting()
        check(manual.screenSaverStartsForTesting == 1, "manual break started the screensaver")
        check(manual.secondsUntilNextBreak == nil, "nothing armed while the break is on")

        // This is the notification a real screensaver lock produces.
        let distributed = DistributedNotificationCenter.default()
        distributed.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        // Distributed notifications are delivered asynchronously, so let the run
        // loop drain before asserting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check(manual.isAwayForTesting, "screenIsLocked marked the session away")

        distributed.post(name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check(!manual.isAwayForTesting, "back after unlocking")
        let afterManual = manual.secondsUntilNextBreak
        check(afterManual != nil && afterManual! > 44 * 60,
              "fresh interval armed after a manual break (got \(afterManual.map { Int($0) } ?? -1)s)")
        check(manual.screenSaverStartsForTesting == 1, "screensaver not restarted on unlock")

        // An unlock with no matching lock event. This happens whenever the away
        // notification is dropped, and it used to hit an early return in
        // handleReturn that left the schedule dead with no way back.
        print("\nunlock with no recorded absence still arms a timer")
        let orphan = AppDelegate()
        orphan.testInterval = 45
        orphan.testStyle = .lockScreen
        orphan.startScreenSaver = { true }
        orphan.startScheduleForTesting()
        orphan.takeBreakNowForTesting()
        check(!orphan.isAwayForTesting, "no absence was ever recorded")
        // Only the unlock arrives.
        distributed.post(name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let afterOrphan = orphan.secondsUntilNextBreak
        check(afterOrphan != nil && afterOrphan! > 44 * 60,
              "unmatched unlock armed a fresh interval (got \(afterOrphan.map { Int($0) } ?? -1)s)")

        // Belt and braces: even if every lock/unlock notification is missed, the
        // watchdog must not leave the schedule dead forever.
        print("\nwatchdog revives a schedule left unarmed")
        let stalled = AppDelegate()
        stalled.testInterval = 45
        stalled.testStyle = .lockScreen
        stalled.startScreenSaver = { true }
        stalled.startScheduleForTesting()
        stalled.takeBreakNowForTesting()
        check(!stalled.hasArmedTimerForTesting, "nothing armed straight after the break starts")
        // No lock or unlock event ever arrives — the exact failure mode.
        stalled.healScheduleForTesting()
        // Under a real locked screen the watchdog adopts the absence instead of
        // arming; either outcome is correct, a dead schedule is not.
        let healed = stalled.hasArmedTimerForTesting || stalled.isAwayForTesting
        check(healed, "watchdog left either an armed timer or a recorded absence, not a dead schedule")

        print("\nresult")
        if failures.isEmpty {
            print("  all checks passed")
            exit(0)
        }
        print("  \(failures.count) failure(s): \(failures.joined(separator: "; "))")
        exit(1)
    }
}
