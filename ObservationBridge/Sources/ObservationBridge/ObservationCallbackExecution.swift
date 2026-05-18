import Synchronization

enum OwnerValueEmission<Value> {
    case value(Value)
    case ownerGone
}

extension OwnerValueEmission: Sendable where Value: Sendable {}

@discardableResult
func makeObservationTask<Success: Sendable>(
    @_inheritActorContext operation: @escaping @isolated(any) @Sendable () async -> Success
) -> Task<Success, Never> {
    if #available(iOS 26.0, macOS 26.0, *) {
        return Task.immediate(operation: operation)
    }
    return Task(operation: operation)
}

final class ObservationExecutionLifetime: Sendable {
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

final class _UncheckedSendableValueBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
