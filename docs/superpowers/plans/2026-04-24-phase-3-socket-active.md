# Phase 3 — `socket.active` Property Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `socket.active: Bool` matching JS `!!this.subs` — a lifecycle flag flipped `true` at user `connect()` and `false` at user `disconnect()`. Survives engine-close + reconnect cycles. Independent of `status` and `manager.reconnecting`.

**Architecture:** Stored Bool on concrete `SocketIOClient` (NOT in `SocketIOClientSpec`). Set `true` at the start of both `connect(withPayload:)` overloads. Set `false` only inside the user-facing `open func disconnect()` — `didDisconnect(reason:)` (called on engine close, transport error, reconnect cycles) must NOT clear it.

**Tech Stack:** Swift 5.x, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 3.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Client/SocketIOClient.swift` | Add `public private(set) var active: Bool = false`; flip in `connect()` and `disconnect()` |
| `Tests/TestSocketIO/SocketActiveTest.swift` (new) | Unit tests for lifecycle Bool semantics |

---

### Task 1: Add stored Bool + flip in `connect()`

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift:132-148` (`connect` overloads)
- Test: `Tests/TestSocketIO/SocketActiveTest.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/TestSocketIO/SocketActiveTest.swift`:

```swift
import XCTest
@testable import SocketIO

final class SocketActiveTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
    }

    func testActiveFalseAfterInit() {
        XCTAssertFalse(socket.active, "active must be false before any connect()")
    }

    func testActiveTrueAfterConnect() {
        socket.connect()
        XCTAssertTrue(socket.active, "active must be true immediately after connect()")
    }

    func testActiveTrueAfterConnectWithPayload() {
        socket.connect(withPayload: ["x": 1])
        XCTAssertTrue(socket.active)
    }

    func testActiveTrueAfterConnectWithTimeout() {
        socket.connect(withPayload: nil, timeoutAfter: 1, withHandler: nil)
        XCTAssertTrue(socket.active)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SocketActiveTest`
Expected: All four tests fail with "value of type 'SocketIOClient' has no member 'active'".

- [ ] **Step 3: Add property + flip in `connect()`**

In `Source/SocketIO/Client/SocketIOClient.swift`, near other public stored vars (search for `public private(set) var status`), add:

```swift
    /// Whether the socket is currently subscribed to its manager. Mirrors JS
    /// `socket.io-client/lib/socket.ts` `get active() { return !!this.subs }`.
    /// Flipped `true` at the start of `connect()` and `false` only inside the
    /// user-facing `disconnect()`. Survives engine-close + reconnect cycles.
    /// Distinct from `status.active` (which reports the current status enum's
    /// liveness, not the lifecycle).
    public private(set) var active: Bool = false
```

In both `connect(withPayload:)` overloads (lines 132 and 144), add `self.active = true` as the first line of the body:

```swift
    open func connect(withPayload payload: [String: Any]? = nil) {
        self.active = true
        // ... existing body ...
    }

    open func connect(withPayload payload: [String: Any]? = nil, timeoutAfter: Double, withHandler handler: (() -> ())?) {
        self.active = true
        // ... existing body ...
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SocketActiveTest`
Expected: First four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketActiveTest.swift
git commit -m "Phase 3: add socket.active stored Bool, set true on connect()"
```

---

### Task 2: Flip `false` only on user `disconnect()`

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift:360` (`open func disconnect()`)

- [ ] **Step 1: Add failing tests**

Append to `Tests/TestSocketIO/SocketActiveTest.swift`:

```swift
    func testActiveFalseAfterUserDisconnect() {
        socket.connect()
        XCTAssertTrue(socket.active)
        socket.disconnect()
        XCTAssertFalse(socket.active, "user disconnect() must flip active false")
    }

    func testActiveSurvivesDidDisconnect() {
        // didDisconnect simulates engine-close / transport error / reconnect cycle.
        // Must NOT clear active (matches JS — subs live across reconnect cycles).
        socket.connect()
        XCTAssertTrue(socket.active)
        socket.didDisconnect(reason: "Got Disconnect")
        XCTAssertTrue(socket.active, "didDisconnect must NOT flip active false; only user disconnect() does")
    }

    func testActiveCycleConnectDisconnectConnect() {
        socket.connect()
        socket.disconnect()
        socket.connect()
        XCTAssertTrue(socket.active, "active must come back true on second connect()")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SocketActiveTest`
Expected: `testActiveFalseAfterUserDisconnect` fails (active stays true because `disconnect()` doesn't clear it yet); `testActiveSurvivesDidDisconnect` passes (we only added a setter for connect so far); `testActiveCycleConnectDisconnectConnect` fails.

- [ ] **Step 3: Implement `disconnect()` flip**

In `Source/SocketIO/Client/SocketIOClient.swift`, modify `open func disconnect()` (around line 360). Add `self.active = false` as the first line:

```swift
    open func disconnect() {
        self.active = false
        // ... existing body ...
    }
```

**Critical:** do NOT add the same line to `didDisconnect(reason:)` (line 336). `didDisconnect` is called on engine close / transport error / reconnect — those must keep `active == true` per JS semantics.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SocketActiveTest`
Expected: All seven tests pass.

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketActiveTest.swift
git commit -m "Phase 3: socket.active flips false only on user disconnect(); survives didDisconnect"
```

---

### Task 3: E2E — verify `active` survives a real reconnect cycle

**Files:**
- Create: `Tests/TestSocketIO/E2E/SocketActiveE2ETest.swift`

- [ ] **Step 1: Write E2E test**

```swift
import XCTest
@testable import SocketIO

final class SocketActiveE2ETest: XCTestCase {
    var server: TestServerProcess!

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    func testActiveSurvivesEngineClose() {
        let manager = SocketManager(socketURL: server.url, config: [.reconnects(true), .log(false)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "first connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        XCTAssertTrue(socket.active)

        // Force engine close by stopping server, then restarting.
        let reconnected = expectation(description: "auto-reconnect")
        var firstFire = true
        socket.on(clientEvent: .reconnect) { _, _ in
            if firstFire { firstFire = false; reconnected.fulfill() }
        }
        server.stop()
        Thread.sleep(forTimeInterval: 0.5)
        // active MUST remain true throughout the gap.
        XCTAssertTrue(socket.active, "active must survive engine close + reconnect attempt window")
        server = try! TestServerProcess.start()
        wait(for: [reconnected], timeout: 10)

        XCTAssertTrue(socket.active, "active still true after reconnect")

        socket.disconnect()
        XCTAssertFalse(socket.active, "active false after explicit disconnect")
    }

    func testNamespacesIndependent() {
        let manager = SocketManager(socketURL: server.url, config: [.autoConnect(true), .log(false)])
        let defaultSocket = manager.defaultSocket
        let admin = manager.socket(forNamespace: "/admin")

        let bothConnected = expectation(description: "both namespaces connect")
        bothConnected.expectedFulfillmentCount = 2
        defaultSocket.on(clientEvent: .connect) { _, _ in bothConnected.fulfill() }
        admin.on(clientEvent: .connect) { _, _ in bothConnected.fulfill() }
        admin.connect()
        wait(for: [bothConnected], timeout: 5)

        XCTAssertTrue(defaultSocket.active)
        XCTAssertTrue(admin.active)

        admin.disconnect()
        XCTAssertFalse(admin.active)
        XCTAssertTrue(defaultSocket.active, "disconnecting /admin must not affect / active")
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketActiveE2ETest
git add Tests/TestSocketIO/E2E/SocketActiveE2ETest.swift
git commit -m "Phase 3: E2E — active survives engine close, namespaces independent"
```

---

### Task 4: Doc-comment + CHANGELOG + PR

- [ ] **Step 1: CHANGELOG**

```markdown
### Added (Phase 3)
- `SocketIOClient.active: Bool` — lifecycle flag matching JS `socket.active`. `true` from user `connect()` until user `disconnect()`; survives engine-close / reconnect cycles. Distinct from `socket.status.active` (which reports the current status enum's liveness).
```

- [ ] **Step 2: PR**

```bash
git push -u origin phase-3-socket-active
gh pr create --title "Phase 3: socket.active lifecycle property" --body "$(cat <<'EOF'
## Summary
- Adds `SocketIOClient.active: Bool` matching JS `!!this.subs` semantics.
- Flipped `true` at the start of both `connect()` overloads.
- Flipped `false` only inside user-facing `disconnect()` — `didDisconnect(reason:)` (engine close / reconnect) does NOT clear it.

## Spec
docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md — Phase 3.

## Test plan
- [x] Unit: `active` defaults `false`
- [x] Unit: all `connect()` overloads set `true`
- [x] Unit: user `disconnect()` sets `false`
- [x] Unit: `didDisconnect` does NOT set `false`
- [x] Unit: connect → disconnect → connect cycle returns `true`
- [x] E2E: `active` survives engine close + reconnect
- [x] E2E: namespace independence

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
