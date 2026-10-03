// Draws SiliconWin's app icon (a chip with a four-pane window) and writes
// AppIcon.icns.   swift Scripts/make-icon.swift <output.icns>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.setShouldAntialias(true)

    // Tile with drop shadow (macOS icon grid: 824 pt body on a 1024 canvas).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = roundedRect(body, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.32))
    ctx.addPath(tile)
    ctx.setFillColor(color(0.05, 0.25, 0.55))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let background = CGGradient(colorsSpace: colorSpace,
                                colors: [color(0.10, 0.60, 0.98), color(0.02, 0.27, 0.66)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: colorSpace,
                          colors: [color(1, 1, 1, 0.28), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 360, y: 860), endRadius: 620, options: [])
    ctx.restoreGState()

    // Chip with pins.
    let chip = CGRect(x: 287, y: 287, width: 450, height: 450)
    ctx.setFillColor(color(0.86, 0.92, 1.0, 0.92))
    let pinCount = 6
    let pinLength: CGFloat = 46, pinWidth: CGFloat = 24
    let spacing = (chip.width - 90) / CGFloat(pinCount - 1)
    for index in 0..<pinCount {
        let offset = chip.minX + 45 + CGFloat(index) * spacing - pinWidth / 2
        for rect in [CGRect(x: offset, y: chip.maxY - 6, width: pinWidth, height: pinLength),
                     CGRect(x: offset, y: chip.minY - pinLength + 6, width: pinWidth, height: pinLength),
                     CGRect(x: chip.minX - pinLength + 6, y: offset, width: pinLength, height: pinWidth),
                     CGRect(x: chip.maxX - 6, y: offset, width: pinLength, height: pinWidth)] {
            ctx.addPath(roundedRect(rect, 9))
            ctx.fillPath()
        }
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 0.05, 0.2, 0.45))
    ctx.addPath(roundedRect(chip, 70))
    ctx.setFillColor(color(0.09, 0.12, 0.20))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(chip.insetBy(dx: 10, dy: 10), 60))
    ctx.setStrokeColor(color(1, 1, 1, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Four window panes.
    let gap: CGFloat = 22
    let pane: CGFloat = 118
    let originX = chip.midX - pane - gap / 2
    let originY = chip.midY - pane - gap / 2
    let paneColors = [color(0.35, 0.80, 1.0), color(0.55, 0.88, 1.0), color(0.25, 0.70, 1.0), color(0.45, 0.84, 1.0)]
    for index in 0..<4 {
        let x = originX + CGFloat(index % 2) * (pane + gap)
        let y = originY + CGFloat(index / 2) * (pane + gap)
        ctx.addPath(roundedRect(CGRect(x: x, y: y, width: pane, height: pane), 18))
        ctx.setFillColor(paneColors[index])
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(pixels: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    writePNG(drawIcon(pixels: size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
