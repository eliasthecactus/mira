import Foundation

enum AppInfo {
    static let repository = "eliasthecactus/mira"
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!

    // From the app bundle's Info.plist, or the one embedded in the bare executable.
    // MiraVersion carries pre-release suffixes (e.g. 0.2.0-beta.1) that
    // CFBundleShortVersionString can't.
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "MiraVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    // The Mira.app this process runs from, also when started through a symlink such as
    // /usr/local/bin/mira -> /Applications/Mira.app/Contents/MacOS/Mira (then
    // Bundle.main points at /usr/local/bin, not at the app).
    static var appBundleURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleURL.resolvingSymlinksInPath() }
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        return containingApp(ofExecutable: exe)
    }

    // .../X.app/Contents/MacOS/<exe> -> .../X.app
    static func containingApp(ofExecutable exe: URL) -> URL? {
        let macOS = exe.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    static var isAppBundle: Bool { appBundleURL != nil }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
