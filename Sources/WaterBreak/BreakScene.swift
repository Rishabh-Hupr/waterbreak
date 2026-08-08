import CoreGraphics
import Foundation

/// Renders one animated frame of the break screen into a low-resolution pixel
/// canvas. Everything is drawn procedurally, so there are no image assets to
/// ship and the scene scales to any display size.
struct BreakScene {
    /// Logical canvas height in pixels; width is derived from the aspect ratio
    /// so pixels stay square.
    static let canvasHeight = 180

    private let stars: [Star]
    private let bubbles: [Bubble]

    init(seed: UInt64 = 0x5EED_1234) {
        var rng = SplitMix64(seed: seed)
        stars = (0..<90).map { _ in
            Star(
                x: rng.nextDouble(),
                y: rng.nextDouble() * 0.62,
                phase: rng.nextDouble() * 2 * .pi,
                speed: 0.6 + rng.nextDouble() * 1.8
            )
        }
        bubbles = (0..<14).map { _ in
            Bubble(
                x: rng.nextDouble(),
                offset: rng.nextDouble(),
                speed: 0.18 + rng.nextDouble() * 0.30,
                size: rng.nextDouble() < 0.3 ? 2 : 1,
                drift: (rng.nextDouble() - 0.5) * 2.4
            )
        }
    }

    /// - Parameters:
    ///   - time: Seconds since the break started, used to drive animation.
    ///   - aspectRatio: width / height of the target screen.
    ///   - remaining: Seconds left in the break, or nil to hide the countdown.
    ///   - fadeIn: 0...1 opacity ramp applied to foreground elements.
    ///   - footer: Small line along the bottom, or nil for none. The overlay uses
    ///     it for the dismissal hint; the screensaver has nothing to say there.
    func render(time: Double, aspectRatio: Double, remaining: Int?, fadeIn: Double, footer: String? = nil) -> CGImage? {
        let height = Self.canvasHeight
        let width = max(160, Int((Double(height) * aspectRatio).rounded()))
        var canvas = PixelCanvas(width: width, height: height)

        drawBackground(&canvas, time: time)
        drawStars(&canvas, time: time)
        drawGlass(&canvas, time: time, fadeIn: fadeIn)
        drawWaterline(&canvas, time: time)
        drawText(&canvas, remaining: remaining, fadeIn: fadeIn, footer: footer)

        return canvas.makeImage()
    }

    // MARK: - Layers

    /// Vertical gradient from deep night at the top to dusk near the horizon.
    private func drawBackground(_ canvas: inout PixelCanvas, time: Double) {
        for row in 0..<canvas.height {
            let t = Double(row) / Double(canvas.height - 1)
            let color: PixelColor
            if t < 0.5 {
                color = Palette.deepNight.mixed(with: Palette.night, amount: t / 0.5)
            } else {
                color = Palette.night.mixed(with: Palette.dusk, amount: (t - 0.5) / 0.5)
            }
            canvas.rect(x: 0, y: row, width: canvas.width, height: 1, color)
        }
    }

    private func drawStars(_ canvas: inout PixelCanvas, time: Double) {
        for star in stars {
            let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * star.speed + star.phase))
            let x = Int(star.x * Double(canvas.width - 1))
            let y = Int(star.y * Double(canvas.height - 1))
            canvas.set(x, y, Palette.foam, alpha: twinkle * 0.75)
        }
    }

    /// The glass of water: outline, wobbling surface, bubbles and a highlight.
    private func drawGlass(_ canvas: inout PixelCanvas, time: Double, fadeIn: Double) {
        let glassWidth = 68
        let originX = (canvas.width - glassWidth) / 2
        // Anchored in the gap between the subtitle above and the countdown below,
        // rather than centred — centring made the rim clip the subtitle whenever
        // the countdown was absent, as it is in the screensaver.
        let originY = 46
        let glassHeight = (canvas.height - 50) - originY

        // Fill level breathes gently between roughly 55% and 75% full.
        let level = 0.65 + 0.10 * sin(time * 0.7)
        let waterTop = originY + Int(Double(glassHeight) * (1 - level))

        // Water body, with a subtle horizontal shimmer.
        for row in waterTop..<(originY + glassHeight - 2) {
            let depth = Double(row - waterTop) / Double(max(1, originY + glassHeight - waterTop))
            let base = Palette.waterLight.mixed(with: Palette.water, amount: depth)
            for column in (originX + 2)..<(originX + glassWidth - 2) {
                let shimmer = sin(Double(column) * 0.35 + time * 1.6 + depth * 3.0) * 0.08
                let color = base.mixed(with: Palette.foam, amount: max(0, shimmer))
                canvas.set(column, row, color, alpha: fadeIn)
            }
        }

        // Wavy surface line on top of the water.
        for column in (originX + 2)..<(originX + glassWidth - 2) {
            let wave = sin(Double(column) * 0.45 + time * 2.4) + 0.5 * sin(Double(column) * 0.19 - time * 1.7)
            let row = waterTop + Int(wave.rounded())
            canvas.set(column, row, Palette.foam, alpha: fadeIn)
            canvas.set(column, row + 1, Palette.waterLight, alpha: fadeIn * 0.8)
        }

        // Rising bubbles, clipped to the water column.
        let waterDepth = Double((originY + glassHeight - 2) - waterTop)
        if waterDepth > 4 {
            for bubble in bubbles {
                let progress = (bubble.offset + time * bubble.speed).truncatingRemainder(dividingBy: 1.0)
                let row = (originY + glassHeight - 3) - Int(progress * waterDepth)
                guard row > waterTop + 1 else { continue }
                let drift = sin(time * 1.3 + bubble.offset * 6.28) * bubble.drift
                let column = originX + 3 + Int(bubble.x * Double(glassWidth - 8) + drift)
                let alpha = fadeIn * (1.0 - progress * 0.55)
                canvas.rect(x: column, y: row, width: bubble.size, height: bubble.size, Palette.foam, alpha: alpha)
            }
        }

        // Glass outline: two vertical walls plus a base, drawn last so it sits
        // over the water.
        for row in originY..<(originY + glassHeight) {
            canvas.rect(x: originX, y: row, width: 2, height: 1, Palette.glass, alpha: fadeIn)
            canvas.rect(x: originX + glassWidth - 2, y: row, width: 2, height: 1, Palette.glass, alpha: fadeIn)
        }
        canvas.rect(x: originX, y: originY + glassHeight - 2, width: glassWidth, height: 2, Palette.glass, alpha: fadeIn)

        // Specular highlight down the left wall, proportional to the glass so it
        // stays right if the dimensions change.
        let highlightTop = originY + glassHeight / 10
        for row in highlightTop..<(highlightTop + glassHeight / 3) {
            canvas.rect(x: originX + 4, y: row, width: 2, height: 1, Palette.glassShine, alpha: fadeIn * 0.5)
        }
    }

    /// A calm sea at the bottom of the screen for a bit of depth.
    private func drawWaterline(_ canvas: inout PixelCanvas, time: Double) {
        let seaTop = canvas.height - 22
        for row in seaTop..<canvas.height {
            let depth = Double(row - seaTop) / Double(canvas.height - seaTop)
            let color = Palette.dusk.mixed(with: Palette.water, amount: depth * 0.8)
            canvas.rect(x: 0, y: row, width: canvas.width, height: 1, color)
        }
        for column in 0..<canvas.width {
            let wave = sin(Double(column) * 0.12 + time * 1.1) + 0.6 * sin(Double(column) * 0.05 - time * 0.6)
            let row = seaTop + Int(wave.rounded())
            canvas.set(column, row, Palette.waterLight, alpha: 0.9)
            canvas.set(column, row - 1, Palette.foam, alpha: 0.35)
        }
    }

    private func drawText(_ canvas: inout PixelCanvas, remaining: Int?, fadeIn: Double, footer: String?) {
        canvas.centeredText("TIME FOR A WATER BREAK", y: 14, scale: 2, Palette.ink, alpha: fadeIn)
        canvas.centeredText("STAND UP - STRETCH - HYDRATE", y: 32, scale: 1, Palette.dim, alpha: fadeIn)

        if let remaining, remaining > 0 {
            let minutes = remaining / 60
            let seconds = remaining % 60
            let clock = String(format: "%d:%02d", minutes, seconds)
            canvas.centeredText(clock, y: canvas.height - 46, scale: 2, Palette.accent, alpha: fadeIn)
        }
        if let footer {
            canvas.centeredText(footer, y: canvas.height - 12, scale: 1, Palette.dim, alpha: fadeIn * 0.85)
        }
    }
}

private struct Star {
    let x: Double
    let y: Double
    let phase: Double
    let speed: Double
}

private struct Bubble {
    let x: Double
    let offset: Double
    let speed: Double
    let size: Int
    let drift: Double
}

/// Deterministic RNG so the star field and bubbles look the same every launch.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
