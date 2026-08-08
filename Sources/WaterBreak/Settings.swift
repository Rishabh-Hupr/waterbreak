import Foundation

/// User-tunable options, persisted in UserDefaults.
struct Settings {
    /// Minutes of work between breaks.
    var intervalMinutes: Int
    /// Length of each break, in seconds.
    var breakSeconds: Int
    /// Whether the reminder schedule is running.
    var enabled: Bool
    /// How a due break is presented.
    var style: BreakStyle

    static let intervalChoices = [20, 30, 45, 60, 90]
    static let breakChoices = [20, 30, 60, 120]

    private enum Key {
        static let interval = "intervalMinutes"
        static let breakLength = "breakSeconds"
        static let enabled = "scheduleEnabled"
        static let style = "breakStyle"
    }

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.interval: 45,
            Key.breakLength: 30,
            Key.enabled: true,
            Key.style: BreakStyle.lockScreen.rawValue,
        ])
        let rawStyle = defaults.string(forKey: Key.style) ?? BreakStyle.lockScreen.rawValue
        return Settings(
            intervalMinutes: defaults.integer(forKey: Key.interval),
            breakSeconds: defaults.integer(forKey: Key.breakLength),
            enabled: defaults.bool(forKey: Key.enabled),
            style: BreakStyle(rawValue: rawStyle) ?? .lockScreen
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(intervalMinutes, forKey: Key.interval)
        defaults.set(breakSeconds, forKey: Key.breakLength)
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(style.rawValue, forKey: Key.style)
    }
}
