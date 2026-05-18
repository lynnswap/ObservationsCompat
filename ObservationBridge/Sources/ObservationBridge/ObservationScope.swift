import Observation

/// Owns owner-bound observations for an explicit lifecycle.
///
/// Call ``observe(_:options:_:isolation:_fileID:_line:_column:)`` at lifecycle boundaries such as
/// view setup or cell configuration. The scope cancels all stored observations when it is
/// deallocated.
public final class ObservationScope {
    private var slots: [ObservationScopeID: any ObservationScopeSlotProtocol] = [:]

    /// Creates an empty observation scope.
    public init() {}

    /// Starts or replaces an owner-bound observation.
    ///
    /// The callback body is the tracking body: every observable property read from `owner` inside
    /// `apply` becomes part of the observation. Calling the same observation again from the same
    /// call site replaces the existing pipeline so the new callback body is tracked immediately.
    ///
    /// - Parameters:
    ///   - owner: The observable object whose properties are read by `apply`.
    ///   - options: Event delivery options. Defaults to ``ObservationOptions/didSet``.
    ///   - apply: The callback to run for the initial pass and selected subsequent events.
    ///   - isolation: The actor isolation used to start the observation.
    public func observe<Owner: AnyObject & Observable>(
        _ owner: Owner,
        options: ObservationOptions = .didSet,
        @_inheritActorContext _ apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) {
        let observationIsolation = apply.isolation ?? isolation
        let id = ObservationScopeID(
            fileID: String(describing: _fileID),
            line: _line,
            column: _column,
            ownerID: ObjectIdentifier(owner)
        )
        let descriptor = ObservationScopeDescriptor(
            owner: owner,
            options: options,
            observationIsolation: observationIsolation,
            callbackIsolation: apply.isolation
        )

        slots.removeValue(forKey: id)?.cancel()
        slots[id] = makeObservationSlot(
            owner: owner,
            descriptor: descriptor,
            options: options,
            isolation: observationIsolation,
            apply: apply
        )
    }

    /// Cancels every observation currently owned by the scope.
    public func cancelAll() {
        let currentSlots = Array(slots.values)
        slots.removeAll(keepingCapacity: true)

        for slot in currentSlots {
            slot.cancel()
        }
    }

    deinit {
        cancelAll()
    }

    private func makeObservationSlot<Owner: AnyObject & Observable>(
        owner: Owner,
        descriptor: ObservationScopeDescriptor,
        options: ObservationOptions,
        isolation: (any Actor)?,
        apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    ) -> ObservationScopeSlot<Owner> {
        let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
        let state = ScopedObservationState()
        let lifetime = ObservationExecutionLifetime()
        let callbackBox = ObservationScopeCallbackBox(apply)
        let runner: any ScopedObservationRunner = TypedScopedObservationRunner(callbackBox: callbackBox)
        lifetime.addCancellationHandler {
            WeakOwnerRegistry.removeToken(ownerToken)
        }
        lifetime.addCancellationHandler {
            state.terminate()
        }

        let monitorTask = makeObservationTask {
            defer {
                lifetime.cancel()
            }

            await runner.run(
                ownerToken: ownerToken,
                options: options,
                isolation: isolation,
                state: state
            )
        }

        let handle = ObservationHandle {
            monitorTask.cancel()
            lifetime.cancel()
        }
        OwnerCancellationRegistry.register(handle, owner: owner)

        return ObservationScopeSlot(
            descriptor: descriptor,
            state: state,
            handle: handle,
            callbackBox: callbackBox
        )
    }
}

func runScopedObservationLoop<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) async {
    #if compiler(>=6.4)
    // TODO: Replace this fallback with native withContinuousObservation(options:apply:)
    // and ObservationTracking.Event forwarding once the Swift 6.4 API is available.
    #endif
    await runLegacyScopedObservationLoop(
        ownerToken: ownerToken,
        options: options,
        isolation: isolation,
        state: state,
        callbackBox: callbackBox
    )
}

private func runLegacyScopedObservationLoop<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) async {
    var kind = ObservationEvent.Kind.initial

    while !Task.isCancelled {
        guard await trackLegacyScopedObservation(
            ownerToken: ownerToken,
            kind: kind,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox
        ) else {
            break
        }

        guard let changeKind = options.legacyChangeKind else {
            break
        }

        guard await state.waitForChange() else {
            break
        }

        kind = changeKind
    }

    state.terminate()
}

private func trackLegacyScopedObservation<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    kind: ObservationEvent.Kind,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) async -> Bool {
    await withObservationIsolation(isolation: isolation) {
        guard let owner = WeakOwnerRegistry.owner(token: ownerToken) as? Owner else {
            return false
        }

        let event = ObservationEvent(kind: kind) {
            state.terminate()
        }

        withObservationTracking {
            callbackBox.call(event: event, owner: owner)
        } onChange: {
            state.emitChange()
        }

        return !state.isTerminated
    }
}

private func withObservationIsolation<T>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    operation()
}
