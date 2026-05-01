import Synchronization

enum OwnerValueEmission<Value> {
    case value(Value)
    case ownerGone
}

extension OwnerValueEmission: Sendable where Value: Sendable {}

@discardableResult
func makeObservationTask<Success: Sendable>(
    @_inheritActorContext operation: @escaping @isolated(any) @Sendable () async -> Success
) -> Task<Success, Never> {
    if #available(iOS 26.0, macOS 26.0, *) {
        return Task.immediate(operation: operation)
    }
    return Task(operation: operation)
}

final class ObservationExecutionLifetime: Sendable {
    private struct State {
        var isCancelled = false
        var handlers: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    func addCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        let shouldRunImmediately = state.withLock { state in
            if state.isCancelled {
                return true
            }

            state.handlers.append(handler)
            return false
        }

        if shouldRunImmediately {
            handler()
        }
    }

    func cancel() {
        let handlersToRun = state.withLock { state in
            if state.isCancelled {
                return [@Sendable () -> Void]()
            }

            state.isCancelled = true
            let handlers = state.handlers
            state.handlers = []
            return handlers
        }

        for handler in handlersToRun {
            handler()
        }
    }
}

final class _UncheckedSendableValueBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

func observeImpl<Owner: AnyObject, Value: Sendable>(
    owner: Owner,
    options: ObservationOptions,
    rateLimit: ObservationRateLimit?,
    rateLimitClock: any Clock<Duration>,
    isolation: (any Actor)?,
    callbackIsolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) async -> Void
) -> ObservationHandle {
    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let lifetime = ObservationExecutionLifetime()
    lifetime.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }
    let monitorTask = makeObservationTask {
        defer {
            lifetime.cancel()
        }

        if let rateLimit {
            switch rateLimit {
            case let .debounce(debounce) where debounce.mode == .delayedFirst:
                let observedValues = makeObservedValueChannel(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value
                )
                lifetime.addCancellationHandler {
                    observedValues.producerTask.cancel()
                    observedValues.channel.finish()
                }
                let rateLimitedValues = makeRateLimitedValueStream(
                    observedValues.channel,
                    rateLimit: rateLimit,
                    rateLimitClock: rateLimitClock
                )
                for await observedValue in rateLimitedValues {
                    guard !Task.isCancelled else {
                        break
                    }
                    await onChange(observedValue)
                }
            case let .debounce(debounce):
                await forEachImmediateFirstDebouncedOwnerValue(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value,
                    debounce: debounce,
                    debounceClock: rateLimitClock,
                    emitFirstInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            case let .throttle(throttle):
                await forEachThrottledOwnerValue(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value,
                    throttle: throttle,
                    throttleClock: rateLimitClock,
                    emitReadyValuesInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        } else {
            await forEachOwnerValueEmission(
                ownerToken: ownerToken,
                options: options,
                isolation: isolation,
                of: value
            ) { emission in
                switch emission {
                case .ownerGone:
                    return false
                case .value(let observedValue):
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
        lifetime.cancel()
    }

    OwnerCancellationRegistry.register(handle, owner: owner)
    return handle
}

func observeImplNonSendable<Owner: AnyObject, Value>(
    owner: Owner,
    options: ObservationOptions,
    rateLimit: ObservationRateLimit?,
    rateLimitClock: any Clock<Duration>,
    isolation: (any Actor)?,
    callbackIsolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
) -> ObservationHandle {
    _ = options

    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let lifetime = ObservationExecutionLifetime()
    lifetime.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }
    let monitorTask = makeObservationTask {
        defer {
            lifetime.cancel()
        }

        if let rateLimit {
            switch rateLimit {
            case let .debounce(debounce) where debounce.mode == .delayedFirst:
                let observedValues = makeObservedValueStreamNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value
                )
                let rateLimitedValues = makeRateLimitedValueStreamNonSendable(
                    observedValues,
                    rateLimit: rateLimit,
                    rateLimitClock: rateLimitClock
                )
                for await observedValue in rateLimitedValues {
                    guard !Task.isCancelled else {
                        break
                    }
                    await onChange(_UncheckedSendableValueBox(observedValue))
                }
            case let .debounce(debounce):
                await forEachImmediateFirstDebouncedOwnerValueNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value,
                    debounce: debounce,
                    debounceClock: rateLimitClock,
                    emitFirstInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            case let .throttle(throttle):
                await forEachThrottledOwnerValueNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value,
                    throttle: throttle,
                    throttleClock: rateLimitClock,
                    emitReadyValuesInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        } else {
            await forEachOwnerValueEmissionNonSendable(
                ownerToken: ownerToken,
                isolation: isolation,
                of: value
            ) { emission in
                switch emission {
                case .ownerGone:
                    return false
                case .value(let observedValue):
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
        lifetime.cancel()
    }

    OwnerCancellationRegistry.register(handle, owner: owner)
    return handle
}
