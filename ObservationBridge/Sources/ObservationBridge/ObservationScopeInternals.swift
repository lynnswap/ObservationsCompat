import Observation
import Synchronization

struct ObservationScopeID: Hashable, Sendable {
    let fileID: String
    let line: UInt
    let column: UInt
}

struct ObservationScopeDescriptor: Equatable, Sendable {
    let ownerID: ObjectIdentifier
    let options: ObservationOptions
    let observationIsolationID: ObjectIdentifier?
    let callbackIsolationID: ObjectIdentifier?

    init(
        owner: AnyObject,
        options: ObservationOptions,
        observationIsolation: (any Actor)?,
        callbackIsolation: (any Actor)?
    ) {
        self.ownerID = ObjectIdentifier(owner)
        self.options = options
        self.observationIsolationID = Self.actorID(observationIsolation)
        self.callbackIsolationID = Self.actorID(callbackIsolation)
    }

    private static func actorID(_ actor: (any Actor)?) -> ObjectIdentifier? {
        actor.map { ObjectIdentifier($0 as AnyObject) }
    }
}

protocol ObservationScopeSlotProtocol: AnyObject, Sendable {
    var descriptor: ObservationScopeDescriptor { get }
    var isActive: Bool { get }

    func reserveStart() -> (@Sendable () -> Void)?
    func cancel()
}

protocol ObservationScopeCallbackClearing: Sendable {
    func clear()
}

final class ObservationScopeSlot<Owner: AnyObject>: ObservationScopeSlotProtocol, @unchecked Sendable {
    let descriptor: ObservationScopeDescriptor
    let callbackBox: ObservationScopeCallbackBox<Owner>
    private let state: ScopedObservationState
    private let handle: ObservationHandle
    private let taskBox: ObservationTaskBox
    private let startOperation: Mutex<(@Sendable () -> Task<Void, Never>)?>

    var isActive: Bool {
        !state.isTerminated
    }

    init(
        descriptor: ObservationScopeDescriptor,
        state: ScopedObservationState,
        handle: ObservationHandle,
        taskBox: ObservationTaskBox,
        callbackBox: ObservationScopeCallbackBox<Owner>,
        startOperation: @escaping @Sendable () -> Task<Void, Never>
    ) {
        self.descriptor = descriptor
        self.state = state
        self.handle = handle
        self.taskBox = taskBox
        self.callbackBox = callbackBox
        self.startOperation = Mutex(startOperation)

        handle.addCancellationHandler { [callbackBox] in
            callbackBox.clear()
        }
    }

    func reserveStart() -> (@Sendable () -> Void)? {
        guard let operation = startOperation.withLock({ state in
            let operation = state
            state = nil
            return operation
        }) else {
            return nil
        }

        guard isActive else {
            return nil
        }

        return { [state, taskBox] in
            guard !state.isTerminated else {
                return
            }

            let task = operation()
            taskBox.replace(with: task)
        }
    }

    func start() {
        reserveStart()?()
    }

    func cancel() {
        handle.cancel()
    }
}

final class ObservationScopeCallbackBox<Owner: AnyObject>: @unchecked Sendable {
    private struct State {
        var callback: @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    }

    private let state: Mutex<State>

    init(
        _ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    ) {
        state = Mutex(State(callback: callback))
    }

    func snapshot() -> @isolated(any) @Sendable (ObservationEvent, Owner) -> Void {
        state.withLock { state in
            state.callback
        }
    }

    func update(
        _ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    ) {
        state.withLock { state in
            state.callback = callback
        }
    }

    func clear() {
        update { _, _ in }
    }

    func call(event: ObservationEvent, owner: Owner) {
        let callback = snapshot()
        callObservationCallback(callback, event, owner)
    }
}

extension ObservationScopeCallbackBox: ObservationScopeCallbackClearing {}

protocol ScopedObservationRunner: Sendable {
    func run(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: (any Actor)?,
        state: ScopedObservationState
    ) async
}

final class TypedScopedObservationRunner<Owner: AnyObject & Observable>: ScopedObservationRunner, @unchecked Sendable {
    private let callbackBox: ObservationScopeCallbackBox<Owner>

    init(callbackBox: ObservationScopeCallbackBox<Owner>) {
        self.callbackBox = callbackBox
    }

    func run(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: (any Actor)?,
        state: ScopedObservationState
    ) async {
        await runScopedObservationLoop(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox
        )
    }
}

final class ScopedObservationState: @unchecked Sendable {
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

    var isTerminated: Bool {
        state.withLock { state in
            state.terminated
        }
    }

    func emitChange() {
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
            continuation.resume()
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
            continuation.resume()
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
            immediate?.resume()
        }

        return state.withLock { state in
            !state.terminated
        }
    }
}

@inline(__always)
private func callObservationCallback<Owner: AnyObject>(
    _ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void,
    _ event: ObservationEvent,
    _ owner: Owner
) {
    let unisolated = unsafe unsafeBitCast(
        callback,
        to: (@Sendable (ObservationEvent, Owner) -> Void).self
    )
    unisolated(event, owner)
}
