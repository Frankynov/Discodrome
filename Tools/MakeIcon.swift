// Renders Discodrome's app icon into an .iconset:
//   swift Tools/MakeIcon.swift Resources/AppIcon.iconset
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// A graphite rounded square on the standard macOS icon grid, holding a disc: dark grooves, a
// light sheen that follows the grooves, and a warm label — the disc a player turns.
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [r, g, b, a])!
}

func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high

    // Body on the 824 pt macOS grid, with its drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0, 0, 0, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0.12, 0.12, 0.14))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0.25, 0.26, 0.30), color(0.09, 0.09, 0.11)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 318

    // Disc shadow and base.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.55))
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.setFillColor(color(0.05, 0.05, 0.06))
    context.fillPath()
    context.restoreGState()

    let discRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.saveGState()
    context.addEllipse(in: discRect)
    context.clip()
    let base = CGGradient(colorsSpace: space, colors: [color(0.14, 0.14, 0.16), color(0.03, 0.03, 0.04)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(base, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])

    // Grooves.
    context.setLineWidth(2)
    var r: CGFloat = 132
    while r < radius - 8 {
        context.setStrokeColor(color(1, 1, 1, r.truncatingRemainder(dividingBy: 28) < 14 ? 0.05 : 0.025))
        context.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        r += 7
    }

    // Two sheens along the grooves, opposite each other.
    for start in [CGFloat.pi * 0.20, CGFloat.pi * 1.20] {
        let wedge = CGMutablePath()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: radius, startAngle: start, endAngle: start + .pi * 0.28, clockwise: false)
        wedge.closeSubpath()
        context.saveGState()
        context.addPath(wedge)
        context.clip()
        let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.0), color(1, 1, 1, 0.16), color(1, 1, 1, 0.0)] as CFArray, locations: [0, 0.5, 1])!
        let a = CGPoint(x: center.x + cos(start) * radius, y: center.y + sin(start) * radius)
        let b = CGPoint(x: center.x + cos(start + .pi * 0.28) * radius, y: center.y + sin(start + .pi * 0.28) * radius)
        context.drawLinearGradient(sheen, start: a, end: b, options: [])
        context.restoreGState()
    }
    context.restoreGState()

    // Rim.
    context.setStrokeColor(color(1, 1, 1, 0.14))
    context.setLineWidth(3)
    context.strokeEllipse(in: discRect.insetBy(dx: 1.5, dy: 1.5))

    // Label.
    let labelRadius: CGFloat = 112
    let labelRect = CGRect(x: center.x - labelRadius, y: center.y - labelRadius, width: labelRadius * 2, height: labelRadius * 2)
    context.saveGState()
    context.addEllipse(in: labelRect)
    context.clip()
    let label = CGGradient(colorsSpace: space, colors: [color(1.0, 0.56, 0.28), color(0.93, 0.25, 0.33)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(label, start: CGPoint(x: labelRect.minX, y: labelRect.maxY), end: CGPoint(x: labelRect.maxX, y: labelRect.minY), options: [])
    context.setStrokeColor(color(1, 1, 1, 0.22))
    context.setLineWidth(2)
    context.strokeEllipse(in: labelRect.insetBy(dx: 26, dy: 26))
    context.restoreGState()

    // Spindle hole.
    let hole: CGFloat = 20
    context.setFillColor(color(0.09, 0.09, 0.11))
    context.fillEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
    context.setStrokeColor(color(0, 0, 0, 0.35))
    context.setLineWidth(3)
    context.strokeEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))

    context.restoreGState()

    // Edge highlight on the body.
    context.addPath(shape)
    context.setStrokeColor(color(1, 1, 1, 0.10))
    context.setLineWidth(2)
    context.strokePath()

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels: pixels).write(to: output.appending(path: "\(name).png"))
}
print("wrote \(sizes.count) images to \(output.path)")
