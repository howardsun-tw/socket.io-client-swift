import XCTest
@testable import SocketIO

/// Unit tests for the Phase 8 `setAuth` / `clearAuth` / `resolveConnectPayload`
/// surface on `SocketIOClient`.
///
/// All tests use a dedicated background `handleQueue` because
/// `manager.handleQueue.sync { }` from the main thread would deadlock if the
/// queue were `.main`. The internal `resolveConnectPayload` requires the caller
/// to be on `handleQueue`, so tests dispatch onto it explicitly.
final class SocketAuthProviderTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.auth.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .version(.three), .handleQueue(queue)])
        socket = manager.defaultSocket
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    /// Drain pending work on the handle queue so that async-dispatched mutations
    /// (e.g. `setAuth`'s install hop, `clearAuth`'s tear-down hop) are visible
    /// before the test asserts.
    private func drain() {
        queue.sync { }
    }

    // MARK: U-A1 — provider stored at install but NOT invoked until resolution

    func testProviderStoredButNotInvokedUntilConnect() {
        var invoked = 0
        socket.setAuth { cb in
            invoked += 1
            cb(["token": "abc"])
        }
        drain()

        XCTAssertEqual(invoked, 0,
                       "setAuth must only store the provider; resolution happens on CONNECT")

        // Now drive a single resolution: provider must run exactly once.
        let resolved = expectation(description: "resolution completed")
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { _ in
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(invoked, 1, "exactly one resolution should invoke the provider once")
    }

    // MARK: U-A2 — no provider → completion gets explicit verbatim

    func testResolveConnectPayloadWithoutProviderReturnsExplicit() {
        let resolved = expectation(description: "explicit returned verbatim")
        var captured: [String: Any]?
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: ["x": 1]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(captured?["x"] as? Int, 1)
    }

    // MARK: U-A3 — provider's resolved dict overrides explicit

    func testResolveConnectPayloadWithProviderOverridesExplicit() {
        socket.setAuth { cb in cb(["a": 1]) }
        drain()

        let resolved = expectation(description: "provider value wins")
        var captured: [String: Any]?
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: ["b": 2]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(captured?["a"] as? Int, 1, "provider value must win")
        XCTAssertNil(captured?["b"], "explicit must be discarded when provider returns non-nil")
    }

    // MARK: U-A4 — provider returning nil falls back to explicit (`resolved ?? explicit`)

    func testResolveConnectPayloadWithProviderReturningNilFallsBackToExplicit() {
        socket.setAuth { cb in cb(nil) }
        drain()

        let resolved = expectation(description: "fallback to explicit")
        var captured: [String: Any]?
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: ["x": 1]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(captured?["x"] as? Int, 1,
                       "provider returning nil should fall through to explicit per `resolved ?? explicit`")
    }

    // MARK: U-A5 — clearAuth removes installed provider

    func testClearAuthRemovesProvider() {
        var invoked = 0
        socket.setAuth { cb in
            invoked += 1
            cb(["token": "abc"])
        }
        drain()
        socket.clearAuth()
        drain()

        let resolved = expectation(description: "explicit returned after clearAuth")
        var captured: [String: Any]?
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: ["x": 1]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(invoked, 0, "cleared provider must never be invoked")
        XCTAssertEqual(captured?["x"] as? Int, 1, "after clearAuth, explicit is returned verbatim")
    }

    // MARK: U-A6 — multi-callback provider invokes completion twice (JS parity)

    func testMultiCallbackProviderInvokesCompletionTwice() {
        // Provider that calls cb twice mirrors socket.io-client/lib/socket.ts
        // multi-callback semantics: each cb invocation produces a CONNECT.
        socket.setAuth { cb in
            cb(["a": 1])
            cb(["b": 2])
        }
        drain()

        let twice = expectation(description: "completion fires twice")
        twice.expectedFulfillmentCount = 2
        var captures = [[String: Any]]()
        let lock = NSLock()
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                lock.lock()
                if let p = payload { captures.append(p) }
                lock.unlock()
                twice.fulfill()
            }
        }
        wait(for: [twice], timeout: 2)

        XCTAssertEqual(captures.count, 2, "completion must be invoked once per provider callback")
        let firstA = captures.first?["a"] as? Int
        let secondB = captures.last?["b"] as? Int
        XCTAssertEqual(firstA, 1)
        XCTAssertEqual(secondB, 2)
    }

    // MARK: U-A7 — v2 manager + provider installed → .error fired, completion gets nil

    func testV2ManagerProviderFiresErrorAndPassesNilPayload() {
        // Build a fresh v2 manager on its own background queue.
        let v2Queue = DispatchQueue(label: "test.auth.v2.handleQueue")
        let v2Manager = SocketManager(
            socketURL: URL(string: "http://localhost/")!,
            config: [.log(false), .version(.two), .handleQueue(v2Queue)]
        )
        let v2Socket = v2Manager.defaultSocket

        var providerInvocations = 0
        v2Socket.setAuth { cb in
            providerInvocations += 1
            cb(["token": "x"])
        }
        v2Queue.sync { }

        let errorFired = expectation(description: ".error fired with v2 bypass message")
        let resolved = expectation(description: "completion called with nil")
        var captured: [String: Any]?
        var errorMessage: String?
        v2Socket.on(clientEvent: .error) { data, _ in
            errorMessage = data.first as? String
            errorFired.fulfill()
        }
        v2Queue.async {
            v2Socket.resolveConnectPayload(explicit: ["x": 1]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [errorFired, resolved], timeout: 2)

        XCTAssertEqual(providerInvocations, 0, "v2 must NOT invoke the provider")
        XCTAssertNil(captured, "completion must receive nil on v2 bypass")
        XCTAssertNotNil(errorMessage)
        XCTAssertTrue(errorMessage?.contains("v2 manager") ?? false,
                      "error message should mention v2 bypass; got: \(errorMessage ?? "<nil>")")
    }

    // MARK: U-A8 — async provider stale result discarded after clearAuth + new provider install

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    func testAsyncProviderStaleResultDiscardedAfterClearAuth() {
        // Provider 1 sleeps 200ms then returns ["old": true]. We immediately
        // clearAuth + install a fresh sync provider returning ["new": true].
        // The contract: the late ["old": true] result must NEVER reach completion
        // because clearAuth bumps `authGeneration`, and the async overload
        // discards any result whose captured generation no longer matches.
        socket.setAuth {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return ["old": true]
        }
        drain()

        // Trigger first resolution while status is .connecting (the async
        // overload also requires status == .connecting on the result hop).
        socket.setTestStatus(.connecting)

        let firstScheduled = expectation(description: "first resolution scheduled")
        let lock = NSLock()
        var observed = [[String: Any]?]()

        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                lock.lock()
                observed.append(payload)
                lock.unlock()
            }
            firstScheduled.fulfill()
        }
        wait(for: [firstScheduled], timeout: 1)

        // Immediately swap identity. clearAuth bumps the generation token; the
        // in-flight async Task's result hop will then be dropped.
        socket.clearAuth()
        socket.setAuth { cb in cb(["new": true]) }
        drain()

        // Trigger a second resolution that should run the new sync provider
        // and complete immediately.
        let secondCompleted = expectation(description: "fresh provider produced new value")
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                lock.lock()
                observed.append(payload)
                lock.unlock()
                if (payload?["new"] as? Bool) == true {
                    secondCompleted.fulfill()
                }
            }
        }
        wait(for: [secondCompleted], timeout: 1)

        // Give the stale Task ample time (>>200ms sleep + hop) to attempt
        // its forbidden completion.
        Thread.sleep(forTimeInterval: 0.6)

        lock.lock()
        let snapshot = observed
        lock.unlock()

        for entry in snapshot {
            if let dict = entry, dict["old"] as? Bool == true {
                XCTFail("stale async result leaked through completion: \(dict)")
            }
        }
        let sawNew = snapshot.contains { ($0?["new"] as? Bool) == true }
        XCTAssertTrue(sawNew, "fresh provider must produce ['new': true] in observed results")
    }

    // MARK: U-A9 — async provider throw fires .error and does NOT call completion

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    func testAsyncProviderThrowFiresErrorClientEvent() {
        struct ProviderError: LocalizedError {
            let errorDescription: String? = "fetch failed"
        }
        socket.setAuth { () async throws -> [String: Any]? in
            throw ProviderError()
        }
        drain()

        socket.setTestStatus(.connecting)

        let errorFired = expectation(description: ".error fired with provider failure message")
        let noCompletion = expectation(description: "completion must NOT fire on throw")
        noCompletion.isInverted = true
        var errorMessage: String?
        socket.on(clientEvent: .error) { data, _ in
            errorMessage = data.first as? String
            errorFired.fulfill()
        }

        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { _ in
                noCompletion.fulfill()
            }
        }

        wait(for: [errorFired], timeout: 2)
        // Brief inverted wait — give the wrong path a chance to fire.
        wait(for: [noCompletion], timeout: 0.4)

        XCTAssertNotNil(errorMessage)
        XCTAssertTrue(errorMessage?.contains("auth provider failed") ?? false,
                      "expected localized failure message; got: \(errorMessage ?? "<nil>")")
        XCTAssertTrue(errorMessage?.contains("fetch failed") ?? false,
                      "expected error.localizedDescription to be included")
    }

    // MARK: U-A10 — v2 root-namespace + provider fires .error per CONNECT attempt
    //
    // Spec §Phase 8: "on every CONNECT attempt where a provider is installed
    // but the manager is v2, fires `handleClientEvent(.error, ...)`."
    //
    // The v2 root-namespace path in `_engineDidOpen` short-circuits via
    // `didConnect` and never visits `resolveConnectPayload`. The bypass guard
    // must therefore be emitted directly from `_engineDidOpen` for the v2 root
    // case so a provider installed on the root namespace of a v2 manager is
    // observable per CONNECT attempt.

    func testV2ManagerProviderOnRootNamespaceFiresError() {
        let url = URL(string: "http://localhost/")!
        let v2RootQueue = DispatchQueue(label: "test.v2.root")
        let mgr = SocketManager(socketURL: url,
                                config: [.log(false), .version(.two), .handleQueue(v2RootQueue)])
        let sock = mgr.defaultSocket  // root nsp
        let engine = CaptureEngine()
        mgr.engine = engine
        engine.client = mgr

        let lock = NSLock()
        var errorMessages = [String]()
        sock.on(clientEvent: .error) { data, _ in
            if let msg = data.first as? String {
                lock.lock()
                errorMessages.append(msg)
                lock.unlock()
            }
        }
        sock.setAuth { cb in cb(["x": 1]) }
        v2RootQueue.sync { }

        sock.connect()
        v2RootQueue.sync { }
        mgr.engineDidOpen(reason: "test")
        v2RootQueue.sync { }

        lock.lock()
        let snapshot = errorMessages
        lock.unlock()
        XCTAssertTrue(snapshot.contains(where: { $0.contains("v2 manager") }),
                      "v2 root + provider must fire .error per CONNECT: got \(snapshot)")
    }

    // MARK: U-A11 — setAuth and clearAuth bump the generation token

    func testSetAuthBumpsGenerationAndClearAuthAlsoBumps() {
        // We can't read `authGeneration` directly (private), but we can observe
        // its effect on the async path's stale-result discard. This test just
        // verifies the generation-mutating methods are no-throw and queue-safe.
        socket.setAuth { cb in cb(nil) }
        socket.setAuth { cb in cb(["a": 1]) }
        socket.clearAuth()
        socket.setAuth { cb in cb(["b": 2]) }
        drain()

        let resolved = expectation(description: "final provider wins")
        var captured: [String: Any]?
        queue.async { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(captured?["b"] as? Int, 2,
                       "the most recently installed provider must be the one invoked")
    }
}
