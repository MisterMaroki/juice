import AppKit

/// Draws the menu bar item: [mode badge] 80% [battery with fill + bolt/plug].
/// Plain states are template images so macOS tints them for light/dark menu bars;
/// coloured states (low power yellow, low battery red) use labelColor for the outline.
enum StatusIcon {
    static func make(percent: Int, charging: Bool, pluggedIn: Bool, mode: Int) -> NSImage {
        let pct = max(0, min(100, percent))
        let lowBattery = pct <= 10 && !pluggedIn
        let fillColor: NSColor? = mode == 1 ? .systemYellow : (lowBattery ? .systemRed : nil)
        let template = fillColor == nil

        let text = "\(pct)%" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let badgeName: String? = mode == 2 ? "hare.fill" : (mode == 1 ? "leaf.fill" : nil)
        let badge = badgeName.flatMap { symbol($0, size: 10, weight: .semibold) }

        let h: CGFloat = 18
        let bodyW: CGFloat = 25, bodyH: CGFloat = 12, capW: CGFloat = 2, capH: CGFloat = 4.5
        let textSize = text.size(withAttributes: [.font: font])
        let badgeW = badge.map { $0.size.width + 3 } ?? 0
        let width = ceil(badgeW + textSize.width + 4 + bodyW + capW + 1)

        let img = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            let ink = template ? NSColor.black : NSColor.labelColor
            var x: CGFloat = 0

            if let badge {
                tinted(badge, ink).draw(at: NSPoint(x: x, y: (h - badge.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                x += badgeW
            }

            text.draw(at: NSPoint(x: x, y: (h - textSize.height) / 2),
                      withAttributes: [.font: font, .foregroundColor: ink])
            x += textSize.width + 4

            // Battery outline (dimmed like the system icon) and cap.
            let body = NSRect(x: x + 0.5, y: (h - bodyH) / 2, width: bodyW - 1, height: bodyH)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1
            ink.withAlphaComponent(0.4).setStroke()
            outline.stroke()
            let cap = NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: (h - capH) / 2, width: capW, height: capH), xRadius: 1, yRadius: 1)
            ink.withAlphaComponent(0.4).setFill()
            cap.fill()

            // Fill level.
            let inner = body.insetBy(dx: 2, dy: 2)
            let fillW = max(pct > 0 ? 2 : 0, inner.width * CGFloat(pct) / 100)
            (fillColor ?? ink).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height), xRadius: 1.5, yRadius: 1.5).fill()

            // State glyph, knocked out of the fill so it reads on any level.
            let glyphName: String? = charging ? "bolt.fill" : (pluggedIn ? "powerplug.fill" : nil)
            if let glyphName, let g = symbol(glyphName, size: 7.5, weight: .black),
               let halo = symbol(glyphName, size: 7.5, weight: .black) {
                let origin = NSPoint(x: body.midX - g.size.width / 2, y: body.midY - g.size.height / 2)
                // Halo: punch a slightly larger hole around the glyph.
                for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] {
                    halo.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .destinationOut, fraction: 1)
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
        let out = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        return out
    }
}

extension StatusIcon {
    /// Debug: every state on a light and a dark menu bar strip.
    static func renderPreview(to path: String) {
        let states: [(String, Int, Bool, Bool, Int)] = [
            ("battery", 64, false, false, 0), ("charging", 42, true, true, 0),
            ("held at limit", 80, false, true, 0), ("high + charging", 55, true, true, 2),
            ("high on battery", 73, false, false, 2), ("low power", 35, false, false, 1),
            ("low + plugged", 80, false, true, 1), ("low battery", 8, false, false, 0),
        ]
        let rowH: CGFloat = 26, colW: CGFloat = 230, scale: CGFloat = 3
        let size = NSSize(width: colW * 2, height: rowH * CGFloat(states.count))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (col, dark) in [false, true].enumerated() {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: CGFloat(col) * colW, y: 0, width: colW, height: size.height).fill()
                for (row, s) in states.enumerated() {
                    let y = size.height - CGFloat(row + 1) * rowH
                    var img = make(percent: s.1, charging: s.2, pluggedIn: s.3, mode: s.4)
                    if img.isTemplate { img = tinted(img, dark ? .white : .black) }
                    img.draw(at: NSPoint(x: CGFloat(col) * colW + 8, y: y + 4), from: .zero, operation: .sourceOver, fraction: 1)
                    (s.0 as NSString).draw(at: NSPoint(x: CGFloat(col) * colW + 110, y: y + 6),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: dark ? NSColor.lightGray : NSColor.darkGray])
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
