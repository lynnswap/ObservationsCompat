import Observation
import Testing
@testable import ObservationBridge

private struct ScopePass: Sendable, Equatable {
    let kind: ObservationEvent.Kind
    let value: Int
    let isEnabled: Bool
}

private final class WeakDeinitProbeModelBox: @unchecked Sendable {
    weak var model: DeinitProbeCounterModel?
}

@Suite
final class ObservationScopeObserveTests {
    @Test
    func observationEventKindStaticValuesAreEquatable() {
        #expect(ObservationEvent.Kind.initial == .initial)
        #expect(ObservationEvent.Kind.didSet == .didSet)
        #expect(ObservationEvent.Kind.initial != .didSet)
        #expect(String(describing: ObservationEvent.Kind.didSet) == "didSet")
    }

    @Test
    func observeStartsImmediatelyAndTracksPropertiesReadByCallback() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<ScopePass>()
        defer { observations.cancelAll() }

        observations.observe(model) { event, model in
            recorder.append(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.isEnabled
                )
            )
        }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot().last == ScopePass(kind: .didSet, value: 1, isEnabled: false))

        model.isEnabled = true
        #expect(await waitUntilCount(3, in: recorder))
        #expect(recorder.snapshot().last == ScopePass(kind: .didSet, value: 1, isEnabled: true))
    }

    @Test
    func didSetPassReadsValueAfterMutationBody() async {
        let model = DelayedMutationCounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<ScopePass>()
        defer { observations.cancelAll() }

        observations.observe(model) { event, model in
            recorder.append(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
        }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 7
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot().last == ScopePass(kind: .didSet, value: 7, isEnabled: false))
    }

    @Test
    func emptyOptionsDeliverOnlyInitialEvent() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<ScopePass>()
        defer { observations.cancelAll() }

        observations.observe(model, options: []) { event, model in
            recorder.append(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.isEnabled
                )
            )
        }

        #expect(await waitUntilCount(1, in: recorder))
        model.value = 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @Test
    func repeatedObserveFromSameCallSiteReplacesCallbackWithoutDuplicatingPipeline() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<String>()
        defer { observations.cancelAll() }

        installReplacingObservation(
            observations: observations,
            model: model,
            label: "first",
            recorder: recorder
        )
        #expect(await waitUntilCount(1, in: recorder))

        installReplacingObservation(
            observations: observations,
            model: model,
            label: "second",
            recorder: recorder
        )

        #expect(await waitUntilCount(2, in: recorder))
        model.value = 1
        #expect(await waitUntilCount(3, in: recorder))
        #expect(recorder.snapshot() == ["first:initial:0", "second:initial:0", "second:didSet:1"])
    }

    @Test
    func repeatedObserveFromSameCallSiteRetracksReplacementCallbackBody() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<String>()
        defer { observations.cancelAll() }

        installReplacingObservation(
            observations: observations,
            model: model,
            readTarget: .value,
            label: "value",
            recorder: recorder
        )
        #expect(await waitUntilCount(1, in: recorder))

        installReplacingObservation(
            observations: observations,
            model: model,
            readTarget: .isEnabled,
            label: "enabled",
            recorder: recorder
        )
        #expect(await waitUntilCount(2, in: recorder))

        model.isEnabled = true
        #expect(await waitUntilCount(3, in: recorder))
        model.value = 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(
            recorder.snapshot() == [
                "value:initial:value:0",
                "enabled:initial:isEnabled:false",
                "enabled:didSet:isEnabled:true",
            ]
        )
    }

    @Test
    func repeatedObserveFromSameCallSiteWithDifferentOptionsReplacesPipeline() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<String>()
        defer { observations.cancelAll() }

        installReplacingObservation(
            observations: observations,
            model: model,
            options: [],
            label: "initial",
            recorder: recorder
        )
        #expect(await waitUntilCount(1, in: recorder))

        installReplacingObservation(
            observations: observations,
            model: model,
            options: .didSet,
            label: "did",
            recorder: recorder
        )
        #expect(await waitUntilCount(2, in: recorder))

        model.value = 1
        #expect(await waitUntilCount(3, in: recorder))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.snapshot() == ["initial:initial:0", "did:initial:0", "did:didSet:1"])
    }

    @Test
    func repeatedObserveFromSameCallSiteWithDifferentOwnerReplacesPipeline() async {
        let first = CounterModel()
        let second = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<String>()
        defer { observations.cancelAll() }

        installReplacingObservation(
            observations: observations,
            model: first,
            label: "first",
            recorder: recorder
        )
        #expect(await waitUntilCount(1, in: recorder))

        installReplacingObservation(
            observations: observations,
            model: second,
            label: "second",
            recorder: recorder
        )
        #expect(await waitUntilCount(2, in: recorder))

        first.value = 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.snapshot() == ["first:initial:0", "second:initial:0"])

        second.value = 2
        #expect(await waitUntilCount(3, in: recorder))
        #expect(recorder.snapshot() == ["first:initial:0", "second:initial:0", "second:didSet:2"])
    }

    @Test
    func cancelAllStopsLaterEvents() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<ScopePass>()

        observations.observe(model) { event, model in
            recorder.append(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.isEnabled
                )
            )
        }

        #expect(await waitUntilCount(1, in: recorder))
        observations.cancelAll()

        model.value = 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @Test
    func eventCancelStopsCurrentObservationOnly() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<ObservationEvent.Kind>()
        defer { observations.cancelAll() }

        observations.observe(model) { event, model in
            recorder.append(event.kind)
            _ = model.value
            event.cancel()
        }

        #expect(await waitUntilCount(1, in: recorder))
        model.value = 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.snapshot() == [.initial])
    }

    @Test
    func cancelAllDuringInitialCallbackStopsCurrentObservation() async {
        let model = CounterModel()
        let probe = ObservationScopeCancellationProbe()
        let observations = probe.observations
        let recorder = ValueRecorder<ObservationEvent.Kind>()
        defer { observations.cancelAll() }

        observations.observe(model) { event, model in
            recorder.append(event.kind)
            _ = model.value
            probe.cancelAll()
        }

        #expect(await waitUntilCount(1, in: recorder))
        model.value = 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.snapshot() == [.initial])
    }

    @Test
    func initialOnlyObservationReleasesCallbackAfterNaturalCompletion() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<Int>()
        let didDeinit = DeinitFlag()

        do {
            let probe = CallbackCaptureProbe {
                Task {
                    await didDeinit.mark()
                }
            }
            observations.observe(model, options: []) { _, model in
                probe.record(model.value)
                recorder.append(model.value)
            }
            #expect(await waitUntilCount(1, in: recorder))
        }

        let releasedCallbackCapture = await waitWithTimeout {
            while !(await didDeinit.didDeinit) {
                if Task.isCancelled {
                    return false
                }
                await Task.yield()
            }
            return true
        }
        #expect(releasedCallbackCapture == true)
        observations.cancelAll()
    }

    @Test
    func observeDoesNotRetainOwner() async {
        let observations = ObservationScope()
        let didDeinit = DeinitFlag()
        let weakModel = WeakDeinitProbeModelBox()

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await didDeinit.mark()
                }
            }
            weakModel.model = model
            observations.observe(model) { _, model in
                _ = model.value
            }
            #expect(await waitUntilCondition { weakModel.model != nil })
        }

        #expect(await waitUntilCondition { weakModel.model == nil })
        let observedDeinit = await waitWithTimeout {
            while !(await didDeinit.didDeinit) {
                if Task.isCancelled {
                    return false
                }
                await Task.yield()
            }
            return true
        }
        #expect(observedDeinit == true)
        observations.cancelAll()
    }

    @MainActor
    @Test
    func observeSupportsMainActorNonSendableValues() async {
        let model = MainActorNonSendablePayloadModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<Int>()
        defer { observations.cancelAll() }

        observations.observe(model) { _, model in
            MainActor.assertIsolated()
            recorder.append(model.payload.value)
        }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [0])

        model.payload = NonSendablePayload(value: 2)
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot() == [0, 2])
    }

    @Test
    func observeUsesCustomActorIsolationForCallbacks() async {
        let model = CounterModel()
        let probe = CustomActorObservationProbe()

        await probe.observe(model)
        #expect(await waitUntilValues([0], in: probe))

        model.value = 4
        #expect(await waitUntilValues([0, 4], in: probe))
        await probe.cancelAll()
    }

    @Test
    func observeHopsToExplicitCustomActorIsolation() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let probe = CustomActorObservationProbe()
        defer { observations.cancelAll() }

        await observations.observe(
            model,
            options: .didSet,
            { _, model in
                probe.assumeIsolated { isolatedProbe in
                    isolatedProbe.record(model.value)
                }
            },
            isolation: probe
        )

        #expect(await waitUntilValues([0], in: probe))

        model.value = 5
        #expect(await waitUntilValues([0, 5], in: probe))
    }
}

private enum ReplacementReadTarget {
    case value
    case isEnabled
}

private func installReplacingObservation(
    observations: ObservationScope,
    model: CounterModel,
    options: ObservationOptions = .didSet,
    label: String,
    recorder: ValueRecorder<String>
) {
    observations.observe(model, options: options) { event, model in
        recorder.append("\(label):\(event.kind):\(model.value)")
    }
}

private func installReplacingObservation(
    observations: ObservationScope,
    model: CounterModel,
    readTarget: ReplacementReadTarget,
    label: String,
    recorder: ValueRecorder<String>
) {
    observations.observe(model) { event, model in
        switch readTarget {
        case .value:
            recorder.append("\(label):\(event.kind):value:\(model.value)")
        case .isEnabled:
            recorder.append("\(label):\(event.kind):isEnabled:\(model.isEnabled)")
        }
    }
}

private actor CustomActorObservationProbe {
    private let observations = ObservationScope()
    private var values: [Int] = []

    func observe(_ model: CounterModel) {
        observations.observe(model) { _, model in
            self.preconditionIsolated()
            self.values.append(model.value)
        }
    }

    func record(_ value: Int) {
        preconditionIsolated()
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }

    func cancelAll() {
        observations.cancelAll()
    }
}

private func waitUntilValues(
    _ expected: [Int],
    in probe: CustomActorObservationProbe,
    nanoseconds: UInt64 = 5_000_000_000
) async -> Bool {
    let reached = await waitWithTimeout(nanoseconds: nanoseconds) {
        while await probe.snapshot() != expected {
            if Task.isCancelled {
                return false
            }
            await Task.yield()
        }
        return true
    }
    return reached == true
}
