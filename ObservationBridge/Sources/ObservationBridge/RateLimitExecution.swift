import AsyncAlgorithms
import Observation
import Synchronization
internal import _ObservationBridgeLegacy

struct ObservedValueChannel<Value: Sendable>: Sendable {
    let channel: AsyncChannel<Value>
    let producerTask: Task<Void, Never>
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
    var waiters: [CheckedContinuation<Void, Never>] = []
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

enum ThrottleAction<Value>: Sendable where Value: Sendable {
    case emit(value: Value, timerToken: UInt64?, finishAfterEmit: Bool)
    case finish
    case idle
}

func makeObservedValueChannel<Owner: AnyObject, Value: Sendable>(
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

func makeObservedValueStreamNonSendable<Owner: AnyObject, Value>(
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

func forEachOwnerValueEmissionNonSendable<Owner: AnyObject, Value>(
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

func forEachImmediateFirstDebouncedOwnerValue<Owner: AnyObject, Value: Sendable>(
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

func forEachImmediateFirstDebouncedOwnerValueNonSendable<Owner: AnyObject, Value>(
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

func forEachThrottledOwnerValue<Owner: AnyObject, Value: Sendable>(
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

func forEachThrottledOwnerValueNonSendable<Owner: AnyObject, Value>(
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
                // `Clock.sleep` is untyped throws; non-cancellation errors violate
                // the clock contract expected by this rate-limit pipeline.
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
            let (shouldDrainAgain, waiters) = drainState.withLock { state in
                guard shouldContinue, state.needsDrain else {
                    state.isDraining = false
                    state.needsDrain = false
                    let waiters = state.waiters
                    state.waiters = []
                    return (false, waiters)
                }
                state.needsDrain = false
                return (true, [])
            }
            for waiter in waiters {
                waiter.resume()
            }
            if !shouldContinue {
                drainFinishedSignal.yield(())
            }

            guard shouldDrainAgain else {
                return shouldContinue
            }
        }
    }

    let resumeThrottleDrainWaiters: @Sendable () -> Void = {
        let waiters = drainState.withLock { state in
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    let waitForThrottleDrainToFinish: @Sendable () async -> Void = {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = drainState.withLock { state in
                    guard state.isDraining else {
                        return true
                    }
                    state.waiters.append(continuation)
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            resumeThrottleDrainWaiters()
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
        resumeThrottleDrainWaiters()
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
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
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
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
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
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
    switch debounce.mode {
    case .delayedFirst:
        return AsyncStream { continuation in
            let task = Task {
                for await value in source.debounce(
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
                    var didEmitFirstValue = false
                    for await nextValue in source {
                        guard !Task.isCancelled else {
                            break
                        }
                        guard didEmitFirstValue else {
                            didEmitFirstValue = true
                            continuation.yield(nextValue)
                            continue
                        }
                        remainingContinuation.yield(nextValue)
                    }

                    remainingContinuation.finish()
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
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
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
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
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
                for await value in source {
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
                        // `Clock.sleep` is untyped throws; non-cancellation errors violate
                        // the clock contract expected by this rate-limit pipeline.
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

func forEachOwnerValueEmission<Owner: AnyObject, Value: Sendable>(
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
