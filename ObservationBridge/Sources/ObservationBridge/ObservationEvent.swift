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

        #if compiler(>=6.4)
        /// A pass triggered before a tracked property mutation.
        @available(*, unavailable, message: "ObservationEvent.Kind.willSet is reserved for the Swift 6.4 native backend.")
        public static var willSet: Kind {
            Kind(rawValue: .willSet)
        }
        #endif

        /// A pass after observed state changed.
        public static var didSet: Kind {
            Kind(rawValue: .didSet)
        }

        static var legacyWillSet: Kind {
            Kind(rawValue: .willSet)
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
    @available(*, unavailable, message: "ObservationEvent.matches(_:) is reserved for the Swift 6.4 native backend.")
    public func matches(_ keyPath: PartialKeyPath<some Observable>) -> Bool {
        false
    }
    #endif

    /// Cancels the current observation.
    public func cancel() {
        cancelOperation()
    }
}
