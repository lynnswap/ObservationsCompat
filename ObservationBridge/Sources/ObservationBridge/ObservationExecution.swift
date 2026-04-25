import AsyncAlgorithms
import Observation
import Synchronization
internal import _ObservationBridgeLegacy

private enum OwnerValueEmission<Value> {
    case value(Value)
    case ownerGone
}

extension OwnerValueEmission: Sendable where Value: Sendable {}

private struct ObservedValueChannel<Value: Sendable>: Sendable {
    let channel: AsyncChannel<Value>
    let producerTask: Task<Void, Never>
}

private struct PendingObserveTaskOperation<Value: Sendable>: Sendable {
    let id: UInt64
    let value: Value
}

private struct ImmediateFirstDebounceExecutionState: Sendable {
    var didEmitFirst = false
    var shouldStop = false
}

private struct RateLimitedConsumerState: Sendable {
    var shouldStop = false
}

private struct RateLimitedDrainState: Sendable {
    var isDraining = false
    var needsDrain = false
}

private struct ObserveTaskExecutionState<Value: Sendable>: Sendable {
    var activeOperationTask: Task<Void, Never>? = nil
    var activeOperationID: UInt64? = nil
    var activeOperationValue: Value? = nil
    var nextOperationID: UInt64 = 0
    var pendingNextValue: Value? = nil
    var pendingFollowingValue: Value? = nil
    var pendingCoalescedValue: Value? = nil
    var lastDeliveredValue: Value? = nil
    var isCancelled = false

    var hasActiveOperation: Bool {
        activeOperationID != nil
    }
}

@discardableResult
private func makeObservationTask<Success: Sendable>(
    @_inheritActorContext operation: @escaping @isolated(any) @Sendable () async -> Success
) -> Task<Success, Never> {
    if #available(iOS 26.0, macOS 26.0, *) {
        return Task.immediate(operation: operation)
    }
    return Task(operation: operation)
}

private final class ObservationExecutionLifetime: Sendable {
    private struct State {
        var isCancelled = false
        var handlers: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    func addCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        let shouldRunImmediately = state.withLock { state in
            if state.isCancelled {
                return true
            }

            state.handlers.append(handler)
            return false
        }

        if shouldRunImmediately {
            handler()
        }
    }

    func cancel() {
        let handlersToRun = state.withLock { state in
            if state.isCancelled {
                return [@Sendable () -> Void]()
            }

            state.isCancelled = true
            let handlers = state.handlers
            state.handlers = []
            return handlers
        }

        for handler in handlersToRun {
            handler()
        }
    }
}

struct ThrottleExecutionState<Value: Sendable>: Sendable {
    var readyValue: Value? = nil
    var pendingValue: Value? = nil
    var nextTimerToken: UInt64 = 0
    var activeTimerToken: UInt64? = nil
    var isSourceFinished = false

    mutating func recordIncomingValue(
        _ value: Value,
        keepLatestPending: Bool
    ) {
        if activeTimerToken == nil {
            if readyValue == nil {
                readyValue = value
            } else if pendingValue == nil || keepLatestPending {
                pendingValue = value
            }
        } else if pendingValue == nil || keepLatestPending {
            pendingValue = value
        }
    }

    mutating func finishSource() {
        isSourceFinished = true
    }

    mutating func expireTimer(token: UInt64) -> Bool {
        guard activeTimerToken == token else {
            return false
        }

        activeTimerToken = nil
        if let pendingValue {
            readyValue = pendingValue
            self.pendingValue = nil
        }
        return true
    }

    mutating func nextAction() -> ThrottleAction<Value> {
        if let readyValue {
            self.readyValue = nil
            if isSourceFinished, pendingValue == nil {
                return .emit(value: readyValue, timerToken: nil, finishAfterEmit: true)
            }

            let timerToken = nextTimerToken
            nextTimerToken &+= 1
            activeTimerToken = timerToken
            return .emit(value: readyValue, timerToken: timerToken, finishAfterEmit: false)
        }

        if activeTimerToken == nil {
            if isSourceFinished {
                return .finish
            }
        } else if isSourceFinished, pendingValue == nil {
            activeTimerToken = nil
            return .finish
        }

        return .idle
    }
}

private final class ThrottleStateBox<Value: Sendable>: @unchecked Sendable {
    let state: Mutex<ThrottleExecutionState<Value>>

    init() {
        state = Mutex(ThrottleExecutionState())
    }
}

private final class ObservationTaskBox: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func replace(with newTask: Task<Void, Never>?) {
        let oldTask = task.withLock { task in
            let oldTask = task
            task = newTask
            return oldTask
        }
        oldTask?.cancel()
    }

    func cancel() {
        replace(with: nil)
    }
}

enum ThrottleAction<Value>: Sendable where Value: Sendable {
    case emit(value: Value, timerToken: UInt64?, finishAfterEmit: Bool)
    case finish
    case idle
}

final class _UncheckedSendableValueBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

func observeImpl<Owner: AnyObject, Value: Sendable>(
    owner: Owner,
    options: ObservationOptions,
    rateLimit: ObservationRateLimit?,
    rateLimitClock: any Clock<Duration>,
    isolation: (any Actor)?,
    callbackIsolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) async -> Void
) -> ObservationHandle {
    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let lifetime = ObservationExecutionLifetime()
    lifetime.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }
    let monitorTask = makeObservationTask {
        defer {
            lifetime.cancel()
        }

        if let rateLimit {
            switch rateLimit {
            case let .debounce(debounce) where debounce.mode == .delayedFirst:
                let observedValues = makeObservedValueChannel(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value
                )
                lifetime.addCancellationHandler {
                    observedValues.producerTask.cancel()
                    observedValues.channel.finish()
                }
                let rateLimitedValues = makeRateLimitedValueStream(
                    observedValues.channel,
                    rateLimit: rateLimit,
                    rateLimitClock: rateLimitClock
                )
                for await observedValue in rateLimitedValues {
                    guard !Task.isCancelled else {
                        break
                    }
                    await onChange(observedValue)
                }
            case let .debounce(debounce):
                await forEachImmediateFirstDebouncedOwnerValue(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value,
                    debounce: debounce,
                    debounceClock: rateLimitClock,
                    emitFirstInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            case let .throttle(throttle):
                await forEachThrottledOwnerValue(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value,
                    throttle: throttle,
                    throttleClock: rateLimitClock,
                    emitReadyValuesInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        } else {
            await forEachOwnerValueEmission(
                ownerToken: ownerToken,
                options: options,
                isolation: isolation,
                of: value
            ) { emission in
                switch emission {
                case .ownerGone:
                    return false
                case .value(let observedValue):
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
        lifetime.cancel()
    }

    OwnerCancellationRegistry.register(handle.box, owner: owner)
    return handle
}

func observeImplNonSendable<Owner: AnyObject, Value>(
    owner: Owner,
    options: ObservationOptions,
    rateLimit: ObservationRateLimit?,
    rateLimitClock: any Clock<Duration>,
    isolation: (any Actor)?,
    callbackIsolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
) -> ObservationHandle {
    _ = options

    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let lifetime = ObservationExecutionLifetime()
    lifetime.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }
    let monitorTask = makeObservationTask {
        defer {
            lifetime.cancel()
        }

        if let rateLimit {
            switch rateLimit {
            case let .debounce(debounce) where debounce.mode == .delayedFirst:
                let observedValues = makeObservedValueStreamNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value
                )
                let rateLimitedValues = makeRateLimitedValueStreamNonSendable(
                    observedValues,
                    rateLimit: rateLimit,
                    rateLimitClock: rateLimitClock
                )
                for await observedValue in rateLimitedValues {
                    guard !Task.isCancelled else {
                        break
                    }
                    await onChange(_UncheckedSendableValueBox(observedValue))
                }
            case let .debounce(debounce):
                await forEachImmediateFirstDebouncedOwnerValueNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value,
                    debounce: debounce,
                    debounceClock: rateLimitClock,
                    emitFirstInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            case let .throttle(throttle):
                await forEachThrottledOwnerValueNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value,
                    throttle: throttle,
                    throttleClock: rateLimitClock,
                    emitReadyValuesInline: callbackIsolation == nil
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        } else {
            await forEachOwnerValueEmissionNonSendable(
                ownerToken: ownerToken,
                isolation: isolation,
                of: value
            ) { emission in
                switch emission {
                case .ownerGone:
                    return false
                case .value(let observedValue):
                    guard !Task.isCancelled else {
                        return false
                    }
                    await onChange(observedValue)
                    return !Task.isCancelled
                }
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
        lifetime.cancel()
    }

    OwnerCancellationRegistry.register(handle.box, owner: owner)
    return handle
}

func observeTaskImpl<Owner: AnyObject, Value: Sendable>(
    owner: Owner,
    options: ObservationOptions,
    rateLimit: ObservationRateLimit?,
    rateLimitClock: any Clock<Duration>,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
) -> ObservationHandle {
    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let lifetime = ObservationExecutionLifetime()
    lifetime.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }
    let observeTaskState = Mutex(ObserveTaskExecutionState<Value>())
    let (operationWakeStream, operationWakeSignal) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )

    let operationDidFinish: @Sendable (UInt64) -> Void = { operationID in
        let shouldWake = observeTaskState.withLock { state in
            guard state.activeOperationID == operationID else {
                return false
            }

            if let activeOperationValue = state.activeOperationValue {
                state.lastDeliveredValue = activeOperationValue
            }
            state.activeOperationValue = nil
            state.activeOperationTask = nil
            state.activeOperationID = nil
            guard !state.isCancelled else {
                return false
            }
            return state.pendingNextValue != nil
        }

        if shouldWake {
            operationWakeSignal.yield(())
        }
    }

    let shutdownObserveTaskExecution: @Sendable () -> Void = {
        let activeTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            guard !state.isCancelled else {
                return nil
            }

            state.isCancelled = true
            state.pendingNextValue = nil
            state.pendingFollowingValue = nil
            state.pendingCoalescedValue = nil
            state.activeOperationID = nil
            state.activeOperationValue = nil
            let activeTask = state.activeOperationTask
            state.activeOperationTask = nil
            return activeTask
        }

        activeTask?.cancel()
        operationWakeSignal.finish()
    }

    let enqueueLatestValue: @Sendable (Value) -> Bool = { observedValue in
        let transition: (accepted: Bool, shouldWake: Bool) = observeTaskState.withLock { state -> (accepted: Bool, shouldWake: Bool) in
            guard !state.isCancelled else {
                return (accepted: false, shouldWake: false)
            }

            if state.pendingNextValue == nil {
                state.pendingNextValue = observedValue
                return (accepted: true, shouldWake: !state.hasActiveOperation)
            }

            if !state.hasActiveOperation, state.lastDeliveredValue == nil, state.pendingFollowingValue == nil {
                state.pendingFollowingValue = observedValue
                return (accepted: true, shouldWake: false)
            }

            state.pendingCoalescedValue = observedValue
            return (accepted: true, shouldWake: false)
        }

        guard transition.accepted else {
            return false
        }

        if transition.shouldWake {
            operationWakeSignal.yield(())
        }
        return true
    }

    let drainTask = makeObservationTask {
        for await _ in operationWakeStream {
            guard !Task.isCancelled else {
                break
            }

            while true {
                let pendingOperation: PendingObserveTaskOperation<Value>? = observeTaskState.withLock { state -> PendingObserveTaskOperation<Value>? in
                    guard !state.isCancelled else {
                        return nil
                    }
                    guard !state.hasActiveOperation, let nextValue = state.pendingNextValue else {
                        return nil
                    }

                    if let pendingFollowingValue = state.pendingFollowingValue {
                        state.pendingNextValue = pendingFollowingValue
                        state.pendingFollowingValue = nil
                    } else {
                        state.pendingNextValue = state.pendingCoalescedValue
                        state.pendingCoalescedValue = nil
                    }
                    let operationID = state.nextOperationID
                    state.nextOperationID &+= 1
                    state.activeOperationID = operationID
                    state.activeOperationValue = nextValue
                    return PendingObserveTaskOperation(id: operationID, value: nextValue)
                }

                guard let pendingOperation else {
                    break
                }

                let operation = makeObservationTask {
                    await task(pendingOperation.value)
                    operationDidFinish(pendingOperation.id)
                }
                let shouldCancelOperation = observeTaskState.withLock { state -> Bool in
                    guard !state.isCancelled, state.activeOperationID == pendingOperation.id else {
                        return true
                    }
                    state.activeOperationTask = operation
                    return false
                }
                if shouldCancelOperation {
                    operation.cancel()
                }
            }
        }

        let remainingTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            let remainingTask = state.activeOperationTask
            state.activeOperationTask = nil
            state.activeOperationID = nil
            state.activeOperationValue = nil
            return remainingTask
        }
        remainingTask?.cancel()
    }
    lifetime.addCancellationHandler {
        shutdownObserveTaskExecution()
        drainTask.cancel()
    }

    let monitorTask = makeObservationTask {
        defer {
            lifetime.cancel()
        }

        if let rateLimit {
            switch rateLimit {
            case let .debounce(debounce) where debounce.mode == .delayedFirst:
                let observedValues = makeObservedValueChannel(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value
                )
                lifetime.addCancellationHandler {
                    observedValues.producerTask.cancel()
                    observedValues.channel.finish()
                }
                let rateLimitedValues = makeRateLimitedValueStream(
                    observedValues.channel,
                    rateLimit: rateLimit,
                    rateLimitClock: rateLimitClock
                )
                for await observedValue in rateLimitedValues {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard enqueueLatestValue(observedValue) else {
                        break
                    }
                }
            case let .debounce(debounce):
                await forEachImmediateFirstDebouncedOwnerValue(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value,
                    debounce: debounce,
                    debounceClock: rateLimitClock,
                    emitFirstInline: true
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    return enqueueLatestValue(observedValue)
                }
            case let .throttle(throttle):
                await forEachThrottledOwnerValue(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    of: value,
                    throttle: throttle,
                    throttleClock: rateLimitClock,
                    emitReadyValuesInline: true
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    return enqueueLatestValue(observedValue)
                }
            }
        } else {
            await forEachOwnerValueEmission(
                ownerToken: ownerToken,
                options: options,
                isolation: isolation,
                of: value
            ) { emission in
                switch emission {
                case .ownerGone:
                    return false
                case .value(let observedValue):
                    guard !Task.isCancelled else {
                        return false
                    }
                    return enqueueLatestValue(observedValue)
                }
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
        lifetime.cancel()
    }

    OwnerCancellationRegistry.register(handle.box, owner: owner)
    return handle
}

func observeTaskImplNonSendable<Owner: AnyObject, Value>(
    owner: Owner,
    options: ObservationOptions,
    rateLimit: ObservationRateLimit?,
    rateLimitClock: any Clock<Duration>,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
) -> ObservationHandle {
    _ = options

    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let lifetime = ObservationExecutionLifetime()
    lifetime.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }
    let observeTaskState = Mutex(ObserveTaskExecutionState<_UncheckedSendableValueBox<Value>>())
    let (operationWakeStream, operationWakeSignal) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )

    let operationDidFinish: @Sendable (UInt64) -> Void = { operationID in
        let shouldWake = observeTaskState.withLock { state in
            guard state.activeOperationID == operationID else {
                return false
            }

            if let activeOperationValue = state.activeOperationValue {
                state.lastDeliveredValue = activeOperationValue
            }
            state.activeOperationValue = nil
            state.activeOperationTask = nil
            state.activeOperationID = nil
            guard !state.isCancelled else {
                return false
            }
            return state.pendingNextValue != nil
        }

        if shouldWake {
            operationWakeSignal.yield(())
        }
    }

    let shutdownObserveTaskExecution: @Sendable () -> Void = {
        let activeTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            guard !state.isCancelled else {
                return nil
            }

            state.isCancelled = true
            state.pendingNextValue = nil
            state.pendingFollowingValue = nil
            state.pendingCoalescedValue = nil
            state.activeOperationID = nil
            state.activeOperationValue = nil
            let activeTask = state.activeOperationTask
            state.activeOperationTask = nil
            return activeTask
        }

        activeTask?.cancel()
        operationWakeSignal.finish()
    }

    let enqueueLatestValue: @Sendable (sending _UncheckedSendableValueBox<Value>) -> Bool = { observedValue in
        let transition: (accepted: Bool, shouldWake: Bool) = observeTaskState.withLock { state -> (accepted: Bool, shouldWake: Bool) in
            guard !state.isCancelled else {
                return (accepted: false, shouldWake: false)
            }

            if state.pendingNextValue == nil {
                state.pendingNextValue = observedValue
                return (accepted: true, shouldWake: !state.hasActiveOperation)
            }

            if !state.hasActiveOperation, state.lastDeliveredValue == nil, state.pendingFollowingValue == nil {
                state.pendingFollowingValue = observedValue
                return (accepted: true, shouldWake: false)
            }

            state.pendingCoalescedValue = observedValue
            return (accepted: true, shouldWake: false)
        }

        guard transition.accepted else {
            return false
        }

        if transition.shouldWake {
            operationWakeSignal.yield(())
        }
        return true
    }

    let drainTask = makeObservationTask {
        for await _ in operationWakeStream {
            guard !Task.isCancelled else {
                break
            }

            while true {
                let pendingOperation: PendingObserveTaskOperation<_UncheckedSendableValueBox<Value>>? = observeTaskState.withLock { state -> PendingObserveTaskOperation<_UncheckedSendableValueBox<Value>>? in
                    guard !state.isCancelled else {
                        return nil
                    }
                    guard !state.hasActiveOperation, let nextValue = state.pendingNextValue else {
                        return nil
                    }

                    if let pendingFollowingValue = state.pendingFollowingValue {
                        state.pendingNextValue = pendingFollowingValue
                        state.pendingFollowingValue = nil
                    } else {
                        state.pendingNextValue = state.pendingCoalescedValue
                        state.pendingCoalescedValue = nil
                    }
                    let operationID = state.nextOperationID
                    state.nextOperationID &+= 1
                    state.activeOperationID = operationID
                    state.activeOperationValue = nextValue
                    return PendingObserveTaskOperation(id: operationID, value: nextValue)
                }

                guard let pendingOperation else {
                    break
                }

                let operation = makeObservationTask {
                    await task(pendingOperation.value)
                    operationDidFinish(pendingOperation.id)
                }
                let shouldCancelOperation = observeTaskState.withLock { state -> Bool in
                    guard !state.isCancelled, state.activeOperationID == pendingOperation.id else {
                        return true
                    }
                    state.activeOperationTask = operation
                    return false
                }
                if shouldCancelOperation {
                    operation.cancel()
                }
            }
        }

        let remainingTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            let remainingTask = state.activeOperationTask
            state.activeOperationTask = nil
            state.activeOperationID = nil
            state.activeOperationValue = nil
            return remainingTask
        }
        remainingTask?.cancel()
    }
    lifetime.addCancellationHandler {
        shutdownObserveTaskExecution()
        drainTask.cancel()
    }

    let monitorTask = makeObservationTask {
        defer {
            lifetime.cancel()
        }

        if let rateLimit {
            switch rateLimit {
            case let .debounce(debounce) where debounce.mode == .delayedFirst:
                let observedValues = makeObservedValueStreamNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value
                )
                let rateLimitedValues = makeRateLimitedValueStreamNonSendable(
                    observedValues,
                    rateLimit: rateLimit,
                    rateLimitClock: rateLimitClock
                )
                for await observedValue in rateLimitedValues {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard enqueueLatestValue(_UncheckedSendableValueBox(observedValue)) else {
                        break
                    }
                }
            case let .debounce(debounce):
                await forEachImmediateFirstDebouncedOwnerValueNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value,
                    debounce: debounce,
                    debounceClock: rateLimitClock,
                    emitFirstInline: true
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    return enqueueLatestValue(observedValue)
                }
            case let .throttle(throttle):
                await forEachThrottledOwnerValueNonSendable(
                    ownerToken: ownerToken,
                    isolation: isolation,
                    of: value,
                    throttle: throttle,
                    throttleClock: rateLimitClock,
                    emitReadyValuesInline: true
                ) { observedValue in
                    guard !Task.isCancelled else {
                        return false
                    }
                    return enqueueLatestValue(observedValue)
                }
            }
        } else {
            await forEachOwnerValueEmissionNonSendable(
                ownerToken: ownerToken,
                isolation: isolation,
                of: value
            ) { emission in
                switch emission {
                case .ownerGone:
                    return false
                case .value(let observedValue):
                    guard !Task.isCancelled else {
                        return false
                    }
                    return enqueueLatestValue(observedValue)
                }
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
        lifetime.cancel()
    }

    OwnerCancellationRegistry.register(handle.box, owner: owner)
    return handle
}

private func makeObservedValueChannel<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value
) -> ObservedValueChannel<Value> {
    let channel = AsyncChannel<Value>()
    let producerTask = Task {
        await forEachOwnerValueEmission(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            of: value
        ) { emission in
            switch emission {
            case .ownerGone:
                return false
            case .value(let observedValue):
                guard !Task.isCancelled else {
                    return false
                }
                await channel.send(observedValue)
                return !Task.isCancelled
            }
        }

        channel.finish()
    }

    return ObservedValueChannel(
        channel: channel,
        producerTask: producerTask
    )
}

private func makeObservedValueStreamNonSendable<Owner: AnyObject, Value>(
    ownerToken: UInt64,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value
) -> AsyncStream<Value> {
    let resolveOwner = WeakOwnerRegistry.ownerAccessor(token: ownerToken)
    let resolvedIsolation = value.isolation ?? isolation
    let observeOwnerValue: @isolated(any) @Sendable () -> OwnerValueEmission<_UncheckedSendableValueBox<Value>> = {
        switch _ObservationBridgeLegacy.legacyEvaluateObservedOwnerValue(
            owner: resolveOwner() as? Owner,
            value: value,
            map: _UncheckedSendableValueBox.init
        ) {
        case .ownerGone:
            return .ownerGone
        case .value(let observedValue):
            return .value(observedValue)
        }
    }

    let stream = makeLegacyObservationStream(
        observeOwnerValue,
        isolation: resolvedIsolation
    )
    return AsyncStream { continuation in
        let task = Task {
            for await emission in stream {
                guard !Task.isCancelled else {
                    break
                }

                switch emission {
                case .ownerGone:
                    continuation.finish()
                    return
                case .value(let observedValue):
                    continuation.yield(observedValue.value)
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

private func forEachOwnerValueEmissionNonSendable<Owner: AnyObject, Value>(
    ownerToken: UInt64,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    consume: @escaping @Sendable (OwnerValueEmission<_UncheckedSendableValueBox<Value>>) async -> Bool
) async {
    let resolveOwner = WeakOwnerRegistry.ownerAccessor(token: ownerToken)
    let resolvedIsolation = value.isolation ?? isolation
    let observeOwnerValue: @isolated(any) @Sendable () -> OwnerValueEmission<_UncheckedSendableValueBox<Value>> = {
        switch _ObservationBridgeLegacy.legacyEvaluateObservedOwnerValue(
            owner: resolveOwner() as? Owner,
            value: value,
            map: _UncheckedSendableValueBox.init
        ) {
        case .ownerGone:
            return .ownerGone
        case .value(let observedValue):
            return .value(observedValue)
        }
    }

    await forEachLegacyObservationEmission(
        observeOwnerValue,
        isolation: resolvedIsolation
    ) { emission in
        guard !Task.isCancelled else {
            return false
        }
        return await consume(emission)
    }
}

private func forEachImmediateFirstDebouncedOwnerValue<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>,
    emitFirstInline: Bool,
    consume: @escaping @Sendable (Value) async -> Bool
) async {
    await forEachImmediateFirstDebouncedValue(
        debounce: debounce,
        debounceClock: debounceClock,
        emitFirstInline: emitFirstInline
    ) { consumeValue in
        await forEachOwnerValueEmission(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            of: value
        ) { emission in
            switch emission {
            case .ownerGone:
                return false
            case .value(let observedValue):
                guard !Task.isCancelled else {
                    return false
                }
                return await consumeValue(observedValue)
            }
        }
    } consume: { observedValue in
        await consume(observedValue)
    }
}

private func forEachImmediateFirstDebouncedOwnerValueNonSendable<Owner: AnyObject, Value>(
    ownerToken: UInt64,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>,
    emitFirstInline: Bool,
    consume: @escaping @Sendable (_UncheckedSendableValueBox<Value>) async -> Bool
) async {
    await forEachImmediateFirstDebouncedValue(
        debounce: debounce,
        debounceClock: debounceClock,
        emitFirstInline: emitFirstInline
    ) { consumeValue in
        await forEachOwnerValueEmissionNonSendable(
            ownerToken: ownerToken,
            isolation: isolation,
            of: value
        ) { emission in
            switch emission {
            case .ownerGone:
                return false
            case .value(let observedValue):
                guard !Task.isCancelled else {
                    return false
                }
                return await consumeValue(observedValue)
            }
        }
    } consume: { observedValue in
        await consume(observedValue)
    }
}

private func forEachImmediateFirstDebouncedValue<Value: Sendable>(
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>,
    emitFirstInline: Bool,
    source: (@escaping @Sendable (Value) async -> Bool) async -> Void,
    consume: @escaping @Sendable (Value) async -> Bool
) async {
    let (remainingStream, remainingContinuation) = AsyncStream<Value>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let (outputStream, outputContinuation) = AsyncStream<Value>.makeStream(
        bufferingPolicy: .unbounded
    )
    let state = Mutex(ImmediateFirstDebounceExecutionState())
    let delayedDebounce = ObservationDebounce(
        interval: debounce.interval,
        tolerance: debounce.tolerance,
        mode: .delayedFirst
    )
    let consumerTask = makeObservationTask {
        for await observedValue in outputStream {
            guard !Task.isCancelled else {
                break
            }
            guard await consume(observedValue) else {
                state.withLock { state in
                    state.shouldStop = true
                }
                break
            }
        }
    }
    let debounceTask = makeObservationTask {
        let debouncedValues = makeDebouncedValueStream(
            remainingStream,
            debounce: delayedDebounce,
            debounceClock: debounceClock
        )
        for await observedValue in debouncedValues {
            guard !Task.isCancelled else {
                break
            }
            let shouldStop = state.withLock { state in
                state.shouldStop
            }
            guard !shouldStop else {
                break
            }
            outputContinuation.yield(observedValue)
        }
    }

    await withTaskCancellationHandler {
        await source { observedValue in
            let shouldEmitFirst: Bool? = state.withLock { state in
                guard !state.shouldStop else {
                    return nil
                }
                guard state.didEmitFirst else {
                    state.didEmitFirst = true
                    return true
                }
                return false
            }

            guard let shouldEmitFirst else {
                return false
            }

            if shouldEmitFirst {
                if emitFirstInline {
                    guard await consume(observedValue) else {
                        state.withLock { state in
                            state.shouldStop = true
                        }
                        return false
                    }
                    return !Task.isCancelled
                }

                outputContinuation.yield(observedValue)
                return state.withLock { state in
                    !state.shouldStop
                } && !Task.isCancelled
            }

            remainingContinuation.yield(observedValue)
            return state.withLock { state in
                !state.shouldStop
            } && !Task.isCancelled
        }

        remainingContinuation.finish()
        await debounceTask.value
        outputContinuation.finish()
        await consumerTask.value
    } onCancel: {
        state.withLock { state in
            state.shouldStop = true
        }
        remainingContinuation.finish()
        debounceTask.cancel()
        outputContinuation.finish()
        consumerTask.cancel()
    }
}

private func forEachThrottledOwnerValue<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    throttle: ObservationThrottle,
    throttleClock: any Clock<Duration>,
    emitReadyValuesInline: Bool,
    consume: @escaping @Sendable (Value) async -> Bool
) async {
    await forEachThrottledValue(
        throttle: throttle,
        throttleClock: throttleClock,
        emitReadyValuesInline: emitReadyValuesInline
    ) { consumeValue in
        await forEachOwnerValueEmission(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            of: value
        ) { emission in
            switch emission {
            case .ownerGone:
                return false
            case .value(let observedValue):
                guard !Task.isCancelled else {
                    return false
                }
                return await consumeValue(observedValue)
            }
        }
    } consume: { observedValue in
        await consume(observedValue)
    }
}

private func forEachThrottledOwnerValueNonSendable<Owner: AnyObject, Value>(
    ownerToken: UInt64,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    throttle: ObservationThrottle,
    throttleClock: any Clock<Duration>,
    emitReadyValuesInline: Bool,
    consume: @escaping @Sendable (_UncheckedSendableValueBox<Value>) async -> Bool
) async {
    await forEachThrottledValue(
        throttle: throttle,
        throttleClock: throttleClock,
        emitReadyValuesInline: emitReadyValuesInline
    ) { consumeValue in
        await forEachOwnerValueEmissionNonSendable(
            ownerToken: ownerToken,
            isolation: isolation,
            of: value
        ) { emission in
            switch emission {
            case .ownerGone:
                return false
            case .value(let observedValue):
                guard !Task.isCancelled else {
                    return false
                }
                return await consumeValue(observedValue)
            }
        }
    } consume: { observedValue in
        await consume(observedValue)
    }
}

func forEachThrottledValue<Value: Sendable>(
    throttle: ObservationThrottle,
    throttleClock: any Clock<Duration>,
    emitReadyValuesInline: Bool,
    source: (@escaping @Sendable (Value) async -> Bool) async -> Void,
    consume: @escaping @Sendable (Value) async -> Bool
) async {
    await forEachThrottledValue(
        throttle: throttle,
        clock: throttleClock,
        emitReadyValuesInline: emitReadyValuesInline,
        source: source,
        consume: consume
    )
}

func forEachThrottledValue<Value: Sendable, C: Clock<Duration>>(
    throttle: ObservationThrottle,
    clock: C,
    emitReadyValuesInline: Bool,
    source: (@escaping @Sendable (Value) async -> Bool) async -> Void,
    consume: @escaping @Sendable (Value) async -> Bool
) async {
    let stateBox = ThrottleStateBox<Value>()
    let timerTaskBox = ObservationTaskBox()
    let consumerState = Mutex(RateLimitedConsumerState())
    let drainState = Mutex(RateLimitedDrainState())
    let (wakeStream, wakeSignal) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let (drainFinishedStream, drainFinishedSignal) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let (outputStream, outputContinuation) = AsyncStream<Value>.makeStream(
        bufferingPolicy: .unbounded
    )
    let keepLatestPending = throttle.mode == .latest
    let throttleInterval = throttle.interval
    let consumerTask = makeObservationTask {
        for await observedValue in outputStream {
            guard !Task.isCancelled else {
                break
            }
            guard await consume(observedValue) else {
                consumerState.withLock { state in
                    state.shouldStop = true
                }
                break
            }
        }
    }

    let scheduleTimer: @Sendable (UInt64) -> Void = { token in
        let timerTask = makeObservationTask { @Sendable [stateBox, wakeSignal, clock, throttleInterval] in
            do {
                try await clock.sleep(until: clock.now.advanced(by: throttleInterval), tolerance: nil)
                guard !Task.isCancelled else {
                    return
                }
                let shouldWake = stateBox.state.withLock { state in
                    state.expireTimer(token: token)
                }
                if shouldWake {
                    wakeSignal.yield(())
                }
            } catch is CancellationError {
            } catch {
                preconditionFailure("throttle timer unexpectedly threw")
            }
        }
        timerTaskBox.replace(with: timerTask)
    }

    let drainThrottleActionsWithOwnership: @Sendable () async -> Bool = {
        while !Task.isCancelled {
            let action = stateBox.state.withLock { state -> ThrottleAction<Value> in
                state.nextAction()
            }

            switch action {
            case let .emit(value, timerToken, finishAfterEmit):
                if let timerToken {
                    scheduleTimer(timerToken)
                } else {
                    timerTaskBox.cancel()
                }
                if emitReadyValuesInline {
                    guard await consume(value) else {
                        consumerState.withLock { state in
                            state.shouldStop = true
                        }
                        return false
                    }
                } else {
                    outputContinuation.yield(value)
                }
                if finishAfterEmit {
                    return false
                }
            case .finish:
                timerTaskBox.cancel()
                return false
            case .idle:
                return true
            }
        }
        return false
    }

    let drainThrottleActions: @Sendable () async -> Bool = {
        let shouldStartDrain = drainState.withLock { state in
            if state.isDraining {
                state.needsDrain = true
                return false
            }
            state.isDraining = true
            return true
        }

        guard shouldStartDrain else {
            return consumerState.withLock { state in
                !state.shouldStop
            } && !Task.isCancelled
        }

        while true {
            let shouldContinue = await drainThrottleActionsWithOwnership()
            if !shouldContinue {
                drainFinishedSignal.yield(())
            }
            let shouldDrainAgain = drainState.withLock { state in
                guard shouldContinue, state.needsDrain else {
                    state.isDraining = false
                    state.needsDrain = false
                    return false
                }
                state.needsDrain = false
                return true
            }

            guard shouldDrainAgain else {
                return shouldContinue
            }
        }
    }

    let waitForThrottleDrainToFinish: @Sendable () async -> Void = {
        while drainState.withLock({ state in state.isDraining }) {
            await Task.yield()
        }
    }
    let isWaitingForThrottleTimerAfterSourceFinish: @Sendable () -> Bool = {
        stateBox.state.withLock { state in
            state.isSourceFinished
                && state.readyValue == nil
                && state.pendingValue != nil
                && state.activeTimerToken != nil
        }
    }

    let timerDrainTask = makeObservationTask {
        for await _ in wakeStream {
            guard await drainThrottleActions() else {
                break
            }
        }
    }

    await withTaskCancellationHandler {
        await source { observedValue in
            guard !Task.isCancelled else {
                return false
            }
            stateBox.state.withLock { state in
                state.recordIncomingValue(
                    observedValue,
                    keepLatestPending: keepLatestPending
                )
            }
            let shouldContinue = await drainThrottleActions()
            let shouldStop = consumerState.withLock { state in
                state.shouldStop
            }
            return shouldContinue && !shouldStop && !Task.isCancelled
        }

        stateBox.state.withLock { state in
            state.finishSource()
        }
        while true {
            let shouldContinue = await drainThrottleActions()
            await waitForThrottleDrainToFinish()
            guard shouldContinue else {
                break
            }
            guard isWaitingForThrottleTimerAfterSourceFinish() else {
                continue
            }
            for await _ in drainFinishedStream {
                break
            }
        }
        drainFinishedSignal.finish()
        outputContinuation.finish()
        await consumerTask.value
    } onCancel: {
        timerTaskBox.cancel()
        wakeSignal.finish()
        drainFinishedSignal.finish()
        timerDrainTask.cancel()
        outputContinuation.finish()
        consumerTask.cancel()
    }

    timerTaskBox.cancel()
    wakeSignal.finish()
    drainFinishedSignal.finish()
    timerDrainTask.cancel()
    outputContinuation.finish()
    consumerTask.cancel()
}

func makeRateLimitedValueStream<S: AsyncSequence & Sendable>(
    _ source: S,
    rateLimit: ObservationRateLimit,
    rateLimitClock: any Clock<Duration>
) -> AsyncStream<S.Element> where S.Element: Sendable {
    switch rateLimit {
    case let .debounce(debounce):
        return makeDebouncedValueStream(
            source,
            debounce: debounce,
            debounceClock: rateLimitClock
        )
    case let .throttle(throttle):
        return makeThrottledValueStream(
            source,
            throttle: throttle,
            throttleClock: rateLimitClock
        )
    }
}

func makeDebouncedValueStream<S: AsyncSequence & Sendable>(
    _ source: S,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>
) -> AsyncStream<S.Element> where S.Element: Sendable {
    makeDebouncedValueStream(
        source,
        debounce: debounce,
        clock: debounceClock
    )
}

func makeDebouncedValueStream<S: AsyncSequence & Sendable, C: Clock<Duration>>(
    _ source: S,
    debounce: ObservationDebounce,
    clock: C
) -> AsyncStream<S.Element> where S.Element: Sendable {
    switch debounce.mode {
    case .delayedFirst:
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in source.debounce(
                        for: debounce.interval,
                        tolerance: debounce.tolerance,
                        clock: clock
                    ) {
                        guard !Task.isCancelled else {
                            break
                        }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    preconditionFailure("debounce source unexpectedly threw")
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    case .immediateFirst:
        return AsyncStream { continuation in
            let task = Task {
                let (remainingStream, remainingContinuation) = AsyncStream<S.Element>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                let producerTask = Task {
                    do {
                        var iterator = source.makeAsyncIterator()
                        guard let firstValue = try await iterator.next() else {
                            remainingContinuation.finish()
                            return
                        }

                        guard !Task.isCancelled else {
                            remainingContinuation.finish()
                            return
                        }

                        continuation.yield(firstValue)

                        while let nextValue = try await iterator.next() {
                            guard !Task.isCancelled else {
                                break
                            }
                            remainingContinuation.yield(nextValue)
                        }

                        remainingContinuation.finish()
                    } catch {
                        remainingContinuation.finish()
                        preconditionFailure("debounce source unexpectedly threw")
                    }
                }

                for await value in remainingStream.debounce(
                    for: debounce.interval,
                    tolerance: debounce.tolerance,
                    clock: clock
                ) {
                    guard !Task.isCancelled else {
                        break
                    }
                    continuation.yield(value)
                }

                producerTask.cancel()
                await producerTask.value
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

func makeThrottledValueStream<S: AsyncSequence & Sendable>(
    _ source: S,
    throttle: ObservationThrottle,
    throttleClock: any Clock<Duration>
) -> AsyncStream<S.Element> where S.Element: Sendable {
    makeThrottledValueStream(
        source,
        throttle: throttle,
        clock: throttleClock
    )
}

func makeThrottledValueStream<S: AsyncSequence & Sendable, C: Clock<Duration>>(
    _ source: S,
    throttle: ObservationThrottle,
    clock: C
) -> AsyncStream<S.Element> where S.Element: Sendable {
    AsyncStream { continuation in
        let task = Task {
            let stateBox = ThrottleStateBox<S.Element>()
            let (wakeStream, wakeSignal) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            var timerTask: Task<Void, Never>? = nil
            let keepLatestPending = throttle.mode == .latest
            let throttleInterval = throttle.interval

            let sourceTask = Task { @Sendable [stateBox, wakeSignal, keepLatestPending, source] in
                do {
                    for try await value in source {
                        guard !Task.isCancelled else {
                            break
                        }
                        stateBox.state.withLock { state in
                            state.recordIncomingValue(
                                value,
                                keepLatestPending: keepLatestPending
                            )
                        }
                        wakeSignal.yield(())
                    }
                    stateBox.state.withLock { state in
                        state.finishSource()
                    }
                    wakeSignal.yield(())
                } catch {
                    preconditionFailure("throttle source unexpectedly threw")
                }
            }

            defer {
                timerTask?.cancel()
                sourceTask.cancel()
                wakeSignal.finish()
                continuation.finish()
            }

            let scheduleTimer = { (timerToken: UInt64) in
                timerTask?.cancel()
                timerTask = Task { @Sendable [stateBox, wakeSignal, clock, throttleInterval] in
                    do {
                        try await clock.sleep(until: clock.now.advanced(by: throttleInterval), tolerance: nil)
                        guard !Task.isCancelled else {
                            return
                        }
                        let shouldWake = stateBox.state.withLock { state in
                            state.expireTimer(token: timerToken)
                        }
                        if shouldWake {
                            wakeSignal.yield(())
                        }
                    } catch is CancellationError {
                    } catch {
                        preconditionFailure("throttle timer unexpectedly threw")
                    }
                }
            }

            let nextAction = {
                stateBox.state.withLock { state -> ThrottleAction<S.Element> in
                    state.nextAction()
                }
            }

            for await _ in wakeStream {
                guard !Task.isCancelled else {
                    break
                }

                while !Task.isCancelled {
                    let action = nextAction()
                    switch action {
                    case let .emit(value, timerToken, finishAfterEmit):
                        continuation.yield(value)
                        if let timerToken {
                            scheduleTimer(timerToken)
                        } else {
                            timerTask?.cancel()
                            timerTask = nil
                        }

                        if finishAfterEmit {
                            return
                        }
                    case .finish:
                        timerTask?.cancel()
                        timerTask = nil
                        return
                    case .idle:
                        break
                    }

                    if case .idle = action {
                        break
                    }
                }
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

func makeRateLimitedValueStreamNonSendable<Element>(
    _ source: AsyncStream<Element>,
    rateLimit: ObservationRateLimit,
    rateLimitClock: any Clock<Duration>
) -> AsyncStream<Element> {
    switch rateLimit {
    case let .debounce(debounce):
        return makeDebouncedValueStreamNonSendable(
            source,
            debounce: debounce,
            debounceClock: rateLimitClock
        )
    case let .throttle(throttle):
        return makeThrottledValueStreamNonSendable(
            source,
            throttle: throttle,
            throttleClock: rateLimitClock
        )
    }
}

func makeDebouncedValueStreamNonSendable<Element>(
    _ source: AsyncStream<Element>,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>
) -> AsyncStream<Element> {
    makeDebouncedValueStreamNonSendable(
        source,
        debounce: debounce,
        clock: debounceClock
    )
}

func makeDebouncedValueStreamNonSendable<Element, C: Clock<Duration>>(
    _ source: AsyncStream<Element>,
    debounce: ObservationDebounce,
    clock: C
) -> AsyncStream<Element> {
    let boxedSource = makeUncheckedSendableBoxedStream(source)
    let debouncedBoxes = makeDebouncedValueStream(
        boxedSource,
        debounce: debounce,
        clock: clock
    )
    return makeUncheckedSendableUnboxedStream(debouncedBoxes)
}

func makeThrottledValueStreamNonSendable<Element>(
    _ source: AsyncStream<Element>,
    throttle: ObservationThrottle,
    throttleClock: any Clock<Duration>
) -> AsyncStream<Element> {
    makeThrottledValueStreamNonSendable(
        source,
        throttle: throttle,
        clock: throttleClock
    )
}

func makeThrottledValueStreamNonSendable<Element, C: Clock<Duration>>(
    _ source: AsyncStream<Element>,
    throttle: ObservationThrottle,
    clock: C
) -> AsyncStream<Element> {
    let boxedSource = makeUncheckedSendableBoxedStream(source)
    let throttledBoxes = makeThrottledValueStream(
        boxedSource,
        throttle: throttle,
        clock: clock
    )
    return makeUncheckedSendableUnboxedStream(throttledBoxes)
}

private func makeUncheckedSendableBoxedStream<Element>(
    _ source: AsyncStream<Element>
) -> AsyncStream<_UncheckedSendableValueBox<Element>> {
    let sourceBox = _UncheckedSendableValueBox(source)
    return AsyncStream { continuation in
        let task = Task {
            for await nextValue in sourceBox.value {
                guard !Task.isCancelled else {
                    break
                }
                continuation.yield(_UncheckedSendableValueBox(nextValue))
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

private func makeUncheckedSendableUnboxedStream<Element>(
    _ source: AsyncStream<_UncheckedSendableValueBox<Element>>
) -> AsyncStream<Element> {
    AsyncStream { continuation in
        let task = Task {
            for await boxedValue in source {
                guard !Task.isCancelled else {
                    break
                }
                continuation.yield(boxedValue.value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

private func forEachOwnerValueEmission<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    let resolveOwner = WeakOwnerRegistry.ownerAccessor(token: ownerToken)
    let resolvedIsolation = value.isolation ?? isolation
    // NOTE:
    // `Observations.Iterator.next(isolation:)` does not rebind `emit` closure isolation.
    // If the projected closure lost actor metadata (e.g. key path getter composition),
    // native Observations can evaluate it off-actor and trip dynamic isolation checks.
    // Legacy path can still execute under `resolvedIsolation`, so bridge there.
    let requiresLegacyIsolationBridge = resolvedIsolation != nil && value.isolation == nil

    let observeOwnerValue: @isolated(any) @Sendable () -> OwnerValueEmission<Value> = {
        guard let owner = resolveOwner() as? Owner else {
            return .ownerGone
        }
        switch _ObservationBridgeLegacy.legacyEvaluateObservedOwnerValue(owner: owner, value: value) {
        case .ownerGone:
            return .ownerGone
        case .value(let observedValue):
            return .value(observedValue)
        }
    }

    switch resolveBackend(options: options) {
    case .native:
        if #available(iOS 26.0, macOS 26.0, *),
           !requiresLegacyIsolationBridge {
            await forEachNativeEmission(
                observeOwnerValue,
                isolation: resolvedIsolation,
                consume: consume
            )
            return
        }
        fallthrough
    case .legacy:
        await forEachLegacyObservationEmission(
            observeOwnerValue,
            isolation: resolvedIsolation
        ) { emission in
            guard !Task.isCancelled else {
                return false
            }
            return await consume(emission)
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func forEachNativeEmission<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> OwnerValueEmission<Value>,
    isolation: (any Actor)?,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    await drainNativeOwnerValueEmissions(
        observe: observe,
        isolation: isolation,
        consume: consume
    )
}

@available(iOS 26.0, macOS 26.0, *)
private func drainNativeOwnerValueEmissions<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> OwnerValueEmission<Value>,
    isolation: isolated (any Actor)?,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    let observations = Observations(observe)
    var iterator = observations.makeAsyncIterator()

    while let value = await iterator.next(isolation: isolation) {
        guard !Task.isCancelled else {
            break
        }
        guard await consume(value) else {
            break
        }
    }
}
