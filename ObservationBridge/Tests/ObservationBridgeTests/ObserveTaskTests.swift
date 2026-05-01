import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
final class ObserveTaskTests {
    @Test
    func observeTaskSingleKeyPathNoArgEmitsInitialAndSubsequentChanges() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let observations = model.observeTask(\.value, options: ObservationOptions()) {
            await queue.push(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 10
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 11
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeTaskNoRateLimitStartsInitialOperationWithoutExplicitYieldForNativeNonisolatedModel() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return
        }

        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let observations = model.observeTask(\.value, options: ObservationOptions()) { value in
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder, nanoseconds: 1_000_000_000))
        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observeTaskNoRateLimitSynchronousInitialOperationDoesNotDeadlock() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return
        }

        let recorder = ValueRecorder<Int>()
        for iteration in 0..<20 {
            let model = CounterModel()
            model.value = iteration

            let observations = model.observeTask(\.value, options: ObservationOptions()) { value in
                recorder.append(value)
            }.storedForTest()

            #expect(await waitUntilCount(iteration + 1, in: recorder, nanoseconds: 1_000_000_000))
            observations.cancelAll()
        }
    }

    @Test
    func observeTaskNoRateLimitImmediateCancelDoesNotLeakStartingOperation() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return
        }

        for _ in 0..<20 {
            let model = CounterModel()
            let started = ValueQueue<Int>()
            let cancelled = ValueQueue<Int>()

            let observations = model.observeTask(\.value, options: ObservationOptions()) { value in
                await started.push(value)
                await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                } onCancel: {
                    Task {
                        await cancelled.push(value)
                    }
                }
            }.storedForTest()

            observations.cancelAll()

            guard let startedValue = await nextWithTimeout(from: started, nanoseconds: 100_000_000) else {
                continue
            }
            #expect(startedValue == 0)
            #expect(await nextWithTimeout(from: cancelled, nanoseconds: 2_000_000_000) == 0)
        }
    }

    @Test
    func observeTaskOptionalKeyPathNoArgIgnoresUnchangedNilAssignments() async {
        let model = OptionalCounterModel()
        let recorder = ValueRecorder<Int>()

        let observations = model.observeTask(\.value, options: ObservationOptions()) {
            recorder.append(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 1)

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))

        model.value = nil
        #expect(await waitUntilCount(3, in: recorder))

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 3)
    }

    @Test
    @MainActor
    func observeTaskMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let observations = model.observeTask(\.value, options: ObservationOptions()) { value in
            MainActor.assertIsolated()
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 1
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    @MainActor
    func observeTaskNoArgMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let observations = model.observeTask(\.value, options: ObservationOptions()) {
            MainActor.assertIsolated()
            await queue.push(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 1
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    @MainActor
    func observeTaskKeyPathGetterDoesNotUseCallbackActorIsolation() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let observations = model.observeTask(\.value, options: ObservationOptions()) { @AlternateGlobalActor value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 0)

        await MainActor.run {
            model.value = 1
        }
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeTaskSupportsMultipleKeyPaths() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let observations = model.observeTask([\.value, \.isEnabled], options: ObservationOptions()) {
            recorder.append(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.count() == 1)

        model.value = 4
        #expect(await waitUntilCount(2, in: recorder))

        model.isEnabled = true
        #expect(await waitUntilCount(3, in: recorder))
    }

    @Test
    func observeTaskStopsAfterScopeCancelAll() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let observations = ObservationScope()

        model.observeTask(\.value, options: ObservationOptions()) { value in
            await queue.push(value)
        }.store(in: observations)

        #expect(await nextWithTimeout(from: queue) == 0)

        observations.cancelAll()
        await Task.yield()

        model.value = 10
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskCancelsInFlightTaskOnScopeCancelAll() async {
        let model = CounterModel()
        let started = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()
        let observations = ObservationScope()

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

        #expect(await nextWithTimeout(from: started) == 0)

        observations.cancelAll()

        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 2_000_000_000) == 0)
    }

    @Test
    func observeTaskCompletesInFlightTasksInOrder() async {
        let model = CounterModel()
        let started = ValueQueue<Int>()
        let completed = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()

        let observations = model.observeTask(\.value, options: ObservationOptions()) { value in
            await started.push(value)
            await withTaskCancellationHandler {
                await gate.wait(for: value)
                guard !Task.isCancelled else {
                    return
                }
                await completed.push(value)
            } onCancel: {
                Task {
                    await cancelled.push(value)
                    await gate.release(value)
                }
            }
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: started) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)

        await gate.release(0)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 0)
        #expect(await nextWithTimeout(from: started, nanoseconds: 15_000_000_000) == 1)

        model.value = 2
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)

        await gate.release(1)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 1)
        #expect(await nextWithTimeout(from: started, nanoseconds: 15_000_000_000) == 2)

        await gate.release(2)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 2)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 300_000_000) == nil)
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskCoalescesBurstValuesWhileCurrentTaskIsRunning() async {
        let model = CounterModel()
        let started = ValueQueue<Int>()
        let completed = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()

        let observations = model.observeTask(\.value, options: ObservationOptions()) { value in
            await started.push(value)
            await withTaskCancellationHandler {
                await gate.wait(for: value)
                guard !Task.isCancelled else {
                    return
                }
                await completed.push(value)
            } onCancel: {
                Task {
                    await cancelled.push(value)
                    await gate.release(value)
                }
            }
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: started) == 0)

        model.value = 1
        await Task.yield()
        model.value = 2
        await Task.yield()
        model.value = 3
        await Task.yield()

        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)

        await gate.release(0)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 0)
        #expect(await nextWithTimeout(from: started, nanoseconds: 15_000_000_000) == 1)

        await gate.release(1)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 1)
        #expect(await nextWithTimeout(from: started, nanoseconds: 15_000_000_000) == 3)

        await gate.release(3)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 3)
        #expect(await nextWithTimeout(from: started, nanoseconds: 300_000_000) == nil)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 300_000_000) == nil)
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskDebounceProcessesSelectedValuesWithoutCancellation() async {
        let model = CounterModel()
        let started = ValueQueue<Int>()
        let completed = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()
        let debounce = ObservationDebounce(interval: .milliseconds(150), mode: .immediateFirst)

        let observations = model.observeTask(
            \.value,
            options: .rateLimit(.debounce(debounce))
        ) { value in
            await started.push(value)
            await withTaskCancellationHandler {
                await gate.wait(for: value)
                guard !Task.isCancelled else {
                    return
                }
                await completed.push(value)
            } onCancel: {
                Task {
                    await cancelled.push(value)
                    await gate.release(value)
                }
            }
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: started) == 0)

        model.value = 1
        model.value = 2
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)

        await gate.release(0)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 0)
        #expect(await nextWithTimeout(from: started, nanoseconds: 15_000_000_000) == 2)

        await gate.release(2)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 2)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 300_000_000) == nil)
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 300_000_000) == nil)
    }
}
