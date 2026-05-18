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
        #expect(ObservationEvent.Kind.willSet == .willSet)
        #expect(ObservationEvent.Kind.didSet == .didSet)
        #expect(ObservationEvent.Kind.initial != .willSet)
        #expect(ObservationEvent.Kind.willSet != .didSet)
        #expect(String(describing: ObservationEvent.Kind.willSet) == "willSet")
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
    func willSetOptionsDeliverWillSetEvent() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<ObservationEvent.Kind>()
        defer { observations.cancelAll() }

        observations.observe(model, options: .willSet) { event, model in
            recorder.append(event.kind)
            _ = model.value
        }

        #expect(await waitUntilCount(1, in: recorder))
        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot() == [.initial, .willSet])
    }

    @Test
    func willSetAndDidSetOptionsUseSingleLegacyChangePass() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let recorder = ValueRecorder<ObservationEvent.Kind>()
        defer { observations.cancelAll() }

        observations.observe(model, options: [.willSet, .didSet]) { event, model in
            recorder.append(event.kind)
            _ = model.value
        }

        #expect(await waitUntilCount(1, in: recorder))
        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.snapshot() == [.initial, .willSet])
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

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot() == ["first:initial:0", "second:didSet:1"])
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
}

private func installReplacingObservation(
    observations: ObservationScope,
    model: CounterModel,
    label: String,
    recorder: ValueRecorder<String>
) {
    observations.observe(model) { event, model in
        recorder.append("\(label):\(event.kind):\(model.value)")
    }
}
