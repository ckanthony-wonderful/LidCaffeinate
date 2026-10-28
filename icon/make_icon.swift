// LidCaffeinate app icon in Apple's style: one white SF Symbols glyph (cup on battery)
// on a smooth single-hue gradient tile. Draws a 1024 master, writes AppIcon.iconset + AppIcon-1024.png.
// Usage: swift icon/make_icon.swift <out_dir> && iconutil -c icns <out_dir>/AppIcon.iconset -o <out_dir>/AppIcon.icns
import AppKit

let S: CGFloat = 1024
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func grad(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = ns

// tile on Apple's icon grid
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: col(0x000000, 0.30))
ctx.addPath(tile); ctx.setFillColor(col(0xF2771F)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState(); ctx.addPath(tile); ctx.clip()
ctx.drawLinearGradient(grad([(col(0xFFB443), 0), (col(0xFF8A1F), 0.55), (col(0xEE5E12), 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// faint top sheen, like Apple's system icons
ctx.drawLinearGradient(grad([(col(0xFFFFFF, 0.16), 0), (col(0xFFFFFF, 0), 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, colors: [NSColor]) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: colors))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}
func draw(_ img: NSImage, centerX: CGFloat, bottom: CGFloat) -> CGRect {
    let r = CGRect(x: centerX - img.size.width / 2, y: bottom, width: img.size.width, height: img.size.height)
    img.draw(in: r)
    return r
}

// soft glyph shadow, then white glyphs: steaming cup sitting on a battery
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: col(0x8A2E00, 0.35))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
let battery = symbol("battery.75percent", pointSize: 300, weight: .semibold, colors: [.white, .white])
let cup = symbol("cup.and.heat.waves.fill", pointSize: 330, weight: .semibold, colors: [.white, .white])
// cup sits right on the battery; the pair is centred on the tile
let gapOverlap: CGFloat = 44                          // symbol images carry padding
let groupH = battery.size.height + cup.size.height - gapOverlap
let bottom0 = 512 - groupH / 2 - 8                     // a touch low reads as optically centred
let bRect = draw(battery, centerX: 512, bottom: bottom0)
_ = draw(cup, centerX: 500, bottom: bRect.maxY - gapOverlap)
ctx.endTransparencyLayer()
ctx.restoreGState()

NSGraphicsContext.current = nil
let master = ctx.makeImage()!

func png(_ px: Int, _ path: String) {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let set = "\(out)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (pt, sc) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    png(pt * sc, "\(set)/icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png")
}
png(1024, "\(out)/AppIcon-1024.png")
print("wrote \(set)")
