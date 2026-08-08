import AppKit

// `--render <path>` writes a single frame to a PNG and exits, without opening
// any windows. Useful for eyeballing the scene and for tests.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render") {
    let path = CommandLine.arguments.count > flagIndex + 1
        ? CommandLine.arguments[flagIndex + 1]
        : "waterbreak-frame.png"
    guard let image = BreakScene().render(time: 3.5, aspectRatio: 16.0 / 10.0, remaining: 27, fadeIn: 1.0) else {
        FileHandle.standardError.write(Data("failed to render frame\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(image.width)x\(image.height))")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

let application = NSApplication.shared
let delegate = AppDelegate()

// `--now` shows a single break immediately and exits, which is handy for trying
// the scene out without waiting for the schedule.
delegate.runOnceAndQuit = CommandLine.arguments.contains("--now")

application.delegate = delegate
// Accessory: menu-bar only, no Dock icon and no app menu.
application.setActivationPolicy(.accessory)
application.run()
