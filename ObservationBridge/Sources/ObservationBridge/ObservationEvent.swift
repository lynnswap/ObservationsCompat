import Observation

/// Information about a single owner-bound observation pass.
public struct ObservationEvent: Sendable {
    /// The reason the observation callback is running.
    public struct Kind: Sendable, Equatable, Hashable, CustomStringConvertible {
        private enum RawValue: UInt8, Sendable {
            case initial
            case willSet
            case didSet
        }

        private let rawValue: RawValue

        /// The initial tracking pass.
        public static var initial: Kind {
            Kind(rawValue: .initial)
        }

        /// A pass triggered by a tracked property mutation.
        public static var willSet: Kind {
            Kind(rawValue: .willSet)
        }

        /// A pass after observed state changed.
        public static var didSet: Kind {
            Kind(rawValue: .didSet)
        }

        public var description: String {
            switch rawValue {
            case .initial:
                "initial"
            case .willSet:
                "willSet"
            case .didSet:
                "didSet"
            }
        }

        private init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }

    /// The reason the observation callback is running.
    public let kind: Kind

    private let cancelOperation: @Sendable () -> Void

    init(
        kind: Kind,
        cancelOperation: @escaping @Sendable () -> Void
    ) {
        self.kind = kind
        self.cancelOperation = cancelOperation
    }

    #if compiler(>=6.4)
    /// Returns whether this event was triggered by the supplied key path.
    public func matches(_ keyPath: PartialKeyPath<some Observable>) -> Bool {
        #error("Delegate ObservationEvent.matches(_:) to ObservationTracking.Event.matches(_:) in the Swift 6.4 backend.")
        false
    }
    #endif

    /// Cancels the current observation.
    public func cancel() {
        cancelOperation()
    }
}
