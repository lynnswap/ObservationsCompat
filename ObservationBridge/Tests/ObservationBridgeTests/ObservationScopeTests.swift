import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
final class ObservationScopeTests {
    @Test
    func observeTaskRegistrationWithoutStoreDoesNotStartObservation() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        _ = model.observeTask(\.value, options: ObservationOptions()) { value in
            await queue.push(value)
        }

        await Task.yield()
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskStoreInScopeKeepsObservationAlive() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        model.observeTask(\.value, options: ObservationOptions()) { value in
            await queue.push(value)
        }
        .store(in: observations)

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 9
        #expect(await nextWithTimeout(from: queue) == 9)
    }

    @Test
    func observeTaskStoreInScopeStopsAfterCancelAll() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let observations = ObservationScope()

        model.observeTask(\.value, options: ObservationOptions()) { value in
            await queue.push(value)
        }
        .store(in: observations)

        #expect(await nextWithTimeout(from: queue) == 0)

        observations.cancelAll()
        await Task.yield()

        model.value = 10
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskStoreInScopeCanCancelExplicitID() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let observations = ObservationScope()

        model.observeTask(\.value, id: "value", options: ObservationOptions()) { value in
            await queue.push(value)
        }.store(in: observations)

        #expect(await nextWithTimeout(from: queue) == 0)

        observations.cancel(id: "value")
        await Task.yield()

        model.value = 9
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationRegistrationStoresIndependentCallbackBoxesPerScope() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let firstScope = ObservationScope()
        let secondScope = ObservationScope()
        defer {
            firstScope.cancelAll()
            secondScope.cancelAll()
        }

        let registration = model.observeTask(\.value, options: ObservationOptions()) { value in
            await queue.push(value)
        }

        registration.store(in: firstScope)
        #expect(await nextWithTimeout(from: queue) == 0)

        registration.store(in: secondScope)
        #expect(await nextWithTimeout(from: queue) == 0)

        firstScope.cancelAll()
        await Task.yield()

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observationScopeCancelIDDuringInitialObserveCallbackPreventsSlotStorage() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = CounterModel()
        let holder = ObservationScopeCancellationProbe()
        let recorder = ValueRecorder<Int>()

        model.observe(\.value, id: "value", options: ObservationOptions()) { value in
            recorder.append(value)
            holder.cancel(id: "value")
        }.store(in: holder.observations)

        #expect(recorder.snapshot() == [0])

        model.value = 1
        await Task.yield()
        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observationScopeCancelIDDuringInitialReplacementCallbackPreventsSlotStorage() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = CounterModel()
        let holder = ObservationScopeCancellationProbe()
        let recorder = ValueRecorder<Int>()

        model.observe(\.value, id: "value", options: ObservationOptions()) { value in
            recorder.append(value)
        }.store(in: holder.observations)

        #expect(recorder.snapshot() == [0])

        model.observe(\.secondaryValue, id: "value", options: ObservationOptions()) { value in
            recorder.append(100 + value)
            holder.cancel(id: "value")
        }.store(in: holder.observations)

        #expect(recorder.snapshot() == [0, 100])

        model.value = 1
        model.secondaryValue = 1
        await Task.yield()
        #expect(recorder.snapshot() == [0, 100])
    }

    @Test
    func observationScopeStoreDuringInitialObserveCallbackDoesNotOverwriteReentrantSlot() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = CounterModel()
        let holder = ObservationScopeCancellationProbe()
        let recorder = ValueRecorder<Int>()
        let didReenter = Mutex(false)

        model.observe(\.value, id: "value", options: ObservationOptions()) { value in
            recorder.append(value)

            let shouldReenter = didReenter.withLock { didReenter in
                if didReenter {
                    return false
                }
                didReenter = true
                return true
            }

            if shouldReenter {
                model.observe(\.value, id: "value", options: ObservationOptions()) { value in
                    recorder.append(100 + value)
                }.store(in: holder.observations)
            }
        }.store(in: holder.observations)

        #expect(recorder.snapshot() == [0, 100])

        model.value = 1
        await Task.yield()
        #expect(recorder.snapshot() == [0, 100, 101])
    }

    @Test
    func observationScopeUpdateOmittingIDDuringInitialObserveCallbackPreventsSlotStorage() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = CounterModel()
        let holder = ObservationScopeCancellationProbe()
        let recorder = ValueRecorder<Int>()

        model.observe(\.value, id: "value", options: ObservationOptions()) { value in
            recorder.append(value)
            holder.observations.update {}
        }.store(in: holder.observations)

        #expect(recorder.snapshot() == [0])

        model.value = 1
        await Task.yield()
        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observationScopeCancelIDDuringBatchedInitialCallbackPreventsPendingSlotStorage() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = CounterModel()
        let holder = ObservationScopeCancellationProbe()
        let recorder = ValueRecorder<Int>()

        holder.observations.update {
            model.observe(\.value, id: "first", options: ObservationOptions()) { value in
                recorder.append(value)
                holder.cancel(id: "second")
            }.store(in: holder.observations)

            model.observe(\.secondaryValue, id: "second", options: ObservationOptions()) { value in
                recorder.append(100 + value)
            }.store(in: holder.observations)
        }

        model.secondaryValue = 1
        await Task.yield()
        #expect(!recorder.snapshot().contains(101))
    }

    @Test
    func observationScopeReentrantStoreDuringBatchedInitialCallbackWinsOverPendingDeclaration() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = CounterModel()
        let holder = ObservationScopeCancellationProbe()
        let recorder = ValueRecorder<Int>()

        holder.observations.update {
            model.observe(\.value, id: "first", options: ObservationOptions()) { _ in
                model.observe(\.secondaryValue, id: "second", options: ObservationOptions()) { value in
                    recorder.append(200 + value)
                }.store(in: holder.observations)
            }.store(in: holder.observations)

            model.observe(\.secondaryValue, id: "second", options: ObservationOptions()) { value in
                recorder.append(100 + value)
            }.store(in: holder.observations)
        }

        model.secondaryValue = 1
        await Task.yield()
        let values = recorder.snapshot()
        #expect(values.contains(201))
        #expect(!values.contains(101))
    }

    @Test
    func observationScopeCancelAllDuringInitialObserveCallbackPreventsSlotStorage() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = CounterModel()
        let holder = ObservationScopeCancellationProbe()
        let recorder = ValueRecorder<Int>()

        model.observe(\.value, options: ObservationOptions()) { value in
            recorder.append(value)
            holder.cancelAll()
        }.store(in: holder.observations)

        #expect(recorder.snapshot() == [0])

        model.value = 1
        await Task.yield()
        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observationScopeUpdateKeepsInFlightTaskForSameAutomaticID() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let started = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()
        defer {
            observations.cancelAll()
        }

        func bind() {
            observations.update {
                model.observeTask(\.value, options: ObservationOptions()) { value in
                    await started.push(value)
                    await withTaskCancellationHandler {
                        await gate.wait(for: value)
                    } onCancel: {
                        Task {
                            await cancelled.push(value)
                            await gate.release(value)
                        }
                    }
                }.store(in: observations)
            }
        }

        bind()
        #expect(await nextWithTimeout(from: started) == 0)

        bind()
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)

        await gate.release(0)
    }

    @Test
    func observationScopeUpdateKeepsInFlightTaskForEquivalentDynamicKeyPath() async {
        let model = NestedCounterModel()
        let observations = ObservationScope()
        let started = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()
        defer {
            observations.cancelAll()
        }

        func makeKeyPath() -> KeyPath<NestedCounterModel, Int> {
            (\NestedCounterModel.payload).appending(path: \NestedCounterPayload.value)
        }

        func bind() {
            observations.update {
                model.observeTask(makeKeyPath(), options: ObservationOptions()) { value in
                    await started.push(value)
                    await withTaskCancellationHandler {
                        await gate.wait(for: value)
                    } onCancel: {
                        Task {
                            await cancelled.push(value)
                            await gate.release(value)
                        }
                    }
                }.store(in: observations)
            }
        }

        bind()
        #expect(await nextWithTimeout(from: started) == 0)

        bind()
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)

        await gate.release(0)
    }

    @Test
    func observationScopeUpdateReplacesCallbackForSameAutomaticID() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let firstQueue = ValueQueue<Int>()
        let secondQueue = ValueQueue<Int>()
        var usesSecondQueue = false
        defer {
            observations.cancelAll()
        }

        func bind() {
            let targetQueue = usesSecondQueue ? secondQueue : firstQueue
            observations.update {
                model.observeTask(\.value, options: ObservationOptions()) { value in
                    await targetQueue.push(value)
                }.store(in: observations)
            }
        }

        bind()
        #expect(await nextWithTimeout(from: firstQueue) == 0)

        usesSecondQueue = true
        bind()

        model.value = 1
        #expect(await nextWithTimeout(from: secondQueue) == 1)
        #expect(await nextWithTimeout(from: firstQueue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationScopeUpdateCancelsMissingDeclaration() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let queue = ValueQueue<Int>()

        observations.update {
            model.observeTask(\.value, options: ObservationOptions()) { value in
                await queue.push(value)
            }.store(in: observations)
        }
        #expect(await nextWithTimeout(from: queue) == 0)

        observations.update {}
        await Task.yield()

        model.value = 1
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationScopeUpdateUsesLastDeclarationForDuplicateID() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let firstQueue = ValueQueue<Int>()
        let secondQueue = ValueQueue<Int>()
        defer {
            observations.cancelAll()
        }

        observations.update {
            model.observeTask(\.value, id: "value", options: ObservationOptions()) { value in
                await firstQueue.push(value)
            }.store(in: observations)

            model.observeTask(\.value, id: "value", options: ObservationOptions()) { value in
                await secondQueue.push(value)
            }.store(in: observations)
        }

        #expect(await nextWithTimeout(from: secondQueue) == 0)
        #expect(await nextWithTimeout(from: firstQueue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationScopeCancelIDInsideUpdateBodyRemovesQueuedDeclaration() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let queue = ValueQueue<Int>()

        observations.update {
            model.observeTask(\.value, id: "value", options: ObservationOptions()) { value in
                await queue.push(value)
            }.store(in: observations)

            observations.cancel(id: "value")
        }

        await Task.yield()
        model.value = 1
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationScopeCancelAllInsideUpdateBodyRemovesQueuedDeclarations() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let queue = ValueQueue<Int>()

        observations.update {
            model.observeTask(\.value, id: "value", options: ObservationOptions()) { value in
                await queue.push(value)
            }.store(in: observations)

            observations.cancelAll()
        }

        await Task.yield()
        model.value = 1
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationScopeUpdateRestartsWhenDescriptorChanges() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let firstStarted = ValueQueue<Int>()
        let firstCancelled = ValueQueue<Int>()
        let secondStarted = ValueQueue<Int>()
        let gate = OperationGate()
        defer {
            observations.cancelAll()
        }

        observations.update {
            model.observeTask(\.value, id: "counter", options: ObservationOptions()) { value in
                await firstStarted.push(value)
                await withTaskCancellationHandler {
                    await gate.wait(for: value)
                } onCancel: {
                    Task {
                        await firstCancelled.push(value)
                        await gate.release(value)
                    }
                }
            }.store(in: observations)
        }
        #expect(await nextWithTimeout(from: firstStarted) == 0)

        observations.update {
            model.observeTask(\.secondaryValue, id: "counter", options: ObservationOptions()) { value in
                await secondStarted.push(value)
            }.store(in: observations)
        }

        #expect(await nextWithTimeout(from: firstCancelled, nanoseconds: 2_000_000_000) == 0)
        #expect(await nextWithTimeout(from: secondStarted) == 0)
    }

    @Test
    func observationScopeUpdateRestartsRateLimitedPipelineWhenClockChanges() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let firstClock = TestDebounceClock()
        let secondClock = TestDebounceClock()
        let firstQueue = ValueQueue<Int>()
        let secondQueue = ValueQueue<Int>()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .delayedFirst)
        let options: ObservationOptions = .rateLimit(.debounce(debounce))
        defer {
            observations.cancelAll()
        }

        func bind(clock: TestDebounceClock, queue: ValueQueue<Int>) {
            observations.update {
                model.observeTask(\.value, id: "counter", options: options, clock: clock) { value in
                    await queue.push(value)
                }.store(in: observations)
            }
        }

        bind(clock: firstClock, queue: firstQueue)
        let firstPipelineSuspended = await waitWithTimeout(nanoseconds: 1_000_000_000) {
            await firstClock.sleep(untilSuspendedBy: 1)
            return true
        }
        #expect(firstPipelineSuspended == true)

        bind(clock: secondClock, queue: secondQueue)
        let secondPipelineSuspended = await waitWithTimeout(nanoseconds: 1_000_000_000) {
            await secondClock.sleep(untilSuspendedBy: 1)
            return true
        }
        #expect(secondPipelineSuspended == true)

        secondClock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: secondQueue) == 0)

        firstClock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: firstQueue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationScopeDescriptorTracksActorIsolationChanges() {
        let model = CounterModel()
        let firstIsolation = CallbackIsolationActor()
        let secondIsolation = CallbackIsolationActor()
        let firstDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: ObservationOptions(),
            clock: ContinuousClock(),
            isolation: firstIsolation,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Int.self
        )
        let equivalentDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: ObservationOptions(),
            clock: ContinuousClock(),
            isolation: firstIsolation,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Int.self
        )
        let changedIsolationDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: ObservationOptions(),
            clock: ContinuousClock(),
            isolation: secondIsolation,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Int.self
        )
        let observeDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: ObservationOptions(),
            clock: ContinuousClock(),
            isolation: firstIsolation,
            callbackIsolation: nil,
            kind: .observeValue,
            valueType: Int.self
        )
        let changedCallbackIsolationDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: ObservationOptions(),
            clock: ContinuousClock(),
            isolation: firstIsolation,
            callbackIsolation: secondIsolation,
            kind: .observeValue,
            valueType: Int.self
        )

        #expect(firstDescriptor == equivalentDescriptor)
        #expect(firstDescriptor != changedIsolationDescriptor)
        #expect(observeDescriptor != changedCallbackIsolationDescriptor)
    }

    @Test
    func observationScopeDescriptorTracksValueClockChanges() {
        let model = CounterModel()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .delayedFirst)
        let options: ObservationOptions = .rateLimit(.debounce(debounce))
        let firstDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: options,
            clock: DescriptorValueClock(id: 1),
            isolation: nil,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Int.self
        )
        let equivalentDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: options,
            clock: DescriptorValueClock(id: 1),
            isolation: nil,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Int.self
        )
        let changedClockDescriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: model,
            keyPath: \.value,
            options: options,
            clock: DescriptorValueClock(id: 2),
            isolation: nil,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Int.self
        )

        #expect(firstDescriptor == equivalentDescriptor)
        #expect(firstDescriptor != changedClockDescriptor)
    }
}
