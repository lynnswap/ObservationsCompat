/// Controls when the first value is emitted by a debounced observation.
public enum ObservationDebounceMode: Sendable, Hashable {
    /// Emits the first observed value immediately, then debounces later values.
    case immediateFirst

    /// Waits for the debounce interval before emitting the first observed value.
    case delayedFirst
}

/// Configuration for debounce-based rate limiting.
public struct ObservationDebounce: Sendable, Hashable {
    /// The quiet period that must elapse before the latest pending value is emitted.
    public let interval: Duration

    /// The optional scheduling tolerance used when sleeping for the debounce interval.
    public let tolerance: Duration?

    /// The first-value behavior for the debounce pipeline.
    public let mode: ObservationDebounceMode

    /// Creates a debounce configuration.
    ///
    /// - Parameters:
    ///   - interval: The quiet period that must elapse before emitting the latest pending value.
    ///   - tolerance: The optional scheduling tolerance used by the underlying clock.
    ///   - mode: The first-value behavior. Defaults to ``ObservationDebounceMode/immediateFirst``.
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

/// Controls which pending value is emitted by a throttled observation.
public enum ObservationThrottleMode: Sendable, Hashable {
    /// Emits the latest value seen during each throttle interval.
    case latest

    /// Emits the earliest value seen during each throttle interval.
    case earliest
}

/// Configuration for throttle-based rate limiting.
public struct ObservationThrottle: Sendable, Hashable {
    /// The minimum interval between emitted values.
    public let interval: Duration

    /// The pending-value selection mode used after the initial immediate emission.
    public let mode: ObservationThrottleMode

    /// Creates a throttle configuration.
    ///
    /// - Parameters:
    ///   - interval: The minimum interval between emitted values.
    ///   - mode: The pending-value selection mode. Defaults to ``ObservationThrottleMode/latest``.
    public init(
        interval: Duration,
        mode: ObservationThrottleMode = .latest
    ) {
        self.interval = interval
        self.mode = mode
    }
}

/// Rate limiting applied to observation emissions.
public enum ObservationRateLimit: Sendable, Hashable {
    /// Emits the latest value after a quiet period.
    case debounce(ObservationDebounce)

    /// Emits at most one value per interval.
    case throttle(ObservationThrottle)
}

/// Selects the observation backend used to produce changes.
public enum ObservationBackend: Sendable, Hashable {
    /// Chooses the best backend for the current platform and observed value.
    case automatic

    /// Forces the legacy `withObservationTracking` backend.
    case legacy
}

/// Configuration shared by callback, task, and `AsyncSequence` observations.
public struct ObservationOptions: Sendable, Hashable {
    /// The optional rate-limit configuration applied before values reach the consumer.
    public let rateLimit: ObservationRateLimit?

    /// The backend selection strategy for the observation pipeline.
    public let backend: ObservationBackend

    /// Creates observation options.
    ///
    /// - Parameters:
    ///   - rateLimit: The optional rate-limit configuration applied to emitted values.
    ///   - backend: The backend selection strategy. Defaults to ``ObservationBackend/automatic``.
    public init(
        rateLimit: ObservationRateLimit? = nil,
        backend: ObservationBackend = .automatic
    ) {
        self.rateLimit = rateLimit
        self.backend = backend
    }

    /// Options that force the legacy `withObservationTracking` backend.
    @available(iOS 26.0, macOS 26.0, *)
    public static let legacyBackend = ObservationOptions(backend: .legacy)

    /// Creates options that apply the supplied rate-limit configuration.
    ///
    /// - Parameter configuration: The rate-limit configuration to apply.
    /// - Returns: Options with the rate limit set and the backend left automatic.
    public static func rateLimit(_ configuration: ObservationRateLimit) -> ObservationOptions {
        ObservationOptions(rateLimit: configuration)
    }

    var forcesLegacyBackend: Bool {
        backend == .legacy
    }
}
