import AppKit
import CoreGraphics
import RestABitCore

extension ExcludedApp {
    @MainActor
    var applicationIcon: NSImage? {
        let remembered = bundlePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { url in
                Bundle(url: url)?.bundleIdentifier?.caseInsensitiveCompare(id) == .orderedSame ? url : nil
            }
        guard let url = remembered ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct ForegroundIdentity {
    let identifiers: Set<String>
    let applicationPaths: Set<String>

    init(bundleIdentifier: String?, locations: [URL]) {
        var identifiers = Set([bundleIdentifier].compactMap { $0?.lowercased() })
        var paths: Set<String> = []
        for location in locations {
            var ancestor = location.resolvingSymlinksInPath().standardizedFileURL
            while ancestor.path != "/" {
                if ancestor.pathExtension.lowercased() == "app", paths.insert(ancestor.path).inserted,
                   let identifier = Bundle(url: ancestor)?.bundleIdentifier {
                    identifiers.insert(identifier.lowercased())
                }
                let parent = ancestor.deletingLastPathComponent()
                guard parent.path != ancestor.path else { break }
                ancestor = parent
            }
        }
        self.identifiers = identifiers
        applicationPaths = paths
    }

    func matches(_ exclusion: ExcludedApp) -> Bool {
        identifiers.contains(exclusion.id.lowercased()) ||
            exclusion.bundlePath.map { applicationPaths.contains($0) } == true
    }
}

@MainActor
final class ForegroundProtection {
    enum Reason { case excluded, fullScreen }

    private struct Process {
        let pid: pid_t
        let launchedAt: Date?
    }

    private var identityCache: (process: Process, identity: ForegroundIdentity)?
    private var fullScreenCache: (process: Process, checkedAt: TimeInterval, result: Bool)?

    func reason(for app: NSRunningApplication?, exclusions: [ExcludedApp], pauseForFullScreen: Bool,
                now: TimeInterval, refresh: Bool = false) -> Reason? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        if isExcluded(app, exclusions: exclusions) { return .excluded }
        guard pauseForFullScreen else { return nil }
        return isFullScreen(app, now: now, refresh: refresh) ? .fullScreen : nil
    }

    func isExcluded(_ app: NSRunningApplication?, exclusions: [ExcludedApp]) -> Bool {
        guard let app, !exclusions.isEmpty else { return false }
        if let identifier = app.bundleIdentifier,
           exclusions.contains(where: { $0.id.caseInsensitiveCompare(identifier) == .orderedSame }) {
            return true
        }
        let process = Process(pid: app.processIdentifier, launchedAt: app.launchDate)
        if let cached = identityCache, sameProcess(cached.process, process) {
            return exclusions.contains(where: cached.identity.matches)
        }
        let identity = ForegroundIdentity(bundleIdentifier: app.bundleIdentifier,
                                          locations: [app.bundleURL, app.executableURL].compactMap { $0 })
        identityCache = (process, identity)
        return exclusions.contains(where: identity.matches)
    }

    func invalidateFullScreen() { fullScreenCache = nil }

    private func isFullScreen(_ app: NSRunningApplication, now: TimeInterval, refresh: Bool) -> Bool {
        let process = Process(pid: app.processIdentifier, launchedAt: app.launchDate)
        if !refresh, let cached = fullScreenCache, sameProcess(cached.process, process),
           now - cached.checkedAt < 2 {
            return cached.result
        }

        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
        let result = windows.contains { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.pid,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  (0...floatingLayer).contains(layer),
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let window = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return displays.contains { FullScreenWindow.matchesDisplay(window, display: $0) }
        }
        fullScreenCache = (process, now, result)
        return result
    }

    private func sameProcess(_ first: Process, _ second: Process) -> Bool {
        first.pid == second.pid && first.launchedAt == second.launchedAt
    }
}
