import AppKit
import CoreText

// Draws the 1024px app icon PNG (a serif "O." on warm paper) to the path given as the first argument.
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let cg = context.cgContext

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Paper tile with a soft drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
color(0xF6F1E7).setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0xFBF8F1), ending: color(0xEFE7D7))!.draw(in: path, angle: -90)
NSColor(white: 0, alpha: 0.07).setStroke()
path.lineWidth = 3
path.stroke()

// Serif "O" in ink, centred on its glyph bounds, with a red full stop.
let base = NSFont.systemFont(ofSize: 640, weight: .regular)
let font = NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: 640)!
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(0x24211D)]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "O", attributes: attrs))
let ink = CTLineGetImageBounds(line, cg)
let dotR: CGFloat = 38, gap: CGFloat = 22
let totalWidth = ink.width + gap + dotR * 2
let originX = (CGFloat(px) - totalWidth) / 2 - ink.minX
let originY = (CGFloat(px) - ink.height) / 2 - ink.minY + 8
cg.textPosition = CGPoint(x: originX, y: originY)
CTLineDraw(line, cg)

let dotX = originX + ink.maxX + gap
let dotY = originY + ink.minY
color(0x2F6BD8).setFill()
NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotR * 2, height: dotR * 2)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
