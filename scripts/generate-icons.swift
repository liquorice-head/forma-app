import AppKit

// Compile alongside Sources/Forma/BrandIcon.swift. No image-generation service is
// needed to rebuild the production icons: the shared vector is the source of truth.
@main
struct GenerateIcons {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try BrandIcon.symbolSVG().write(to: root.appendingPathComponent("Forma-mark.svg"), atomically: true, encoding: .utf8)
        for dark in [false, true] {
            let name = dark ? "Forma-dark" : "Forma"
            let iconset = root.appendingPathComponent("\(name).iconset", isDirectory: true)
            try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let pixels = points * scale
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    let context = NSGraphicsContext.current!.cgContext
                    context.translateBy(x: 0, y: CGFloat(pixels))
                    context.scaleBy(x: 1, y: -1)
                    BrandIcon.drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), dark: dark)
                    NSGraphicsContext.restoreGraphicsState()
                    let suffix = scale == 2 ? "@2x" : ""
                    let data = bitmap.representation(using: .png, properties: [:])!
                    try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
                    if pixels == 1024 { try data.write(to: root.appendingPathComponent("\(name).png")) }
                }
            }
        }
    }
}
