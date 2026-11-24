import AppKit

/// Draws the menu bar item: "80%" + a battery. Everything else lives inside the battery:
///   fill colour = power mode  (plain: automatic, yellow: low power, orange: high power, red: nearly empty)
///   glyph       = what it's doing (bolt: charging, plug: plugged in but not charging,
///                 leaf / flame: low / high power while on battery)
/// The plain state is a template image so macOS tints it for light and dark menu bars.
enum StatusIcon {
    static func make(percent: Int, charging: Bool, pluggedIn: Bool, mode: Int, showPercent: Bool = true) -> NSImage {
        let pct = max(0, min(100, percent))
        let lowBattery = pct <= 10 && !pluggedIn
        let fillColor: NSColor? = mode == 1 ? .systemYellow : (mode == 2 ? .systemOrange : (lowBattery ? .systemRed : nil))
        let template = fillColor == nil

        let glyphName: String? =
            charging ? "bolt.fill" :
            pluggedIn ? "powerplug.fill" :
            mode == 1 ? "leaf.fill" :
            mode == 2 ? "flame.fill" : nil

        let text = "\(pct)%" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let h: CGFloat = 18
        let bodyW: CGFloat = 27, bodyH: CGFloat = 12.5, capW: CGFloat = 2, capH: CGFloat = 4.5
        let textSize = showPercent ? text.size(withAttributes: [.font: font]) : .zero
        let gapW: CGFloat = showPercent ? 4 : 0
        let width = ceil(textSize.width + gapW + bodyW + capW + 1)

        let img = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            let ink = template ? NSColor.black : NSColor.labelColor
            var x: CGFloat = 0

            if showPercent {
                text.draw(at: NSPoint(x: x, y: (h - textSize.height) / 2),
                          withAttributes: [.font: font, .foregroundColor: ink])
            }
            x += textSize.width + gapW

            // Outline and cap, dimmed like the system icon.
            let body = NSRect(x: x + 0.5, y: (h - bodyH) / 2, width: bodyW - 1, height: bodyH)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.8, yRadius: 3.8)
            outline.lineWidth = 1
            ink.withAlphaComponent(0.45).setStroke()
            outline.stroke()
            ink.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: (h - capH) / 2, width: capW, height: capH), xRadius: 1, yRadius: 1).fill()

            // Fill level.
            let inner = body.insetBy(dx: 2, dy: 2)
            let fillW = max(pct > 0 ? 2.5 : 0, inner.width * CGFloat(pct) / 100)
            (fillColor ?? ink).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height), xRadius: 1.8, yRadius: 1.8).fill()

            // Glyph: punch a halo out of the fill, then draw it, so it reads at any level.
            if let glyphName, let g = symbol(glyphName, size: 7.5, weight: .black) {
                let origin = NSPoint(x: body.midX - g.size.width / 2, y: body.midY - g.size.height / 2)
                for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] {
                    g.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .destinationOut, fraction: 1)
                } }
                tinted(g, ink).draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        img.isTemplate = template
        return img
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    fileprivate static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}

extension StatusIcon {
    /// Debug: every state on a light and a dark menu bar strip.
    static func renderPreview(to path: String) {
        // (label, percent, charging, pluggedIn, mode)
        let states: [(String, Int, Bool, Bool, Int)] = [
            ("on battery", 64, false, false, 0),
            ("charging", 42, true, true, 0),
            ("plugged in, held at limit", 80, false, true, 0),
            ("high power, on battery", 73, false, false, 2),
            ("high power, charging", 55, true, true, 2),
            ("high power, held at limit", 80, false, true, 2),
            ("low power, on battery", 35, false, false, 1),
            ("low power, charging", 48, true, true, 1),
            ("low power, held at limit", 80, false, true, 1),
            ("nearly empty", 8, false, false, 0),
        ]
        let rowH: CGFloat = 26, colW: CGFloat = 240, scale: CGFloat = 3
        let size = NSSize(width: colW * 2, height: rowH * CGFloat(states.count))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (col, dark) in [false, true].enumerated() {
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: CGFloat(col) * colW, y: 0, width: colW, height: size.height).fill()
                for (row, s) in states.enumerated() {
                    let y = size.height - CGFloat(row + 1) * rowH
                    var img = make(percent: s.1, charging: s.2, pluggedIn: s.3, mode: s.4)
                    if img.isTemplate { img = tinted(img, dark ? .white : .black) }
                    img.draw(at: NSPoint(x: CGFloat(col) * colW + 8, y: y + 4), from: .zero, operation: .sourceOver, fraction: 1)
                    (s.0 as NSString).draw(at: NSPoint(x: CGFloat(col) * colW + 80, y: y + 6),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: dark ? NSColor.lightGray : NSColor.darkGray])
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension StatusIcon {
    /// Build step: draws the 1024px app icon. The mark is a citrus slice read as a gauge:
    /// eight segments, six full and two left pale, the way a battery sits at its charge limit.
    static func renderAppIcon(to path: String) {
        let px = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
        NSColor.orange.setFill(); shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 1), NSColor(red: 1.0, green: 0.36, blue: 0.02, alpha: 1)])!
            .draw(in: shape, angle: -90)

        let c = NSPoint(x: tile.midX, y: tile.midY)
        let cream = NSColor(red: 1.0, green: 0.97, blue: 0.89, alpha: 1)
        // Rind
        let rind = NSBezierPath(ovalIn: NSRect(x: c.x - 292, y: c.y - 292, width: 584, height: 584))
        rind.lineWidth = 40
        cream.setStroke(); rind.stroke()
        // Segments, clockwise from 12 o'clock
        for i in 0..<8 {
            let mid = 90 - 22.5 - 45 * CGFloat(i), half: CGFloat = 16.5
            let wedge = NSBezierPath()
            wedge.appendArc(withCenter: c, radius: 78, startAngle: mid + half - 5, endAngle: mid - half + 5, clockwise: true)
            wedge.appendArc(withCenter: c, radius: 216, startAngle: mid - half, endAngle: mid + half, clockwise: false)
            wedge.close()
            wedge.lineJoinStyle = .round
            wedge.lineWidth = 26
            // Fill and stroke on a transparency layer so the pale segments don't double up where they overlap.
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState(); ctx.setAlpha(i < 6 ? 1 : 0.32); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            cream.setFill(); cream.setStroke(); wedge.fill(); wedge.stroke()
            ctx.endTransparencyLayer(); ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
