public enum ObservationDebounceMode: Sendable, Hashable {
    case immediateFirst
    case delayedFirst
}

public struct ObservationDebounce: Sendable, Hashable {
    public let interval: Duration
    public let tolerance: Duration?
    public let mode: ObservationDebounceMode

    public init(
        interval: Duration,
        tolerance: Duration? = nil,
        mode: ObservationDebounceMode = .immediateFirst
    ) {
        self.interval = interval
        self.tolerance = tolerance
        self.mode = mode
    }
}

public enum ObservationThrottleMode: Sendable, Hashable {
    case latest
    case earliest
}

public struct ObservationThrottle: Sendable, Hashable {
    public let interval: Duration
    public let mode: ObservationThrottleMode

    public init(
        interval: Duration,
        mode: ObservationThrottleMode = .latest
    ) {
        self.interval = interval
        self.mode = mode
    }
}

public enum ObservationRateLimit: Sendable, Hashable {
    case debounce(ObservationDebounce)
    case throttle(ObservationThrottle)
}

public enum ObservationBackend: Sendable, Hashable {
    case automatic
    case legacy
}

public struct ObservationOptions: Sendable, Hashable {
    public let rateLimit: ObservationRateLimit?
    public let backend: ObservationBackend

    public init(
        rateLimit: ObservationRateLimit? = nil,
        backend: ObservationBackend = .automatic
    ) {
        self.rateLimit = rateLimit
        self.backend = backend
    }

    @available(iOS 26.0, macOS 26.0, *)
    public static let legacyBackend = ObservationOptions(backend: .legacy)

    public static func rateLimit(_ configuration: ObservationRateLimit) -> ObservationOptions {
        ObservationOptions(rateLimit: configuration)
    }

    var forcesLegacyBackend: Bool {
        backend == .legacy
    }
}
