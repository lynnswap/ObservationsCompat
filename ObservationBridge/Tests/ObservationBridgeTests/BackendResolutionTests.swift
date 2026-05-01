import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
final class BackendResolutionTests {
    @Test
    func defaultBackendFallsBackToLegacyOnUnsupportedOS() async {
        if #available(iOS 26.0, macOS 26.0, *) {
            return
        }

        let model = CounterModel()
        let stream = ObservationBridge {
            model.value
        }
        let queue = ValueQueue<Int>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 7
        #expect(await nextWithTimeout(from: queue) == 7)
    }

    @Test
    func observationOptionsStoresRateLimitConfiguration() {
        let debounce = ObservationDebounce(
            interval: .milliseconds(100),
            tolerance: .milliseconds(20),
            mode: .immediateFirst
        )
        let throttle = ObservationThrottle(
            interval: .milliseconds(120),
            mode: .earliest
        )

        let debounceOptions = ObservationOptions.rateLimit(.debounce(debounce))
        #expect(debounceOptions.rateLimit == .debounce(debounce))
        #expect(debounceOptions.backend == .automatic)
        #expect(debounceOptions == ObservationOptions(rateLimit: .debounce(debounce)))

        let throttleOptions = ObservationOptions.rateLimit(.throttle(throttle))
        #expect(throttleOptions.rateLimit == .throttle(throttle))
        #expect(throttleOptions.backend == .automatic)
        #expect(throttleOptions == ObservationOptions(rateLimit: .throttle(throttle)))
    }

    @Test
    func observationOptionsCanCombineRateLimitAndLegacyBackend() {
        let debounce = ObservationDebounce(
            interval: .milliseconds(80),
            tolerance: .milliseconds(10),
            mode: .delayedFirst
        )
        let options = ObservationOptions(
            rateLimit: .debounce(debounce),
            backend: .legacy
        )

        #expect(options.rateLimit == .debounce(debounce))
        #expect(options.backend == .legacy)
        #expect(options.forcesLegacyBackend)
    }

    @Test
    func observeTaskDefaultBackendFallsBackToLegacyOnUnsupportedOS() async {
        if #available(iOS 26.0, macOS 26.0, *) {
            return
        }

        let model = PlainCounterModel()
        let queue = ValueQueue<Int>()

        let observations = model.observeTask(\.value, options: ObservationOptions()) { value in
            await queue.push(value)
        }.storedForTest()
        defer { observations.cancelAll() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 42
        #expect(await nextWithTimeout(from: queue) == 42)
    }
}
