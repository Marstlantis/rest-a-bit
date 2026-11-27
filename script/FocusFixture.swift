import AppKit

// An independent, empty editor used only by the native window probe.
@MainActor
final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var editor: NSTextView!
    private var lastFullScreenCommand: String?
    private let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 530, height: 300),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        writeFullScreenState("windowed")
        window.title = "Rest a Bit QA – Synthetic Editor"
        editor = NSTextView(frame: window.contentView!.bounds)
        editor.autoresizingMask = [.width, .height]
        editor.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        editor.textContainerInset = CGSize(width: 25, height: 25)
        editor.string = "Synthetic editor for Rest a Bit focus tests.\n"
        window.contentView = editor
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)

        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.processFullScreenCommand()
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                if foreground, NSApp.keyWindow === self.window, self.window.firstResponder === self.editor {
                    try? "\(ProcessInfo.processInfo.processIdentifier)".write(
                        to: self.output.appendingPathComponent("fixture-ready.txt"), atomically: true, encoding: .utf8)
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: self.window.windowNumber, context: nil,
                                                     characters: "x", charactersIgnoringModifiers: "x",
                                                     isARepeat: false, keyCode: 7) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    if FileManager.default.fileExists(atPath: self.output.appendingPathComponent("escaped.flag").path),
                       !FileManager.default.fileExists(atPath: self.output.appendingPathComponent("editor-return.png").path) {
                        self.captureReturn()
                    }
                    let typed = self.editor.string.filter { $0 == "x" }.count
                    try? String(typed).write(to: self.output.appendingPathComponent("fixture-typed.txt"),
                                             atomically: true, encoding: .utf8)
                }
                if FileManager.default.fileExists(atPath: self.output.appendingPathComponent("result.txt").path) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func processFullScreenCommand() {
        let file = output.appendingPathComponent("fullscreen-command.txt")
        guard let command = try? String(contentsOf: file, encoding: .utf8),
              command != lastFullScreenCommand else { return }
        lastFullScreenCommand = command
        if (command == "enter") != window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        writeFullScreenState("fullscreen")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        writeFullScreenState("windowed")
    }

    private func writeFullScreenState(_ state: String) {
        try? state.write(to: output.appendingPathComponent("fullscreen-state.txt"), atomically: true, encoding: .utf8)
    }

    private func captureReturn() {
        guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else { return }
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("editor-return.png"))
    }
}

@main
enum FocusFixture {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let fixture = Fixture()
        app.delegate = fixture
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(fixture) {}
    }
}
