import Observation

public extension Observable where Self: AnyObject {
    /// Declares a synchronous callback observation for a `Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. The callback receives the latest observed value after any configured rate limit.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - onChange: The callback to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares a synchronous trigger-only observation for a `Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Use this overload when the callback only needs to know that the value changed.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - onChange: The callback to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares an asynchronous task observation for a `Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. The task receives the latest observed value after any configured rate limit.
    ///
    /// ObservationBridge does not cancel an in-flight task when a new value arrives; it preserves
    /// one pending latest value and coalesces any additional backlog into that pending value.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - task: The asynchronous task to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares an asynchronous trigger-only task observation for a `Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Use this overload when the task only needs to know that the value changed.
    ///
    /// ObservationBridge does not cancel an in-flight task when a new change arrives; it preserves
    /// one pending change and coalesces any additional backlog into that pending change.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - task: The asynchronous task to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares a synchronous trigger-only observation for multiple key paths.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Multiple-key-path observations do not pass values to the callback; read any
    /// derived state from the owner inside `onChange`.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPaths: The key paths to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - onChange: The callback to run when any observed value changes.
    ///   - isolation: The actor isolation used to read the observed values.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares an asynchronous trigger-only task observation for multiple key paths.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Multiple-key-path observations do not pass values to the task; read any derived
    /// state from the owner inside `task`.
    ///
    /// ObservationBridge does not cancel an in-flight task when a new change arrives; it preserves
    /// one pending change and coalesces any additional backlog into that pending change.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPaths: The key paths to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - task: The asynchronous task to run when any observed value changes.
    ///   - isolation: The actor isolation used to read the observed values.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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
    /// Declares a synchronous callback observation for a non-`Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Non-`Sendable` values use the legacy backend and require the producer and
    /// consumer closures to share the same actor isolation.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - onChange: The callback to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares a synchronous trigger-only observation for a non-`Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Non-`Sendable` observations require the producer and consumer closures to share
    /// the same actor isolation even though this overload does not pass the value to the callback.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - onChange: The callback to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares an asynchronous task observation for a non-`Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Non-`Sendable` values use the legacy backend and require the producer and task
    /// closures to share the same actor isolation.
    ///
    /// ObservationBridge does not cancel an in-flight task when a new value arrives; it preserves
    /// one pending latest value and coalesces any additional backlog into that pending value.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - task: The asynchronous task to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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

    /// Declares an asynchronous trigger-only task observation for a non-`Sendable` value at a key path.
    ///
    /// Store the returned registration in an ``ObservationScope`` to start the observation and keep
    /// it active. Non-`Sendable` observations require the producer and task closures to share the
    /// same actor isolation even though this overload does not pass the value to the task.
    ///
    /// ObservationBridge does not cancel an in-flight task when a new change arrives; it preserves
    /// one pending change and coalesces any additional backlog into that pending change.
    ///
    /// The underscored source-location parameters are used to derive a stable automatic identity;
    /// leave their default values unless you are intentionally overriding call-site identity.
    ///
    /// - Parameters:
    ///   - keyPath: The key path to read and observe.
    ///   - id: An optional explicit identity for reuse and cancellation.
    ///   - options: Backend and rate-limit configuration.
    ///   - clock: The clock used for debounce or throttle timing.
    ///   - task: The asynchronous task to run when the observed value changes.
    ///   - isolation: The actor isolation used to read the observed value.
    /// - Returns: A registration that must be stored in an ``ObservationScope``.
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
