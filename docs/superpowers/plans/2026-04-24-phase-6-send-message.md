# Phase 6 — `socket.send()` / `"message"` Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add JS-aligned `socket.send(...)` and `socket.sendWithAck(...)` as thin wrappers over `emit("message", ...)` / `emitWithAck("message", ...)`. Reception via existing `socket.on("message") { data, _ in }`.

**Architecture:** Pure sugar — four methods on concrete `SocketIOClient` plus four protocol requirements with default impls on `SocketIOClientSpec`. No new storage, no new wire behavior.

**Tech Stack:** Swift 5.x, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 6.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Client/SocketIOClient.swift` | Add `send` + `sendWithAck` wrappers (concrete impl) |
| `Source/SocketIO/Client/SocketIOClientSpec.swift` | Add 4 protocol requirements + default impls |
| `Tests/TestSocketIO/SocketSendTest.swift` (new) | Unit + E2E tests |

---

### Task 1: Add `send(...)` wrappers

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift` (after `emit` overloads, near line 386)
- Modify: `Source/SocketIO/Client/SocketIOClientSpec.swift` (add requirements + default impls)
- Test: `Tests/TestSocketIO/SocketSendTest.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SocketIO

final class SocketSendTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    func testSendVariadicEmitsAsMessage() {
        var captured: SocketAnyEvent?
        _ = socket.addAnyOutgoingListener { event in captured = event }
        manager.handleQueue.sync { }
        socket.send("hello")
        XCTAssertEqual(captured?.event, "message")
        XCTAssertEqual(captured?.items?.first as? String, "hello")
    }

    func testSendWithItemsArray() {
        var captured: SocketAnyEvent?
        _ = socket.addAnyOutgoingListener { event in captured = event }
        manager.handleQueue.sync { }
        socket.send(with: ["hello", 42])
        XCTAssertEqual(captured?.event, "message")
        XCTAssertEqual(captured?.items?.count, 2)
    }

    func testSendNoArgsEmitsValidPacket() {
        // Empty send() should still write "message" with no payload — JS allows this.
        var captured: SocketAnyEvent?
        _ = socket.addAnyOutgoingListener { event in captured = event }
        manager.handleQueue.sync { }
        socket.send()
        XCTAssertEqual(captured?.event, "message")
        XCTAssertEqual(captured?.items?.count, 0)
    }
}
```

(This test depends on Phase 5 being already merged. If running Phase 6 in isolation, swap the listener for a hook into the internal funnel — but per the spec, Phases ship in order so Phase 5 is already in.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SocketSendTest`
Expected: All fail with "no member 'send'".

- [ ] **Step 3: Add wrappers**

In `Source/SocketIO/Client/SocketIOClient.swift`, near `emit` overloads (around line 386):

```swift
    /// JS-aligned `socket.send(...)` — sugar for `emit("message", ...)`.
    /// Server-side receives via `socket.on("message", ...)`.
    open func send(_ items: SocketData..., completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    open func send(with items: [SocketData], completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    /// JS-aligned `socket.send(...)` returning an ack callback. Note: the legacy
    /// `OnAckCallback.timingOut(after:)` chain on the result still uses the
    /// magic-string `SocketAckStatus.noAck` for timeouts AND is NOT cleared on
    /// disconnect (legacy back-compat divergence — see Phase 9 Key decisions).
    /// Users wanting typed errors and disconnect-clearing should use Phase 9's
    /// `socket.timeout(after:).emit("message", ack:)` instead.
    open func sendWithAck(_ items: SocketData...) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }

    open func sendWithAck(with items: [SocketData]) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }
```

In `Source/SocketIO/Client/SocketIOClientSpec.swift`, add requirements (locate the existing `emit` requirements and add nearby):

```swift
    func send(_ items: SocketData..., completion: (() -> ())?)
    func send(with items: [SocketData], completion: (() -> ())?)
    func sendWithAck(_ items: SocketData...) -> OnAckCallback
    func sendWithAck(with items: [SocketData]) -> OnAckCallback
```

Default impls in the same file (extension `SocketIOClientSpec`):

```swift
public extension SocketIOClientSpec {
    func send(_ items: SocketData..., completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    func send(with items: [SocketData], completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    func sendWithAck(_ items: SocketData...) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }

    func sendWithAck(with items: [SocketData]) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }
}
```

(Verify `emit(_:with:completion:)` signature in `SocketIOClientSpec.swift` matches — adapt if needed.)

- [ ] **Step 4: Run tests**

Run: `swift test --filter SocketSendTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift Source/SocketIO/Client/SocketIOClientSpec.swift Tests/TestSocketIO/SocketSendTest.swift
git commit -m "Phase 6: socket.send(...) and sendWithAck(...) wrappers over emit(\"message\", ...)"
```

---

### Task 2: E2E — server-side `on("message")` + `socket.send` round-trip

- [ ] **Step 1: Write E2E test**

Create `Tests/TestSocketIO/E2E/SocketSendE2ETest.swift`:

```swift
import XCTest
@testable import SocketIO

final class SocketSendE2ETest: XCTestCase {
    var server: TestServerProcess!

    override func setUp() {
        super.setUp(); server = try! TestServerProcess.start()
    }
    override func tearDown() { server.stop(); super.tearDown() }

    func testSendReachesServerOnMessage() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        // server.js fixture must echo received "message" events back via socket.send(receivedPayload).
        let echoed = expectation(description: "server echoes via send")
        socket.on("message") { data, _ in
            XCTAssertEqual(data.first as? String, "hello")
            echoed.fulfill()
        }
        socket.send("hello")
        wait(for: [echoed], timeout: 3)
    }

    func testSendWithAckReachesServer() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false)])
        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let acked = expectation(description: "server acks")
        socket.sendWithAck("ping").timingOut(after: 2) { data in
            XCTAssertEqual(data.first as? String, "pong")
            acked.fulfill()
        }
        wait(for: [acked], timeout: 3)
    }
}
```

(Server fixture must expose `socket.on("message", (msg) => socket.send(msg))` and `socket.on("message", (msg, cb) => cb && cb("pong"))`. Update `Tests/TestSocketIO/E2E/Fixtures/server.js` accordingly.)

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketSendE2ETest
git add Tests/TestSocketIO/E2E/SocketSendE2ETest.swift Tests/TestSocketIO/E2E/Fixtures/server.js
git commit -m "Phase 6: E2E — socket.send round-trip via server on(\"message\")"
```

---

### Task 3: Reserved-guard interaction + PR

- [ ] **Step 1: Add test confirming `"message"` is NOT reserved**

```swift
    func testMessageIsNotReserved() {
        var errorFired = 0
        socket.on(clientEvent: .error) { _, _ in errorFired += 1 }
        socket.send("hi")
        XCTAssertEqual(errorFired, 0, "\"message\" is not in reserved set; send must not trigger guard")
    }
```

- [ ] **Step 2: PR**

```markdown
### Added (Phase 6)
- `SocketIOClient.send(...)`, `send(with:)`, `sendWithAck(...)`, `sendWithAck(with:)` — JS-aligned shortcuts for `emit("message", ...)` / `emitWithAck("message", ...)`. Server-side reception via existing `socket.on("message", ...)`.
- README maps server `socket.send(payload)` ↔ client `on("message")`.
```

```bash
git push -u origin phase-6-send-message
gh pr create --title "Phase 6: socket.send / sendWithAck shortcuts" --body "..."
```
