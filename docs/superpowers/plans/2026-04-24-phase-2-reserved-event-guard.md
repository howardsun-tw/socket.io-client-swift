# Phase 2 — Reserved Event Name Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent users from emitting reserved event names (`connect`, `connect_error`, `disconnect`, `disconnecting`) by intercepting at the internal `emit` funnel. JS throws an Error; Swift cannot throw without breaking emit signatures, so the equivalent user-visible signal is `handleClientEvent(.error)`. Wire behavior matches JS exactly: **no packet is written**.

**Architecture:** Add a private `SocketReservedEvent` enum holding the name set. In the internal `emit(_ data:[Any]...)` funnel (`SocketIOClient.swift:454`), inject a `failIfReserved(_ event:) -> Bool` helper at the top — before the existing `status == .connected` guard so the reserved check fires regardless of connection state (matches JS where `emit()` throws even pre-connect). On hit: `assertionFailure` (DEBUG) + `handleClientEvent(.error, ...)` + early return.

**Tech Stack:** Swift 5.x, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 2.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Client/SocketReservedEvent.swift` (new) | `internal enum SocketReservedEvent { static let names: Set<String> }` |
| `Source/SocketIO/Client/SocketIOClient.swift:454` | Inject `failIfReserved` at top of internal `emit` funnel |
| `Tests/TestSocketIO/SocketReservedEventTest.swift` (new) | Unit tests for reserved-name guard behavior |
| `Tests/TestSocketIO/E2E/ReservedEventE2ETest.swift` (new) | E2E: server receives no packet for reserved emits |

---

### Task 1: Create the reserved-event constant

**Files:**
- Create: `Source/SocketIO/Client/SocketReservedEvent.swift`

- [ ] **Step 1: Create the file**

```swift
//
//  SocketReservedEvent.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// Reserved event names that user code is forbidden from emitting.
/// JS-aligned: `socket.io-client/lib/socket.ts` RESERVED_EVENTS — Swift drops only
/// `newListener`/`removeListener` (Node EventEmitter internals with no Swift equivalent).
internal enum SocketReservedEvent {
    static let names: Set<String> = [
        "connect", "connect_error", "disconnect", "disconnecting"
    ]
}
```

- [ ] **Step 2: Add file to SwiftPM target**

If the project uses an explicit file list in `Package.swift`, add `SocketReservedEvent.swift` to the `SocketIO` target. If it uses default file discovery (just a `path:`), no change needed — verify with: `grep -n 'sources:' Package.swift`.

- [ ] **Step 3: Commit**

```bash
git add Source/SocketIO/Client/SocketReservedEvent.swift Package.swift
git commit -m "Phase 2: add SocketReservedEvent reserved-name set"
```

---

### Task 2: Add `failIfReserved` helper + wire into internal emit funnel

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift:454-480` (internal `emit` funnel)
- Test: `Tests/TestSocketIO/SocketReservedEventTest.swift`

- [ ] **Step 1: Write failing tests for the guard**

Create `Tests/TestSocketIO/SocketReservedEventTest.swift`:

```swift
import XCTest
@testable import SocketIO

final class SocketReservedEventTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var loggerEvents: [(String, [Any])]!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        loggerEvents = []
        socket.on(clientEvent: .error) { [weak self] data, _ in
            self?.loggerEvents.append((SocketClientEvent.error.rawValue, data))
        }
        // Force socket into a state where emit could write — for unit tests we use setTestStatus.
        socket.setTestStatus(.connected)
    }

    func testReservedConnectEmitFiresErrorClientEvent() {
        socket.emit("connect", "x")
        XCTAssertEqual(loggerEvents.count, 1, "user .on(clientEvent: .error) listener must fire for reserved emit")
        let payload = loggerEvents.first?.1.first as? String
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload!.contains("connect"), "error message must mention the reserved name")
        XCTAssertTrue(payload!.contains("reserved"), "error message must say 'reserved'")
    }

    func testAllFourReservedNamesFire() {
        for name in ["connect", "connect_error", "disconnect", "disconnecting"] {
            loggerEvents = []
            socket.emit(name, "x")
            XCTAssertEqual(loggerEvents.count, 1, "\(name) must fire .error clientEvent")
        }
    }

    func testCaseSensitivity() {
        socket.emit("Connect", "x")
        socket.emit("CONNECT", "x")
        XCTAssertEqual(loggerEvents.count, 0, "case variants must NOT trigger guard")
    }

    func testWhitespaceVariant() {
        socket.emit(" connect", "x")
        XCTAssertEqual(loggerEvents.count, 0, "whitespace variants must NOT trigger guard")
    }

    func testNormalEventEmits() {
        socket.emit("foo", "x")
        XCTAssertEqual(loggerEvents.count, 0, "non-reserved emit must not trigger guard")
    }

    func testEmitAckIsAckTrueDoesNotTrigger() {
        // emitAck(_:with:) calls internal emit(..., isAck: true) — first item of an ack frame
        // is the ack id, not an event name; reserved guard must not fire.
        socket.emitAck(1, with: ["connect"])
        XCTAssertEqual(loggerEvents.count, 0, "isAck=true frames must bypass reserved guard")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SocketReservedEventTest`
Expected: All tests fail because the guard isn't installed yet (no `.error` event fires for `connect`).

- [ ] **Step 3: Implement the guard**

In `Source/SocketIO/Client/SocketIOClient.swift`, modify the internal `emit` funnel (lines 454-480). Current:

```swift
    func emit(_ data: [Any],
              ack: Int? = nil,
              binary: Bool = true,
              isAck: Bool = false,
              completion: (() -> ())? = nil
    ) {
        // wrap the completion handler so it always runs async via handlerQueue
        let wrappedCompletion: (() -> ())? = (completion == nil) ? nil : {[weak self] in
            guard let this = self else { return }
            this.manager?.handleQueue.async {
                completion!()
            }
        }

        guard status == .connected else {
            wrappedCompletion?()
            handleClientEvent(.error, data: ["Tried emitting when not connected"])
            return
        }
        ...
```

Change to:

```swift
    func emit(_ data: [Any],
              ack: Int? = nil,
              binary: Bool = true,
              isAck: Bool = false,
              completion: (() -> ())? = nil
    ) {
        // wrap the completion handler so it always runs async via handlerQueue
        let wrappedCompletion: (() -> ())? = (completion == nil) ? nil : {[weak self] in
            guard let this = self else { return }
            this.manager?.handleQueue.async {
                completion!()
            }
        }

        // Reserved-event guard — fires BEFORE the connected-state check, matching JS
        // where `emit()` throws regardless of connection state. isAck=true frames
        // (ack response packets) bypass the guard because their first item is the
        // ack id, not an event name.
        if !isAck, failIfReserved(data) {
            wrappedCompletion?()
            return
        }

        guard status == .connected else {
            wrappedCompletion?()
            handleClientEvent(.error, data: ["Tried emitting when not connected"])
            return
        }
        ...
```

Add the helper as a private method on `SocketIOClient` (place it near other private helpers, or at the end of the class):

```swift
    /// Returns `true` if the first element of `data` is a reserved event name.
    /// On hit: `assertionFailure` (DEBUG) + `handleClientEvent(.error, ...)` for
    /// user-visible signal. Wire behavior matches JS `emit()` throw — caller
    /// must early-return so no packet is written.
    private func failIfReserved(_ data: [Any]) -> Bool {
        guard let event = data.first as? String,
              SocketReservedEvent.names.contains(event) else {
            return false
        }
        let message = "\"\(event)\" is a reserved event name"
        assertionFailure(message)  // DEBUG-only loud failure (matches JS dev-time throw)
        handleClientEvent(.error, data: [message])
        return true
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SocketReservedEventTest -c release`
Expected: All tests pass in release mode (`assertionFailure` is no-op in release).

For DEBUG mode: most cases will trap on `assertionFailure`. Either skip the unit tests in DEBUG or wrap the assertion in `#if !DEBUG`. Recommended: keep `assertionFailure` so dev users get a loud signal; mark the test class `XCTest` with the precondition that it runs against a release build (add a comment at top of test file).

Alternative if DEBUG-trap blocks the dev workflow: replace `assertionFailure(message)` with:

```swift
        #if DEBUG
        // In tests we explicitly want to verify the .error clientEvent path,
        // so trap only when not running under XCTest.
        if NSClassFromString("XCTest") == nil {
            assertionFailure(message)
        }
        #endif
```

Pick the approach that fits the project's existing test posture (check whether other tests use `setTestStatus` to bypass assertions; if so, follow that pattern).

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketReservedEventTest.swift
git commit -m "Phase 2: install reserved-event guard at internal emit funnel"
```

---

### Task 3: E2E test — verify NO packet reaches the server

**Files:**
- Create: `Tests/TestSocketIO/E2E/ReservedEventE2ETest.swift`

This is the critical wire-parity assertion: the spec promises that reserved emits result in **no** server-side event. We must verify against a live server.

- [ ] **Step 1: Write the E2E test**

```swift
import XCTest
@testable import SocketIO

final class ReservedEventE2ETest: XCTestCase {
    var server: TestServerProcess!

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    func testReservedConnectEmitDoesNotReachServer() {
        let manager = SocketManager(socketURL: server.url, config: [.autoConnect(true), .log(false)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "socket connects")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        wait(for: [connected], timeout: 5)

        // Tell the server-side test fixture to count any `connect` events it receives
        // from this client. server.js (Tests/TestSocketIO/E2E/Fixtures/server.js) must
        // expose a `socket.on("__check_reserved_count")` ack that returns the count.
        socket.emit("connect", "x")
        socket.emit("disconnecting", "x")
        socket.emit("connect_error", "x")
        socket.emit("disconnect", "x")

        // Give the server a moment to (not) receive them.
        Thread.sleep(forTimeInterval: 0.3)

        let counted = expectation(description: "server reports zero reserved emits")
        socket.emitWithAck("__check_reserved_count").timingOut(after: 2) { data in
            XCTAssertEqual(data.first as? Int, 0,
                           "server must have received zero reserved-event packets")
            counted.fulfill()
        }
        wait(for: [counted], timeout: 3)
    }

    func testNonReservedEmitStillReachesServer() {
        let manager = SocketManager(socketURL: server.url, config: [.autoConnect(true), .log(false)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "socket connects")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        wait(for: [connected], timeout: 5)

        let echoed = expectation(description: "server echoes")
        socket.emitWithAck("echo", "hello").timingOut(after: 2) { data in
            XCTAssertEqual(data.first as? String, "hello")
            echoed.fulfill()
        }
        wait(for: [echoed], timeout: 3)
    }
}
```

- [ ] **Step 2: Update test server fixture**

Modify `Tests/TestSocketIO/E2E/Fixtures/server.js` to add the counter handler (find the existing `io.on("connection", ...)` block and add):

```js
  let reservedCount = 0;
  ["connect", "connect_error", "disconnect", "disconnecting"].forEach((name) => {
    socket.on(name, () => { reservedCount++; });
  });
  socket.on("__check_reserved_count", (cb) => cb(reservedCount));
```

(Adapt placement to match the file's existing structure — check `Tests/TestSocketIO/E2E/Fixtures/server.js` first.)

- [ ] **Step 3: Run E2E test**

Run: `swift test --filter ReservedEventE2ETest`
Expected: Both tests pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/TestSocketIO/E2E/ReservedEventE2ETest.swift Tests/TestSocketIO/E2E/Fixtures/server.js
git commit -m "Phase 2: E2E — reserved emits write no packet to server"
```

---

### Task 4: SocketRawView coverage

`SocketRawView.emit` calls the internal funnel directly. Verify the guard catches it too.

- [ ] **Step 1: Add test**

Append to `Tests/TestSocketIO/SocketReservedEventTest.swift`:

```swift
    func testRawViewReservedEmitTriggersGuard() {
        socket.rawEmitView.emit(["connect", "x"])
        XCTAssertEqual(loggerEvents.count, 1, "SocketRawView.emit must also trigger reserved guard")
    }
```

(Verify the actual property/method name by `grep -n 'public var rawEmitView\|class SocketRawView' Source/SocketIO/Client/SocketRawView.swift`.)

- [ ] **Step 2: Run + commit**

Run: `swift test --filter testRawViewReservedEmitTriggersGuard`
Expected: PASS (no implementation change needed — guard is at the funnel; `SocketRawView` already routes through it).

```bash
git add Tests/TestSocketIO/SocketReservedEventTest.swift
git commit -m "Phase 2: verify SocketRawView is covered by reserved guard"
```

---

### Task 5: Documentation + PR

- [ ] **Step 1: CHANGELOG entry**

```markdown
### Added (Phase 2)
- Reserved event names (`connect`, `connect_error`, `disconnect`, `disconnecting`) now trigger a `.error` client-event and are dropped without writing a packet to the wire — matching JS `socket.io-client` behavior. Previously a Swift client could silently emit one of these names, which would confuse the server. DEBUG builds additionally trigger `assertionFailure` to surface the issue at development time.
```

- [ ] **Step 2: Open PR**

Branch: `phase-2-reserved-event-guard`. Title: `Phase 2: reserved-event-name emit guard`.

```bash
git push -u origin phase-2-reserved-event-guard
gh pr create --title "Phase 2: reserved-event-name emit guard" --body "$(cat <<'EOF'
## Summary
- Adds `SocketReservedEvent.names` (`connect`, `connect_error`, `disconnect`, `disconnecting`).
- Internal `emit` funnel checks the first element of the data array and:
  - DEBUG: `assertionFailure` (matches JS dev-time throw)
  - All builds: `handleClientEvent(.error, ...)` so user `.on(clientEvent: .error)` listeners fire
  - Early-return — no packet written
- Wire behavior is identical to JS `emit()` throw.

## Spec
docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md — Phase 2.

## Test plan
- [x] Unit: each reserved name fires `.error`
- [x] Unit: case-sensitive (`Connect`, `CONNECT` do NOT trigger)
- [x] Unit: whitespace (` connect`) does NOT trigger
- [x] Unit: non-reserved names emit normally
- [x] Unit: `emitAck` (`isAck=true`) bypasses guard
- [x] Unit: `SocketRawView.emit` covered by funnel-level guard
- [x] E2E: server receives ZERO packets for reserved emits
- [x] E2E: server receives non-reserved emits normally

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review Checklist

- [ ] All four reserved names tested.
- [ ] Wire-parity E2E test exists and asserts server-side count == 0.
- [ ] Guard fires before `status == .connected` check (so pre-connect emits also caught).
- [ ] `isAck == true` bypasses guard (verified in test).
- [ ] No mention of `Logger.warning` (doesn't exist in this codebase) — only `Logger.log` / `Logger.error` / `handleClientEvent(.error)`.
