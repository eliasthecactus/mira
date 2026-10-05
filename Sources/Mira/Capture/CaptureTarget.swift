import Foundation
import ScreenCaptureKit
import AppKit

// What gets shown on the TV.
enum CaptureTarget: Equatable, CustomStringConvertible {
    case screen                                   // the chosen display (or main)
    case app(bundleID: String, name: String)      // only this app's windows, everything else black
    case window(id: CGWindowID, title: String)    // one window, wherever it is, even if covered

    var description: String {
        switch self {
        case .screen: return "entire screen"
        case .app(_, let name): return "app '\(name)'"
        case .window(_, let title): return "window '\(title)'"
        }
    }
}

// Apps and windows that can be shared right now.
struct ShareableItems {
    struct App { let bundleID: String; let name: String; let windowCount: Int }
    struct Window { let id: CGWindowID; let title: String; let appName: String; let size: CGSize }

    var apps: [App] = []
    var windows: [Window] = []

    static func load() async throws -> ShareableItems {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { w in
            w.windowLayer == 0 && w.frame.width >= 120 && w.frame.height >= 80
                && w.owningApplication?.processID != me
                && !(w.title ?? "").isEmpty
        }
        var counts: [String: Int] = [:]
        for w in windows { if let b = w.owningApplication?.bundleIdentifier { counts[b, default: 0] += 1 } }
        let apps = content.applications
            .filter { counts[$0.bundleIdentifier] != nil && $0.processID != me }
            .map { App(bundleID: $0.bundleIdentifier, name: $0.applicationName, windowCount: counts[$0.bundleIdentifier] ?? 0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let wins = windows
            .map { Window(id: $0.windowID, title: $0.title ?? "", appName: $0.owningApplication?.applicationName ?? "?", size: $0.frame.size) }
            .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
        return ShareableItems(apps: Self.unique(apps), windows: wins)
    }

    // Running apps from NSWorkspace: needs no Screen Recording permission, so the Share
    // menu can offer "one app" even before the permission is granted.
    static func runningApps() -> [App] {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .compactMap { a -> App? in
                guard let id = a.bundleIdentifier else { return nil }
                return App(bundleID: id, name: a.localizedName ?? id, windowCount: 0)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return unique(apps)
    }

    private static func unique(_ apps: [App]) -> [App] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleID).inserted }
    }

    // Resolves a CLI argument: bundle ID, exact or partial app name.
    func app(matching query: String) -> App? {
        apps.first { $0.bundleID.caseInsensitiveCompare(query) == .orderedSame }
            ?? apps.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? apps.first { $0.name.localizedCaseInsensitiveContains(query) }
    }

    // Window by numeric ID or (partial) title.
    func window(matching query: String) -> Window? {
        if let id = CGWindowID(query) { return windows.first { $0.id == id } }
        return windows.first { $0.title.caseInsensitiveCompare(query) == .orderedSame }
            ?? windows.first { $0.title.localizedCaseInsensitiveContains(query) }
    }
}
