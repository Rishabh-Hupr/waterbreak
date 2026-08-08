import ScreenSaver
import AppKit

/// Screensaver front-end for `BreakScene`.
///
/// This is what puts the pixel art on the lock screen: `loginwindow` hosts
/// screensavers itself, so a `.saver` bundle can draw there even though no
/// ordinary app window can. The scene sources are shared with the app target
/// rather than copied — see `build-saver.sh`.
/// `@objc` with an explicit name is required: Swift would otherwise mangle this
/// to `_TtC15WaterBreakSaver19WaterBreakSaverView`, and the `NSPrincipalClass`
/// lookup in Info.plist would fail — which manifests as a plain black screen
/// rather than any error.
@objc(WaterBreakSaverView)
final class WaterBreakSaverView: ScreenSaverView {
    private let scene = BreakScene()
    private var elapsed: Double = 0

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        // 20 fps, matching the app. `animateOneFrame` is called at this rate.
        animationTimeInterval = 1.0 / 20.0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used for screen savers")
    }

    override func animateOneFrame() {
        elapsed += animationTimeInterval
        setNeedsDisplay(bounds)
    }

    override func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return }

        // Black base, so any rounding at the edges reads as intentional.
        context.setFillColor(.black)
        context.fill(bounds)

        // No countdown and no dismissal hint: a screensaver has no fixed length,
        // and it ends when the user touches the machine rather than on a keypress.
        guard let image = scene.render(
            time: elapsed,
            aspectRatio: bounds.width / bounds.height,
            remaining: nil,
            fadeIn: min(1.0, elapsed / 1.0),
            footer: nil
        ) else { return }

        context.interpolationQuality = .none
        context.draw(image, in: bounds)
    }

    /// No configuration UI.
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
