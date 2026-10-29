import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct GuardRuntimeNetworkLookupTests {
    actor Requests {
        var calls = 0
        var waits = 0
        let failures: Int
        let cancelled: Bool
        init(failures: Int, cancelled: Bool = false) { self.failures = failures; self.cancelled = cancelled }
        func load() throws -> GuardNetworkObservation {
            calls += 1
            if calls <= failures { throw URLError(cancelled ? .cancelled : .timedOut) }
            return .init(countryCode: "US", fetchedAt: .now, ip: "203.0.113.1")
        }
        func wait() { waits += 1 }
    }

    @Test func firstSuccessDoesNotWaitOrRetry() async throws {
        let requests = Requests(failures: 0)
        let result = try await GuardRuntimeNetworkLookup.observation(load: { try await requests.load() }, wait: { await requests.wait() })
        #expect(result.ip == "203.0.113.1")
        #expect(await requests.calls == 1)
        #expect(await requests.waits == 0)
    }

    @Test func transientTimeoutRecoversWithoutReturningAFailure() async throws {
        let requests = Requests(failures: 1)
        let result = try await GuardRuntimeNetworkLookup.observation(load: { try await requests.load() }, wait: { await requests.wait() })
        #expect(result.ip == "203.0.113.1")
        #expect(await requests.calls == 2)
        #expect(await requests.waits == 1)
    }

    @Test func secondFailurePropagatesAndStopsRetrying() async {
        let requests = Requests(failures: 9)
        do {
            _ = try await GuardRuntimeNetworkLookup.observation(load: { try await requests.load() }, wait: { await requests.wait() })
            Issue.record("Two failures must leave the exit unverified")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(await requests.calls == 2)
        #expect(await requests.waits == 1)
    }

    @Test func cancelledRequestAndCancelledDelayNeverRetry() async {
        let cancelled = Requests(failures: 1, cancelled: true)
        do {
            _ = try await GuardRuntimeNetworkLookup.observation(load: { try await cancelled.load() }, wait: { await cancelled.wait() })
            Issue.record("Cancelled request must stop")
        } catch {}
        #expect(await cancelled.calls == 1)
        #expect(await cancelled.waits == 0)
        let delayed = Requests(failures: 1)
        do {
            _ = try await GuardRuntimeNetworkLookup.observation(load: { try await delayed.load() }, wait: { throw CancellationError() })
            Issue.record("Cancelled delay must stop")
        } catch { #expect(error is CancellationError) }
        #expect(await delayed.calls == 1)
    }
}
