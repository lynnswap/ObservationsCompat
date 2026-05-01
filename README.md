# ObservationBridge

ObservationBridge is an integration layer that provides a consistent API for Swift Observations.

It provides two usage styles:

- owner-bound callbacks: `observe` / `observeTask`
- `AsyncSequence` wrappers: `ObservationBridge` / `makeObservationBridgeStream`

`observe` / `observeTask` return an `ObservationRegistration`.
Store registrations in an `ObservationScope` while observation should stay active.

## Requirements

- Swift 6.2
- iOS 18+
- macOS 15+

## Basic Usage

### Synchronous updates (`observe`)

```swift
import ObservationBridge

let observations = ObservationScope()

model.observe(\.count) { value in
    analytics.markCountChanged(value)
}
.store(in: observations)
```

### Async updates (`observeTask`)

```swift
import ObservationBridge

let observations = ObservationScope()

model.observeTask(\.count) { value in
    await analytics.trackCount(value)
}
.store(in: observations)
```

### Multiple key paths (trigger-only)

```swift
model.observeTask([\.count, \.isEnabled]) {
    await analytics.trackStateChanged()
}
.store(in: observations)
```

If you need derived state from multiple key paths, use trigger-only observation and read the owner inside the callback or task.

## Configuration

### Options

Available options:

- `ObservationOptions(rateLimit:backend:)`: explicit full configuration.
- `.rateLimit(ObservationRateLimit)`: explicit rate-limit configuration (`.debounce(...)` / `.throttle(...)`).
- `.legacyBackend` (`iOS 26.0+` / `macOS 26.0+`): forces legacy `withObservationTracking` backend even on modern OS.
- `ObservationDebounce` fields: `interval`, `tolerance` (optional), `mode` (`.immediateFirst` / `.delayedFirst`).
- `ObservationThrottle` fields: `interval`, `mode` (`.latest` / `.earliest`).

Rate-limit notes:

- `debounce` and `throttle` are mutually exclusive because `ObservationOptions` stores one optional rate-limit value.
- `throttle(mode: .latest)` is the default and means: emit the first value immediately, then emit the latest value seen during each interval.
- `throttle(mode: .earliest)` emits the first value seen during each interval after the initial immediate emission.
- If you need duplicate suppression, implement it explicitly at the call site.

### Clock

#### Deterministic testing

In tests, pass your own `Clock` implementation to drive debounce or throttle timing manually:

```swift
let clock = MyTestClock() // your Clock implementation for tests
let throttle = ObservationThrottle(interval: .milliseconds(250))

let stream = ObservationBridge(
    options: .rateLimit(.throttle(throttle)),
    clock: clock
) {
    model.count
}

await clock.sleep(untilSuspendedBy: 1) // helper provided by your test clock
clock.advance(by: .milliseconds(250))  // deterministic time progression
```

## AsyncSequence Style

### `ObservationBridge`

```swift
import ObservationBridge

let stream = ObservationBridge {
    model.count
}

for await value in stream {
    print("count = \(value)")
}
```

### `makeObservationBridgeStream`

```swift
let stream = makeObservationBridgeStream {
    model.count
}

for await value in stream {
    print(value)
}
```

## Repeated UI Updates

Use `ObservationScope.update` for repeated UI lifecycle updates. Observations declared
again from the same call site keep their pipeline and only replace the callback.
Observations omitted from the next update are cancelled.

```swift
let observations = ObservationScope()

func render() {
    observations.update {
        model.observe(\.count) { value in
            countLabel.text = "\(value)"
        }
        .store(in: observations)
    }
}
```

Use `id:` only when you need explicit cancellation or a stable logical identity
that does not match the call site.

```swift
model.observe(\.count, id: "header-count") { value in
    print("count = \(value)")
}
.store(in: observations)

observations.cancel(id: "header-count")
```

## Behavior Notes

Both APIs:

- use native `Observations` on supported OS versions
- fall back to legacy `withObservationTracking` on older OS versions
- support non-`Sendable` observed values when producer and consumer closures share the same actor isolation
- create a fresh observation pipeline for each `ObservationBridge` iterator
- require storing the returned `ObservationRegistration` in an `ObservationScope` to keep observation active
- cancel automatically if the observed owner is released

Backend behavior note:

- by default, native `Observations` is used on `iOS/macOS 26.0+`, and legacy `withObservationTracking` is used on older OS versions
- `.legacyBackend` forces legacy behavior on `iOS/macOS 26.0+`
- legacy coalesces burst mutations and emits the latest observed value instead of replaying every intermediate mutation
- native uses Swift `Observations` transaction semantics
- `observeTask` never cancels in-flight work; it preserves the next selected output, then coalesces any additional backlog to the latest pending value
- non-`Sendable` values always use the legacy backend, even on `iOS/macOS 26.0+`
- non-`Sendable` observation preconditions producer/callback isolation equality; mismatch traps at runtime
- keep the owning `ObservationScope` alive while observation should continue
- use `ObservationScope.update { ... }` when repeated updates should cancel observations that disappear
- use `ObservationScope.cancel(id:)` or `cancelAll()` for explicit lifecycle shutdown

## Migration

### v0.8.0

- `observe` / `observeTask` now return `ObservationRegistration` and no longer start observation until `.store(in:)` is called.
- `ObservationScope` is the lifecycle owner for callback observations.
- `ObservationHandle`, direct `cancel()`, `Set<ObservationHandle>`, and `.store(in: &set)` have been removed from the public API.
- `ObservationOptions` is no longer an `OptionSet`; use `.rateLimit(...)`, `.legacyBackend`, or `ObservationOptions(rateLimit:backend:)`.
- `ObservationOptions(rawValue:)`, array-literal merging, and set-algebra APIs have been removed.
- Replace handle storage with `ObservationScope`:

Before:

```swift
var cancellables = Set<ObservationHandle>()

model.observeTask(\.count) { value in
    await analytics.trackCount(value)
}
.store(in: &cancellables)
```

After:

```swift
let observations = ObservationScope()

model.observeTask(\.count) { value in
    await analytics.trackCount(value)
}
.store(in: observations)
```

### v0.7.0

- `.removeDuplicates` has been removed from `ObservationOptions`.
- multi-keypath projection overloads that accepted `of:` have been removed.
- multi-keypath observation is intentionally trigger-only now. Producer-side snapshot projection, including cross-actor derived value delivery, is no longer supported.
- If you need duplicate suppression, implement it at the call site.

Before:

```swift
let stateStream = ObservationBridge {
    model.count
}

model.observeTask(
    [\.count, \.isEnabled],
    of: { owner in (owner.count, owner.isEnabled) }
) { state in
    await analytics.trackState(state)
}
```

After:

```swift
model.observeTask([\.count, \.isEnabled]) {
    await analytics.trackState((model.count, model.isEnabled))
}
.store(in: observations)
```

This is an intentional API reduction. Multi-keypath observers now only tell you that one of the tracked key paths changed; they do not preserve or deliver a producer-side snapshot anymore.

### v0.6.0

- `.debounce(ObservationDebounce)` was deprecated; v0.8.0 removes it. Use `.rateLimit(.debounce(...))` instead.
- Inspect `options.rateLimit` instead of relying on the removed `options.debounce` convenience accessor.

### v0.5.0

- Up to `v0.4.x`, `observe` / `observeTask` included owner-lifetime automatic handle retention.
- Starting with `v0.5.0`, automatic handle retention is no longer supported.
- Store the returned registration in an `ObservationScope`, or observation will not start.
