import GhuppyCore
import SwiftUI

/// The cleanup icon: a still triangle with straight lines, which comes alive
/// while `animating`, or with Reduce Motion on only fades in and out.
/// Coloured by `foregroundStyle`, like text, and `small` or regular by
/// `controlSize`.
struct TriangleSpinner: View {
    var animating = true

    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: Double { controlSize == .small ? 16 : 20 }

    var body: some View {
        Group {
            if animating {
                // A 20-point icon gains nothing from the display's full rate.
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    if reduceMotion {
                        SpinnerShape(frame: .triangle)
                            .opacity(0.65 + 0.35 * cos(2 * .pi * time / 1.6))
                    } else {
                        SpinnerShape(frame: SpinnerFrame(at: time))
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("In progress")
            } else {
                SpinnerShape(frame: .triangle)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A `Shape` rather than a `Canvas`, which would paint a flat colour and miss
/// the blending macOS gives text in dark mode. The lines and dots are one
/// path, so a translucent style doesn't show darker where they overlap.
private struct SpinnerShape: Shape {
    /// The width of the lines in the symbols it stands among.
    private static let lineWidth = 1.0

    let frame: SpinnerFrame

    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let dotRadius = max(size * 0.12, 1.58)
        let radius = size / 2 - dotRadius - 0.25

        func point(_ position: SIMD2<Double>) -> CGPoint {
            CGPoint(x: rect.midX + position.x * radius, y: rect.midY + position.y * radius)
        }

        var lines = Path()
        lines.addLines(frame.outline.map(point))
        lines.closeSubpath()

        var dots = Path()
        for dot in frame.dots {
            let centre = point(dot)
            dots.addEllipse(in: CGRect(
                x: centre.x - dotRadius,
                y: centre.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }

        return lines
            .strokedPath(StrokeStyle(lineWidth: Self.lineWidth, lineJoin: .round))
            .union(dots)
    }
}
