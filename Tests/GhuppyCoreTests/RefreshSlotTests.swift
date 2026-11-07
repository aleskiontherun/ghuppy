import Foundation
import Testing
@testable import GhuppyCore

@MainActor
struct RefreshSlotTests {
    /// Waits for cancellation, the way a job in the middle of its work would.
    private func untilCancelled() async {
        while !Task.isCancelled {
            await Task.yield()
        }
    }

    @Test func runsAJobAndThenStops() async {
        let slot = RefreshSlot()
        var ran = false
        let job = slot.start { ran = true }
        #expect(slot.isRunning)
        await job.value
        #expect(ran)
        #expect(!slot.isRunning)
    }

    @Test func aNewJobCancelsTheOneRunningAndStartsAfterIt() async {
        let slot = RefreshSlot()
        var events: [String] = []
        slot.start {
            events.append("first started")
            await untilCancelled()
            await Task.yield()
            events.append("first ended")
        }
        while events.isEmpty {
            await Task.yield()
        }
        let second = slot.start { events.append("second started") }
        await second.value
        #expect(events == ["first started", "first ended", "second started"])
    }

    @Test func onlyTheLastOfSeveralJobsRuns() async {
        let slot = RefreshSlot()
        var ran: [Int] = []
        var last: Task<Void, Never>?
        for number in 1...5 {
            last = slot.start { ran.append(number) }
        }
        await last?.value
        #expect(ran == [5])
        #expect(!slot.isRunning)
    }

    @Test func cancelStopsTheJobRunning() async {
        let slot = RefreshSlot()
        var started = false
        let job = slot.start {
            started = true
            await untilCancelled()
        }
        while !started {
            await Task.yield()
        }
        slot.cancel()
        await job.value
        #expect(!slot.isRunning)
    }

    @Test func staysRunningWhileOneJobTakesOverFromAnother() async {
        let slot = RefreshSlot()
        var started = false
        let first = slot.start {
            started = true
            await untilCancelled()
        }
        while !started {
            await Task.yield()
        }
        var released = false
        let second = slot.start {
            while !released {
                await Task.yield()
            }
        }
        await first.value
        #expect(slot.isRunning)
        released = true
        await second.value
        #expect(!slot.isRunning)
    }
}
