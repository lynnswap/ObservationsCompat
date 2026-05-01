import Observation
internal import _ObservationBridgeLegacy

public enum ObservationDebounceMode: Sendable, Hashable {
    case immediateFirst
    case delayedFirst
}

public struct ObservationDebounce: Sendable, Hashable {
    public let interval: Duration
    public let tolerance: Duration?
    public let mode: ObservationDebounceMode

    public init(
        interval: Duration,
        tolerance: Duration? = nil,
        mode: ObservationDebounceMode = .immediateFirst
    ) {
        self.interval = interval
        self.tolerance = tolerance
        self.mode = mode
    }
}

public enum ObservationThrottleMode: Sendable, Hashable {
    case latest
    case earliest
}

public struct ObservationThrottle: Sendable, Hashable {
    public let interval: Duration
    public let mode: ObservationThrottleMode

    public init(
        interval: Duration,
        mode: ObservationThrottleMode = .latest
    ) {
        self.interval = interval
        self.mode = mode
    }
}

public enum ObservationRateLimit: Sendable, Hashable {
    case debounce(ObservationDebounce)
    case throttle(ObservationThrottle)
}

public enum ObservationBackend: Sendable, Hashable {
    case automatic
    case legacy
}

public struct ObservationOptions: Sendable, Hashable {
    public let rateLimit: ObservationRateLimit?
    public let backend: ObservationBackend

    public init(
        rateLimit: ObservationRateLimit? = nil,
        backend: ObservationBackend = .automatic
    ) {
        self.rateLimit = rateLimit
        self.backend = backend
    }

    @available(iOS 26.0, macOS 26.0, *)
    public static let legacyBackend = ObservationOptions(backend: .legacy)

    public static func rateLimit(_ configuration: ObservationRateLimit) -> ObservationOptions {
        ObservationOptions(rateLimit: configuration)
    }

    var forcesLegacyBackend: Bool {
        backend == .legacy
    }
}

public extension Observable where Self: AnyObject {
    func observe<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: onChange.isolation,
            kind: .observeValue,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let callback: @isolated(any) @Sendable (sending Value) async -> Void = { value in
            await onChange(value)
        }

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeValueCallbackBox<Value> else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeValueCallbackBox<Value>(callback)
                let handle = observeImpl(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    callbackIsolation: onChange.isolation,
                    of: getter,
                    onChange: { value in
                        await callbackBox.call(value)
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observe<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: onChange.isolation,
            kind: .observeVoid,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let callback: @isolated(any) @Sendable () async -> Void = {
            await onChange()
        }

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeVoidCallbackBox else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeVoidCallbackBox(callback)
                let handle = observeImpl(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    callbackIsolation: onChange.isolation,
                    of: getter,
                    onChange: { _ in
                        await callbackBox.call()
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observeTask<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let callback: @isolated(any) @Sendable (sending Value) async -> Void = task

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeValueCallbackBox<Value> else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeValueCallbackBox<Value>(callback)
                let handle = observeTaskImpl(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    of: getter,
                    task: { value in
                        await callbackBox.call(value)
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observeTask<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: nil,
            kind: .observeTaskVoid,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let callback: @isolated(any) @Sendable () async -> Void = task

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeVoidCallbackBox else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeVoidCallbackBox(callback)
                let handle = observeTaskImpl(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    of: getter,
                    task: { _ in
                        await callbackBox.call()
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observe(
        _ keyPaths: sending [PartialKeyPath<Self>],
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.multipleKeyPaths(
            owner: self,
            keyPaths: keyPaths,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: onChange.isolation,
            kind: .observeTrigger
        )
        let getter = observationScopeMakeAnyKeyPathsTriggerGetter(keyPaths)
        let callback: @isolated(any) @Sendable () async -> Void = {
            await onChange()
        }

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeVoidCallbackBox else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeVoidCallbackBox(callback)
                let handle = observeImpl(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    callbackIsolation: onChange.isolation,
                    of: getter,
                    onChange: { _ in
                        await callbackBox.call()
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observeTask(
        _ keyPaths: sending [PartialKeyPath<Self>],
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.multipleKeyPaths(
            owner: self,
            keyPaths: keyPaths,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: nil,
            kind: .observeTaskTrigger
        )
        let getter = observationScopeMakeAnyKeyPathsTriggerGetter(keyPaths)
        let callback: @isolated(any) @Sendable () async -> Void = task

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeVoidCallbackBox else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeVoidCallbackBox(callback)
                let handle = observeTaskImpl(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    of: getter,
                    task: { _ in
                        await callbackBox.call()
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }
}

public extension Observable where Self: AnyObject {
    func observe<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: onChange.isolation,
            kind: .observeValue,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:id:options:clock:onChange:isolation:)"
        )
        let callback: @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void = { boxedValue in
            await onChange(boxedValue.value)
        }

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeNonSendableValueCallbackBox<Value> else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeNonSendableValueCallbackBox<Value>(callback)
                let handle = observeImplNonSendable(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    callbackIsolation: onChange.isolation,
                    of: getter,
                    onChange: { boxedValue in
                        await callbackBox.call(boxedValue)
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observe<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: onChange.isolation,
            kind: .observeVoid,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:id:options:clock:onChange:isolation:)"
        )
        let callback: @isolated(any) @Sendable () async -> Void = {
            await onChange()
        }

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeVoidCallbackBox else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeVoidCallbackBox(callback)
                let handle = observeImplNonSendable(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    callbackIsolation: onChange.isolation,
                    of: getter,
                    onChange: { _ in
                        await callbackBox.call()
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observeTask<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: nil,
            kind: .observeTaskValue,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:id:options:clock:task:isolation:)"
        )
        let callback: @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void = { boxedValue in
            await task(boxedValue.value)
        }

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeNonSendableValueCallbackBox<Value> else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeNonSendableValueCallbackBox<Value>(callback)
                let handle = observeTaskImplNonSendable(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    of: getter,
                    task: { boxedValue in
                        await callbackBox.call(boxedValue)
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }

    func observeTask<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        id: AnyHashable? = nil,
        options: ObservationOptions = ObservationOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationRegistration {
        let descriptor = ObservationScopeDescriptor.singleKeyPath(
            owner: self,
            keyPath: keyPath,
            options: options,
            clock: clock,
            isolation: isolation,
            callbackIsolation: nil,
            kind: .observeTaskVoid,
            valueType: Value.self
        )
        let getter = observationScopeMakeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:id:options:clock:task:isolation:)"
        )
        let callback: @isolated(any) @Sendable () async -> Void = task

        return ObservationRegistration(
            id: id,
            descriptor: descriptor,
            fileID: _fileID,
            line: _line,
            column: _column,
            update: { slot in
                guard let existing = slot.callbackBox as? ObservationScopeVoidCallbackBox else {
                    return false
                }
                existing.update(callback)
                return true
            },
            makeSlot: { [weak owner = self] in
                guard let owner else {
                    return nil
                }
                let callbackBox = ObservationScopeVoidCallbackBox(callback)
                let handle = observeTaskImplNonSendable(
                    owner: owner,
                    options: options,
                    rateLimit: options.rateLimit,
                    rateLimitClock: clock,
                    isolation: isolation,
                    of: getter,
                    task: { _ in
                        await callbackBox.call()
                    }
                )
                return ObservationScopeSlot(
                    descriptor: descriptor,
                    owner: owner,
                    handle: handle,
                    callbackBox: callbackBox
                )
            }
        )
    }
}

func hasSameObservationIsolation(
    _ lhs: (any Actor)?,
    _ rhs: (any Actor)?
) -> Bool {
    guard let lhs, let rhs else {
        return false
    }
    return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
}

private func preconditionNonSendableSameIsolation(
    producerIsolation: (any Actor)?,
    consumerIsolation: (any Actor)?,
    operation: StaticString
) {
    // Swift does not expose a static way to prove two @isolated(any) closures
    // share the same actor instance, so non-Sendable delivery keeps this runtime
    // invariant.
    precondition(
        hasSameObservationIsolation(producerIsolation, consumerIsolation),
        "\(operation): non-Sendable observation requires producer and consumer closures to share the same actor isolation"
    )
}

enum ResolvedBackend: Sendable {
    case native
    case legacy
}

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

func makeObservationStream<Value: Sendable>(
    options: ObservationOptions = ObservationOptions(),
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

private func makeObservationStreamFromCapturedIsolation<Value: Sendable>(
    options: ObservationOptions = ObservationOptions(),
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
    options: ObservationOptions = ObservationOptions(),
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

private func makeObservationStreamFromCapturedIsolation<Value>(
    options: ObservationOptions = ObservationOptions(),
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
    options: ObservationOptions = ObservationOptions(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: (any Actor)?
) -> AsyncStream<Value> {
    switch resolveBackend(options: options) {
    case .legacy:
        return makeLegacyObservationStream(
            observe,
            isolation: isolation
        )
    case .native:
        if #available(iOS 26.0, macOS 26.0, *) {
            return makeNativeStream(
                observe,
                isolation: isolation
            )
        }
        return makeLegacyObservationStream(
            observe,
            isolation: isolation
        )
    }
}

func resolveBackend(options: ObservationOptions) -> ResolvedBackend {
    if options.forcesLegacyBackend {
        return .legacy
    }

    if #available(iOS 26.0, macOS 26.0, *) {
        return .native
    }
    return .legacy
}

@available(iOS 26.0, macOS 26.0, *)
private func makeNativeStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: (any Actor)?
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let task = Task.immediate {
            await drainNativeObservationValues(
                observe: observe,
                isolation: isolation,
                continuation: continuation
            )

            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func drainNativeObservationValues<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)?,
    continuation: AsyncStream<Value>.Continuation
) async {
    let observations = Observations(observe)
    var iterator = observations.makeAsyncIterator()

    while let value = await iterator.next(isolation: isolation) {
        if Task.isCancelled {
            break
        }
        continuation.yield(value)
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
