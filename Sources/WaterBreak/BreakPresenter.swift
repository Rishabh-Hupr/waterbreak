import AppKit

/// How a due break is presented.
enum BreakStyle: String {
    /// Start the screensaver, which locks the screen. The break lasts until the
    /// user comes back and unlocks — walking away *is* the break.
    case lockScreen
    /// Draw the pixel overlay over the desktop for a fixed number of seconds.
    case overlay
}

/// Starts the system screensaver, which in turn locks the screen if the user's
/// security policy says to lock on screensaver.
enum ScreenSaver {
    private static let enginePath = "/System/Library/CoreServices/ScreenSaverEngine.app"

    /// Launches the screensaver engine. Returns false if it could not be started,
    /// so the caller can fall back to the overlay rather than silently skipping
    /// the break.
    static func start() -> Bool {
        let url = URL(fileURLWithPath: enginePath)
        guard FileManager.default.fileExists(atPath: enginePath) else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Fire and forget; the engine takes over the display itself.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    /// Whether the machine locks as soon as the screensaver starts. When false a
    /// lock-screen break will show the art but leave the session unlocked, so the
    /// app can tell the user their setting undercuts the intent.
    static var locksImmediately: Bool {
        // askForPassword with a delay of 0 means "require password immediately".
        let defaults = UserDefaults(suiteName: "com.apple.screensaver")
        guard let asksForPassword = defaults?.object(forKey: "askForPassword") as? Int, asksForPassword == 1 else {
            // Modern macOS manages this outside the readable domain; assume the
            // common default of locking rather than warning noisily.
            return true
        }
        let delay = defaults?.object(forKey: "askForPasswordDelay") as? Int ?? 0
        return delay == 0
    }
}
