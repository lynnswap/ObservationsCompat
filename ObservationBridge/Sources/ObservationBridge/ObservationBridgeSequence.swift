private final class ObservationBridgeStreamFactory<Value>: Sendable {
    let makeStream: @Sendable () -> AsyncStream<Value>

    init(makeStream: @escaping @Sendable () -> AsyncStream<Value>) {
        self.makeStream = makeStream
    }
}

private struct SendableObservationBridgeStreamBuilder<Value: Sendable>: Sendable {
    let options: ObservationOptions
    let observe: @isolated(any) @Sendable () -> Value
    let capturedIsolation: (any Actor)?
    let rateLimit: ObservationRateLimit?
    let rateLimitClock: any Clock<Duration>

    func makeStream() -> AsyncStream<Value> {
        makeObservationStreamFromCapturedIsolation(
            options: options,
            observe,
            capturedIsolation: capturedIsolation,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
}

private struct ObservationBridgeStreamBuilder<Value>: Sendable {
    let options: ObservationOptions
    let observe: @isolated(any) @Sendable () -> Value
    let capturedIsolation: (any Actor)?
    let rateLimit: ObservationRateLimit?
    let rateLimitClock: any Clock<Duration>

    func makeStream() -> AsyncStream<Value> {
        makeObservationStreamFromCapturedIsolation(
            options: options,
            observe,
            capturedIsolation: capturedIsolation,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
}

public struct ObservationBridge<Value>: AsyncSequence {
    public typealias Element = Value
    public typealias Failure = Never

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = Value
        public typealias Failure = Never

        private var base: AsyncStream<Value>.Iterator

        fileprivate init(base: AsyncStream<Value>.Iterator) {
            self.base = base
        }

        public mutating func next() async -> Value? {
            await base.next()
        }
    }

    private let streamFactory: ObservationBridgeStreamFactory<Value>

    fileprivate init(streamFactory: @escaping @Sendable () -> AsyncStream<Value>) {
        self.streamFactory = ObservationBridgeStreamFactory(makeStream: streamFactory)
    }

    public init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        let builder = ObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            rateLimit: options.rateLimit,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: streamFactory.makeStream().makeAsyncIterator())
    }

    public init(
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        self.init(
            options: ObservationOptions(),
            observe
        )
    }
}

extension ObservationBridge: Sendable where Value: Sendable {}

public extension ObservationBridge where Value: Sendable {
    init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        let builder = SendableObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            rateLimit: options.rateLimit,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }

    init(
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        self.init(
            options: ObservationOptions(),
            observe
        )
    }
}

public func makeObservationBridgeStream<Value>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(observe)
}

public func makeObservationBridgeStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(observe)
}

public func makeObservationBridgeStream<Value>(
    options: ObservationOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}

public func makeObservationBridgeStream<Value: Sendable>(
    options: ObservationOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}
