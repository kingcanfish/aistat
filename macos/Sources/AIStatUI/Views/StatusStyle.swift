import AIStatCore
import SwiftUI

/// How a ``Status`` looks.
///
/// The web panel carried two hand-tuned six-colour palettes — one for light,
/// one for dark — because CSS had no way to say "the system's green". SwiftUI
/// does, and the system colours are already contrast-tuned per appearance, so
/// the palettes are gone.
///
/// The bigger change is that **shape carries the meaning too**. The original
/// distinguished six states by hue alone, which is the one encoding that
/// disappears for a red/green colour-blind user and at a glance in peripheral
/// vision. Here each state gets an SF Symbol whose silhouette is unambiguous
/// without any colour at all; the colour is reinforcement, not the signal.
extension Status {
    var symbolName: String {
        switch self {
        case .operational: "checkmark.circle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .partialOutage: "exclamationmark.triangle.fill"
        case .fullOutage: "xmark.octagon.fill"
        case .maintenance: "wrench.adjustable.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    /// System colours, which resolve per appearance on their own.
    var tint: Color {
        switch self {
        case .operational: .green
        case .degraded: .yellow
        case .partialOutage: .orange
        case .fullOutage: .red
        case .maintenance: .blue
        case .unknown: .secondary
        }
    }

    /// Healthy and unknown recede into the secondary colour: a list of rows all
    /// saying the same fine thing shouldn't shout, and "we couldn't ask" is not
    /// news. Anything worse takes the colour of the state it names.
    var isNoteworthy: Bool {
        self != .operational && self != .unknown
    }

    var foreground: Color { isNoteworthy ? tint : .secondary }
}

/// The one-glance state marker used in rows and headers.
struct StatusBadge: View {
    var status: Status
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: status.symbolName)
            .font(.system(size: size))
            .foregroundStyle(status.tint)
            .accessibilityLabel(status.label)
    }
}
