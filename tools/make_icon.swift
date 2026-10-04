// Renders Mira's app icon. Usage: swift tools/make_icon.swift Support/AppIcon.icns
import AppKit
import CoreGraphics

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824×824 rounded square centred in 1024, radius ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.18, green: 0.42, blue: 0.98, alpha: 1),
        CGColor(red: 0.47, green: 0.25, blue: 0.93, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    ctx.restoreGState()

    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // TV / display
    let screen = CGRect(x: 232, y: 330, width: 560, height: 360)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.setStrokeColor(white)
    ctx.setLineWidth(44)
    ctx.strokePath()
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: 432, y: 250, width: 160, height: 36))     // stand
    ctx.fill(CGRect(x: 492, y: 270, width: 40, height: 60))

    // Wireless waves rising from the bottom-centre inside the screen
    ctx.setLineCap(.round)
    let centre = CGPoint(x: 512, y: 400)
    for (i, r) in [70.0, 140.0, 210.0].enumerated() {
        ctx.setLineWidth(38)
        ctx.setAlpha(1 - CGFloat(i) * 0.18)
        ctx.addArc(center: centre, radius: r, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }
    ctx.setAlpha(1)
    ctx.fillEllipse(in: CGRect(x: centre.x - 26, y: centre.y - 26, width: 52, height: 52))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Mira-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
try render(size: 512).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
exit(p.terminationStatus)
