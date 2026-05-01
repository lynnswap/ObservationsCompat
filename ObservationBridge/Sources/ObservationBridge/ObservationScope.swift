import Synchronization

public final class ObservationScope {
    private var slots: [AnyHashable: ObservationScopeSlot] = [:]
    private var transactionDeclarations: [AnyHashable: ObservationScopeDeclaration]?
    private var creatingSlotCounts: [AnyHashable: Int] = [:]
    private var pendingDeclarationTokens: [AnyHashable: [UInt64]] = [:]
    private var invalidatedPendingDeclarationTokens: Set<UInt64> = []
    private var nextPendingDeclarationToken: UInt64 = 0
    private var cancelledSlotCreationIDs: Set<AnyHashable> = []
    private var cancelsAllDuringSlotCreation = false

    public init() {}

    public func update(_ body: () -> Void) {
        if transactionDeclarations != nil {
            body()
            return
        }

        transactionDeclarations = [:]
        body()
        let declarations = transactionDeclarations ?? [:]
        transactionDeclarations = nil

        apply(declarations, cancelsMissingSlots: true)
    }

    public func cancel(id: some Hashable) {
        let id = AnyHashable(id)
        transactionDeclarations?.removeValue(forKey: id)
        if creatingSlotCounts[id] != nil || pendingDeclarationTokens[id] != nil {
            cancelledSlotCreationIDs.insert(id)
        }
        if let slot = slots.removeValue(forKey: id) {
            slot.cancel()
        }
    }

    public func cancelAll() {
        transactionDeclarations?.removeAll(keepingCapacity: true)
        let currentSlots = Array(slots.values)
        slots.removeAll(keepingCapacity: true)
        if !creatingSlotCounts.isEmpty {
            cancelsAllDuringSlotCreation = true
            cancelledSlotCreationIDs.formUnion(creatingSlotCounts.keys)
        }

        for slot in currentSlots {
            slot.cancel()
        }
    }

    deinit {
        cancelAll()
    }

    fileprivate func store(_ declaration: ObservationScopeDeclaration) {
        if transactionDeclarations != nil {
            transactionDeclarations?[declaration.id] = declaration
            return
        }

        apply([declaration.id: declaration], cancelsMissingSlots: false)
    }

    private func apply(
        _ declarations: [AnyHashable: ObservationScopeDeclaration],
        cancelsMissingSlots: Bool
    ) {
        let declarationIDs = Array(declarations.keys)
        invalidatePendingDeclarations(for: declarationIDs)
        let pendingTokens = beginPendingDeclarations(declarationIDs)
        defer {
            endPendingDeclarations(pendingTokens, clearsCancellation: true)
        }

        for (id, declaration) in declarations {
            let token = pendingTokens[id]
            let isSuperseded = token.map { invalidatedPendingDeclarationTokens.remove($0) != nil } ?? false
            if let token {
                endPendingDeclaration(id: id, token: token, clearsCancellation: false)
            }
            if isSuperseded {
                clearCancelledSlotCreationIDIfInactive(id: id)
                continue
            }

            if cancelledSlotCreationIDs.contains(id) {
                slots.removeValue(forKey: id)?.cancel()
                clearCancelledSlotCreationIDIfInactive(id: id)
                continue
            }

            if let slot = slots[id],
               slot.matches(declaration.descriptor),
               declaration.update(slot) {
                continue
            }

            slots.removeValue(forKey: id)?.cancel()
            guard makeAndStoreSlot(id: id, declaration: declaration) else {
                break
            }
        }

        guard cancelsMissingSlots else {
            return
        }

        let activeIDs = Set(declarations.keys)
        let missingCreatingIDs = creatingSlotCounts.keys.filter { !activeIDs.contains($0) }
        cancelledSlotCreationIDs.formUnion(missingCreatingIDs)

        let inactiveIDs = slots.keys.filter { !activeIDs.contains($0) }
        for id in inactiveIDs {
            slots.removeValue(forKey: id)?.cancel()
        }
    }

    private func makeAndStoreSlot(
        id: AnyHashable,
        declaration: ObservationScopeDeclaration
    ) -> Bool {
        creatingSlotCounts[id, default: 0] += 1
        let slot = declaration.makeSlot()
        endCreatingSlot(id: id)

        let wasCancelled = cancelsAllDuringSlotCreation || cancelledSlotCreationIDs.contains(id)
        let wasSuperseded = slots[id] != nil
        let shouldCancel = wasCancelled || wasSuperseded
        if shouldCancel {
            slot?.cancel()
        } else if let slot {
            slots[id] = slot
        }

        if creatingSlotCounts[id] == nil {
            clearCancelledSlotCreationIDIfInactive(id: id)
        }

        let shouldContinue = !cancelsAllDuringSlotCreation
        if creatingSlotCounts.isEmpty, cancelsAllDuringSlotCreation {
            cancelsAllDuringSlotCreation = false
            cancelledSlotCreationIDs.removeAll(keepingCapacity: true)
        }
        return shouldContinue
    }

    private func endCreatingSlot(id: AnyHashable) {
        guard let count = creatingSlotCounts[id] else {
            return
        }
        if count == 1 {
            creatingSlotCounts.removeValue(forKey: id)
        } else {
            creatingSlotCounts[id] = count - 1
        }
    }

    private func invalidatePendingDeclarations(for ids: some Sequence<AnyHashable>) {
        for id in ids {
            if let tokens = pendingDeclarationTokens[id] {
                invalidatedPendingDeclarationTokens.formUnion(tokens)
            }
        }
    }

    private func beginPendingDeclarations(_ ids: some Sequence<AnyHashable>) -> [AnyHashable: UInt64] {
        var tokensByID: [AnyHashable: UInt64] = [:]
        for id in ids {
            nextPendingDeclarationToken += 1
            let token = nextPendingDeclarationToken
            pendingDeclarationTokens[id, default: []].append(token)
            tokensByID[id] = token
        }
        return tokensByID
    }

    private func endPendingDeclarations(
        _ tokensByID: [AnyHashable: UInt64],
        clearsCancellation: Bool
    ) {
        for (id, token) in tokensByID {
            endPendingDeclaration(
                id: id,
                token: token,
                clearsCancellation: clearsCancellation
            )
        }
    }

    private func endPendingDeclaration(
        id: AnyHashable,
        token: UInt64,
        clearsCancellation: Bool
    ) {
        guard var tokens = pendingDeclarationTokens[id],
              let index = tokens.firstIndex(of: token)
        else {
            return
        }

        tokens.remove(at: index)
        invalidatedPendingDeclarationTokens.remove(token)

        if tokens.isEmpty {
            pendingDeclarationTokens.removeValue(forKey: id)
            if clearsCancellation {
                clearCancelledSlotCreationIDIfInactive(id: id)
            }
        } else {
            pendingDeclarationTokens[id] = tokens
        }
    }

    private func clearCancelledSlotCreationIDIfInactive(id: AnyHashable) {
        if creatingSlotCounts[id] == nil, pendingDeclarationTokens[id] == nil {
            cancelledSlotCreationIDs.remove(id)
        }
    }
}

public struct ObservationRegistration: @unchecked Sendable {
    private let declaration: ObservationScopeDeclaration

    init(
        id: AnyHashable?,
        descriptor: ObservationScopeDescriptor,
        fileID: StaticString,
        line: UInt,
        column: UInt,
        update: @escaping (ObservationScopeSlot) -> Bool,
        makeSlot: @escaping () -> ObservationScopeSlot?
    ) {
        declaration = ObservationScopeDeclaration(
            id: observationScopeResolvedID(
                id,
                descriptor: descriptor,
                fileID: fileID,
                line: line,
                column: column
            ),
            descriptor: descriptor,
            update: update,
            makeSlot: makeSlot
        )
    }

    public func store(in scope: ObservationScope) {
        scope.store(declaration)
    }
}

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
    let optionsRawValue: UInt64
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
            optionsRawValue: options.rawValue,
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
            optionsRawValue: options.rawValue,
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
    let optionsRawValue: UInt64
    let isolationID: ObjectIdentifier?
    let callbackIsolationID: ObjectIdentifier?
    let kind: ObservationScopeKind
    let valueTypeID: ObjectIdentifier?
}

private func observationScopeResolvedID(
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
            optionsRawValue: descriptor.optionsRawValue,
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
