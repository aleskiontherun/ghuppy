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

    /// Follows each dot from frame to frame over `crossings` crossings, and
    /// returns which of them was crossing halfway through each one, and where
    /// each was at every step.
    private func track(circling: Bool, crossings: Int) -> (crossers: [Int], paths: [[SIMD2<Double>]]) {
        var tracked = SpinnerFrame(at: 0, circling: circling).dots
        var crossers: [Int] = []
        var paths = tracked.map { [$0] }
        let steps = 200
        for step in 1...(crossings * steps) {
            let frame = SpinnerFrame(at: Double(step) / Double(steps) * duration, circling: circling)
            tracked = tracked.map { dot in
                frame.dots.min { distance(dot, $0) < distance(dot, $1) } ?? dot
            }
            for index in tracked.indices { paths[index].append(tracked[index]) }
            if step % steps == steps / 2 {
                crossers.append(tracked.firstIndex { length($0) < 1e-9 } ?? -1)
            }
        }
        return (crossers, paths)
    }

    @Test func circlingDotNeverCrossesAndOnlyGoesForwards() {
        let (crossers, paths) = track(circling: true, crossings: 12)
        #expect(!crossers.contains(2))
        var previous = atan2(paths[2][0].y, paths[2][0].x), turned = 0.0
        for point in paths[2].dropFirst() {
            #expect(abs(length(point) - 1) < 1e-9)
            let angle = atan2(point.y, point.x)
            var step = angle - previous
            if step < -.pi { step += 2 * .pi }
            if step > .pi { step -= 2 * .pi }
            #expect(step > 0)
            turned += step
            previous = angle
        }
        // A sixth of a turn per crossing: twice round in twelve.
        #expect(abs(turned - 4 * .pi) < 1e-6)
    }

    @Test func circlingLeavesTheOtherTwoTakingTurns() {
        let crossers = track(circling: true, crossings: 12).crossers
        #expect(crossers == Array(repeating: [0, 1], count: 6).flatMap { $0 })
    }

    @Test func circlingDotsSitWhereTheyWouldOtherwiseAsEachCrossingEnds() {
        for crossing in 0...12 {
            let time = Double(crossing) * duration
            let usual = SpinnerFrame(at: time).dots
            for dot in SpinnerFrame(at: time, circling: true).dots {
                #expect(usual.contains { distance($0, dot) < 1e-9 })
            }
        }
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

    @Test func dotsAreBackWhereTheyStartedAfterTwoCrossings() {
        let later = SpinnerFrame(at: 2 * duration).dots
        for (dot, start) in zip(later, SpinnerFrame(at: 0).dots) {
            #expect(distance(dot, start) < 1e-9)
        }
    }

    @Test func curveNeverJumps() {
        let curves = frames().map(\.curve)
        for (previous, next) in zip(curves, curves.dropFirst()) {
            #expect(abs(previous - next) < 0.05)
        }
    }
}
