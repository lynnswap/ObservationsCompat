import Synchronization

private struct PendingObserveTaskOperation<Value: Sendable>: Sendable {
    let id: UInt64
    let value: Value
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

final class ObservationTaskBox: Sendable {
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

                let (operationStartStream, operationStartSignal) = AsyncStream<Bool>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                let operation = makeObservationTask {
                    var shouldStartOperation = false
                    for await shouldStart in operationStartStream {
                        shouldStartOperation = shouldStart
                        break
                    }
                    guard shouldStartOperation, !Task.isCancelled else {
                        operationDidFinish(pendingOperation.id)
                        return
                    }
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
                    operationStartSignal.yield(false)
                    operationStartSignal.finish()
                    operation.cancel()
                } else {
                    operationStartSignal.yield(true)
                    operationStartSignal.finish()
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

    OwnerCancellationRegistry.register(handle, owner: owner)
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

                let (operationStartStream, operationStartSignal) = AsyncStream<Bool>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                let operation = makeObservationTask {
                    var shouldStartOperation = false
                    for await shouldStart in operationStartStream {
                        shouldStartOperation = shouldStart
                        break
                    }
                    guard shouldStartOperation, !Task.isCancelled else {
                        operationDidFinish(pendingOperation.id)
                        return
                    }
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
                    operationStartSignal.yield(false)
                    operationStartSignal.finish()
                    operation.cancel()
                } else {
                    operationStartSignal.yield(true)
                    operationStartSignal.finish()
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

    OwnerCancellationRegistry.register(handle, owner: owner)
    return handle
}
