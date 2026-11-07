import Foundation
import Testing
@testable import GhuppyCore

struct SpinnerFrameTests {
    private let duration = SpinnerFrame.crossingDuration

    private func length(_ vector: SIMD2<Double>) -> Double {
        (vector * vector).sum().squareRoot()
    }

    private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        length(a - b)
    }

    private func frames(crossings: Int = 12, steps: Int = 200) -> [SpinnerFrame] {
        (0..<(crossings * steps)).map {
            SpinnerFrame(at: Double($0) / Double(steps) * duration)
        }
    }

    @Test func slidingDotsStayOnTheCircle() {
        for frame in frames() {
            #expect(abs(length(frame.dots[1]) - 1) < 1e-9)
            #expect(abs(length(frame.dots[2]) - 1) < 1e-9)
        }
    }

    @Test func triangleStaysCentredOnTheCircle() {
        for frame in frames() {
            #expect(length(frame.dots.reduce(.zero, +)) < 1e-9)
        }
    }

    @Test func dotsFormAnEquilateralTriangleAsEachCrossingEnds() {
        let side = 3.0.squareRoot()
        for crossing in 0..<12 {
            let dots = SpinnerFrame(at: Double(crossing) * duration).dots
            #expect(abs(distance(dots[0], dots[1]) - side) < 1e-9)
            #expect(abs(distance(dots[1], dots[2]) - side) < 1e-9)
            #expect(abs(distance(dots[2], dots[0]) - side) < 1e-9)
        }
    }

    @Test func crossingDotPassesThroughTheCentreHalfwayAcross() {
        for crossing in 0..<12 {
            let frame = SpinnerFrame(at: (Double(crossing) + 0.5) * duration)
            #expect(length(frame.dots[0]) < 1e-9)
            #expect(abs(frame.curve) < 1e-9)
        }
    }

    @Test func noDotJumpsOrStopsBetweenCrossings() {
        let step = duration / 1000
        for crossing in 1..<12 {
            let handoff = Double(crossing) * duration
            let before = SpinnerFrame(at: handoff - step).dots
            let after = SpinnerFrame(at: handoff + step).dots
            for dot in before {
                let moved = after.map { distance(dot, $0) }.min() ?? .infinity
                #expect(moved > 0)
                #expect(moved < 0.01)
            }
        }
    }

    @Test func everyDotTakesItsTurnCrossing() {
        var tracked = SpinnerFrame(at: 0).dots
        var crossers: [Int] = []
        let steps = 200
        for step in 1...(6 * steps) {
            let frame = SpinnerFrame(at: Double(step) / Double(steps) * duration)
            tracked = tracked.map { dot in
                frame.dots.min { distance(dot, $0) < distance(dot, $1) } ?? dot
            }
            if step % steps == steps / 2 {
                crossers.append(tracked.firstIndex { length($0) < 1e-9 } ?? -1)
            }
        }
        #expect(Set(crossers.prefix(3)) == [0, 1, 2])
        #expect(Array(crossers.prefix(3)) == Array(crossers.suffix(3)))
    }

    @Test func linesAlternateBetweenCurvingInAndOut() {
        func closestToCentre(at crossing: Int) -> Double {
            SpinnerFrame(at: Double(crossing) * duration).outline.map(length).min() ?? .infinity
        }
        #expect(abs(closestToCentre(at: 0) - 0.2) < 1e-9)
        #expect(abs(closestToCentre(at: 1) - 0.8) < 1e-9)
        #expect(abs(closestToCentre(at: 2) - 0.2) < 1e-9)
    }

    @Test func linesJoinTheDots() {
        for frame in frames() {
            for dot in frame.dots {
                #expect(frame.outline.contains { distance($0, dot) < 1e-6 })
            }
        }
    }

    @Test func linesNeverJumpBetweenPoints() {
        for frame in frames() {
            let closed = frame.outline + frame.outline.prefix(1)
            for (point, next) in zip(closed, closed.dropFirst()) {
                #expect(distance(point, next) < 0.5)
            }
        }
    }

    @Test func stillTriangleHasStraightLines() {
        let triangle = SpinnerFrame.triangle
        #expect(triangle.curve == 0)
        #expect(triangle.dots == SpinnerFrame(at: 0).dots)
        #expect(abs((triangle.outline.map(length).min() ?? 0) - 0.5) < 1e-9)
    }

    @Test func curveNeverJumps() {
        let curves = frames().map(\.curve)
        for (previous, next) in zip(curves, curves.dropFirst()) {
            #expect(abs(previous - next) < 0.05)
        }
    }
}
