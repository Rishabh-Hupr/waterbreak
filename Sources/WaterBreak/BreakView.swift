import AppKit

/// Draws the pixel scene scaled up to fill its bounds, and drives the animation
/// clock off a display-linked timer.
final class BreakView: NSView {
    private let scene = BreakScene()
    private var startTime = Date()
    private var timer: Timer?

    /// Total break length in seconds; nil means no countdown is shown.
    var duration: Int?

    /// Called when the countdown reaches zero.
    var onFinished: (() -> Void)?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func startAnimating() {
        startTime = Date()
        timer?.invalidate()
        // 20 fps is plenty for a chunky pixel scene and keeps the CPU cool.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        needsDisplay = true
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        needsDisplay = true
        if let duration, elapsed >= Double(duration) {
            stopAnimating()
            onFinished?()
        }
    }

    private var elapsed: Double {
        Date().timeIntervalSince(startTime)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return }

        let time = elapsed
        // Ease the foreground in over the first second so it doesn't slam on.
        let fadeIn = min(1.0, time / 1.0)
        let remaining = duration.map { max(0, $0 - Int(time)) }
        let aspectRatio = bounds.width / bounds.height

        guard let image = scene.render(
            time: time,
            aspectRatio: aspectRatio,
            remaining: remaining,
            fadeIn: fadeIn,
            footer: "PRESS ESC TO DISMISS"
        ) else {
            return
        }

        // Nearest-neighbour upscale is what preserves the hard pixel edges.
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
    }
}
