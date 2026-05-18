import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite(.serialized)
final class RateLimitTests {
    @Test
    func observationBridgeDebounceImmediateFirstSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let stream = ObservationBridge(
            options: legacyOptionsForCurrentRuntime(.rateLimit(.debounce(debounce))),
            clock: clock
        ) {
            model.value
        }
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        model.value = 3

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(199))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 3)
    }

    @Test
    func observationBridgeDebounceStillEmitsDuplicateDerivedOutputs() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let stream = ObservationBridge(
            options: legacyOptionsForCurrentRuntime(.rateLimit(.debounce(debounce))),
            clock: clock
        ) {
            model.parity
        }
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 3
        model.value = 4
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 0)
    }

    @Test
    func observationBridgeThrottleLatestSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let throttle = ObservationThrottle(interval: .milliseconds(200))
        let stream = ObservationBridge(
            options: legacyOptionsForCurrentRuntime(.rateLimit(.throttle(throttle))),
            clock: clock
        ) {
            model.value
        }
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        model.value = 3

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(199))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 3)
    }

    @Test
    func observationBridgeThrottleEarliestSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let throttle = ObservationThrottle(
            interval: .milliseconds(200),
            mode: .earliest
        )
        let stream = ObservationBridge(
            options: legacyOptionsForCurrentRuntime(.rateLimit(.throttle(throttle))),
            clock: clock
        ) {
            model.value
        }
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 10
        await Task.yield()
        model.value = 11
        await Task.yield()
        model.value = 12

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(200))
        let throttledValue = await nextWithTimeout(from: queue)
        #expect(throttledValue == 10)
    }
}
