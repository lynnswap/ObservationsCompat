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
