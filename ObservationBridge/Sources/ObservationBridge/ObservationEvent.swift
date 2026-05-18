/// Information about a single owner-bound observation pass.
public struct ObservationEvent: Sendable {
    /// The reason the observation callback is running.
    public enum Kind: Sendable, Equatable {
        /// The initial tracking pass.
        case initial

        /// A subsequent pass after observed state changed.
        case didSet
    }

    /// The reason the observation callback is running.
    public let kind: Kind

    private let cancelOperation: @Sendable () -> Void

    init(kind: Kind, cancelOperation: @escaping @Sendable () -> Void) {
        self.kind = kind
        self.cancelOperation = cancelOperation
    }

    /// Cancels the current observation.
    public func cancel() {
        cancelOperation()
    }
}
