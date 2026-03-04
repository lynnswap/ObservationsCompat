import Synchronization

private final class WeakOwnerReference: @unchecked Sendable {
    weak var owner: AnyObject?

    init(owner: AnyObject) {
        self.owner = owner
    }
}

private final class WeakOwnerBox: @unchecked Sendable {
    private struct State {
        var isActive: Bool
        var ownerReference: WeakOwnerReference
    }

    init(owner: AnyObject) {
        state = Mutex(
            State(
                isActive: true,
                ownerReference: WeakOwnerReference(owner: owner)
            )
        )
    }

    func ownerIfActive() -> AnyObject? {
        state.withLock { state in
            guard state.isActive else {
                return nil
            }
            return state.ownerReference.owner
        }
    }

    func deactivate() {
        state.withLock { state in
            state.isActive = false
        }
    }

    private let state: Mutex<State>
}

enum WeakOwnerRegistry {
    private struct State {
        var nextToken: UInt64 = 1
        var owners: [UInt64: WeakOwnerBox] = [:]
    }

    private static let state = Mutex(State())

    static func createToken(owner: AnyObject) -> UInt64 {
        var token: UInt64 = 0
        state.withLock { (state: inout State) in
            token = state.nextToken
            state.nextToken &+= 1
            state.owners[token] = WeakOwnerBox(owner: owner)
        }
        return token
    }

    static func owner(token: UInt64) -> AnyObject? {
        let resolvedOwner = state.withLock { (state: inout State) -> AnyObject? in
            guard let box = state.owners[token] else {
                return nil
            }

            guard let owner = box.ownerIfActive() else {
                state.owners[token] = nil
                box.deactivate()
                return nil
            }

            return owner
        }
        return resolvedOwner
    }

    static func ownerAccessor(token: UInt64) -> @Sendable () -> AnyObject? {
        let box = state.withLock { (state: inout State) in
            state.owners[token]
        }

        guard let box else {
            return { nil }
        }

        return {
            guard let owner = box.ownerIfActive() else {
                removeToken(token)
                return nil
            }
            return owner
        }
    }

    static func removeToken(_ token: UInt64) {
        let box = state.withLock { (state: inout State) in
            state.owners.removeValue(forKey: token)
        }
        box?.deactivate()
    }
}
