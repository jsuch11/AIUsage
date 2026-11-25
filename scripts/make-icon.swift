// Renders LogoMark (Sources/AIUsage/Views/Logo.swift) into Resources/AppIcon.icns.
// Run via scripts/make-icon.sh.
import SwiftUI
import AppKit

@main
struct MakeIcon {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(pt * scale)
                // macOS icon grid: the tile fills ~80% of the canvas, centered.
                let view = LogoMark(size: px * 0.805)
                    .shadow(color: .black.opacity(0.3), radius: px * 0.012, y: px * 0.01)
                    .frame(width: px, height: px)
                let r = ImageRenderer(content: view)
                r.scale = 1
                guard let cg = r.cgImage else { throw NSError(domain: "icon", code: 1) }
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                try png.write(to: out.appendingPathComponent(name))
            }
        }
    }
}
