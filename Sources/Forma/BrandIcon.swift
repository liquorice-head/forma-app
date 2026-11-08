import AppKit

/// The approved offset brackets, shared by the app icon and small template marks.
enum BrandIcon {
    static let ink = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    static let paper = NSColor(srgbRed: 0.985, green: 0.985, blue: 0.985, alpha: 1)

    // Coordinates use the top-left origin of the 1,000-point design tile.
    private static func brackets() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 496, y: 260))
        path.line(to: NSPoint(x: 347, y: 260))
        path.curve(to: NSPoint(x: 257, y: 350), controlPoint1: NSPoint(x: 297, y: 260), controlPoint2: NSPoint(x: 257, y: 300))
        path.line(to: NSPoint(x: 257, y: 547))
        path.curve(to: NSPoint(x: 347, y: 637), controlPoint1: NSPoint(x: 257, y: 597), controlPoint2: NSPoint(x: 297, y: 637))
        path.line(to: NSPoint(x: 379, y: 637))

        path.move(to: NSPoint(x: 551, y: 396))
        path.line(to: NSPoint(x: 661, y: 396))
        path.curve(to: NSPoint(x: 751, y: 486), controlPoint1: NSPoint(x: 711, y: 396), controlPoint2: NSPoint(x: 751, y: 436))
        path.line(to: NSPoint(x: 751, y: 671))
        path.curve(to: NSPoint(x: 661, y: 761), controlPoint1: NSPoint(x: 751, y: 721), controlPoint2: NSPoint(x: 711, y: 761))
        path.line(to: NSPoint(x: 516, y: 761))
        path.lineWidth = 100
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private static func drawMark(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
            .scaled(by: rect.width / 1000)
        let path = brackets()
        path.transform(using: transform)
        path.lineWidth = 100 * rect.width / 1000
        color.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func symbolSVG() -> String {
        // Outline strokes before export: Icon Composer's appearance fills must
        // recolor the stroke silhouette, not fill the open bracket centerlines.
        let path = brackets().cgPath.copy(strokingWithWidth: 100, lineCap: .round, lineJoin: .round, miterLimit: 10)
        var commands: [String] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint: commands.append("M \(points[0].x) \(points[0].y)")
            case .addLineToPoint: commands.append("L \(points[0].x) \(points[0].y)")
            case .addQuadCurveToPoint: commands.append("Q \(points[0].x) \(points[0].y) \(points[1].x) \(points[1].y)")
            case .addCurveToPoint: commands.append("C \(points[0].x) \(points[0].y) \(points[1].x) \(points[1].y) \(points[2].x) \(points[2].y)")
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1000 1000">
          <path d="\(commands.joined(separator: " "))" fill="#141414"/>
        </svg>
        """
    }

    static func drawAppIcon(in rect: NSRect, dark: Bool) {
        // Standard macOS optical inset; the surrounding pixels stay transparent.
        let tile = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10)
        (dark ? ink : paper).setFill()
        NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.20, yRadius: tile.height * 0.20).fill()
        drawMark(in: tile, color: dark ? paper : ink)
    }

    static func appImage(dark: Bool) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { rect in
            drawAppIcon(in: rect, dark: dark)
            return true
        }
    }

    static let templateImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            // Crop the tile padding to keep the actual mark legible in the menu bar.
            let scale = rect.width / 650
            let design = NSRect(x: rect.minX - 179 * scale, y: rect.minY - 185 * scale,
                                width: 1000 * scale, height: 1000 * scale)
            drawMark(in: design, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Forma"
        return image
    }()
}

private extension AffineTransform {
    func scaled(by factor: CGFloat) -> AffineTransform {
        var transform = self
        transform.scale(factor)
        return transform
    }
}
