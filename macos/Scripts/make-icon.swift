// Renders the app icon. Run through Scripts/make-icon.sh, which packages the
// PNGs this writes into macos/Resources/AppIcon.icns and src-tauri/icons/.
//
//     swift Scripts/make-icon.swift <out-dir>
//
// The mark is the menu bar glyph (same geometry as MenuBarGlyph, in the same
// 18-point box) so the Dock and the menu bar show one character, not two. Every
// size is rendered from the vector rather than downscaled from 1024, which is
// what keeps the 16 px and 32 px variants from turning to mush.
import AppKit
import SwiftUI

private enum Glyph {
    static let head = CGRect(x: 2.4, y: 5.4, width: 13.2, height: 11.2)
    static let headRadius: CGFloat = 4
    static let eyeL = CGPoint(x: 6.5, y: 10.5)
    static let eyeR = CGPoint(x: 11.5, y: 10.5)
    /// Further out than the menu bar's (14, 14). At 18 pt the lamp's knockout
    /// clipping the right eye is invisible; at icon size it reads as a bite
    /// taken out of the face. Out here the two clear each other.
    static let lamp = CGPoint(x: 14.9, y: 14.9)
    static let lampRadius: CGFloat = 2.3
}

private let green = Color(red: 0.20, green: 0.84, blue: 0.42)

private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

private struct AppIcon: View {
    /// Apple's macOS grid: an 824-point continuous-corner square centred in a
    /// 1024 canvas, the remaining margin left for the drop shadow.
    private let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)

    var body: some View {
        ZStack {
            tile
                .fill(LinearGradient(
                    colors: [Color(red: 0.22, green: 0.25, blue: 0.40),
                             Color(red: 0.06, green: 0.07, blue: 0.13)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(tile.fill(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                                  startPoint: .top, endPoint: .center)))
                .overlay(tile.strokeBorder(.white.opacity(0.10), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            // Scaled inside the context, not with `.scaleEffect`: a Canvas
            // rasterises at its own frame, so an 18-point canvas blown up 28×
            // is a smear at 1024 and nothing at all at 16 px.
            Canvas { ctx, _ in
                ctx.scaleBy(x: 28, y: 28)
                drawGlyph(&ctx)
            }
                .frame(width: 18 * 28, height: 18 * 28)
                // Nudged left and down so the glyph *with its lamp* is what sits
                // optically centred, not the bare head.
                .offset(x: -6, y: 4)
        }
        .frame(width: 1024, height: 1024)
    }

    private func drawGlyph(_ ctx: inout GraphicsContext) {
        let head = Path(roundedRect: Glyph.head, cornerRadius: Glyph.headRadius, style: .continuous)
        var antenna = Path()
        antenna.move(to: CGPoint(x: 9, y: 3.5))
        antenna.addLine(to: CGPoint(x: 9, y: 5.4))
        let pen: CGFloat = 1.5

        ctx.drawLayer { layer in
            layer.stroke(head, with: .color(.white), lineWidth: pen)
            layer.stroke(antenna, with: .color(.white), style: StrokeStyle(lineWidth: pen, lineCap: .round))
            layer.fill(circle(CGPoint(x: 9, y: 2.45), 1.15), with: .color(.white))
            layer.fill(circle(Glyph.eyeL, 1.35), with: .color(.white))
            layer.fill(circle(Glyph.eyeR, 1.35), with: .color(.white))
            // Punched out, as in the menu bar, so the lamp never shares a pixel
            // with the outline.
            layer.blendMode = .destinationOut
            layer.fill(circle(Glyph.lamp, Glyph.lampRadius + 0.95), with: .color(.black))
        }
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 0.9))
            glow.fill(circle(Glyph.lamp, Glyph.lampRadius + 0.1), with: .color(green.opacity(0.8)))
        }
        // Off-centre radial fill so the lamp reads as a lit bulb, not a sticker.
        ctx.fill(circle(Glyph.lamp, Glyph.lampRadius), with: .radialGradient(
            Gradient(colors: [Color(red: 0.55, green: 1.0, blue: 0.68), green,
                              Color(red: 0.10, green: 0.62, blue: 0.30)]),
            center: CGPoint(x: Glyph.lamp.x - 0.7, y: Glyph.lamp.y - 0.8),
            startRadius: 0, endRadius: 3.2))
    }
}

@MainActor private func write(size: Int, to url: URL) {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = CGFloat(size) / 1024
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("could not render \(size)px") }
    try! png.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out-dir>\n".data(using: .utf8)!)
    exit(64)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
MainActor.assumeIsolated {
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        write(size: size, to: out.appendingPathComponent("\(size).png"))
    }
}
