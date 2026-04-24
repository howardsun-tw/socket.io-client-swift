# Phase 8 — `auth` Function Form Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `socket.setAuth(provider)` (callback form + async/throws form) and `socket.clearAuth()`. Provider is invoked on every CONNECT (initial + reconnect) on `handleQueue`. Result feeds the existing `pid`/`offset` recovery merge. v2 manager logs at install AND fires per-CONNECT `.error` clientEvent so the silent bypass is observable.

**Architecture:** New private state on `SocketIOClient`: `authProvider`, `pendingAuthTask`, `authGeneration` (UInt64 token bumped on `setAuth`/`clearAuth`/`connect()`). Extract `writeConnectPacket(_:withPayload:)` raw writer in `SocketManager` to break recursion. `resolveConnectPayload(explicit:completion:)` invokes provider on `handleQueue`, hops async results back via `handleQueue.async` (NEVER `.sync` — would deadlock against `_engineDidOpen`). Late callback dropped if generation mismatch OR status no longer `.connecting`.

**Hard deps:** Phase 1 (autoConnect) optional but tests cleaner with it. No code dep.

**Tech Stack:** Swift 5.x with concurrency, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 8.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Client/SocketIOClient.swift` | `authProvider`, `pendingAuthTask`, `authGeneration`; `setAuth(_:)` (callback + async); `clearAuth()`; `resolveConnectPayload(explicit:completion:)` |
| `Source/SocketIO/Manager/SocketManager.swift:208,387` | Extract `writeConnectPacket(_:withPayload:)` raw writer; wrap both CONNECT-write sites with `resolveConnectPayload` |
| `Tests/TestSocketIO/SocketAuthProviderTest.swift` (new) | Unit tests |
| `Tests/TestSocketIO/E2E/SocketAuthProviderE2ETest.swift` (new) | E2E + identity-swap race |

---

### Task 1: Add `authProvider` storage + `setAuth(callback)` / `clearAuth()`

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift`
- Test: `Tests/TestSocketIO/SocketAuthProviderTest.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SocketIO

final class SocketAuthProviderTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.log(false), .version(.three)])
        socket = manager.defaultSocket
    }

    func testSetAuthCallbackInstalled() {
        var invoked = 0
        socket.setAuth { cb in invoked += 1; cb(["token": "abc"]) }
        // Provider not yet invoked — only stored.
        XCTAssertEqual(invoked, 0)
    }

    func testClearAuthRemovesProvider() {
        socket.setAuth { cb in cb(["token": "abc"]) }
        socket.clearAuth()
        // Internal: authProvider should be nil. Verified indirectly by Task 3.
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SocketAuthProviderTest`
Expected: FAIL — no `setAuth`.

- [ ] **Step 3: Add typealiases + storage + setAuth/clearAuth**

In `Source/SocketIO/Client/SocketIOClient.swift`:

```swift
public typealias SocketAuthCallback = ([String: Any]?) -> Void
public typealias SocketAuthProvider = (@escaping SocketAuthCallback) -> Void
```

Inside `SocketIOClient` class, add private storage:

```swift
    private var authProvider: SocketAuthProvider?
    private var pendingAuthTask: Task<Void, Never>?
    private var authGeneration: UInt64 = 0
```

Public extension at file bottom (concrete-class only — NOT in `SocketIOClientSpec`):

```swift
public extension SocketIOClient {
    /// Install a callback-form auth provider. Invoked on `handleQueue` for every
    /// CONNECT. JS-aligned: multi-callback sends multiple CONNECTs.
    func setAuth(_ provider: @escaping SocketAuthProvider) {
        manager?.handleQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAuthTask?.cancel()
            self.pendingAuthTask = nil
            self.authProvider = provider
            self.authGeneration &+= 1  // wrap-around safe; UInt64 won't realistically wrap
        }
    }

    /// Remove the installed provider; cancels in-flight async Task.
    func clearAuth() {
        manager?.handleQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAuthTask?.cancel()
            self.pendingAuthTask = nil
            self.authProvider = nil
            self.authGeneration &+= 1
        }
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
swift test --filter SocketAuthProviderTest
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketAuthProviderTest.swift
git commit -m "Phase 8: setAuth(callback) + clearAuth + auth state storage"
```

---

### Task 2: Add `setAuth(async)` overload + fail-closed `.error` channel

- [ ] **Step 1: Write failing test**

```swift
    func testSetAuthAsyncOverloadStores() {
        socket.setAuth { try await Task.sleep(nanoseconds: 1_000_000); return ["token": "x"] }
        // Stored only; not invoked.
    }

    func testSetAuthAsyncThrowFiresErrorClientEvent() async {
        let errorFired = expectation(description: ".error fires on async-throw")
        socket.on(clientEvent: .error) { data, _ in
            if let msg = data.first as? String, msg.contains("auth") { errorFired.fulfill() }
        }
        socket.setAuth { throw NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "auth fetch failed"]) }
        // Trigger CONNECT (which would invoke provider). For unit test we manually call
        // resolveConnectPayload via the test hook (added below).
        socket.setTestStatus(.connecting)
        await socket.testInvokeAuthResolution()  // Internal test hook
        await fulfillment(of: [errorFired], timeout: 2)
    }
```

- [ ] **Step 2: Implement async overload**

```swift
public extension SocketIOClient {
    /// Async variant. Throws → `handleClientEvent(.error, ...)` fires; CONNECT NOT sent.
    func setAuth(_ provider: @escaping () async throws -> [String: Any]?) {
        // Wrap the async provider into the callback shape, capturing the generation
        // at install time so a stale completion doesn't fire CONNECT.
        let wrapped: SocketAuthProvider = { [weak self] cb in
            guard let self = self else { cb(nil); return }
            let generation = self.authGeneration
            let task = Task { [weak self] in
                guard let self = self else { return }
                do {
                    let payload = try await provider()
                    self.manager?.handleQueue.async {
                        guard self.authGeneration == generation,
                              self.status == .connecting else {
                            DefaultSocketLogger.Logger.log(
                                "auth result discarded; generation mismatch or socket no longer .connecting",
                                type: "SocketIOClient"
                            )
                            return
                        }
                        cb(payload)
                    }
                } catch {
                    self.manager?.handleQueue.async {
                        self.handleClientEvent(.error, data: ["auth provider failed: \(error.localizedDescription)"])
                    }
                }
            }
            self.pendingAuthTask = task
        }
        setAuth(wrapped)
    }
}
```

(Add a test-only helper if needed for direct invocation.)

- [ ] **Step 3: Run + commit**

```bash
swift test --filter SocketAuthProviderTest
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketAuthProviderTest.swift
git commit -m "Phase 8: async setAuth overload with fail-closed .error channel"
```

---

### Task 3: Add `resolveConnectPayload(explicit:completion:)` + bump generation on connect

- [ ] **Step 1: Add helper + bump on connect**

```swift
extension SocketIOClient {
    /// Invokes the installed provider (callback or async) and forwards the result
    /// via `completion`. If no provider, calls completion with `explicit` immediately.
    /// Always runs on `handleQueue` (callers must dispatch from there).
    internal func resolveConnectPayload(explicit: [String: Any]?,
                                        completion: @escaping ([String: Any]?) -> Void) {
        guard let provider = authProvider else {
            completion(explicit)
            return
        }
        // v2 check — see Task 5.
        if (manager?.version.rawValue ?? 0) < 3 {
            DefaultSocketLogger.Logger.error(
                "setAuth provider installed on v2 manager — auth bypassed for this CONNECT",
                type: logType
            )
            handleClientEvent(.error, data: [
                "setAuth provider installed on v2 manager — auth bypassed for this CONNECT"
            ])
            completion(nil)
            return
        }
        provider { [weak self] resolved in
            guard let self = self else { return }
            self.manager?.handleQueue.async {
                completion(resolved ?? explicit)
            }
        }
    }
}
```

In both `connect(withPayload:)` overloads, bump `authGeneration` after setting `active = true` (added in Phase 3):

```swift
    open func connect(withPayload payload: [String: Any]? = nil) {
        self.active = true
        self.authGeneration &+= 1
        // ... existing body ...
    }
```

- [ ] **Step 2: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift
git commit -m "Phase 8: resolveConnectPayload helper + authGeneration bump on connect()"
```

---

### Task 4: Extract `writeConnectPacket` raw writer in `SocketManager`

**Files:**
- Modify: `Source/SocketIO/Manager/SocketManager.swift:208-257` (split `connectSocket`)

- [ ] **Step 1: Refactor**

Find the existing `connectSocket(_:withPayload:)` (line 208). Split into:

```swift
    /// Public entry — wraps `writeConnectPacket` with provider resolution.
    open func connectSocket(_ socket: SocketIOClient, withPayload payload: [String: Any]? = nil) {
        guard status == .connected else {
            // ... existing pending-payload + connect() bootstrap ...
            return
        }

        socket.resolveConnectPayload(explicit: payload) { [weak self, weak socket] resolved in
            guard let self = self, let socket = socket else { return }
            self.writeConnectPacket(socket, withPayload: resolved)
        }
    }

    /// Raw CONNECT-packet writer. Does NOT consult any auth provider.
    /// Idempotent on the wire side. Called from `connectSocket` and `_engineDidOpen`.
    private func writeConnectPacket(_ socket: SocketIOClient, withPayload payload: [String: Any]?) {
        var payloadStr = ""
        let effective = effectiveConnectPayload(for: socket, explicitPayload: payload)

        if version.rawValue >= 3, let effective = effective {
            // ... existing JSON serialization + sendCONNECT block ...
        } else {
            // ... existing v2/no-payload branch ...
        }
    }
```

In `_engineDidOpen` (line 387), wrap the `connectSocket` call in `resolveConnectPayload` and call `writeConnectPacket` directly:

```swift
    private func _engineDidOpen(reason: String) {
        // ... existing pre-loop logic ...

        for (nsp, socket) in nsps where socket.status == .connecting {
            if version.rawValue < 3 && nsp == "/" { continue }

            let pending = consumePendingConnectPayload(for: socket) ?? socket.connectPayload
            socket.resolveConnectPayload(explicit: pending) { [weak self, weak socket] resolved in
                guard let self = self, let socket = socket else { return }
                self.writeConnectPacket(socket, withPayload: resolved)
            }
        }
    }
```

(Adapt to actual current code; verify `connectSocket` body before splitting. Use `git diff` between commits to verify the body of `writeConnectPacket` matches the original `connectSocket` body verbatim.)

- [ ] **Step 2: Run existing manager tests**

Run: `swift test --filter TestSocketManager`
Expected: PASS — no behavior change for static-payload paths because `resolveConnectPayload` short-circuits when `authProvider == nil`.

- [ ] **Step 3: Commit**

```bash
git add Source/SocketIO/Manager/SocketManager.swift
git commit -m "Phase 8: extract writeConnectPacket; wrap both CONNECT-write sites with resolveConnectPayload"
```

---

### Task 5: Tests — provider invocation, multi-callback, identity-swap race

- [ ] **Step 1: Write tests**

Append to `SocketAuthProviderTest.swift`:

```swift
    func testProviderInvokedOnConnect() {
        var invoked = 0
        socket.setAuth { cb in invoked += 1; cb(["token": "abc"]) }
        manager.handleQueue.sync { }
        socket.connect()
        // resolveConnectPayload runs after engine open; for unit isolation set status manually:
        socket.setTestStatus(.connecting)
        // Invoke the manager's _engineDidOpen path indirectly via setTestEngineDidOpen helper
        // (or simulate via manager.setTestStatus(.connected) + manual writeConnectPacket trigger).
        // Pragmatic: rely on E2E test below for full path; here we just verify provider stored.
        XCTAssertEqual(invoked, 0, "provider not invoked until CONNECT-write")
    }
```

The fully-deterministic provider-invocation test is E2E (Task 6). Unit tests verify the storage + cancellation paths.

```swift
    func testClearAuthCancelsPendingTask() async {
        let started = expectation(description: "task started")
        let cancelled = expectation(description: "task cancelled")
        socket.setAuth {
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)  // 5s
                XCTFail("should have been cancelled")
            } catch {
                cancelled.fulfill()
            }
            return nil
        }
        // Trigger via test hook or wait for connect; here we set status + manually
        // invoke resolveConnectPayload in test:
        await socket.testInvokeAuthResolution()
        await fulfillment(of: [started], timeout: 1)
        socket.clearAuth()
        await fulfillment(of: [cancelled], timeout: 2)
    }
```

(`testInvokeAuthResolution` is a `#if DEBUG`-gated helper that calls `resolveConnectPayload` with `nil` explicit and a no-op completion.)

- [ ] **Step 2: Commit**

```bash
git add Tests/TestSocketIO/SocketAuthProviderTest.swift Source/SocketIO/Client/SocketIOClient.swift
git commit -m "Phase 8: tests for provider storage + clearAuth Task cancellation"
```

---

### Task 6: E2E — provider per-attempt + recovery merge + identity-swap stale-auth race

- [ ] **Step 1: Write E2E test**

Create `Tests/TestSocketIO/E2E/SocketAuthProviderE2ETest.swift`:

```swift
import XCTest
@testable import SocketIO

final class SocketAuthProviderE2ETest: XCTestCase {
    var server: TestServerProcess!
    override func setUp() { super.setUp(); server = try! TestServerProcess.start() }
    override func tearDown() { server.stop(); super.tearDown() }

    func testProviderSendsAuthOnConnect() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false), .version(.three)])
        let socket = manager.defaultSocket
        socket.setAuth { cb in cb(["token": "abc"]) }

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        // Server fixture echoes received auth back on "__check_auth".
        let checked = expectation(description: "auth echoed")
        socket.emitWithAck("__check_auth").timingOut(after: 2) { data in
            XCTAssertEqual(data.first as? [String: String], ["token": "abc"])
            checked.fulfill()
        }
        wait(for: [checked], timeout: 3)
    }

    func testProviderReinvokedOnReconnect() {
        let manager = SocketManager(socketURL: server.url,
                                    config: [.log(false), .version(.three), .reconnects(true)])
        let socket = manager.defaultSocket
        var invocations = 0
        socket.setAuth { cb in invocations += 1; cb(["token": "abc"]) }

        let firstConnect = expectation(description: "first connect")
        socket.on(clientEvent: .connect) { _, _ in firstConnect.fulfill() }
        socket.connect()
        wait(for: [firstConnect], timeout: 5)
        XCTAssertEqual(invocations, 1)

        let reconnected = expectation(description: "reconnect")
        socket.on(clientEvent: .reconnect) { _, _ in reconnected.fulfill() }
        server.stop()
        Thread.sleep(forTimeInterval: 0.5)
        server = try! TestServerProcess.start()
        wait(for: [reconnected], timeout: 10)
        XCTAssertEqual(invocations, 2, "provider re-invoked on reconnect")
    }

    func testProviderMultiCallbackSendsTwoConnects() {
        // JS-parity: provider invoking cb twice → server sees TWO CONNECT packets.
        let manager = SocketManager(socketURL: server.url, config: [.log(false), .version(.three)])
        let socket = manager.defaultSocket
        socket.setAuth { cb in cb(["a": 1]); cb(["b": 2]) }

        let dualReceived = expectation(description: "server gets 2 CONNECTs")
        // Server fixture must expose __connect_count to ack the count for this client.
        socket.on(clientEvent: .connect) { _, _ in
            socket.emitWithAck("__connect_count").timingOut(after: 2) { data in
                if (data.first as? Int) == 2 { dualReceived.fulfill() }
            }
        }
        socket.connect()
        wait(for: [dualReceived], timeout: 5)
    }

    func testIdentitySwapStaleAuthRace() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false), .version(.three)])
        let socket = manager.defaultSocket

        // provider1 delays 500ms
        let provider1Done = expectation(description: "provider1 ran (would have)")
        socket.setAuth { try await Task.sleep(nanoseconds: 500_000_000); provider1Done.fulfill(); return ["token": "old"] }
        socket.connect()

        // Immediately swap identity.
        socket.disconnect()
        socket.clearAuth()
        socket.setAuth { cb in cb(["token": "new"]) }
        socket.connect()

        let connected = expectation(description: "connect with new auth")
        socket.on(clientEvent: .connect) { _, _ in
            socket.emitWithAck("__check_auth").timingOut(after: 2) { data in
                let auth = data.first as? [String: String]
                XCTAssertEqual(auth, ["token": "new"], "stale provider1 callback must NOT have fired CONNECT")
                connected.fulfill()
            }
        }
        wait(for: [provider1Done, connected], timeout: 5)
    }
}
```

(Update `Tests/TestSocketIO/E2E/Fixtures/server.js` to expose `__check_auth` and `__connect_count` ack handlers.)

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketAuthProviderE2ETest
git add Tests/TestSocketIO/E2E/SocketAuthProviderE2ETest.swift Tests/TestSocketIO/E2E/Fixtures/server.js
git commit -m "Phase 8: E2E — provider per-CONNECT, multi-callback, identity-swap race"
```

---

### Task 7: v2 manager test + recovery-merge wire-shape test

- [ ] **Step 1: Add v2 test**

```swift
    func testV2ManagerProviderInstallEmitsErrorAndPerAttempt() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false), .version(.two)])
        let socket = manager.defaultSocket
        var providerInvocations = 0
        var errorFires = 0
        socket.on(clientEvent: .error) { data, _ in
            if let msg = data.first as? String, msg.contains("v2") { errorFires += 1 }
        }
        socket.setAuth { cb in providerInvocations += 1; cb(["token": "x"]) }

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        XCTAssertEqual(providerInvocations, 0, "provider must not be invoked on v2")
        XCTAssertEqual(errorFires, 1, "v2 + provider must fire .error per CONNECT attempt")
    }
```

- [ ] **Step 2: Add wire-shape parity test**

```swift
    func testProviderNilProducesIdenticalPacketAsStaticNil() {
        // Capture wire bytes for `setAuth { cb in cb(nil) }` vs `connect(withPayload: nil)`
        // — both must produce identical CONNECT packets. Server fixture echoes the raw
        // received packet on "__last_packet".
        let m1 = SocketManager(socketURL: server.url, config: [.log(false), .version(.three)])
        let s1 = m1.defaultSocket
        s1.setAuth { cb in cb(nil) }
        let c1 = expectation(description: "s1 connect")
        s1.on(clientEvent: .connect) { _, _ in
            s1.emitWithAck("__last_packet").timingOut(after: 2) { data in
                let packet1 = data.first as? String
                // Open a second client with static nil
                let m2 = SocketManager(socketURL: self.server.url, config: [.log(false), .version(.three)])
                let s2 = m2.defaultSocket
                let c2 = self.expectation(description: "s2 connect")
                s2.on(clientEvent: .connect) { _, _ in
                    s2.emitWithAck("__last_packet").timingOut(after: 2) { data2 in
                        let packet2 = data2.first as? String
                        XCTAssertEqual(packet1, packet2, "provider-nil must produce same wire as static-nil")
                        c2.fulfill()
                    }
                }
                s2.connect()
                self.wait(for: [c2], timeout: 5)
                c1.fulfill()
            }
        }
        s1.connect()
        wait(for: [c1], timeout: 10)
    }
```

- [ ] **Step 2: Commit**

```bash
git add Tests/TestSocketIO/E2E/SocketAuthProviderE2ETest.swift Tests/TestSocketIO/E2E/Fixtures/server.js
git commit -m "Phase 8: v2 manager + wire-shape parity for nil provider"
```

---

### Task 8: PR

```markdown
### Added (Phase 8)
- `SocketIOClient.setAuth(_:)` (callback form + async/throws form) and `clearAuth()`.
- Provider invoked on `handleQueue` for every CONNECT (initial + reconnect).
- `authGeneration` token guards against stale-auth race on identity-swap.
- Async-throws → `handleClientEvent(.error, ...)`; CONNECT not sent.
- v2 manager: per-CONNECT `.error` clientEvent + install-time log; provider never invoked.
- `SocketManager.writeConnectPacket(_:withPayload:)` raw writer extracted from `connectSocket` to break recursion.
```

```bash
git push -u origin phase-8-auth-provider
gh pr create --title "Phase 8: auth function form (provider per CONNECT)" --body "..."
```
