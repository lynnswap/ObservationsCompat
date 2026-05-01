import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
final class ObserveCallbackTests {
    @Test
    func observeEmitsInitialAndDuplicateValuesByDefault() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let observations = model.observeTask(\.parity, options: ObservationOptions()) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        await Task.yield()
        model.value = 3
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeSingleKeyPathNoArgEmitsInitialAndSubsequentChanges() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let observations = model.observe(\.value, options: ObservationOptions()) {
            recorder.append(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 4
        #expect(await waitUntilCount(2, in: recorder))

        model.value = 9
        #expect(await waitUntilCount(3, in: recorder))
    }

    @Test
    func observeNoRateLimitRecordsInitialValueBeforeReturnForNativeNonisolatedModel() async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return
        }

        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let observations = model.observe(\.value, options: ObservationOptions()) { value in
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(recorder.snapshot() == [0])
    }

    @Test
    func observeOptionalKeyPathEmitsInitialNilAndTransitions() async {
        let model = OptionalCounterModel()
        let recorder = ValueRecorder<Int?>()

        let observations = model.observe(\.value, options: ObservationOptions()) { value in
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [nil])

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 1)

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))

        model.value = nil
        #expect(await waitUntilCount(3, in: recorder))
        #expect(recorder.snapshot().prefix(3).elementsEqual([nil, 1, nil]))

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 3)
    }

    @Test
    @MainActor
    func observeMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let recorder = ValueRecorder<Int>()
        let observations = model.observe(\.value, options: ObservationOptions()) { value in
            MainActor.assertIsolated()
            recorder.append(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [0])

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot().prefix(2).elementsEqual([0, 1]))
    }

    @Test
    @MainActor
    func observeNoArgMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let recorder = ValueRecorder<Int>()
        let observations = model.observe(\.value, options: ObservationOptions()) {
            MainActor.assertIsolated()
            recorder.append(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))

        model.value = 1
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 2)
    }

    @Test
    @MainActor
    func observeImplPrefersValueIsolationOverCallbackIsolation() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let callbackIsolation = CallbackIsolationActor()
        let readMainActorValue: @isolated(any) @Sendable (MainActorCounterModel) -> Int = { @MainActor owner in
            owner.value
        }
        #expect(readMainActorValue.isolation != nil)

        let handle = observeImpl(
            owner: model,
            options: ObservationOptions(),
            rateLimit: nil,
            rateLimitClock: ContinuousClock(),
            isolation: callbackIsolation,
            callbackIsolation: callbackIsolation,
            of: readMainActorValue,
            onChange: { value in
                await callbackIsolation.handle(value, queue: queue)
            }
        )
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeSupportsMultipleKeyPathsAsTriggerOnly() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let observations = model.observe([\.value, \.isEnabled], options: ObservationOptions()) {
            recorder.append(1)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 4
        #expect(await waitUntilCount(2, in: recorder))

        model.isEnabled = true
        #expect(await waitUntilCount(3, in: recorder))
    }
}
