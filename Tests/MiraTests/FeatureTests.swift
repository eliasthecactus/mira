import XCTest
import VideoToolbox
@testable import Mira

final class EncoderProfileTests: XCTestCase {
    func testEncoderProfileMapping() {
        XCTAssertEqual(VideoEncoder.profileLevel(forLevelBit: 0x40) as String, kVTProfileLevel_H264_Baseline_5_1 as String)
        XCTAssertEqual(VideoEncoder.profileLevel(forLevelBit: 0x04) as String, kVTProfileLevel_H264_Baseline_4_0 as String)
        XCTAssertEqual(VideoEncoder.profileLevel(forLevelBit: 0x40, high: true) as String,
                       kVTProfileLevel_H264_ConstrainedHigh_AutoLevel as String)
    }

    func testCABACOnlyForRestrictedHigh2() {
        // WFD Table 6: CABAC is not allowed in CBP or Constrained High (RHP).
        var c = VideoEncoder.Config()
        c.h264Profile = .constrainedBaseline
        XCTAssertFalse(c.cabac)
        c.h264Profile = .constrainedHigh
        XCTAssertFalse(c.cabac)
        c.h264Profile = .restrictedHigh2
        XCTAssertTrue(c.cabac)
    }
}

final class UpdaterTests: XCTestCase {
    func releases(_ items: [(String, Bool, Bool)]) -> Data {
        let list = items.map { tag, pre, draft -> [String: Any] in
            let v = String(tag.dropFirst())
            return ["tag_name": tag, "prerelease": pre, "draft": draft,
                    "html_url": "https://github.com/x/y/releases/tag/\(tag)", "body": "notes",
                    "assets": [["name": "Mira-\(v).zip", "browser_download_url": "https://e/Mira-\(v).zip"],
                               ["name": "SHA256SUMS.txt", "browser_download_url": "https://e/\(v)/SHA256SUMS.txt"]]]
        }
        return try! JSONSerialization.data(withJSONObject: list)
    }

    func testPicksNewestEligibleRelease() throws {
        let data = releases([("v0.2.0-beta.2", true, false), ("v0.3.0-beta.1", true, true), ("v0.2.0-beta.3", true, false)])
        let r = try Updater.pick(from: data, current: "0.2.0-beta.2", includePrereleases: true)
        XCTAssertEqual(r?.version, "0.2.0-beta.3", "drafts are skipped")
        XCTAssertEqual(r?.zip.lastPathComponent, "Mira-0.2.0-beta.3.zip")
        XCTAssertNil(try Updater.pick(from: data, current: "0.2.0-beta.3", includePrereleases: true))
        XCTAssertNil(try Updater.pick(from: data, current: "0.1.0", includePrereleases: false), "stable users skip betas")
    }

    func testVerifyRejectsForeignBundles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Mira.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: NSDictionary = ["CFBundleIdentifier": "com.evil.app", "MiraVersion": "9.9.9", "CFBundleExecutable": "Mira"]
        plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        XCTAssertThrowsError(try Updater.verify(app, expectedVersion: "9.9.9", replacing: nil))
    }

    func testSHA256() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertEqual(try Updater.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class SharingAndPrivacyTests: XCTestCase {
    func testMatching() {
        let items = ShareableItems(
            apps: [.init(bundleID: "com.apple.Keynote", name: "Keynote", windowCount: 1),
                   .init(bundleID: "com.apple.Safari", name: "Safari", windowCount: 3)],
            windows: [.init(id: 42, title: "Quarterly Review.key", appName: "Keynote", size: .init(width: 800, height: 600))])
        XCTAssertEqual(items.app(matching: "keynote")?.bundleID, "com.apple.Keynote")
        XCTAssertEqual(items.app(matching: "com.apple.Safari")?.name, "Safari")
        XCTAssertEqual(items.app(matching: "Saf")?.name, "Safari")
        XCTAssertEqual(items.window(matching: "42")?.title, "Quarterly Review.key")
        XCTAssertEqual(items.window(matching: "quarterly")?.id, 42)
        XCTAssertNil(items.window(matching: "nope"))
        XCTAssertEqual(CaptureTarget.app(bundleID: "x", name: "Keynote").description, "app 'Keynote'")
    }

    func testBlackFrameIsOpaqueBlack() throws {
        let r = WFDResolution.cea(width: 1280, height: 720, fps: 30)!
        let pb = try XCTUnwrap(MediaPipeline.blackFrame(r))
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 1280)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let px = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual([px[0], px[1], px[2], px[3]], [0, 0, 0, 255], "BGRA black, opaque")
    }
}
