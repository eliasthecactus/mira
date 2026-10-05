import Foundation
import CryptoKit
import AppKit

// Installs new releases straight from GitHub:
//   1. find the newest release (pre-releases only if this build is a pre-release)
//   2. download Mira-<version>.zip and SHA256SUMS.txt, check the hash
//   3. unpack, check bundle ID, version and code signature (same Team ID if signed)
//   4. swap the app bundle in place (the old one goes to the Trash) and relaunch
enum Updater {

    struct Release {
        let version: String
        let tag: String
        let zip: URL
        let checksums: URL
        let page: URL
        let notes: String
    }

    enum UpdateError: LocalizedError {
        case notAnAppInstall
        case notWritable(String)
        case missingAsset(String)
        case checksumMismatch
        case invalidBundle(String)

        var errorDescription: String? {
            switch self {
            case .notAnAppInstall:
                return "Updating needs the Mira app (this copy runs from a build folder). Download the latest release from GitHub instead."
            case .notWritable(let path):
                return "Can't replace \(path) (no write permission). Download the new version from GitHub and drag it into Applications."
            case .missingAsset(let name):
                return "The release has no \(name)."
            case .checksumMismatch:
                return "The download doesn't match the release's SHA-256 checksum, so it was not installed."
            case .invalidBundle(let why):
                return "The downloaded app failed verification (\(why)), so it was not installed."
            }
        }
    }

    static var currentApp: URL? {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return url.pathExtension == "app" ? url : nil
    }

    // MARK: - Check

    static func latest(includePrereleases: Bool? = nil, current: String = AppInfo.version) async throws -> Release? {
        let wantPre = includePrereleases ?? current.contains("-")
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases?per_page=20")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mira/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try pick(from: data, current: current, includePrereleases: wantPre)
    }

    // The newest installable release in a GitHub /releases response, if newer than `current`.
    static func pick(from data: Data, current: String, includePrereleases wantPre: Bool) throws -> Release? {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        let releases = list.compactMap { r -> Release? in
            guard r["draft"] as? Bool != true,
                  wantPre || r["prerelease"] as? Bool != true,
                  let tag = r["tag_name"] as? String,
                  let page = (r["html_url"] as? String).flatMap(URL.init(string:)),
                  let assets = r["assets"] as? [[String: Any]] else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            func asset(_ name: String) -> URL? {
                assets.first { $0["name"] as? String == name }
                    .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
            }
            guard let zip = asset("Mira-\(version).zip"), let sums = asset("SHA256SUMS.txt") else { return nil }
            return Release(version: version, tag: tag, zip: zip, checksums: sums, page: page,
                           notes: r["body"] as? String ?? "")
        }
        guard let newest = releases.max(by: { UpdateChecker.isNewer($1.version, than: $0.version) }),
              UpdateChecker.isNewer(newest.version, than: current) else { return nil }
        return newest
    }

    // MARK: - Install

    // Returns the path of the installed app.
    static func install(_ release: Release, progress: @escaping (String) -> Void = { _ in }) async throws -> URL {
        guard let app = currentApp else { throw UpdateError.notAnAppInstall }
        let parent = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: app.path) else {
            throw UpdateError.notWritable(app.path)
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mira-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress("Downloading Mira \(release.version)...")
        let zip = work.appendingPathComponent("Mira.zip")
        let (tmp, _) = try await URLSession.shared.download(from: release.zip)
        try FileManager.default.moveItem(at: tmp, to: zip)
        let (sumsData, _) = try await URLSession.shared.data(from: release.checksums)

        progress("Verifying...")
        let expected = String(decoding: sumsData, as: UTF8.self).components(separatedBy: "\n")
            .first { $0.hasSuffix("Mira-\(release.version).zip") }?
            .split(separator: " ").first.map(String.init)
        guard let expected else { throw UpdateError.missingAsset("checksum for Mira-\(release.version).zip") }
        guard try sha256(of: zip) == expected.lowercased() else { throw UpdateError.checksumMismatch }

        _ = Diagnostics.shell("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("Mira.app")
        try verify(newApp, expectedVersion: release.version, replacing: app)

        progress("Installing...")
        _ = Diagnostics.shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        // Move the old version to the Trash (recoverable), then put the new one in its place.
        var trashed: NSURL?
        try FileManager.default.trashItem(at: app, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: newApp, to: app)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: app) }   // roll back
            throw error
        }
        Log.info("Update", "Installed Mira \(release.version) at \(app.path)")
        return app
    }

    // Starts the given app once this process has exited.
    static func relaunch(_ app: URL) {
        let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"\(app.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
    }

    // MARK: - Verification

    static func verify(_ newApp: URL, expectedVersion: String, replacing current: URL?) throws {
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.invalidBundle("no Info.plist")
        }
        let ourID = Bundle.main.bundleIdentifier ?? "io.github.eliasthecactus.mira"
        guard info["CFBundleIdentifier"] as? String == ourID else {
            throw UpdateError.invalidBundle("bundle ID \(info["CFBundleIdentifier"] ?? "?")")
        }
        let version = (info["MiraVersion"] as? String) ?? (info["CFBundleShortVersionString"] as? String) ?? "?"
        guard version == expectedVersion else { throw UpdateError.invalidBundle("version \(version)") }

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["--verify", "--deep", "--strict", newApp.path]
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw UpdateError.invalidBundle("code signature") }

        // A Developer-ID-signed install only accepts updates from the same team.
        if let current, let team = teamID(current) {
            guard teamID(newApp) == team else { throw UpdateError.invalidBundle("signed by a different team") }
        }
    }

    static func teamID(_ app: URL) -> String? {
        let out = Diagnostics.shell("/usr/bin/codesign", ["-dv", app.path])
        let line = out.components(separatedBy: "\n").first { $0.hasPrefix("TeamIdentifier=") }
        let team = line.map { String($0.dropFirst("TeamIdentifier=".count)) }
        return team == "not set" ? nil : team
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
