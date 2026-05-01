import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite(.serialized)
final class ObservationBridgeStressTests {
    @Test
    func legacyBackendObserveTaskStressNoRaceAcrossOneMillionIterations() async {
    let iterations = 1_000_000
    let seed = stressSeed(default: 0x26_00_00_00_00_00_00_01)
    let result = await runRandomizedObservationStress(iterations: iterations, seed: seed) { model, observations, onObserved in
        model.observeTask(\.value, options: legacyOptionsForCurrentRuntime()) { value in
            onObserved(value)
        }.store(in: observations)
    }

    if !result.completed || result.firstFailure != nil {
        Issue.record(
            "stress seed: \(seed), workers: \(result.workers), failure: \(result.firstFailure ?? "none")"
        )
    }
    #expect(result.completed)
    #expect(result.firstFailure == nil)
    }

    @Test
    func defaultBackendObserveTaskStressNoRaceAcrossOneMillionIterationsOnModernOS() async {
    if #unavailable(iOS 26.0, macOS 26.0) {
        return
    }

    let iterations = 1_000_000
    let seed = stressSeed(default: 0x26_00_00_00_00_00_00_02)
    let result = await runRandomizedObservationStress(iterations: iterations, seed: seed) { model, observations, onObserved in
        model.observeTask(\.value, options: ObservationOptions()) { value in
            onObserved(value)
        }.store(in: observations)
    }

    if !result.completed || result.firstFailure != nil {
        Issue.record(
            "native stress seed: \(seed), workers: \(result.workers), failure: \(result.firstFailure ?? "none")"
        )
    }
    #expect(result.completed)
    #expect(result.firstFailure == nil)
    }

    @Test
    @MainActor
    func mainActorObservationScopeHolderReleaseStressDoesNotCrash() async {
#if canImport(ObjectiveC)
    for iteration in 0..<200 {
        let model = MainActorCounterModel()
        weak var weakHolder: MainActorObservationScopeHolder?
        var observeCount = 0
        var observeTaskCount = 0

        do {
            let holder = MainActorObservationScopeHolder()
            weakHolder = holder

            model.observe(\.value, options: ObservationOptions()) { _ in
                observeCount += 1
            }
            .store(in: holder.observations)

            model.observeTask(\.value, options: ObservationOptions()) { _ in
                observeTaskCount += 1
            }
            .store(in: holder.observations)

            let initialDeadline = ContinuousClock().now + .seconds(2)
            while (observeCount == 0 || observeTaskCount == 0), ContinuousClock().now < initialDeadline {
                await Task.yield()
            }
        }

        let releaseDeadline = ContinuousClock().now + .seconds(2)
        while weakHolder != nil, ContinuousClock().now < releaseDeadline {
            await Task.yield()
        }

        #expect(weakHolder == nil, "iteration \(iteration)")
        #expect(observeCount > 0, "iteration \(iteration)")
        #expect(observeTaskCount > 0, "iteration \(iteration)")
    }
#else
    return
#endif
    }
}
