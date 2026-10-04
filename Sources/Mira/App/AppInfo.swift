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

    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
