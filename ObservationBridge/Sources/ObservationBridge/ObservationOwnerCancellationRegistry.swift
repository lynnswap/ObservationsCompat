import Synchronization

#if canImport(ObjectiveC)
import ObjectiveC
#endif

enum OwnerCancellationRegistry {
#if canImport(ObjectiveC)
    private static let storeLock = Mutex(())
    nonisolated(unsafe) private static var lifetimeStoreKey: UInt8 = 0
#endif

    static func register(
        _ handle: ObservationHandle,
        owner: AnyObject
    ) {
#if canImport(ObjectiveC)
        let handleID = ObjectIdentifier(handle)
        let store = loadOrCreateStore(owner: owner)
        store.insertCancellationHandler(id: handleID) { [weak handle] in
            handle?.cancel()
        }

        handle.addCancellationHandler { [weak store] in
            store?.remove(id: handleID)
        }
#else
        _ = handle
        _ = owner
#endif
    }

#if canImport(ObjectiveC)
    private static func loadOrCreateStore(owner: AnyObject) -> ObservationOwnerCancellationStore {
        storeLock.withLock { (_: inout ()) in
            if let existing = unsafe objc_getAssociatedObject(owner, &lifetimeStoreKey) as? ObservationOwnerCancellationStore {
                return existing
            }

            let store = ObservationOwnerCancellationStore()
            unsafe objc_setAssociatedObject(owner, &lifetimeStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            guard let attached = unsafe objc_getAssociatedObject(owner, &lifetimeStoreKey) as? ObservationOwnerCancellationStore else {
                preconditionFailure("owner cancellation registration is unsupported for this owner type")
            }
            return attached
        }
    }
#endif
}
