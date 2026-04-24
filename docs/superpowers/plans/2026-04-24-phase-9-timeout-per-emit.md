# Phase 9 — `socket.timeout(after:).emit(..., ack:)` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-emit ack with err-first callback (`(Error?, [Any]) -> Void`). Typed `SocketAckError.timeout` / `.disconnected`. New parallel `timedAcks` storage in `SocketAckManager` (legacy `acks` untouched). Atomic one-shot fire across timer/ack/cancel paths. Async/throws overload.

**Architecture:** New `SocketAckError` enum, `SocketTimedEmitter` struct, `timedAcks: [Int: TimedAckEntry]` parallel storage. **`addTimedAck` is registered BEFORE the internal `emit` funnel runs** so disconnected emits still get a deterministic timer fire (matches JS `_registerAckCallback` ordering). All four manager APIs serialize via `handleQueue.async`. Atomic `fired: Bool` flag protected by `handleQueue` ensures the user callback is invoked exactly once across timer / server-ack / `Task.cancel()` paths.

**Hard dep:** Phase 2 (reserved guard).

**Tech Stack:** Swift 5.x with concurrency, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 9.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Ack/SocketAckError.swift` (new) | `public enum SocketAckError: Error, Equatable { case timeout, disconnected }` |
| `Source/SocketIO/Ack/SocketTimedEmitter.swift` (new) | `public struct SocketTimedEmitter` with 4 emit overloads |
| `Source/SocketIO/Ack/SocketAckManager.swift:72-88` | Add `timedAcks` storage + 4 internal APIs |
| `Source/SocketIO/Client/SocketIOClient.swift` | `timeout(after:)`; `handleAck` tries timed first; `didDisconnect` clears timed |
| `Source/SocketIO/Client/SocketIOClientSpec.swift` | Add `timeout(after:)` requirement + default impl |
| `Tests/TestSocketIO/SocketTimedEmitterTest.swift` (new) | Unit tests |
| `Tests/TestSocketIO/E2E/SocketTimedEmitterE2ETest.swift` (new) | E2E tests |

---

### Task 1: `SocketAckError` enum

- [ ] **Step 1: Create the file**

```swift
//
//  SocketAckError.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// Typed error for `SocketTimedEmitter` ack callbacks.
/// JS-aligned mapping of `socket.io-client/lib/socket.ts` distinct error messages:
/// - `.timeout`     ↔ `new Error("operation has timed out")`
/// - `.disconnected` ↔ `new Error("socket has been disconnected")`
public enum SocketAckError: Error, Equatable {
    case timeout
    case disconnected
}
```

- [ ] **Step 2: Commit**

```bash
git add Source/SocketIO/Ack/SocketAckError.swift
git commit -m "Phase 9: add SocketAckError enum"
```

---

### Task 2: `SocketAckManager` — `timedAcks` storage + 4 internal APIs

- [ ] **Step 1: Write failing tests**

Create `Tests/TestSocketIO/SocketTimedEmitterTest.swift`:

```swift
import XCTest
@testable import SocketIO

final class SocketTimedAckManagerTest: XCTestCase {
    var ackManager: SocketAckManager!
    var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        ackManager = SocketAckManager()
        queue = DispatchQueue(label: "test.handle")
    }

    func testAddTimedAckFires() {
        let exp = expectation(description: "callback")
        queue.sync {
            ackManager.addTimedAck(1, on: queue,
                                   callback: { err, data in
                                       XCTAssertNil(err)
                                       XCTAssertEqual(data.first as? String, "ok")
                                       exp.fulfill()
                                   },
                                   timeout: 60)
        }
        queue.async { self.ackManager.executeTimedAck(1, with: ["ok"]) }
        wait(for: [exp], timeout: 1)
    }

    func testTimedAckTimesOut() {
        let exp = expectation(description: "timeout")
        queue.sync {
            ackManager.addTimedAck(2, on: queue,
                                   callback: { err, _ in
                                       XCTAssertEqual(err as? SocketAckError, .timeout)
                                       exp.fulfill()
                                   },
                                   timeout: 0.1)
        }
        wait(for: [exp], timeout: 1)
    }

    func testCancelTimedAck() {
        let exp = expectation(description: "callback NOT fired")
        exp.isInverted = true
        queue.sync {
            ackManager.addTimedAck(3, on: queue,
                                   callback: { _, _ in exp.fulfill() },
                                   timeout: 0.5)
        }
        queue.async { self.ackManager.cancelTimedAck(3) }
        wait(for: [exp], timeout: 1)  // 1s > 0.5s timeout, but cancel removes it
    }

    func testClearTimedAcksFiresAllWithReason() {
        let exp = expectation(description: "both fire .disconnected")
        exp.expectedFulfillmentCount = 2
        queue.sync {
            ackManager.addTimedAck(4, on: queue, callback: { err, _ in
                XCTAssertEqual(err as? SocketAckError, .disconnected); exp.fulfill()
            }, timeout: 60)
            ackManager.addTimedAck(5, on: queue, callback: { err, _ in
                XCTAssertEqual(err as? SocketAckError, .disconnected); exp.fulfill()
            }, timeout: 60)
        }
        queue.async { self.ackManager.clearTimedAcks(reason: .disconnected) }
        wait(for: [exp], timeout: 1)
    }

    func testOneShotGuard() {
        var fires = 0
        let exp = expectation(description: "first execute fires once")
        queue.sync {
            ackManager.addTimedAck(6, on: queue,
                                   callback: { _, _ in fires += 1; exp.fulfill() },
                                   timeout: 60)
        }
        queue.async { self.ackManager.executeTimedAck(6, with: ["a"]) }
        queue.async { self.ackManager.executeTimedAck(6, with: ["b"]) }  // duplicate
        wait(for: [exp], timeout: 1)
        queue.sync { }  // drain
        XCTAssertEqual(fires, 1, "duplicate must be silently dropped")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SocketTimedAckManagerTest`
Expected: FAIL — no `addTimedAck`.

- [ ] **Step 3: Implement on `SocketAckManager`**

In `Source/SocketIO/Ack/SocketAckManager.swift`, append below the existing class (or extend it):

```swift
extension SocketAckManager {
    private struct TimedAckEntry {
        let callback: (Error?, [Any]) -> Void
        var timer: DispatchWorkItem?
        var fired: Bool = false
    }

    // Storage shared via private holder — Swift extensions can't add stored properties,
    // so we use a class-bound static-keyed dictionary or refactor SocketAckManager
    // to hold this directly. Refactor approach (recommended): change the class to:
}

// Refactor SocketAckManager class declaration to:
class SocketAckManager {
    private var acks = Set<SocketAck>(minimumCapacity: 1)
    private var timedAcks: [Int: TimedAckEntry] = [:]

    private struct TimedAckEntry {
        let callback: (Error?, [Any]) -> Void
        var timer: DispatchWorkItem?
        var fired: Bool = false
    }

    // ... existing addAck / executeAck / timeoutAck unchanged ...

    /// Add a timed ack. Caller MUST be on `queue`. Schedules a `DispatchWorkItem`
    /// on `queue.asyncAfter`; on fire, runs `(check fired → set fired → remove
    /// entry → cancel timer → invoke callback)` atomically as one block.
    func addTimedAck(_ id: Int,
                     on queue: DispatchQueue,
                     callback: @escaping (Error?, [Any]) -> Void,
                     timeout: Double) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Already on `queue`.
            guard var entry = self.timedAcks[id], !entry.fired else { return }
            entry.fired = true
            self.timedAcks[id] = nil
            callback(SocketAckError.timeout, [])
        }
        timedAcks[id] = TimedAckEntry(callback: callback, timer: workItem, fired: false)
        let deadline: DispatchTime = timeout.isFinite ? .now() + timeout : .distantFuture
        queue.asyncAfter(deadline: deadline, execute: workItem)
    }

    /// Execute the timed ack with server-supplied data. Caller MUST be on `queue`.
    /// One-shot via `fired` flag.
    func executeTimedAck(_ id: Int, with items: [Any]) {
        guard var entry = timedAcks[id], !entry.fired else {
            DefaultSocketLogger.Logger.log("bad ack id \(id)", type: "SocketAckManager")
            return
        }
        entry.fired = true
        entry.timer?.cancel()
        timedAcks[id] = nil
        entry.callback(nil, items)
    }

    /// Cancel without firing the callback. Used by async overload's
    /// `withTaskCancellationHandler`. Caller MUST be on `queue`.
    func cancelTimedAck(_ id: Int) {
        guard var entry = timedAcks[id], !entry.fired else { return }
        entry.fired = true
        entry.timer?.cancel()
        timedAcks[id] = nil
        // Note: callback NOT invoked — the continuation handles that.
    }

    /// Fire all outstanding timed acks with `reason` and clear storage.
    /// Caller MUST be on `queue`.
    func clearTimedAcks(reason: SocketAckError) {
        let snapshot = timedAcks
        timedAcks.removeAll(keepingCapacity: false)
        for (_, entry) in snapshot where !entry.fired {
            entry.timer?.cancel()
            entry.callback(reason, [])
        }
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
swift test --filter SocketTimedAckManagerTest
git add Source/SocketIO/Ack/SocketAckManager.swift Tests/TestSocketIO/SocketTimedEmitterTest.swift
git commit -m "Phase 9: SocketAckManager timed-ack APIs (add/execute/cancel/clear)"
```

---

### Task 3: `SocketTimedEmitter` struct + `timeout(after:)` getter

- [ ] **Step 1: Create the emitter**

`Source/SocketIO/Ack/SocketTimedEmitter.swift`:

```swift
//
//  SocketTimedEmitter.swift
//  Socket.IO-Client-Swift
//

import Foundation

public struct SocketTimedEmitter {
    let socket: SocketIOClient  // concrete-bound; protocol default impl wraps a Spec
    let timeout: Double

    public func emit(_ event: String, _ items: SocketData...,
                     ack: @escaping (Error?, [Any]) -> Void) {
        emit(event, with: items, ack: ack)
    }

    public func emit(_ event: String, with items: [SocketData],
                     ack: @escaping (Error?, [Any]) -> Void) {
        socket.emitTimed(event: event, items: items, timeout: timeout, ack: ack)
    }

    public func emit(_ event: String, _ items: SocketData...) async throws -> [Any] {
        return try await emit(event, with: items)
    }

    public func emit(_ event: String, with items: [SocketData]) async throws -> [Any] {
        let id = socket.allocateAckId()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                socket.emitTimed(event: event, items: items, timeout: timeout, ackId: id) { err, data in
                    if let err = err {
                        continuation.resume(throwing: err)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
        } onCancel: {
            socket.manager?.handleQueue.async {
                socket.ackHandlers.cancelTimedAck(id)
            }
        }
    }
}
```

- [ ] **Step 2: Add `timeout(after:)` + `emitTimed` + `allocateAckId` on `SocketIOClient`**

```swift
public extension SocketIOClient {
    /// Returns a chainable timed-emit handle.
    func timeout(after seconds: Double) -> SocketTimedEmitter {
        return SocketTimedEmitter(socket: self, timeout: seconds)
    }
}

extension SocketIOClient {
    /// Internal — called from SocketTimedEmitter. Allocates an ack id, registers
    /// the timed ack BEFORE running the emit funnel, then routes through the funnel.
    /// Registration-before-funnel ordering is critical: if the funnel's connected
    /// guard fires .error and early-returns, the timer is already scheduled and
    /// will fire `cb(.timeout, [])` after `timeout` seconds (matches JS).
    internal func emitTimed(event: String,
                            items: [SocketData],
                            timeout: Double,
                            ackId: Int? = nil,
                            ack: @escaping (Error?, [Any]) -> Void) {
        manager?.handleQueue.async { [weak self] in
            guard let self = self else { return }
            let id = ackId ?? self.allocateAckId()
            self.ackHandlers.addTimedAck(id, on: self.manager!.handleQueue,
                                         callback: ack, timeout: timeout)
            do {
                let mapped = [event] + (try items.map { try $0.socketRepresentation() })
                self.emit(mapped, ack: id, binary: true, isAck: false)
            } catch {
                self.ackHandlers.cancelTimedAck(id)
                ack(error, [])
            }
        }
    }

    /// Internal — allocate the next ack id (matches existing `currentAck += 1` pattern).
    internal func allocateAckId() -> Int {
        currentAck += 1
        return currentAck
    }

    /// Test-only access to the internal ack manager (used by SocketTimedEmitter
    /// async cancel path).
    internal var ackHandlers: SocketAckManager { return ackManager }
}
```

(Verify the existing `ackManager` property name in `SocketIOClient.swift` — search for `private let ackManager` or `var ackManager`.)

- [ ] **Step 3: Update `handleAck` to try timed first**

In `SocketIOClient.swift:496-502` (`open func handleAck`):

```swift
    open func handleAck(_ ack: Int, data: [Any]) {
        guard status == .connected else { return }
        DefaultSocketLogger.Logger.log("Handling ack: \(ack) with data: \(data)", type: logType)

        // Try timed-ack path first; on miss, dispatch to legacy executeAck.
        ackHandlers.executeTimedAck(ack, with: data)
        ackHandlers.executeAck(ack, with: data)  // legacy — no-op if id was timed
    }
```

(Important: ack ids are unique across both stores because both call `allocateAckId()` / `currentAck += 1`. `executeAck` no-ops on missing id; same for `executeTimedAck`. So the double-call is safe.)

- [ ] **Step 4: `didDisconnect` clears timed acks**

In `SocketIOClient.swift:336` (`open func didDisconnect`), add at the end:

```swift
        manager?.handleQueue.async { [weak self] in
            self?.ackHandlers.clearTimedAcks(reason: .disconnected)
        }
```

(Or before the existing tail logic, depending on what the function does — verify by reading the current body. Place AFTER any state mutation that would still be observed by the cleared callbacks.)

- [ ] **Step 5: Add `timeout(after:)` to `SocketIOClientSpec` with default impl**

In `SocketIOClientSpec.swift`:

```swift
    func timeout(after seconds: Double) -> SocketTimedEmitter
```

(Default impl is concrete on `SocketIOClient`; for the protocol default, callers via `SocketIOClientSpec` use the concrete via cast. Or skip the protocol addition entirely — keep `timeout(after:)` concrete-only since `SocketTimedEmitter` requires `SocketIOClient` for `allocateAckId`/`ackHandlers`.)

**Recommended:** keep concrete-only. Drop the protocol requirement.

- [ ] **Step 6: Commit**

```bash
git add Source/SocketIO/Ack/SocketTimedEmitter.swift Source/SocketIO/Client/SocketIOClient.swift
git commit -m "Phase 9: SocketTimedEmitter + timeout(after:) + handleAck/didDisconnect wiring"
```

---

### Task 4: End-to-end tests for callback path

- [ ] **Step 1: Append callback-path tests**

```swift
final class SocketTimedEmitterCallbackTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    func testTimedEmitTimesOutWhenNoServer() {
        let exp = expectation(description: ".timeout fires")
        socket.timeout(after: 0.1).emit("ping") { err, data in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            XCTAssertTrue(data.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testDisconnectMidWaitFiresDisconnected() {
        let exp = expectation(description: ".disconnected fires")
        socket.timeout(after: 5).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .disconnected)
            exp.fulfill()
        }
        manager.handleQueue.sync { }
        socket.didDisconnect(reason: "test")
        wait(for: [exp], timeout: 1)
    }

    func testNegativeTimeoutFiresImmediately() {
        let exp = expectation(description: ".timeout fires next tick")
        socket.timeout(after: -1).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testInfinityTimeoutDoesNotFireQuickly() {
        let exp = expectation(description: "no fire within 0.5s")
        exp.isInverted = true
        socket.timeout(after: .infinity).emit("ping") { _, _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)
    }

    func testRegistrationBeforeFunnel_DisconnectedEmitStillTimesOut() {
        // Critical: socket is NOT .connected — funnel will fire .error and early-return.
        // But the ack must be registered BEFORE the funnel runs, so the timer fires.
        socket.setTestStatus(.disconnected)
        let exp = expectation(description: "timeout fires even though emit early-returned")
        socket.timeout(after: 0.2).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketTimedEmitterCallback
git add Tests/TestSocketIO/SocketTimedEmitterTest.swift
git commit -m "Phase 9: callback-path tests (timeout, disconnect, negative, infinity, pre-connect)"
```

---

### Task 5: Async overload + cancellation tests

- [ ] **Step 1: Tests**

```swift
final class SocketTimedEmitterAsyncTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    func testAsyncTimeoutThrows() async {
        do {
            _ = try await socket.timeout(after: 0.1).emit("ping")
            XCTFail("should have thrown")
        } catch let error as SocketAckError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAsyncCancelThrowsCancellationError() async {
        let task = Task {
            do {
                _ = try await socket.timeout(after: 60).emit("ping")
                XCTFail("should have thrown")
            } catch is CancellationError {
                // Expected — cancellation handler resumed continuation throwing.
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value
    }

    func testAsyncCancelClearsTimedAck() async {
        let task = Task { try? await socket.timeout(after: 60).emit("ping") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value
        manager.handleQueue.sync { }
        // Inspect via test hook or by issuing another emit and verifying id reuse pattern.
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketTimedEmitterAsyncTest
git add Tests/TestSocketIO/SocketTimedEmitterTest.swift
git commit -m "Phase 9: async overload tests (timeout throws + Task.cancel cleanup)"
```

---

### Task 6: Race / atomicity stress + storage isolation

- [ ] **Step 1: Tests**

```swift
final class SocketTimedEmitterRaceTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    func testTimerAckRaceFires Once() {
        // 1000 iterations with very tight race windows.
        for _ in 0..<1000 {
            var fires = 0
            let exp = expectation(description: "single fire")
            exp.expectedFulfillmentCount = 1
            socket.timeout(after: 0.001).emit("ping") { _, _ in
                fires += 1
                if fires == 1 { exp.fulfill() }
            }
            // Race: server-ack arrives at ~the same time as timer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.001) { [weak self] in
                self?.manager.handleQueue.async {
                    self?.socket.handleAck(self!.socket.currentAck, data: ["x"])
                }
            }
            wait(for: [exp], timeout: 1)
            // Tiny sleep to let any double-fire surface (would fail XCTest count assertion).
            Thread.sleep(forTimeInterval: 0.005)
            XCTAssertEqual(fires, 1, "must fire exactly once")
        }
    }

    func testLegacyEmitWithAckTimingOutNotClearedOnDisconnect() {
        // JS-divergence regression-pin: legacy path is orphaned on disconnect.
        var fires = 0
        socket.emitWithAck("ping").timingOut(after: 5) { _ in fires += 1 }
        manager.handleQueue.sync { }
        socket.didDisconnect(reason: "test")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fires, 0, "legacy path is NOT cleared on disconnect (Swift backcompat divergence)")
    }
}
```

(Method-name typo `Once` is intentional placeholder — fix to `testTimerAckRaceFiresOnce` before commit.)

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketTimedEmitterRaceTest
git add Tests/TestSocketIO/SocketTimedEmitterTest.swift
git commit -m "Phase 9: race/atomicity stress + legacy-divergence regression pin"
```

---

### Task 7: E2E — server-side ack round-trip

- [ ] **Step 1: Write E2E**

```swift
import XCTest
@testable import SocketIO

final class SocketTimedEmitterE2ETest: XCTestCase {
    var server: TestServerProcess!
    override func setUp() { super.setUp(); server = try! TestServerProcess.start() }
    override func tearDown() { server.stop(); super.tearDown() }

    func testServerAckArrivesBeforeTimeout() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false)])
        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let acked = expectation(description: "server ack")
        socket.timeout(after: 2).emit("ping") { err, data in
            XCTAssertNil(err)
            XCTAssertEqual(data.first as? String, "pong")
            acked.fulfill()
        }
        wait(for: [acked], timeout: 3)
    }

    func testTimeoutWhenServerNeverAcks() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false)])
        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let timedOut = expectation(description: ".timeout")
        socket.timeout(after: 0.3).emit("never_ack") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 2)
    }
}
```

(Server fixture must respond to `ping` with `cb("pong")` and never-ack `never_ack`.)

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketTimedEmitterE2ETest
git add Tests/TestSocketIO/E2E/SocketTimedEmitterE2ETest.swift Tests/TestSocketIO/E2E/Fixtures/server.js
git commit -m "Phase 9: E2E — server ack roundtrip + timeout"
```

---

### Task 8: PR

```markdown
### Added (Phase 9)
- `SocketIOClient.timeout(after:) -> SocketTimedEmitter` — typed-error per-emit ack.
- `SocketAckError.timeout` / `.disconnected` enum.
- Async/throws overload with `Task.cancel()` support.
- Atomic one-shot fire across timer/server-ack/cancel paths.
- `SocketAckManager` parallel `timedAcks` storage; legacy `acks` untouched.
- `didDisconnect` clears `timedAcks` (matches JS `_clearAcks` for `withError` callbacks).
- Legacy `emitWithAck.timingOut` divergence (not cleared on disconnect) regression-pinned.
```

```bash
git push -u origin phase-9-timeout-per-emit
gh pr create --title "Phase 9: socket.timeout(after:).emit per-emit ack" --body "..."
```
