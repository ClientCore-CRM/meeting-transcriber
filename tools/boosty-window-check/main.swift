import AppKit
import CoreGraphics
import CoreMedia
import Foundation

final class FixtureView: NSView {
    var fill = NSColor.blue
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); dirtyRect.fill()
        NSColor.white.setFill(); NSRect(x: 10, y: 10, width: 200, height: 100).fill()
    }
}

enum FixtureFailure: Error { case missingWarning, timing }
@main enum WindowFixture {
    @MainActor static func main() {
        guard CGPreflightScreenCaptureAccess() else {
            print("LIVE_WINDOW_CHECK_BLOCKED: screen-recording permission is absent for the fixture binary")
            exit(77)
        }
        let mode = CommandLine.arguments.dropFirst().first ?? "title"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.title = "Boosty synthetic meeting fixture"
        window.contentView = FixtureView(frame: window.contentLayoutRect)
        window.backgroundColor = .blue
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.display()
        let output = URL(fileURLWithPath: "/private/tmp/boosty-window-fixture-\(UUID().uuidString).mp4")
        let recorder = MeetingWindowRecorder(output: output)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await recorder.start(windowID: UInt32(window.windowNumber))
                if mode == "title_idle" { try await Task.sleep(for: .seconds(2)) }
                else {
                    for _ in 0 ..< 10 {
                        window.contentView?.needsDisplay = true
                        window.display()
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
                let changedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                switch mode {
                case "close": window.close()
                case "minimize": window.miniaturize(nil)
                case "static": break
                default:
                    window.title = "Boosty synthetic other tab"
                    (window.contentView as? FixtureView)?.fill = .red
                    window.contentView?.needsDisplay = true
                    window.display()
                }
                try await Task.sleep(for: .seconds(1))
                let video = try await recorder.stop()
                print("VIDEO_PATH=\(video.path.path)")
                window.orderOut(nil)
                if mode.hasPrefix("title") {
                    guard video.warnings.contains(where: { $0.contains("identity changed") }) else { throw FixtureFailure.missingWarning }
                    guard abs(video.hostStart + video.duration - changedAt) < 0.4 else { throw FixtureFailure.timing }
                }
                if mode == "close", video.warnings.isEmpty { throw FixtureFailure.missingWarning }
                print("MODE=\(mode) WARNINGS=\(video.warnings)")
                print("LIVE_WINDOW_CHECK_PASSED: owned-window capture validated; duration=\(video.duration)")
                exit(0)
            } catch { print("LIVE_WINDOW_CHECK_FAILED: \(error)"); exit(1) }
        }
        app.run()
    }
}
