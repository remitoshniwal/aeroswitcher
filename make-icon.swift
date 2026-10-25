import AppKit

// Draws AeroSwitcher's app icon and packs it into AppIcon.icns.
//
//   swift make-icon.swift            (run in the repo folder, rewrites AppIcon.icns)
//
// build.sh does NOT run this, it only copies the finished AppIcon.icns into
// the app. So this script is only needed when you want to change the icon.
// Change the colors and sizes in the two blocks marked "CHANGE HERE", run it,
// and commit the new AppIcon.icns.
//
// The picture is the Cmd+Tab panel: three window cards in a row, the middle
// one "selected" (bigger, with a bright outline) like the highlighted card
// in the real switcher, on a rounded square like every Mac app icon.
//
// How it works: the picture is drawn once per size macOS asks for (16 up to
// 1024 pixels, drawn at each size so small ones stay sharp instead of being
// shrunk), saved into a temporary "AppIcon.iconset" folder, and Apple's own
// `iconutil` tool packs that folder into AppIcon.icns.

// CHANGE HERE: colors
let backgroundTop = NSColor(calibratedWhite: 0.27, alpha: 1)      // rounded square, top
let backgroundBottom = NSColor(calibratedWhite: 0.09, alpha: 1)   // rounded square, bottom
let cardColor = NSColor(calibratedWhite: 0.96, alpha: 1)          // window cards
let titleBarColor = NSColor(calibratedWhite: 0.80, alpha: 1)      // title strip and grey lines on the cards
let accentColor = NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.00, alpha: 1)  // outline of the selected card (soft light blue)

// CHANGE HERE: where the cards sit and how big they are (all on a 1024 x 1024 canvas)
let sideCardOffset: CGFloat = 275          // how far the two small cards are from the middle
let sideCardSize = NSSize(width: 170, height: 134)
let middleCardSize = NSSize(width: 306, height: 236)

// Draws the whole icon on a 1024 x 1024 canvas, scaled to `pixels`.
func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let canvas: CGFloat = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let scale = CGFloat(pixels) / canvas
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    // The rounded square: 824 points inside the 1024 canvas (Apple's icon
    // grid leaves the rest for the shadow).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Soft shadow under the whole icon.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    shadow.set()
    backgroundBottom.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient, light at the top.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(starting: backgroundTop, ending: backgroundBottom)!.draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // One window card: a rounded rectangle with a title bar strip and a few
    // grey lines standing in for content.
    func drawCard(centerX: CGFloat, size: NSSize, alpha: CGFloat, selected: Bool) {
        let rect = NSRect(x: centerX - size.width / 2, y: canvas / 2 - size.height / 2,
                          width: size.width, height: size.height)
        let radius = size.width * 0.07
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let cardShadow = NSShadow()
        cardShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: selected ? 0.40 : 0.22)
        cardShadow.shadowOffset = NSSize(width: 0, height: -8)
        cardShadow.shadowBlurRadius = selected ? 22 : 12
        cardShadow.set()
        cardColor.withAlphaComponent(alpha).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let barHeight = size.height * 0.17
        titleBarColor.withAlphaComponent(alpha).setFill()
        NSRect(x: rect.minX, y: rect.maxY - barHeight, width: size.width, height: barHeight).fill()
        titleBarColor.withAlphaComponent(alpha * 0.9).setFill()
        let lineHeight = size.height * 0.075
        var y = rect.maxY - barHeight - size.height * 0.16
        for fraction in [0.78, 0.60, 0.70] as [CGFloat] {
            let line = NSRect(x: rect.minX + size.width * 0.09, y: y - lineHeight,
                              width: size.width * 0.82 * fraction, height: lineHeight)
            NSBezierPath(roundedRect: line, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
            y -= size.height * 0.17
        }
        NSGraphicsContext.restoreGraphicsState()

        if selected {
            // The outline sits just outside the card, like the selection in the panel.
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -14, dy: -14),
                                       xRadius: radius + 14, yRadius: radius + 14)
            outline.lineWidth = 15
            accentColor.setStroke()
            outline.stroke()
        }
    }

    drawCard(centerX: 512 - sideCardOffset, size: sideCardSize, alpha: 0.55, selected: false)
    drawCard(centerX: 512 + sideCardOffset, size: sideCardSize, alpha: 0.55, selected: false)
    drawCard(centerX: 512, size: middleCardSize, alpha: 1.0, selected: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The file names and pixel sizes macOS expects inside an .iconset folder.
let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let folder = FileManager.default.currentDirectoryPath
let iconset = URL(fileURLWithPath: folder).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for file in iconFiles {
    let png = renderIcon(pixels: file.pixels).representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent(file.name))
}

let packer = Process()
packer.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
packer.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: folder).appendingPathComponent("AppIcon.icns").path]
try! packer.run()
packer.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(packer.terminationStatus == 0 ? "Wrote AppIcon.icns" : "iconutil failed")
