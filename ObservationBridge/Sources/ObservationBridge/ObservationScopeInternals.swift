import Synchronization

protocol ObservationScopeCallbackBox: AnyObject, Sendable {
    func clear()
}

final class ObservationScopeSlot {
    let descriptor: ObservationScopeDescriptor
    let callbackBox: any ObservationScopeCallbackBox
    private let ownerReference: ObservationScopeWeakOwnerReference
    private let handle: ObservationHandle

    init(
        descriptor: ObservationScopeDescriptor,
        owner: AnyObject,
        handle: ObservationHandle,
        callbackBox: any ObservationScopeCallbackBox
    ) {
        self.descriptor = descriptor
        self.ownerReference = ObservationScopeWeakOwnerReference(owner: owner)
        self.handle = handle
        self.callbackBox = callbackBox

        handle.addCancellationHandler { [callbackBox] in
            callbackBox.clear()
        }
    }

    func matches(_ descriptor: ObservationScopeDescriptor) -> Bool {
        ownerReference.owner != nil && self.descriptor == descriptor
    }

    func cancel() {
        handle.cancel()
    }
}

private final class ObservationScopeWeakOwnerReference {
    weak var owner: AnyObject?

    init(owner: AnyObject) {
        self.owner = owner
    }
}

final class ObservationScopeDeclaration {
    let id: AnyHashable
    let descriptor: ObservationScopeDescriptor
    let update: (ObservationScopeSlot) -> Bool
    let makeSlot: () -> ObservationScopeSlot?

    init(
        id: AnyHashable,
        descriptor: ObservationScopeDescriptor,
        update: @escaping (ObservationScopeSlot) -> Bool,
        makeSlot: @escaping () -> ObservationScopeSlot?
    ) {
        self.id = id
        self.descriptor = descriptor
        self.update = update
        self.makeSlot = makeSlot
    }
}

enum ObservationScopeKind: Hashable {
    case observeValue
    case observeVoid
    case observeTaskValue
    case observeTaskVoid
    case observeTrigger
    case observeTaskTrigger
}

struct ObservationScopeDescriptor: Equatable {
    let ownerID: ObjectIdentifier
    let keyPaths: [AnyKeyPath]
    let options: ObservationOptions
    let clockIdentity: ObservationScopeClockIdentity?
    let isolationID: ObjectIdentifier?
    let callbackIsolationID: ObjectIdentifier?
    let kind: ObservationScopeKind
    let valueTypeID: ObjectIdentifier?

    static func singleKeyPath<Owner: AnyObject, Value>(
        owner: Owner,
        keyPath: KeyPath<Owner, Value>,
        options: ObservationOptions,
        clock: any Clock<Duration>,
        isolation: (any Actor)?,
        callbackIsolation: (any Actor)?,
        kind: ObservationScopeKind,
        valueType: Value.Type
    ) -> ObservationScopeDescriptor {
        ObservationScopeDescriptor(
            ownerID: ObjectIdentifier(owner),
            keyPaths: [keyPath],
            options: options,
            clockIdentity: clockIdentity(for: clock, options: options),
            isolationID: actorID(isolation),
            callbackIsolationID: actorID(callbackIsolation),
            kind: kind,
            valueTypeID: ObjectIdentifier(valueType)
        )
    }

    static func multipleKeyPaths<Owner: AnyObject>(
        owner: Owner,
        keyPaths: [PartialKeyPath<Owner>],
        options: ObservationOptions,
        clock: any Clock<Duration>,
        isolation: (any Actor)?,
        callbackIsolation: (any Actor)?,
        kind: ObservationScopeKind
    ) -> ObservationScopeDescriptor {
        ObservationScopeDescriptor(
            ownerID: ObjectIdentifier(owner),
            keyPaths: keyPaths,
            options: options,
            clockIdentity: clockIdentity(for: clock, options: options),
            isolationID: actorID(isolation),
            callbackIsolationID: actorID(callbackIsolation),
            kind: kind,
            valueTypeID: nil
        )
    }

    private static func clockIdentity(
        for clock: any Clock<Duration>,
        options: ObservationOptions
    ) -> ObservationScopeClockIdentity? {
        guard options.rateLimit != nil else {
            return nil
        }
        return ObservationScopeClockIdentity(clock)
    }

    private static func actorID(_ actor: (any Actor)?) -> ObjectIdentifier? {
        actor.map { ObjectIdentifier($0 as AnyObject) }
    }
}

enum ObservationScopeClockIdentity: Equatable {
    case stateless(typeID: ObjectIdentifier)
    case object(typeID: ObjectIdentifier, objectID: ObjectIdentifier)
    case hashable(typeID: ObjectIdentifier, value: AnyHashable)
    case unique(typeID: ObjectIdentifier, token: ObservationScopeClockIdentityToken)

    init(_ clock: any Clock<Duration>) {
        let clockType = type(of: clock)
        let typeID = ObjectIdentifier(clockType)

        if clockType is AnyObject.Type {
            self = .object(typeID: typeID, objectID: ObjectIdentifier(clock as AnyObject))
        } else if clock is ContinuousClock || clock is SuspendingClock {
            self = .stateless(typeID: typeID)
        } else if let hashableClock = clock as? any Hashable {
            self = .hashable(typeID: typeID, value: AnyHashable(hashableClock))
        } else {
            self = .unique(typeID: typeID, token: ObservationScopeClockIdentityToken())
        }
    }
}

final class ObservationScopeClockIdentityToken: Equatable {
    static func == (
        lhs: ObservationScopeClockIdentityToken,
        rhs: ObservationScopeClockIdentityToken
    ) -> Bool {
        lhs === rhs
    }
}

private struct ObservationScopeAutomaticID: Hashable {
    let fileID: String
    let line: UInt
    let column: UInt
    let ownerID: ObjectIdentifier
    let keyPaths: [AnyKeyPath]
    let options: ObservationOptions
    let isolationID: ObjectIdentifier?
    let callbackIsolationID: ObjectIdentifier?
    let kind: ObservationScopeKind
    let valueTypeID: ObjectIdentifier?
}

func observationScopeResolvedID(
    _ id: AnyHashable?,
    descriptor: ObservationScopeDescriptor,
    fileID: StaticString,
    line: UInt,
    column: UInt
) -> AnyHashable {
    if let id {
        return id
    }

    return AnyHashable(
        ObservationScopeAutomaticID(
            fileID: String(describing: fileID),
            line: line,
            column: column,
            ownerID: descriptor.ownerID,
            keyPaths: descriptor.keyPaths,
            options: descriptor.options,
            isolationID: descriptor.isolationID,
            callbackIsolationID: descriptor.callbackIsolationID,
            kind: descriptor.kind,
            valueTypeID: descriptor.valueTypeID
        )
    )
}

final class ObservationScopeValueCallbackBox<Value: Sendable>: ObservationScopeCallbackBox, @unchecked Sendable {
    private struct State: Sendable {
        var callback: @isolated(any) @Sendable (sending Value) async -> Void
    }

    private let state: Mutex<State>

    init(_ callback: @escaping @isolated(any) @Sendable (sending Value) async -> Void) {
        state = Mutex(State(callback: callback))
    }

    func snapshot() -> @isolated(any) @Sendable (sending Value) async -> Void {
        state.withLock { state in
            state.callback
        }
    }

    func update(_ callback: @escaping @isolated(any) @Sendable (sending Value) async -> Void) {
        state.withLock { state in
            state.callback = callback
        }
    }

    func clear() {
        update { _ in }
    }

    func call(_ value: sending Value) async {
        let callback = snapshot()
        await callback(value)
    }
}

final class ObservationScopeNonSendableValueCallbackBox<Value>: ObservationScopeCallbackBox, @unchecked Sendable {
    private struct State {
        var callback: @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
    }

    private let state: Mutex<State>

    init(
        _ callback: @escaping @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
    ) {
        state = Mutex(State(callback: callback))
    }

    func snapshot() -> @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void {
        state.withLock { state in
            state.callback
        }
    }

    func update(
        _ callback: @escaping @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
    ) {
        state.withLock { state in
            state.callback = callback
        }
    }

    func clear() {
        update { _ in }
    }

    func call(_ value: sending _UncheckedSendableValueBox<Value>) async {
        let callback = snapshot()
        await callback(value)
    }
}

final class ObservationScopeVoidCallbackBox: ObservationScopeCallbackBox, @unchecked Sendable {
    private struct State: Sendable {
        var callback: @isolated(any) @Sendable () async -> Void
    }

    private let state: Mutex<State>

    init(_ callback: @escaping @isolated(any) @Sendable () async -> Void) {
        state = Mutex(State(callback: callback))
    }

    func snapshot() -> @isolated(any) @Sendable () async -> Void {
        state.withLock { state in
            state.callback
        }
    }

    func update(_ callback: @escaping @isolated(any) @Sendable () async -> Void) {
        state.withLock { state in
            state.callback = callback
        }
    }

    func clear() {
        update {}
    }

    func call() async {
        let callback = snapshot()
        await callback()
    }
}

func observationScopeMakeKeyPathGetter<Owner: AnyObject, Value>(
    _ keyPath: KeyPath<Owner, Value>
) -> @isolated(any) @Sendable (Owner) -> Value {
    let keyPath = ObservationScopeUncheckedSendableKeyPath(keyPath: keyPath)
    return { owner in
        owner[keyPath: keyPath.keyPath]
    }
}

func observationScopeMakeAnyKeyPathsTriggerGetter<Owner: AnyObject>(
    _ keyPaths: [PartialKeyPath<Owner>]
) -> @isolated(any) @Sendable (Owner) -> Void {
    let keyPaths = ObservationScopeUncheckedSendablePartialKeyPaths(keyPaths: keyPaths)
    return { owner in
        for keyPath in keyPaths.keyPaths {
            _ = owner[keyPath: keyPath]
        }
    }
}

private struct ObservationScopeUncheckedSendableKeyPath<Owner: AnyObject, Value>: @unchecked Sendable {
    let keyPath: KeyPath<Owner, Value>
}

private struct ObservationScopeUncheckedSendablePartialKeyPaths<Owner: AnyObject>: @unchecked Sendable {
    let keyPaths: [PartialKeyPath<Owner>]
}
