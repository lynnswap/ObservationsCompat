import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
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
        #expect(await nextWithTimeout(from: queue) == 10)
    }

    @Test
    func observeDebounceImmediateFirstRecordsInitialValueBeforeReturnForNativeNonisolatedModel() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return
        }

        let model = CounterModel()
        let recorder = ValueRecorder<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let observations = model.observe(
            \.value,
            options: .rateLimit(.debounce(debounce)),
            clock: clock
        ) { value in
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observeThrottleRecordsInitialValueBeforeReturnForNativeNonisolatedModel() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return
        }

        let model = CounterModel()
        let recorder = ValueRecorder<Int>()
        let clock = TestDebounceClock()
        let throttle = ObservationThrottle(interval: .milliseconds(200))

        let observations = model.observe(
            \.value,
            options: .rateLimit(.throttle(throttle)),
            clock: clock
        ) { value in
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observeTaskThrottleStartsInitialOperationWithoutExplicitYieldForNativeNonisolatedModel() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return
        }

        let model = CounterModel()
        let recorder = ValueRecorder<Int>()
        let clock = TestDebounceClock()
        let throttle = ObservationThrottle(interval: .milliseconds(200))

        let observations = model.observeTask(
            \.value,
            options: .rateLimit(.throttle(throttle)),
            clock: clock
        ) { value in
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder, nanoseconds: 1_000_000_000))
        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observeDebounceDelayedFirstWaitsForClockBeforeInitialValue() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .delayedFirst)

        let observations = model.observe(
            \.value,
            options: .rateLimit(.debounce(debounce)),
            clock: clock
        ) { value in
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        await clock.sleep(untilSuspendedBy: 1)
        #expect(recorder.snapshot().isEmpty)

        clock.advance(by: .milliseconds(200))
        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observeTaskDebounceImmediateFirstSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let observations = model.observeTask(
            \.value,
            options: .rateLimit(.debounce(debounce)),
            clock: clock
        ) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

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
    func observeTaskDebounceDelayedFirstSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .delayedFirst)

        let observations = model.observeTask(
            \.value,
            options: .rateLimit(.debounce(debounce)),
            clock: clock
        ) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 10
        model.value = 11
        await clock.sleep(untilSuspendedBy: 1)

        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(199))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 11)
    }

    @Test
    func observeTaskDebounceWithToleranceSupportsDeterministicClockBoundaryChecks() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(
            interval: .milliseconds(300),
            tolerance: .milliseconds(50),
            mode: .delayedFirst
        )

        let observations = model.observeTask(
            \.value,
            options: .rateLimit(.debounce(debounce)),
            clock: clock
        ) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(299))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 42
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(299))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 42)
    }

    @Test
    func observeTaskThrottleLatestSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let throttle = ObservationThrottle(interval: .milliseconds(200))

        let observations = model.observeTask(
            \.value,
            options: .rateLimit(.throttle(throttle)),
            clock: clock
        ) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

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
    func observeTaskThrottleEarliestSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let throttle = ObservationThrottle(
            interval: .milliseconds(200),
            mode: .earliest
        )

        let observations = model.observeTask(
            \.value,
            options: .rateLimit(.throttle(throttle)),
            clock: clock
        ) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 10
        await Task.yield()
        model.value = 11
        await Task.yield()
        model.value = 12

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 10)
    }

    @Test
    func observeTaskDebounceEmitsPostDebounceDuplicateOutputs() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let observations = model.observeTask(
            \.parity,
            options: .rateLimit(.debounce(debounce)),
            clock: clock
        ) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))

        #expect(await nextWithTimeout(from: queue) == 0)
    }

    @Test
    func observeTaskThrottleEmitsPostThrottleDuplicateOutputs() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let throttle = ObservationThrottle(interval: .milliseconds(200))

        let observations = model.observeTask(
            \.parity,
            options: .rateLimit(.throttle(throttle)),
            clock: clock
        ) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))

        #expect(await nextWithTimeout(from: queue) == 0)
    }

    @Test
    func makeThrottledValueStreamFlushesPendingLatestValueWhenSourceFinishes() async {
        let clock = TestDebounceClock()
        let queue = ValueQueue<Int>()
        let throttle = ObservationThrottle(interval: .milliseconds(200))
        let (source, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let throttled = makeThrottledValueStream(
            source,
            throttle: throttle,
            throttleClock: clock
        )

        let consumer = Task<Void, Never> {
            for await value in throttled {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        continuation.yield(0)
        #expect(await nextWithTimeout(from: queue) == 0)

        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(199))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 2)
    }

    @Test
    func forEachThrottledValueFinishesWhenSourceEndsDuringTimerDrain() async {
        let clock = TestDebounceClock()
        let started = ValueQueue<Int>()
        let sourceCanFinish = ValueQueue<Int>()
        let releaseSecondValue = ValueQueue<Int>()
        let finished = ValueQueue<Int>()
        let throttle = ObservationThrottle(interval: .milliseconds(200))

        let task = Task<Void, Never> {
            await forEachThrottledValue(
                throttle: throttle,
                clock: clock,
                emitReadyValuesInline: true
            ) { consumeValue in
                guard await consumeValue(0) else {
                    return
                }
                guard await consumeValue(1) else {
                    return
                }
                _ = await nextWithTimeout(from: sourceCanFinish)
            } consume: { value in
                await started.push(value)
                if value == 1 {
                    await sourceCanFinish.push(value)
                    _ = await releaseSecondValue.next()
                }
                return true
            }
            await finished.push(1)
        }
        defer { task.cancel() }

        #expect(await nextWithTimeout(from: started) == 0)
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: started) == 1)
        #expect(await nextWithTimeout(from: finished, nanoseconds: 120_000_000) == nil)

        await releaseSecondValue.push(1)
        #expect(await nextWithTimeout(from: finished) == 1)
    }

    @Test
    func throttleExecutionStatePreservesBoundaryEmissionOrderAcrossTimerExpiryRace() {
        var state = ThrottleExecutionState<Int>()
        state.recordIncomingValue(0, keepLatestPending: true)

        let initialAction = state.nextAction()
        let initialTimerToken: UInt64
        switch initialAction {
        case let .emit(value, timerToken, finishAfterEmit):
            #expect(value == 0)
            #expect(!finishAfterEmit)
            guard let timerToken else {
                Issue.record("expected initial throttle emission to schedule a timer")
                return
            }
            initialTimerToken = timerToken
        case .finish, .idle:
            Issue.record("expected initial throttle emission")
            return
        }

        state.recordIncomingValue(1, keepLatestPending: true)
        let initialTimerExpired = state.expireTimer(token: initialTimerToken)
        #expect(initialTimerExpired)

        // Simulate a post-boundary arrival racing in before the drain loop emits
        // the previous window's trailing value.
        state.recordIncomingValue(2, keepLatestPending: true)

        let boundaryAction = state.nextAction()
        let nextTimerToken: UInt64
        switch boundaryAction {
        case let .emit(value, timerToken, finishAfterEmit):
            #expect(value == 1)
            #expect(!finishAfterEmit)
            guard let timerToken else {
                Issue.record("expected boundary emission to schedule the next timer")
                return
            }
            nextTimerToken = timerToken
        case .finish, .idle:
            Issue.record("expected pending boundary value to emit before newer updates")
            return
        }

        state.finishSource()
        let nextTimerExpired = state.expireTimer(token: nextTimerToken)
        #expect(nextTimerExpired)

        let trailingAction = state.nextAction()
        switch trailingAction {
        case let .emit(value, timerToken, finishAfterEmit):
            #expect(value == 2)
            #expect(timerToken == nil)
            #expect(finishAfterEmit)
        case .finish, .idle:
            Issue.record("expected post-boundary update to remain queued for the next interval")
        }
    }

    @Test
    func observeTaskTriggerOnlyMultipleKeyPathSupportsDebounce() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let observations = model.observeTask(
            [\.value, \.isEnabled],
            options: .rateLimit(.debounce(debounce))
        ) {
            recorder.append(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 1
        model.value = 2
        model.isEnabled = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.count() == 1)

        #expect(await waitUntilCount(2, in: recorder))
    }
}
