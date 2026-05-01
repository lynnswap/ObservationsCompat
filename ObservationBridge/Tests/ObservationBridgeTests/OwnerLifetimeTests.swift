import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
final class OwnerLifetimeTests {
    @Test
    func legacyBackendReleasesObservedModelAfterTermination() async {
        let deinitFlag = DeinitFlag()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

            var stream: ObservationBridge<Int>? = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
                model.value
            }
            let capturedStream = stream

            let consumer = Task<Void, Never> {
                guard let capturedStream else {
                    return
                }
                var iterator = capturedStream.makeAsyncIterator()
                while await iterator.next() != nil {}
            }

            await Task.yield()
            consumer.cancel()
            await consumer.value
            stream = nil
        }

        await Task.yield()
        await Task.yield()
        #expect(weakModel == nil)
        #expect(await deinitFlag.didDeinit)
    }

    @Test
    func observationRegistrationWithoutStoreDoesNotRetainOwner() async {
        weak var weakModel: CounterModel?
        var registration: ObservationRegistration?

        do {
            let model = CounterModel()
            weakModel = model
            registration = model.observeTask(\.value, options: ObservationOptions()) { _ in }
        }

        withExtendedLifetime(registration) {
            #expect(weakModel == nil)
        }
    }

    @Test
    @MainActor
    func observeStoreInScopeCancelsWhenOwnerDeinitializes() async {
    #if canImport(ObjectiveC)
        let deinitFlag = DeinitFlag()
        var values: [Int] = []
        let observations = ObservationScope()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

            model.observe(\.value, options: ObservationOptions()) { value in
                values.append(value)
            }
            .store(in: observations)

            let initialDeadline = ContinuousClock().now + .seconds(2)
            while values.isEmpty, ContinuousClock().now < initialDeadline {
                await Task.yield()
            }
            #expect(values == [0])
        }

        let deinitDeadline = ContinuousClock().now + .seconds(2)
        while !(await deinitFlag.didDeinit), ContinuousClock().now < deinitDeadline {
            await Task.yield()
        }
        #expect(await deinitFlag.didDeinit)

        let ownerReleaseDeadline = ContinuousClock().now + .seconds(2)
        while weakModel != nil, ContinuousClock().now < ownerReleaseDeadline {
            await Task.yield()
        }
        #expect(weakModel == nil)

        observations.cancelAll()
    #else
        return
    #endif
    }

    @Test
    func observeStoreInScopeReleasesCallbackCapturesWhenOwnerDeinitializes() async {
    #if canImport(ObjectiveC)
        let ownerDeinitFlag = DeinitFlag()
        let captureDeinitFlag = DeinitFlag()
        let observations = ObservationScope()
        weak var weakCapture: CallbackCaptureProbe?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await ownerDeinitFlag.mark()
                }
            }
            let capture = CallbackCaptureProbe {
                Task {
                    await captureDeinitFlag.mark()
                }
            }
            weakCapture = capture

            model.observe(\.value, options: ObservationOptions()) { [capture] value in
                capture.record(value)
            }.store(in: observations)
        }

        let ownerDeinitDeadline = ContinuousClock().now + .seconds(2)
        while !(await ownerDeinitFlag.didDeinit), ContinuousClock().now < ownerDeinitDeadline {
            await Task.yield()
        }
        #expect(await ownerDeinitFlag.didDeinit)

        let captureDeinitDeadline = ContinuousClock().now + .seconds(2)
        while !(await captureDeinitFlag.didDeinit), ContinuousClock().now < captureDeinitDeadline {
            await Task.yield()
        }
        #expect(await captureDeinitFlag.didDeinit)
        #expect(weakCapture == nil)

        observations.cancelAll()
    #else
        return
    #endif
    }

    @Test
    func observeTaskStoreInScopeCancelsWhenOwnerDeinitializes() async {
    #if canImport(ObjectiveC)
        let started = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let deinitFlag = DeinitFlag()
        let gate = OperationGate()
        let observations = ObservationScope()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

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
            }
            .store(in: observations)

            #expect(await nextWithTimeout(from: started) == 0)
        }

        let deinitDeadline = ContinuousClock().now + .seconds(2)
        while !(await deinitFlag.didDeinit), ContinuousClock().now < deinitDeadline {
            await Task.yield()
        }
        #expect(await deinitFlag.didDeinit)

        let ownerReleaseDeadline = ContinuousClock().now + .seconds(2)
        while weakModel != nil, ContinuousClock().now < ownerReleaseDeadline {
            await Task.yield()
        }
        #expect(weakModel == nil)
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 2_000_000_000) == 0)

        observations.cancelAll()
    #else
        return
    #endif
    }

    @Test
    @MainActor
    func mainActorObservationScopeHolderReleaseStopsObserveAndObserveTaskPipelines() async {
        let model = MainActorCounterModel()
        var observedValues: [Int] = []
        var observedTaskValues: [Int] = []
        weak var weakHolder: MainActorObservationScopeHolder?

        do {
            let holder = MainActorObservationScopeHolder()
            weakHolder = holder

            model.observe(\.value, options: ObservationOptions()) { value in
                observedValues.append(value)
            }
            .store(in: holder.observations)

            model.observeTask(\.value, options: ObservationOptions()) { value in
                observedTaskValues.append(value)
            }
            .store(in: holder.observations)

            let initialDeadline = ContinuousClock().now + .seconds(2)
            while (observedValues.isEmpty || observedTaskValues.isEmpty), ContinuousClock().now < initialDeadline {
                await Task.yield()
            }
            #expect(observedValues == [0])
            #expect(observedTaskValues == [0])
        }

        let holderReleaseDeadline = ContinuousClock().now + .seconds(2)
        while weakHolder != nil, ContinuousClock().now < holderReleaseDeadline {
            await Task.yield()
        }
        #expect(weakHolder == nil)

        model.value = 7
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(observedValues == [0])
        #expect(observedTaskValues == [0])
    }

    @Test
    func observeTaskDoesNotPreventOwnerDeinit() async {
    #if canImport(ObjectiveC)
        let deinitFlag = DeinitFlag()
        let observations = ObservationScope()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

            model.observeTask(\.value, options: ObservationOptions()) {
            }.store(in: observations)
        }

        await Task.yield()
        await Task.yield()
        #expect(weakModel == nil)
        #expect(await deinitFlag.didDeinit)
        observations.cancelAll()
    #else
        return
    #endif
    }
}
