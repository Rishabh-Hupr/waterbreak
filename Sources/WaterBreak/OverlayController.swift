import AppKit

/// A borderless window that sits above everything (including the menu bar and
/// Dock) on a single screen.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        // Show over whatever space the user is on, including full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Keep it out of Mission Control / window cycling.
        isExcludedFromWindowsMenu = true
    }
}

/// Owns one overlay window per attached display and coordinates showing and
/// tearing them all down together.
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var views: [BreakView] = []
    private var keyMonitor: Any?
    private var previouslyActiveApp: NSRunningApplication?

    var isVisible: Bool { !windows.isEmpty }

    /// Called when the break ends, whether by timeout or by the user dismissing.
    var onDismiss: (() -> Void)?

    /// Covers every screen with the break scene.
    /// - Parameter duration: Break length in seconds, or nil for no countdown.
    func show(duration: Int?) {
        guard !isVisible else { return }
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = BreakView(frame: screen.frame)
            view.duration = duration
            view.autoresizingMask = [.width, .height]
            // Only the first screen's view drives dismissal, so a multi-monitor
            // setup doesn't fire onDismiss several times.
            if views.isEmpty {
                view.onFinished = { [weak self] in self?.dismiss() }
            }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }

        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        views.forEach { $0.startAnimating() }

        // A local monitor is more reliable here than relying on first responder
        // routing across several borderless windows.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 is Escape; also accept Return and Space as a dismissal.
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 49 {
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    func dismiss() {
        guard isVisible else { return }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        views.forEach { $0.stopAnimating() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        // Hand focus back to whatever the user was doing before the break.
        previouslyActiveApp?.activate()
        previouslyActiveApp = nil
        onDismiss?()
    }
}
