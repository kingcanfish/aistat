import SwiftUI

/// A single line of text that, while `scrolling` is on and the text does not
/// fit, pans to its end, holds, pans back, and repeats. Otherwise it is an
/// ordinary tail-truncated `Text`.
///
/// Scrolling is opt-in per call site (the caller decides it from hover) rather
/// than automatic, because a panel full of permanently moving labels pulls the
/// eye away from the one row that changed status.
@MainActor
struct MarqueeText: View {
    var text: String
    var scrolling: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Points per second. Slow enough to read while it moves.
    private static let speed: CGFloat = 40
    private static let holdBeforeStart: Duration = .milliseconds(500)
    private static let holdAtEnd: Duration = .seconds(1)

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    private var active: Bool { scrolling && overflow > 0.5 && !reduceMotion }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            // The truncated copy keeps the line's height and lays out the box;
            // it is hidden rather than removed while the full copy pans.
            .opacity(active ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: offset)
                    .opacity(active ? 1 : 0)
            }
            .clipped()
            .task(id: active) { await run() }
    }

    private func run() async {
        guard active else {
            withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
            return
        }
        // `Task.sleep` throws on cancellation, which is how un-hovering stops
        // the loop: `task(id:)` cancels this run and starts the inactive one.
        do {
            while true {
                try await Task.sleep(for: Self.holdBeforeStart)
                let distance = overflow
                let duration = Double(distance / Self.speed)
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try await Task.sleep(for: .seconds(duration) + Self.holdAtEnd)
                withAnimation(.easeInOut(duration: 0.3)) { offset = 0 }
                try await Task.sleep(for: .milliseconds(300))
            }
        } catch {}
    }
}
