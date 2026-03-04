import Observation
import Synchronization

package func makeLegacyObservationStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isDuplicate: (@Sendable (Value, Value) -> Bool)? = nil,
    isolation: (any Actor)? = #isolation
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let observationState = LegacyObservationState()
        let observeIsolation = isolation ?? observe.isolation
        let task = Task {
            await withTaskCancellationHandler(operation: {
                await runLegacyProducer(
                    observe: observe,
                    observeIsolation: observeIsolation,
                    observationState: observationState,
                    isDuplicate: isDuplicate,
                    continuation: continuation
                )
            }, onCancel: {
                observationState.terminate()
            })
        }

        continuation.onTermination = { _ in
            observationState.terminate()
            task.cancel()
        }
    }
}

private func runLegacyProducer<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observeIsolation: (any Actor)?,
    observationState: LegacyObservationState,
    isDuplicate: (@Sendable (Value, Value) -> Bool)?,
    continuation: AsyncStream<Value>.Continuation
) async {
    var latestValue: LatestObservedValue<Value> = .unset

    func emitIfNeeded(_ value: Value) {
        if case .set(let previousValue) = latestValue,
           let isDuplicate,
           isDuplicate(previousValue, value)
        {
            return
        }

        latestValue = .set(value)
        continuation.yield(value)
    }

    func registerTracking() async {
        let value = await trackLegacyValue(
            isolation: observeIsolation,
            observe: observe,
            observationState: observationState
        )
        emitIfNeeded(value)
    }

    await registerTracking()
    while await observationState.waitForChange() {
        guard !Task.isCancelled else {
            break
        }
        await registerTracking()
    }

    observationState.terminate()
    continuation.finish()
}

private enum LatestObservedValue<Value> {
    case unset
    case set(Value)
}

private func trackLegacyValue<Value: Sendable>(
    isolation: (any Actor)?,
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observationState: LegacyObservationState
) async -> Value {
    await withObservationIsolation(isolation: isolation) {
        withObservationTracking({
            callIsolatedWithFastPath(observe)
        }, onChange: {
            observationState.emitWillChange()
        })
    }
}

@inline(__always)
private func callIsolatedWithFastPath<Value>(
    _ closure: @escaping @isolated(any) @Sendable () -> Value
) -> Value {
    if closure.isolation == nil {
        let unisolated = unsafe unsafeBitCast(closure, to: (@Sendable () -> Value).self)
        return unisolated()
    }

    let result = Result(catching: closure)
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        preconditionFailure("legacy observation produced unexpected error: \(error)")
    }
}

@inline(__always)
private func callIsolatedWithFastPath<Input, Value>(
    _ closure: @escaping @isolated(any) (Input) -> Value,
    _ input: Input
) -> Value {
    if closure.isolation == nil {
        let unisolated = unsafe unsafeBitCast(closure, to: ((Input) -> Value).self)
        return unisolated(input)
    }

    let result = Optional(input).map(closure)
    switch result {
    case .some(let value):
        return value
    case .none:
        preconditionFailure("legacy observation produced unexpected nil mapping")
    }
}

private func withObservationIsolation<T>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    operation()
}

private final class LegacyObservationState: @unchecked Sendable {
    private struct State {
        var dirty = false
        var terminated = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum WaitSetup {
        case changed
        case terminated
        case wait
    }

    private let state = Mutex(State())

    func emitWillChange() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.terminated else {
                return []
            }

            if state.waiters.isEmpty {
                state.dirty = true
                return []
            }

            let continuations = state.waiters
            state.waiters.removeAll(keepingCapacity: true)
            return continuations
        }

        for continuation in continuations {
            continuation.resume(returning: ())
        }
    }

    func terminate() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.terminated else {
                return []
            }

            state.terminated = true
            state.dirty = false
            let continuations = state.waiters
            state.waiters.removeAll(keepingCapacity: true)
            return continuations
        }

        for continuation in continuations {
            continuation.resume(returning: ())
        }
    }

    func waitForChange() async -> Bool {
        let setup = state.withLock { state -> WaitSetup in
            if state.terminated {
                return .terminated
            }
            if state.dirty {
                state.dirty = false
                return .changed
            }
            return .wait
        }

        switch setup {
        case .changed:
            return true
        case .terminated:
            return false
        case .wait:
            break
        }

        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if state.terminated {
                    return continuation
                }
                if state.dirty {
                    state.dirty = false
                    return continuation
                }
                state.waiters.append(continuation)
                return nil
            }
            immediate?.resume(returning: ())
        }

        return state.withLock { state in
            !state.terminated
        }
    }
}

package func legacyEvaluateObservedOwnerValue<Owner: AnyObject, Value>(
    owner: Owner?,
    value: @escaping @isolated(any) (Owner) -> Value,
    isolation: isolated (any Actor)? = #isolation
) -> LegacyOwnerObservationResult<Value> {
    guard let owner else {
        return .ownerGone
    }

    return withObservationIsolation(isolation: isolation) {
        .value(callIsolatedWithFastPath(value, owner))
    }
}

package func legacyEvaluateObservedOwnerValue<Owner: AnyObject, Value, Mapped>(
    owner: Owner?,
    value: @escaping @isolated(any) (Owner) -> Value,
    isolation: isolated (any Actor)? = #isolation,
    map: (Value) -> Mapped
) -> LegacyOwnerObservationResult<Mapped> {
    switch legacyEvaluateObservedOwnerValue(owner: owner, value: value, isolation: isolation) {
    case .ownerGone:
        return .ownerGone
    case .value(let observedValue):
        return .value(map(observedValue))
    }
}

package func legacyEvaluateObservedValue<Value>(
    isolation: isolated (any Actor)? = #isolation,
    observe: @escaping @isolated(any) @Sendable () -> Value
) -> Value {
    withObservationIsolation(isolation: isolation) {
        callIsolatedWithFastPath(observe)
    }
}

package enum LegacyOwnerObservationResult<Value> {
    case ownerGone
    case value(Value)
}

extension LegacyOwnerObservationResult: Sendable where Value: Sendable {}
