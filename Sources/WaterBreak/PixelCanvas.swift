import CoreGraphics
import Foundation

/// A small RGB pixel buffer that gets blown up with nearest-neighbour scaling,
/// which is what gives the app its chunky pixel-art look.
struct PixelCanvas {
    let width: Int
    let height: Int
    private var buffer: [UInt8]  // RGBA, 4 bytes per pixel

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.buffer = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func fill(_ color: PixelColor) {
        for index in stride(from: 0, to: buffer.count, by: 4) {
            buffer[index] = color.r
            buffer[index + 1] = color.g
            buffer[index + 2] = color.b
            buffer[index + 3] = 255
        }
    }

    /// Sets a pixel, alpha-blending onto whatever is already there. Out of
    /// bounds writes are dropped so callers can draw without clipping math.
    mutating func set(_ x: Int, _ y: Int, _ color: PixelColor, alpha: Double = 1.0) {
        guard x >= 0, x < width, y >= 0, y < height, alpha > 0 else { return }
        let index = (y * width + x) * 4
        if alpha >= 1.0 {
            buffer[index] = color.r
            buffer[index + 1] = color.g
            buffer[index + 2] = color.b
        } else {
            let a = min(alpha, 1.0)
            buffer[index] = blend(buffer[index], color.r, a)
            buffer[index + 1] = blend(buffer[index + 1], color.g, a)
            buffer[index + 2] = blend(buffer[index + 2], color.b, a)
        }
        buffer[index + 3] = 255
    }

    mutating func rect(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, _ color: PixelColor, alpha: Double = 1.0) {
        for row in y..<(y + rectHeight) {
            for column in x..<(x + rectWidth) {
                set(column, row, color, alpha: alpha)
            }
        }
    }

    /// Draws `text` in the 5x7 pixel font, with each font pixel expanded to a
    /// `scale` x `scale` block of canvas pixels.
    mutating func text(_ string: String, x: Int, y: Int, scale: Int, _ color: PixelColor, alpha: Double = 1.0) {
        for pixel in PixelFont.pixels(for: string) {
            rect(
                x: x + pixel.x * scale,
                y: y + pixel.y * scale,
                width: scale,
                height: scale,
                color,
                alpha: alpha
            )
        }
    }

    /// Draws `text` horizontally centred on the canvas.
    mutating func centeredText(_ string: String, y: Int, scale: Int, _ color: PixelColor, alpha: Double = 1.0) {
        let textWidth = PixelFont.width(of: string) * scale
        text(string, x: (width - textWidth) / 2, y: y, scale: scale, color, alpha: alpha)
    }

    func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func blend(_ base: UInt8, _ overlay: UInt8, _ alpha: Double) -> UInt8 {
        UInt8(max(0, min(255, Double(base) * (1 - alpha) + Double(overlay) * alpha)))
    }
}

struct PixelColor {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: PixelColor, amount: Double) -> PixelColor {
        let t = max(0, min(1, amount))
        return PixelColor(
            UInt8(Double(r) * (1 - t) + Double(other.r) * t),
            UInt8(Double(g) * (1 - t) + Double(other.g) * t),
            UInt8(Double(b) * (1 - t) + Double(other.b) * t)
        )
    }
}

/// Cohesive palette for the whole scene, so nothing looks bolted on.
enum Palette {
    static let deepNight = PixelColor(12, 22, 48)
    static let night = PixelColor(20, 38, 74)
    static let dusk = PixelColor(34, 62, 110)
    static let water = PixelColor(48, 138, 200)
    static let waterLight = PixelColor(96, 194, 232)
    static let foam = PixelColor(198, 240, 252)
    static let glass = PixelColor(150, 196, 220)
    static let glassShine = PixelColor(226, 248, 255)
    static let ink = PixelColor(245, 252, 255)
    static let dim = PixelColor(146, 182, 212)
    static let accent = PixelColor(255, 206, 112)
}
