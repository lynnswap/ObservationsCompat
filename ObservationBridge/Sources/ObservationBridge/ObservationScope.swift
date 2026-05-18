import Darwin
import Foundation
import Observation
import Synchronization
import _ObservationBridgePrivateABI

/// Owns owner-bound observations for an explicit lifecycle.
///
/// Call ``observe(_:options:_:isolation:_fileID:_line:_column:)`` at lifecycle boundaries such as
/// view setup or cell configuration. The scope cancels all stored observations when it is
/// deallocated.
public final class ObservationScope: @unchecked Sendable {
    private let storage = Mutex(ObservationScopeStorage())

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
        let cancellationGeneration = storage.withLock { storage in
            storage.cancellationGeneration
        }
        let observationIsolation = apply.isolation ?? isolation
        let id = ObservationScopeID(
            fileID: String(describing: _fileID),
            line: _line,
            column: _column
        )
        let descriptor = ObservationScopeDescriptor(
            owner: owner,
            options: options,
            observationIsolation: observationIsolation,
            callbackIsolation: apply.isolation
        )

        let slot = makeObservationSlot(
            owner: owner,
            descriptor: descriptor,
            options: options,
            isolation: observationIsolation,
            apply: apply
        )
        let insertion = storage.withLock { storage -> (start: (@Sendable () -> Void)?, shouldCancelNewSlot: Bool) in
            guard storage.cancellationGeneration == cancellationGeneration else {
                return (nil, true)
            }

            let replacedSlot = storage.slots.updateValue(slot, forKey: id)
            replacedSlot?.cancel()
            return (slot.reserveStart(), false)
        }
        if insertion.shouldCancelNewSlot {
            slot.cancel()
        }
        insertion.start?()
    }

    /// Cancels every observation currently owned by the scope.
    public func cancelAll() {
        let currentSlots = storage.withLock { storage in
            storage.cancellationGeneration &+= 1
            let currentSlots = Array(storage.slots.values)
            storage.slots.removeAll(keepingCapacity: true)
            return currentSlots
        }

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
        let callbackCleaner: any ObservationScopeCallbackClearing = callbackBox
        let runner: any ScopedObservationRunner = TypedScopedObservationRunner(callbackBox: callbackBox)
        let taskBox = ObservationTaskBox()
        lifetime.addCancellationHandler {
            WeakOwnerRegistry.removeToken(ownerToken)
        }
        lifetime.addCancellationHandler {
            state.terminate()
        }
        lifetime.addCancellationHandler {
            callbackCleaner.clear()
        }

        let handle = ObservationHandle {
            lifetime.cancel()
            taskBox.finish()
        }
        OwnerCancellationRegistry.register(handle, owner: owner)

        return ObservationScopeSlot(
            descriptor: descriptor,
            state: state,
            handle: handle,
            taskBox: taskBox,
            callbackBox: callbackBox
        ) {
            makeObservationTask {
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
        }
    }
}

private struct ObservationScopeStorage {
    var cancellationGeneration: UInt64 = 0
    var slots: [ObservationScopeID: any ObservationScopeSlotProtocol] = [:]
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
        let changeKind = options.legacyChangeKind

        guard await trackLegacyScopedObservation(
            ownerToken: ownerToken,
            kind: kind,
            changeKind: changeKind,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox
        ) else {
            break
        }

        guard let changeKind else {
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
    changeKind: ObservationEvent.Kind?,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) async -> Bool {
    await withObservationIsolation(isolation: isolation) {
        guard !state.isTerminated else {
            return false
        }

        guard let owner = WeakOwnerRegistry.owner(token: ownerToken) as? Owner else {
            return false
        }

        let event = ObservationEvent(kind: kind) {
            state.terminate()
        }

        guard let changeKind else {
            callbackBox.call(event: event, owner: owner)
            return !state.isTerminated
        }

        if changeKind == .didSet {
            let usedDidSetSPI = withObservationTrackingDidSetIfAvailable {
                callbackBox.call(event: event, owner: owner)
            } didSet: { tracking in
                state.emitChange()
                cancelObservationTrackingIfAvailable(tracking)
            }

            if !usedDidSetSPI {
                withObservationTracking {
                    callbackBox.call(event: event, owner: owner)
                } onChange: {
                    state.emitChange()
                }
            }
        } else {
            withObservationTracking {
                callbackBox.call(event: event, owner: owner)
            } onChange: {
                state.emitChange()
            }
        }

        return !state.isTerminated
    }
}

private func withObservationIsolation<T: Sendable>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    // The isolated parameter makes the caller hop to `isolation` before this body runs.
    return operation()
}

// `ObservationTracking` is hidden from the Swift 6.2 public interface even though the
// didSet SPI passes it to this closure. Use a resilient imported value as the opaque
// ABI carrier so Swift forwards the hidden value with the same indirect convention.
private typealias OpaqueObservationTracking = URL

private typealias ObservationTrackingDidSetFunction = @convention(thin) (
    () -> Void,
    @Sendable (OpaqueObservationTracking) -> Void
) -> Void

private let observationTrackingDidSetFunction: ObservationTrackingDidSetFunction? =
    unsafe lookupObservationSymbol(
        "$s11Observation04withA8Tracking_6didSetxxyXE_yAA0aC0VYbctlF",
        as: ObservationTrackingDidSetFunction.self
    )

private let observationTrackingCancelAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation0A8TrackingV6cancelyyF")
        .map { UInt(bitPattern: $0) }

private func withObservationTrackingDidSetIfAvailable(
    _ apply: () -> Void,
    didSet: @Sendable (OpaqueObservationTracking) -> Void
) -> Bool {
    #if arch(arm64)
    guard let observationTrackingDidSetFunction, observationTrackingCancelAddress != nil else {
        return false
    }

    observationTrackingDidSetFunction(apply, didSet)
    return true
    #else
    return false
    #endif
}

private func cancelObservationTrackingIfAvailable(_ tracking: OpaqueObservationTracking) {
    guard
        let observationTrackingCancelAddress,
        let observationTrackingCancelFunction = unsafe UnsafeMutableRawPointer(
            bitPattern: observationTrackingCancelAddress
        )
    else {
        return
    }

    unsafe withUnsafePointer(to: tracking) { trackingPointer in
        unsafe OBObservationTrackingCancel(observationTrackingCancelFunction, trackingPointer)
    }
}

private func lookupObservationSymbol<T>(
    _ name: UnsafePointer<CChar>,
    as type: T.Type
) -> T? {
    guard let symbol = unsafe lookupObservationSymbol(name) else {
        return nil
    }
    return unsafe unsafeBitCast(symbol, to: type)
}

private func lookupObservationSymbol(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    unsafe dlsym(unsafe UnsafeMutableRawPointer(bitPattern: -2), name)
}
