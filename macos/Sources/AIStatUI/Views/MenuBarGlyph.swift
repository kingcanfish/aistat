import AIStatCore
import SwiftUI

/// The menu bar mark.
///
/// The Rust build rasterised this by hand: a signed distance field sampled with
/// 4×4 supersampling into a 36×36 RGBA buffer, plus a KVO observer on a second,
/// zero-length `NSStatusItem` whose only job was to report what appearance the
/// menu bar was drawing itself in — because the answer is *not* the system
/// appearance (a Light Mac with a dark wallpaper gets a dark menu bar) and the
/// icon had to pick one of two hard-coded palettes before it could draw a pixel.
///
/// Drawn as a SwiftUI `Canvas` instead. The shapes are paths rather than sampled
/// distances, and `.primary` resolves against whatever appearance is installed
/// when it is rasterised — which ``MenuBarController`` sets from the status item
/// button's own `effectiveAppearance`, the supported answer to the question the
/// probe existed to ask. The probe is gone; the appearance observation is not,
/// because nothing else reports a wallpaper change.
///
/// The geometry is the original's, in the same 18-point box the menu bar draws
/// a status item at, because the design is good and it is not what was wrong.
struct MenuBarGlyph: View {
    var status: Status
    var style: IconStyle

    /// How loud the mark is allowed to be. The silhouette is identical in all
    /// three — only the ink changes, so it never stops being the same icon.
    enum Weight { case calm, tinted, filled }

    /// The escalation is the whole argument for the default: a 5 pt lamp is 7%
    /// of the icon, which peripheral vision cannot resolve, whereas the
    /// difference between an outline and a solid block survives being out of
    /// focus. So the glance decision becomes "is there any colour at all", not
    /// "which hue is that dot" — and the bar stays monochrome on a normal day.
    static func weight(for style: IconStyle, status: Status) -> Weight {
        switch style {
        case .lamp: .calm
        case .tinted: .tinted
        case .escalating:
            switch status {
            case .operational, .unknown: .calm
            case .degraded, .maintenance: .tinted
            case .partialOutage, .fullOutage: .filled
            }
        }
    }

    private var weight: Weight { Self.weight(for: style, status: status) }

    // Geometry in icon points.
    private static let head = CGRect(x: 2.4, y: 5.4, width: 13.2, height: 11.2)
    private static let headRadius: CGFloat = 4
    private static let eyeL = CGPoint(x: 6.5, y: 10.5)
    private static let eyeR = CGPoint(x: 11.5, y: 10.5)
    /// Tucked inside the head's outer edge rather than hung off the corner: a
    /// lamp that stuck out would make the icon's extent change with the status,
    /// which reads as the mark resizing every time a service wobbles.
    private static let lamp = CGPoint(x: 14, y: 14)
    private static let lampRadius: CGFloat = 2.4

    var body: some View {
        Canvas { context, _ in draw(in: &context) }
            .frame(width: 18, height: 18)
            .accessibilityLabel("AIStat — \(status.label)")
    }

    private func draw(in context: inout GraphicsContext) {
        let ink: GraphicsContext.Shading =
            weight == .calm
            // `.primary` is the whole point: AppKit hands the menu bar's label
            // colour to this environment, so the glyph is correct on a dark bar
            // over a light system and vice versa.
            ? .color(.primary)
            : .color(status.tint)

        // Unknown is a missing answer, not an alarm, so it stays half-present
        // rather than sitting in the bar at full strength like a real state.
        context.opacity = (status == .unknown && weight == .calm) ? 0.55 : 1

        switch weight {
        case .calm, .tinted:
            let pen: CGFloat = weight == .calm ? 1.4 : 1.6
            let eyeRadius: CGFloat = weight == .calm ? 1.15 : 1.25

            // The lamp is punched out of the glyph rather than drawn over it, so
            // the two never share a pixel and the lamp keeps its full chroma at
            // 5 pt. A layer plus `destinationOut` is the native spelling of what
            // the distance field expressed as a knockout radius.
            context.drawLayer { layer in
                layer.stroke(headPath, with: ink, lineWidth: pen)
                layer.stroke(antennaPath, with: ink, style: StrokeStyle(lineWidth: pen, lineCap: .round))
                layer.fill(circle(at: CGPoint(x: 9, y: 2.45), r: weight == .calm ? 1.05 : 1.2), with: ink)
                layer.fill(circle(at: Self.eyeL, r: eyeRadius), with: ink)
                layer.fill(circle(at: Self.eyeR, r: eyeRadius), with: ink)

                if weight == .calm {
                    layer.blendMode = .destinationOut
                    layer.fill(circle(at: Self.lamp, r: Self.lampRadius + 1.1), with: .color(.black))
                }
            }
            if weight == .calm {
                context.fill(circle(at: Self.lamp, r: Self.lampRadius), with: .color(status.tint))
            }

        case .filled:
            // The calm weight's shapes with the head inked in rather than
            // stroked, and the eyes knocked back out — so the silhouette does
            // not move when the status does.
            context.drawLayer { layer in
                layer.fill(headPath.strokedPath(StrokeStyle(lineWidth: 1.4)), with: ink)
                layer.fill(headPath, with: ink)
                layer.stroke(antennaPath, with: ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                layer.fill(circle(at: CGPoint(x: 9, y: 2.45), r: 1.05), with: ink)

                layer.blendMode = .destinationOut
                layer.fill(circle(at: Self.eyeL, r: 1.55), with: .color(.black))
                layer.fill(circle(at: Self.eyeR, r: 1.55), with: .color(.black))
            }
        }
    }

    private var headPath: Path {
        Path(roundedRect: Self.head, cornerRadius: Self.headRadius, style: .continuous)
    }

    private var antennaPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 3.5))
        path.addLine(to: CGPoint(x: 9, y: 5.4))
        return path
    }

    private func circle(at centre: CGPoint, r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    }
}
