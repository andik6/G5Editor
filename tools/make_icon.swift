// Renders the app icon: gold script "G5" on black tolex with gold piping (amp-head style).
// Usage: swift tools/make_icon.swift <out.png>   (1024×1024)
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let goldLight = rgb(255, 236, 170), gold = rgb(222, 178, 82), goldDark = rgb(140, 98, 30)

// macOS icon grid: 824×824 body centred, corner radius ≈ 185.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the body.
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.45); sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -12)
sh.set(); rgb(12, 12, 12).setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Black tolex: dark gradient plus a fine pebble texture.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [rgb(38, 36, 34), rgb(14, 13, 12)])!.draw(in: body, angle: -90)
var seed: UInt64 = 0x5EED
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<26000 {
    let x = body.minX + rnd() * body.width, y = body.minY + rnd() * body.height, r = 1.2 + rnd() * 2.6
    (rnd() > 0.5 ? NSColor.white.withAlphaComponent(0.035) : NSColor.black.withAlphaComponent(0.22)).setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
}
// Soft top highlight.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Gold piping around the panel.
func piping(_ inset: CGFloat, _ width: CGFloat) {
    let r = body.insetBy(dx: inset, dy: inset)
    let p = NSBezierPath(roundedRect: r, xRadius: 185 - inset * 0.85, yRadius: 185 - inset * 0.85)
    p.lineWidth = width
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(0.7); s.shadowBlurRadius = 6; s.shadowOffset = NSSize(width: 0, height: -3); s.set()
    goldDark.setStroke(); p.stroke()
    NSGraphicsContext.restoreGraphicsState()
    p.lineWidth = width * 0.55; gold.setStroke(); p.stroke()
    p.lineWidth = width * 0.18; goldLight.withAlphaComponent(0.8).setStroke(); p.stroke()
}
piping(46, 16)

// Script "G5" in gold with an engraved look.
let font = NSFont(name: "SnellRoundhand-Black", size: 470) ?? NSFont.boldSystemFont(ofSize: 420)
let text = NSAttributedString(string: "G5", attributes: [.font: font])
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let origin = CGPoint(x: body.midX - bounds.width / 2 - bounds.minX, y: body.midY - bounds.height / 2 - bounds.minY + 8)

// Glyph outlines as one path.
let path = CGMutablePath()
for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
    let n = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
    CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
    let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
    for i in 0..<n {
        if let g = CTFontCreatePathForGlyph(f, glyphs[i], nil) {
            path.addPath(g, transform: CGAffineTransform(translationX: origin.x + pos[i].x, y: origin.y + pos[i].y))
        }
    }
}
// Shadow beneath the lettering.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: NSColor.black.withAlphaComponent(0.85).cgColor)
ctx.addPath(path); ctx.setFillColor(goldDark.cgColor); ctx.fillPath()
ctx.restoreGState()
// Gold gradient fill.
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [goldLight.cgColor, gold.cgColor, goldDark.cgColor, gold.cgColor, goldLight.cgColor] as CFArray,
                      locations: [0, 0.35, 0.55, 0.8, 1])!
let tb = path.boundingBox
ctx.drawLinearGradient(grad, start: CGPoint(x: tb.minX, y: tb.maxY), end: CGPoint(x: tb.minX + tb.width * 0.3, y: tb.minY), options: [])
ctx.restoreGState()
// Thin bright edge.
ctx.addPath(path); ctx.setStrokeColor(goldLight.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(2.5); ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
