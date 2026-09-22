import AppKit
import Foundation

// Brand-first social image. It deliberately does not imitate an in-app screen.
// Usage: swift build_launch_card.swift /path/to/logo.png /path/to/output.png
guard CommandLine.arguments.count == 3 else {
    fputs("usage: swift build_launch_card.swift logo.png output.png\n", stderr)
    exit(2)
}

let width = 1080
let height = 1350
let logoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let logo = NSImage(contentsOf: logoURL),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("could not create launch card canvas\n", stderr)
    exit(1)
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func draw(_ value: String, rect: NSRect, font: NSFont, ink: NSColor, lineSpacing: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = lineSpacing
    (value as NSString).draw(in: rect, withAttributes: [
        .font: font,
        .foregroundColor: ink,
        .paragraphStyle: paragraph,
    ])
}

func font(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

color(0xfff4e9).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let shadow = NSShadow()
shadow.shadowColor = color(0x704322).withAlphaComponent(0.10)
shadow.shadowBlurRadius = 46
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
rounded(NSRect(x: 52, y: 50, width: 976, height: 1250), radius: 58, fill: .white)
NSShadow().set()

logo.draw(in: NSRect(x: 112, y: 1098, width: 110, height: 110))
draw("Nomva", rect: NSRect(x: 248, y: 1117, width: 720, height: 80),
     font: font("AvenirNext-Bold", size: 60, weight: .bold), ink: color(0x1d160f))

rounded(NSRect(x: 112, y: 1005, width: 500, height: 60), radius: 30, fill: color(0xffead5))
draw("FOOD TRACKING FOR IPHONE", rect: NSRect(x: 141, y: 1017, width: 450, height: 40),
     font: font("AvenirNext-DemiBold", size: 24, weight: .semibold), ink: color(0x9c4f13))

draw("Log meals in\nyour own words.", rect: NSRect(x: 112, y: 760, width: 840, height: 250),
     font: font("AvenirNext-Bold", size: 84, weight: .bold), ink: color(0x1d160f), lineSpacing: -4)
draw("Review the estimate. Correct a portion.\nSee your daily calories and macros.",
     rect: NSRect(x: 116, y: 606, width: 840, height: 130),
     font: font("AvenirNext-Regular", size: 36, weight: .regular), ink: color(0x675a4d), lineSpacing: 2)

let features = [
    ("Type or photograph a meal with Pro AI", 476.0),
    ("Review and correct nutrition estimates", 376.0),
    ("Search or scan foods for free", 276.0),
]
for (label, y) in features {
    rounded(NSRect(x: 112, y: y, width: 856, height: 79), radius: 25, fill: color(0xfff7ef))
    rounded(NSRect(x: 137, y: y + 21, width: 38, height: 38), radius: 19, fill: color(0xf18b2f))
    draw("✓", rect: NSRect(x: 145, y: y + 25, width: 32, height: 30),
         font: NSFont.systemFont(ofSize: 24, weight: .bold), ink: .white)
    draw(label, rect: NSRect(x: 195, y: y + 18, width: 740, height: 47),
         font: font("AvenirNext-DemiBold", size: 31, weight: .semibold), ink: color(0x2c241c))
}

rounded(NSRect(x: 112, y: 124, width: 856, height: 105), radius: 31, fill: color(0xe68023))
draw("Free to download  ·  Nomva Pro for AI", rect: NSRect(x: 147, y: 154, width: 795, height: 53),
     font: font("AvenirNext-Bold", size: 32, weight: .bold), ink: .white)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode launch card\n", stderr)
    exit(1)
}
try data.write(to: outputURL, options: .atomic)
print(outputURL.path)
