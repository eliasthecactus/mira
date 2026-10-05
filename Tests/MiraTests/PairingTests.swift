import XCTest
import CoreImage
import Vision
@testable import Mira

final class CastPairingTests: XCTestCase {
    func testParsesCodesAndLinks() {
        XCTAssertEqual(CastPairing.parse(" 7F6GY "), .code("7F6GY"))
        XCTAssertEqual(CastPairing.parse("7F6-GY"), .code("7F6GY"))
        XCTAssertEqual(CastPairing.parse("http://172.20.0.8/pair?pairCode=7F6GY"),
                       .link(URL(string: "http://172.20.0.8/pair?pairCode=7F6GY")!))
        // QR codes and copy-paste sometimes drop the scheme.
        XCTAssertEqual(CastPairing.parse("172.20.0.8/pair?pairCode=7F6GY"),
                       .link(URL(string: "http://172.20.0.8/pair?pairCode=7F6GY")!))
        XCTAssertNil(CastPairing.parse(""))
        XCTAssertNil(CastPairing.parse("ab"))
        XCTAssertNil(CastPairing.parse("what is this?"))
        XCTAssertNil(CastPairing.parse("ftp://x/y"))
    }

    func testGatewayDetection() {
        let hotel = MiracastDevice(name: "Chromecast", ipAddress: "172.20.0.8", port: 55555, kind: .googleCast)
        let home = MiracastDevice(name: "Living Room", ipAddress: "192.168.1.5", kind: .googleCast)
        XCTAssertTrue(CastPairing.isBehindGateway(hotel))
        XCTAssertFalse(CastPairing.isBehindGateway(home))
        XCTAssertFalse(CastPairing.isBehindGateway(MiracastDevice(name: "x", ipAddress: "1.2.3.4", port: 7250)))
        XCTAssertTrue(MiraError.castGatewayNeedsPairing(hotel).localizedDescription.contains("Pair this Mac"))
    }

    func testRedactsCodesInLogs() {
        let s = CastPairing.redacted(URL(string: "http://172.20.0.8/pair?pairCode=7F6GY")!)
        XCTAssertFalse(s.contains("7F6GY"))
        XCTAssertTrue(s.contains("pairCode"))
    }

    func testFindsPairingForm() throws {
        let html = """
        <html><body><h1>Welcome</h1>
        <form method="post" action="/activate"><input type="hidden" name="room" value="412">
        <label>Code <input name="accessCode" autocomplete="off"></label>
        <input type="submit" name="go" value="Connect"></form>
        <form action="search"><input type="text" name="q"></form>
        </body></html>
        """
        let forms = HTMLForm.parse(html, base: URL(string: "http://172.20.0.8/")!)
        XCTAssertEqual(forms.count, 2)
        let f = forms[0]
        XCTAssertEqual(f.method, "POST")
        XCTAssertEqual(f.action.absoluteString, "http://172.20.0.8/activate")
        XCTAssertEqual(f.codeField, "accessCode")
        XCTAssertEqual(f.hidden.map(\.0), ["room"])
        XCTAssertEqual(f.hidden.map(\.1), ["412"])
        XCTAssertEqual(f.submitValues.map(\.0), ["go"])
        XCTAssertFalse(f.needsPerson)
        XCTAssertEqual(forms[1].method, "GET")
        XCTAssertEqual(forms[1].codeField, "q", "a lone text field is the code field")
    }

    func testFormsThatNeedAPersonAreLeftAlone() {
        let html = """
        <form method='POST' action='/pair'><input type='hidden' name='pairCode' value='7F6GY'>
        <input type=checkbox name=terms> I accept <button>Pair</button></form>
        """
        let f = HTMLForm.parse(html, base: URL(string: "http://h/")!)
        XCTAssertEqual(f.count, 1)
        XCTAssertTrue(f[0].needsPerson)
        XCTAssertEqual(f[0].hidden.first?.1, "7F6GY")
    }
}

final class AirPlayDiscoveryTests: XCTestCase {
    func testOnlyScreensAreListed() {
        XCTAssertTrue(DeviceBrowser.isAirPlayDisplay(model: "AppleTV6,2", features: "0x5A7FFFF7,0x1E"))
        XCTAssertTrue(DeviceBrowser.isAirPlayDisplay(model: "QN65Q80T", features: "0x7F8AD0,0x38BCB46"))
        XCTAssertFalse(DeviceBrowser.isAirPlayDisplay(model: "MacBookPro18,1", features: "0x5A7FFFF7,0x1E"))
        XCTAssertFalse(DeviceBrowser.isAirPlayDisplay(model: "iPhone15,2", features: nil))
        XCTAssertFalse(DeviceBrowser.isAirPlayDisplay(model: "AudioAccessory5,1", features: "0x4A7FDFD5,0x3C155FDE"))
        // A speaker from another maker: no video, no screen mirroring.
        XCTAssertFalse(DeviceBrowser.isAirPlayDisplay(model: "Sonos One", features: "0x445F8A00,0x1C340"))
        XCTAssertTrue(MiraError.useAirPlay("Samsung TV").localizedDescription.contains("Screen Mirroring"))
    }
}

final class QRDecodingTests: XCTestCase {
    func testReadsAHotelPairingQRCode() throws {
        let link = "http://172.20.0.8/pair?pairCode=7F6GY"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        // Scale up and add a quiet zone, like a code on a TV screen.
        let code = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let canvas = CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -60, dy: -60))
        let image = code.composited(over: canvas)
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let text = QRScannerWindowController.detectQR(VNImageRequestHandler(cgImage: cg, options: [:]))
        XCTAssertEqual(text, link)
        XCTAssertEqual(CastPairing.parse(try XCTUnwrap(text)), .link(URL(string: link)!))
    }
}
