import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
final class NonSendableObservationTests {
    @Test
    func hasSameObservationIsolationRejectsNonisolatedPairs() {
        let lhs = CallbackIsolationActor()
        let rhs = CallbackIsolationActor()

        #expect(hasSameObservationIsolation(nil, nil) == false)
        #expect(hasSameObservationIsolation(lhs, nil) == false)
        #expect(hasSameObservationIsolation(nil, lhs) == false)
        #expect(hasSameObservationIsolation(lhs, lhs))
        #expect(hasSameObservationIsolation(lhs, rhs) == false)
    }

    @Test
    @MainActor
    func observeSupportsNonSendableValuesOnMainActorIsolation() async {
        let model = MainActorNonSendablePayloadModel()
        var observedValues: [Int] = []

        let observations = model.observe(\.payload, options: ObservationOptions()) { payload in
            MainActor.assertIsolated()
            observedValues.append(payload.value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilMainActorCondition { observedValues.count == 1 })
        #expect(observedValues.first == 0)

        model.payload = NonSendablePayload(value: 1)
        #expect(await waitUntilMainActorCondition { observedValues.count == 2 })
        #expect(observedValues.prefix(2).elementsEqual([0, 1]))
    }

    @Test
    @MainActor
    func observeTaskSupportsNonSendableValuesOnMainActorIsolation() async {
        let model = MainActorNonSendablePayloadModel()
        var observedValues: [Int] = []

        let observations = model.observeTask(\.payload, options: ObservationOptions()) { payload in
            MainActor.assertIsolated()
            observedValues.append(payload.value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilMainActorCondition { observedValues.count == 1 })
        #expect(observedValues.first == 0)

        model.payload = NonSendablePayload(value: 2)
        #expect(await waitUntilMainActorCondition { observedValues.count == 2 })
        #expect(observedValues.prefix(2).elementsEqual([0, 2]))
    }

    @Test
    @MainActor
    func observeTaskSupportsSequentialNonSendableValuesOnMainActorIsolation() async {
        let model = MainActorNonSendablePayloadModel()
        var observedValues: [Int] = []

        let observations = model.observeTask(\.payload, options: ObservationOptions()) { payload in
            observedValues.append(payload.value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await waitUntilMainActorCondition { observedValues.count == 1 })
        #expect(observedValues.first == 0)

        model.payload = NonSendablePayload(value: 1)
        #expect(await waitUntilMainActorCondition { observedValues.count == 2 })
        #expect(observedValues.prefix(2).elementsEqual([0, 1]))

        model.payload = NonSendablePayload(value: 2)
        #expect(await waitUntilMainActorCondition { observedValues.count == 3 })
        #expect(observedValues.prefix(3).elementsEqual([0, 1, 2]))
    }

    @Test
    @MainActor
    func observeTaskCoalescesBurstNonSendableValuesWhileCurrentTaskIsRunning() async {
        let model = MainActorNonSendablePayloadModel()
        let started = ValueQueue<Int>()
        let completed = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()

        let observations = model.observeTask(\.payload, options: ObservationOptions()) { payload in
            let payloadValue = payload.value
            await started.push(payloadValue)
            await withTaskCancellationHandler {
                await gate.wait(for: payloadValue)
                guard !Task.isCancelled else {
                    return
                }
                await completed.push(payloadValue)
            } onCancel: {
                Task {
                    await cancelled.push(payloadValue)
                    await gate.release(payloadValue)
                }
            }
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: started) == 0)

        model.payload = NonSendablePayload(value: 1)
        await Task.yield()
        model.payload = NonSendablePayload(value: 2)
        await Task.yield()
        model.payload = NonSendablePayload(value: 3)
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
    @MainActor
    func observeTaskCancelsInFlightNonSendableTaskOnScopeCancelAll() async {
        let model = MainActorNonSendablePayloadModel()
        let started = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let gate = OperationGate()
        let observations = ObservationScope()

        model.observeTask(\.payload, options: ObservationOptions()) { payload in
            let payloadValue = payload.value
            await started.push(payloadValue)
            await withTaskCancellationHandler {
                await gate.wait(for: payloadValue)
            } onCancel: {
                Task {
                    await cancelled.push(payloadValue)
                    await gate.release(payloadValue)
                }
            }
        }.store(in: observations)

        #expect(await nextWithTimeout(from: started) == 0)

        observations.cancelAll()

        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 2_000_000_000) == 0)
    }
}
