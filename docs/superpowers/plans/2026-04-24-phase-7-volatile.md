# Phase 7 — `socket.volatile.emit(...)` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `socket.volatile.emit(...)` chain. Volatile packets drop when the engine transport is not writable; non-volatile emits proceed normally on the same not-writable transport (preserves existing Swift `.error` behavior). Drop does NOT fire `.error`, does NOT fire outgoing listeners, does NOT buffer.

**Architecture:** New `SocketVolatileEmitter` struct. New `volatile: SocketVolatileEmitter { get }` getter on concrete `SocketIOClient`. Internal `emit` funnel grows a `volatile: Bool = false` parameter. Gate predicate: `volatile && !engine.writable`. **Add `var writable: Bool { get }` to `SocketEngineSpec`** with default impl returning `false` (fail-safe — any conformer that doesn't override drops all volatile packets).

**Tech Stack:** Swift 5.x, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 7.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Engine/SocketEngineSpec.swift:30-43` | Add `var writable: Bool { get }` requirement + default impl |
| `Source/SocketIO/Engine/SocketEngine.swift` | Implement `writable` (forward transport state) |
| `Source/SocketIO/Engine/SocketEnginePollable.swift` | Polling transport `writable` (false while POST in flight) |
| `Source/SocketIO/Engine/SocketEngineWebsocket.swift` | WebSocket transport `writable` |
| `Source/SocketIO/Client/SocketVolatileEmitter.swift` (new) | Struct holding socket reference + `emit(...)` overloads |
| `Source/SocketIO/Client/SocketIOClient.swift` | `volatile` getter; internal funnel grows `volatile: Bool` parameter |
| `Tests/TestSocketIO/SocketVolatileTest.swift` (new) | Unit tests with mock writable hook |

---

### Task 1: Add `writable` to `SocketEngineSpec` with fail-safe default

**Files:**
- Modify: `Source/SocketIO/Engine/SocketEngineSpec.swift`

- [ ] **Step 1: Add the requirement**

In `SocketEngineSpec.swift` near line 43 (after `var connected: Bool { get }`):

```swift
    /// Whether the underlying transport can accept a write right now without
    /// queuing. Used by Phase 7 volatile-emit gate. Default impl returns `false`
    /// (fail-safe — any conformer that doesn't override drops all volatile
    /// packets, which is safer than incorrectly admitting them).
    var writable: Bool { get }
```

Add a default in an extension at the end of the file:

```swift
public extension SocketEngineSpec {
    var writable: Bool { return false }
}
```

- [ ] **Step 2: Implement on `SocketEngine`**

In `Source/SocketIO/Engine/SocketEngine.swift`, override the default. The exact implementation depends on the active transport; concrete approach:

```swift
    public var writable: Bool {
        guard connected else { return false }
        // For WebSocket: forward the underlying socket's writable signal.
        // For polling: false while a POST is in flight.
        if usingWS, let ws = ws { return ws.isWritable }  // adapt to actual property
        return !isPolling && !waitingForPoll && !waitingForPost
    }
```

(Inspect `SocketEngine.swift` for the actual fields tracking polling state. The `ws.isWritable` check assumes the WebSocket library exposes this; if not, maintain a private `private var isWriting = false` set during `write` calls.)

- [ ] **Step 3: Compile-check**

Run: `swift build`
Expected: builds cleanly. If WebSocket transport doesn't expose writable directly, fall back to `connected` for that transport with a TODO comment + open a follow-up issue.

- [ ] **Step 4: Commit**

```bash
git add Source/SocketIO/Engine/SocketEngineSpec.swift Source/SocketIO/Engine/SocketEngine.swift
git commit -m "Phase 7: add SocketEngineSpec.writable with fail-safe default + concrete impl"
```

---

### Task 2: `SocketVolatileEmitter` + `volatile` getter

**Files:**
- Create: `Source/SocketIO/Client/SocketVolatileEmitter.swift`
- Modify: `Source/SocketIO/Client/SocketIOClient.swift` (add `volatile` getter)

- [ ] **Step 1: Create the emitter struct**

```swift
//
//  SocketVolatileEmitter.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// Volatile-emit chain. Drops the packet if the engine transport is not
/// writable. Does NOT fire `.error`, outgoing listeners, or buffer.
/// JS-aligned per `socket.io-client/lib/socket.ts` `emit()` body — gates on
/// `transport.writable`, not on `status`.
public struct SocketVolatileEmitter {
    let socket: SocketIOClient

    public func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil) {
        emit(event, with: items, completion: completion)
    }

    public func emit(_ event: String, with items: [SocketData], completion: (() -> ())? = nil) {
        do {
            let mapped = [event] + (try items.map { try $0.socketRepresentation() })
            socket.emitVolatile(mapped, completion: completion)
        } catch {
            DefaultSocketLogger.Logger.error(
                "Error creating socketRepresentation for volatile emit: \(event), \(items)",
                type: "SocketVolatileEmitter"
            )
            socket.handleClientEvent(.error, data: [event, items, error])
        }
    }
}
```

- [ ] **Step 2: Add `volatile` getter + `emitVolatile` shim on `SocketIOClient`**

In `Source/SocketIO/Client/SocketIOClient.swift`, after the `emit` overloads (around line 386):

```swift
    /// Volatile-emit chain. See `SocketVolatileEmitter`.
    public var volatile: SocketVolatileEmitter {
        return SocketVolatileEmitter(socket: self)
    }

    /// Internal entry — routes through the funnel with `volatile: true`.
    /// Marked `internal`, not `public`, so users go through the chain.
    internal func emitVolatile(_ data: [Any], completion: (() -> ())? = nil) {
        emit(data, ack: nil, binary: true, isAck: false, volatile: true, completion: completion)
    }
```

- [ ] **Step 3: Grow the internal funnel signature**

Modify `func emit(_ data:[Any], ack:Int? = nil, binary:Bool = true, isAck:Bool = false, completion:)` (line 454) to add `volatile: Bool = false`:

```swift
    func emit(_ data: [Any],
              ack: Int? = nil,
              binary: Bool = true,
              isAck: Bool = false,
              volatile: Bool = false,
              completion: (() -> ())? = nil
    ) {
        let wrappedCompletion: (() -> ())? = (completion == nil) ? nil : { /* ... */ }

        if !isAck, failIfReserved(data) {
            wrappedCompletion?()
            return
        }

        // Volatile gate — JS-aligned: gate on transport.writable, NOT on status.
        if volatile, !(manager?.engine?.writable ?? false) {
            DefaultSocketLogger.Logger.log(
                "volatile packet dropped (transport not writable)",
                type: logType
            )
            wrappedCompletion?()
            return
        }

        guard status == .connected else {
            wrappedCompletion?()
            handleClientEvent(.error, data: ["Tried emitting when not connected"])
            return
        }

        // ... existing packet build + outgoing listeners (Phase 5) + send ...
    }
```

The default `volatile: false` means existing call sites are unaffected. Verify all internal call sites still compile (`emitAck`, `emit("message", ...)`, etc.).

- [ ] **Step 4: Commit**

```bash
git add Source/SocketIO/Client/SocketVolatileEmitter.swift Source/SocketIO/Client/SocketIOClient.swift
git commit -m "Phase 7: SocketVolatileEmitter + volatile gate (engine.writable predicate)"
```

---

### Task 3: Unit tests with mock writable

- [ ] **Step 1: Add test helper for writable hook**

Tests need a way to set `engine.writable` deterministically. If `SocketEngine.writable` is a computed property reading other fields, expose a test-only setter:

```swift
#if DEBUG
extension SocketEngineSpec where Self: SocketEngine {
    func setTestWritable(_ value: Bool) { /* set whatever underlying flag drives writable */ }
}
#endif
```

Or — simpler — use a mock `SocketEngineSpec` in tests. Create `Tests/TestSocketIO/Mocks/MockEngine.swift`:

```swift
@testable import SocketIO

final class MockEngine: SocketEngineSpec {
    var connected: Bool = true
    var writable: Bool = true
    // ... other required protocol methods (no-op/stubs) ...
}
```

(Stubbing every protocol method is verbose. Inspect `SocketEngineSpec` requirements; copy stubs from any existing test fixture if one exists. If none, the simpler approach is a test-only setter on real `SocketEngine`.)

- [ ] **Step 2: Write tests**

```swift
import XCTest
@testable import SocketIO

final class SocketVolatileTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var mockEngine: MockEngine!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        mockEngine = MockEngine()
        manager.engine = mockEngine
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    func testVolatileEmitWhileWritableSends() {
        var captured: SocketAnyEvent?
        _ = socket.addAnyOutgoingListener { e in captured = e }
        manager.handleQueue.sync { }
        mockEngine.writable = true
        socket.volatile.emit("foo", "x")
        XCTAssertEqual(captured?.event, "foo")
    }

    func testVolatileEmitWhileNotWritableDrops() {
        var fired = 0
        _ = socket.addAnyOutgoingListener { _ in fired += 1 }
        var errorFired = 0
        socket.on(clientEvent: .error) { _, _ in errorFired += 1 }
        manager.handleQueue.sync { }
        mockEngine.writable = false
        socket.volatile.emit("foo", "x")
        XCTAssertEqual(fired, 0, "volatile drop must NOT fire outgoing listener (JS-aligned)")
        XCTAssertEqual(errorFired, 0, "volatile drop must NOT fire .error")
    }

    func testNonVolatileEmitWhileNotWritableStillTriesToSend() {
        // Non-volatile emit on a not-writable transport: existing Swift behavior preserved.
        // (Swift currently has no outbound buffer, so it routes through the connected guard
        // and into engine.send — engine handles backpressure internally. JS would buffer.)
        mockEngine.writable = false
        var sendCalled = 0
        mockEngine.onSend = { _, _, _ in sendCalled += 1 }
        socket.emit("foo", "x")
        XCTAssertEqual(sendCalled, 1, "non-volatile emit still calls engine.send (Swift backcompat)")
    }

    func testVolatileEmitWithAckIsNotProvided() {
        // SocketVolatileEmitter has no overload accepting an ack callback —
        // verify by inspecting the API surface (compile-time check).
        // The line below would NOT compile:
        //   socket.volatile.emit("foo", "x") { _ in }
        // No runtime test needed.
    }

    func testReservedNameViaVolatileTriggersGuard() {
        var errorFired = 0
        socket.on(clientEvent: .error) { _, _ in errorFired += 1 }
        mockEngine.writable = true
        socket.volatile.emit("connect", "x")
        XCTAssertEqual(errorFired, 1, "reserved guard fires before volatile gate")
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter SocketVolatileTest
git add Tests/TestSocketIO/SocketVolatileTest.swift Tests/TestSocketIO/Mocks/MockEngine.swift
git commit -m "Phase 7: unit tests for volatile gate (writable axis)"
```

---

### Task 4: PR

```markdown
### Added (Phase 7)
- `SocketIOClient.volatile.emit(...)` chain. Drops packet if `engine.writable == false`; no `.error`, no outgoing listener, no buffer. JS-aligned gate (`transport.writable`, not `status`).
- `SocketEngineSpec.writable: Bool { get }` (default `false`); implemented on concrete `SocketEngine` to forward transport state.
```

```bash
git push -u origin phase-7-volatile
gh pr create --title "Phase 7: socket.volatile.emit + SocketEngineSpec.writable" --body "..."
```
