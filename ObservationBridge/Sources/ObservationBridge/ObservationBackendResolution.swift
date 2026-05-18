internal import _ObservationBridgeLegacy

enum ResolvedBackend: Sendable, Equatable {
    case legacy
}

func makeObservationStream<Value: Sendable>(
    options: ObservationStreamOptions = ObservationStreamOptions(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)? = #isolation,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    let stream = makeRawObservationStream(
        options: options,
        observe,
        isolation: observe.isolation ?? isolation
    )
    if let rateLimit {
        return makeRateLimitedValueStream(
            stream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
    return stream
}

func makeObservationStreamFromCapturedIsolation<Value: Sendable>(
    options: ObservationStreamOptions = ObservationStreamOptions(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    capturedIsolation: (any Actor)?,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    let stream = makeRawObservationStream(
        options: options,
        observe,
        isolation: observe.isolation ?? capturedIsolation
    )
    if let rateLimit {
        return makeRateLimitedValueStream(
            stream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
    return stream
}

func makeObservationStream<Value>(
    options: ObservationStreamOptions = ObservationStreamOptions(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)? = #isolation,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    _ = options

    let boxedObserve: @isolated(any) @Sendable () -> _UncheckedSendableValueBox<Value> = {
        _UncheckedSendableValueBox(
            _ObservationBridgeLegacy.legacyEvaluateObservedValue(
                isolation: #isolation,
                observe: observe
            )
        )
    }

    let boxedStream = makeLegacyObservationStream(
        boxedObserve,
        isolation: observe.isolation ?? isolation
    )
    let sourceStream: AsyncStream<_UncheckedSendableValueBox<Value>>
    if let rateLimit {
        sourceStream = makeRateLimitedValueStream(
            boxedStream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    } else {
        sourceStream = boxedStream
    }

    let stream = AsyncStream<Value> { continuation in
        let task = Task {
            for await boxedValue in sourceStream {
                if Task.isCancelled {
                    break
                }
                continuation.yield(boxedValue.value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
    return stream
}

func makeObservationStreamFromCapturedIsolation<Value>(
    options: ObservationStreamOptions = ObservationStreamOptions(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    capturedIsolation: (any Actor)?,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    _ = options

    let boxedObserve: @isolated(any) @Sendable () -> _UncheckedSendableValueBox<Value> = {
        let resolvedIsolation = observe.isolation ?? capturedIsolation
        if let resolvedIsolation {
            return resolvedIsolation.assumeIsolated { _ in
                _UncheckedSendableValueBox(
                    _ObservationBridgeLegacy.legacyEvaluateObservedValue(
                        observe: observe
                    )
                )
            }
        }

        return _UncheckedSendableValueBox(
            _ObservationBridgeLegacy.legacyEvaluateObservedValue(
                observe: observe
            )
        )
    }

    let boxedStream = makeLegacyObservationStream(
        boxedObserve,
        isolation: observe.isolation ?? capturedIsolation
    )
    let sourceStream: AsyncStream<_UncheckedSendableValueBox<Value>>
    if let rateLimit {
        sourceStream = makeRateLimitedValueStream(
            boxedStream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    } else {
        sourceStream = boxedStream
    }

    let stream = AsyncStream<Value> { continuation in
        let task = Task {
            for await boxedValue in sourceStream {
                if Task.isCancelled {
                    break
                }
                continuation.yield(boxedValue.value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
    return stream
}

private func makeRawObservationStream<Value: Sendable>(
    options: ObservationStreamOptions = ObservationStreamOptions(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: (any Actor)?
) -> AsyncStream<Value> {
    switch resolveBackend(options: options) {
    case .legacy:
        return makeLegacyObservationStream(
            observe,
            isolation: isolation
        )
    }
}

func resolveBackend(options: ObservationStreamOptions) -> ResolvedBackend {
    if options.forcesLegacyBackend {
        return .legacy
    }

    #if compiler(>=6.4)
    #error("Implement the native withContinuousObservation stream backend before changing automatic backend resolution")
    #endif

    return .legacy
}
