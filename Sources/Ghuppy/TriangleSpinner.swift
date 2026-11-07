import GhuppyCore
import SwiftUI

/// The cleanup icon: a still triangle with straight lines, which comes alive
/// while `animating`, or with Reduce Motion on only fades in and out.
/// Coloured by `foregroundStyle`, like text, and `small` or regular by
/// `controlSize`.
///
/// It starts from the still triangle and bends its lines in, and when told
/// to stop it finishes the crossing that brings the dots back to where they
/// started, then straightens them out again, so it never jumps.
struct TriangleSpinner: View {
    /// How long the lines take to bend in or straighten out.
    private static let ease = 0.25
    /// A whole cycle: after it the dots are back where they started.
    private static let cycle = 2 * SpinnerFrame.crossingDuration

    var animating = true

    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the run on screen began, nil while still.
    @State private var started: Date?
    /// When the run will be back at rest, once told to stop.
    @State private var settles: Date?

    private var size: Double { controlSize == .small ? 16 : 20 }

    var body: some View {
        Group {
            if let started {
                // A 20-point icon gains nothing from the display's full rate.
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                    pose(at: timeline.date, since: started)
                }
                .accessibilityElement()
                .accessibilityLabel("In progress")
            } else {
                SpinnerShape(frame: .triangle)
            }
        }
        .frame(width: size, height: size)
        .onAppear { if animating { started = .now } }
        .onChange(of: animating) { _, animating in
            if animating {
                // Told to go again while settling: carry on from where it is.
                if settles == nil { started = .now }
                settles = nil
            } else if let started {
                let cycles = (Date.now.timeIntervalSince(started) / Self.cycle).rounded(.up)
                settles = started.addingTimeInterval(max(cycles, 1) * Self.cycle)
            }
        }
        .task(id: settles) {
            guard let settles else { return }
            try? await Task.sleep(for: .seconds(max(settles.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            started = nil
            self.settles = nil
        }
    }

    @ViewBuilder
    private func pose(at date: Date, since started: Date) -> some View {
        let elapsed = date.timeIntervalSince(started)
        let left = settles.map { $0.timeIntervalSince(date) } ?? .infinity
        if reduceMotion {
            // Full strength at the start and at the end of every cycle.
            SpinnerShape(frame: .triangle)
                .opacity(left <= 0 ? 1 : 0.65 + 0.35 * cos(2 * .pi * elapsed / Self.cycle))
        } else if left <= 0 {
            SpinnerShape(frame: .triangle)
        } else {
            let bend = min(elapsed / Self.ease, left / Self.ease, 1)
            SpinnerShape(frame: SpinnerFrame(at: elapsed, curveScale: bend))
        }
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
