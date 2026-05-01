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

    func store(_ declaration: ObservationScopeDeclaration) {
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
