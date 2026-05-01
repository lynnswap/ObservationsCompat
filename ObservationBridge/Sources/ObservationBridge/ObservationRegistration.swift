/// A pending observation declaration that becomes active when stored in an ``ObservationScope``.
///
/// `observe` and `observeTask` return registrations instead of starting immediately. Store the
/// registration in a scope to keep the observation alive for that scope's lifetime.
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

    /// Stores the registration in a scope and starts or updates the observation.
    ///
    /// If the scope already contains a compatible observation with the same resolved identity,
    /// the existing pipeline is reused and only its callback is replaced.
    ///
    /// - Parameter scope: The lifecycle owner that keeps the observation active.
    public func store(in scope: ObservationScope) {
        scope.store(declaration)
    }
}
