import GhuppyCore
import SwiftUI

/// The cleanup icon: the Ghuppy logo, which turns into the triangle spinner
/// while `animating`, or with Reduce Motion on only fades in and out.
/// Coloured by `foregroundStyle`, like text, and `small` or regular by
/// `controlSize`.
///
/// When told to stop it runs on to the end of a cycle that turns it back into
/// the fish, so it never jumps. Told to go again before it has started
/// turning back, it carries on; after that, it finishes and starts afresh.
struct FishSpinner: View {
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
                FishShape(frame: .fish)
            }
        }
        // Wide enough for the fish, which is wider than the spinner's circle.
        .frame(width: size * 1.2, height: size)
        .onAppear { if animating { started = .now } }
        .onChange(of: animating) { _, animating in
            let now = Date.now
            guard let started else {
                if animating { self.started = now }
                return
            }
            let elapsed = now.timeIntervalSince(started)
            if animating {
                // Still the spinner: carry on. Otherwise the settling task
                // starts it again once it is back at rest.
                if let settles, !FishFrame.isUntangling(at: elapsed, settles: settles.timeIntervalSince(started)) {
                    self.settles = nil
                }
            } else if settles == nil {
                settles = started.addingTimeInterval(FishFrame.settles(stoppingAt: elapsed))
            }
        }
        .task(id: settles) {
            guard let settles else { return }
            try? await Task.sleep(for: .seconds(max(settles.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            started = animating ? .now : nil
            self.settles = nil
        }
    }

    @ViewBuilder
    private func pose(at date: Date, since started: Date) -> some View {
        let elapsed = date.timeIntervalSince(started)
        let settling = settles.map { $0.timeIntervalSince(started) }
        if reduceMotion {
            // Full strength at the start and at the end of every cycle.
            FishShape(frame: .fish)
                .opacity(settling.map { elapsed >= $0 } == true
                    ? 1
                    : 0.65 + 0.35 * cos(2 * .pi * elapsed / FishFrame.cycle))
        } else {
            FishShape(frame: FishFrame(at: elapsed, settles: settling))
        }
    }
}

/// A `Shape` rather than a `Canvas`, which would paint a flat colour and miss
/// the blending macOS gives text in dark mode. The lines and dots are one
/// path, so a translucent style doesn't show darker where they overlap.
private struct FishShape: Shape {
    /// The width of the lines in the symbols it stands among.
    private static let lineWidth = 1.0

    let frame: FishFrame

    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let dotRadius = max(size * 0.12, 1.58)
        // The logo's eye is about half the size of its nodes.
        let eyeRadius = max(dotRadius * 0.52, 0.9)
        let radius = size / 2 - dotRadius - 0.25

        func point(_ position: SIMD2<Double>) -> CGPoint {
            CGPoint(x: rect.midX + position.x * radius, y: rect.midY + position.y * radius)
        }

        var lines = Path()
        lines.addLines(frame.outline.map(point))
        lines.closeSubpath()

        var dots = Path()
        for dot in frame.dots {
            let centre = point(dot.position)
            let dotRadiusNow = eyeRadius + (dotRadius - eyeRadius) * dot.growth
            dots.addEllipse(in: CGRect(
                x: centre.x - dotRadiusNow,
                y: centre.y - dotRadiusNow,
                width: dotRadiusNow * 2,
                height: dotRadiusNow * 2
            ))
        }

        return lines
            .strokedPath(StrokeStyle(lineWidth: Self.lineWidth, lineJoin: .round))
            .union(dots)
    }
}
