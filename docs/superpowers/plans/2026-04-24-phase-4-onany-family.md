# Phase 4 — `onAny` Family Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add JS-aligned `addAnyListener` / `prependAnyListener` / `removeAnyListener(id:)` / `removeAllAnyListeners` / `anyListenerCount` on `SocketIOClient`. Existing single-handler `anyHandler` is preserved (back-compat — still fires before the new list).

**Architecture:** New `private var anyListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []` on concrete `SocketIOClient`. Mutators serialize via `handleQueue.async`. Snapshot iteration in `dispatchEvent` (`SocketIOClient.swift:261`) so listener self-removal mid-dispatch is safe.

**Tech Stack:** Swift 5.x, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 4.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Client/SocketIOClient.swift` | Add storage + 5 new methods + dispatch-loop integration |
| `Tests/TestSocketIO/SocketAnyListenersTest.swift` (new) | Unit tests for add/prepend/remove/list/snapshot semantics |

---

### Task 1: Storage + `addAnyListener` / `removeAnyListener` / `removeAllAnyListeners`

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift` (storage near `anyHandler`; new methods near existing `onAny`)
- Test: `Tests/TestSocketIO/SocketAnyListenersTest.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SocketIO

final class SocketAnyListenersTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    func testAddAnyListenerFires() {
        var captured: SocketAnyEvent?
        let id = socket.addAnyListener { event in captured = event }
        XCTAssertNotNil(id)
        socket.handleEvent("foo", data: ["bar"], isInternalMessage: false)
        XCTAssertEqual(captured?.event, "foo")
        XCTAssertEqual(captured?.items?.first as? String, "bar")
    }

    func testAddAnyListenerCount() {
        XCTAssertEqual(socket.anyListenerCount, 0)
        _ = socket.addAnyListener { _ in }
        _ = socket.addAnyListener { _ in }
        XCTAssertEqual(socket.anyListenerCount, 2)
    }

    func testRemoveAnyListenerById() {
        var firedA = 0
        var firedB = 0
        let idA = socket.addAnyListener { _ in firedA += 1 }
        _ = socket.addAnyListener { _ in firedB += 1 }
        socket.removeAnyListener(id: idA)
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(firedA, 0, "removed listener must not fire")
        XCTAssertEqual(firedB, 1, "other listener still fires")
    }

    func testRemoveAnyListenerUnknownIdNoop() {
        socket.removeAnyListener(id: UUID())  // matches JS offAny — silent no-op
    }

    func testRemoveAllAnyListeners() {
        var fired = 0
        _ = socket.addAnyListener { _ in fired += 1 }
        _ = socket.addAnyListener { _ in fired += 1 }
        socket.removeAllAnyListeners()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(socket.anyListenerCount, 0)
    }

    func testLegacyAnyHandlerStillFiresAlongsideNewListeners() {
        var legacyFired = 0
        var newFired = 0
        socket.onAny { _ in legacyFired += 1 }
        _ = socket.addAnyListener { _ in newFired += 1 }
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(legacyFired, 1)
        XCTAssertEqual(newFired, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SocketAnyListenersTest`
Expected: All fail with "no member 'addAnyListener'".

- [ ] **Step 3: Implement storage + add/remove/count**

In `Source/SocketIO/Client/SocketIOClient.swift`, near the existing `public private(set) var anyHandler` (line 52), add:

```swift
    /// Storage for the multi-listener `onAny` family. UUID-keyed because Swift
    /// closures lack identity. Mutators serialize via `handleQueue.async`.
    private var anyListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []
```

Near the existing `open func onAny(...)` (line 665), add:

```swift
    /// Append a catch-all listener. Returns a `UUID` handle for removal.
    /// Mirrors JS `socket.onAny(handler)`. Mutator serializes via `handleQueue.async`.
    @discardableResult
    open func addAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.append((id: id, handler: handler))
        }
        return id
    }

    /// Remove a listener by its `UUID` handle. Unknown id is a silent no-op
    /// (matches JS `offAny`). Mutator serializes via `handleQueue.async`.
    open func removeAnyListener(id: UUID) {
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.removeAll { $0.id == id }
        }
    }

    /// Remove every listener registered via `addAnyListener` / `prependAnyListener`.
    /// Does NOT clear the legacy single `anyHandler`. Mutator serializes via
    /// `handleQueue.async`.
    open func removeAllAnyListeners() {
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.removeAll(keepingCapacity: false)
        }
    }

    /// Count of currently-registered any-listeners. Excludes the legacy single
    /// `anyHandler`. JS counterpart `socket.listenersAny()` returns the handler
    /// array; Swift returns count because closures lack identity.
    public var anyListenerCount: Int {
        return anyListeners.count
    }
```

In `dispatchEvent` (line 261-269), iterate a snapshot AFTER firing the legacy `anyHandler`:

```swift
    private func dispatchEvent(_ event: String, data: [Any], withAck ack: Int) {
        DefaultSocketLogger.Logger.log("Handling event: \(event) with data: \(data)", type: logType)

        anyHandler?(SocketAnyEvent(event: event, items: data))

        // Snapshot the list so a listener's self-removal during dispatch doesn't
        // mutate the iteration. Snapshot is cheap (array of tuples).
        let snapshot = anyListeners
        for entry in snapshot {
            entry.handler(SocketAnyEvent(event: event, items: data))
        }

        for handler in handlers where handler.event == event {
            handler.executeCallback(with: data, withAck: ack, withSocket: self)
        }
    }
```

**Important:** the test class above uses synchronous expectations (`socket.addAnyListener { ... }; socket.handleEvent(...)`). Because the mutator dispatches via `handleQueue.async`, the test must wait for the mutator to complete. Use `manager.handleQueue.sync { }` as a barrier in the test to wait for queued mutations to drain before triggering events. Update test setUp:

```swift
    /// Drains pending handleQueue work — call after any addAnyListener/remove… call
    /// to ensure the mutation has happened before we proceed.
    private func drain() {
        manager.handleQueue.sync { /* barrier */ }
    }
```

Then in each test, after add/remove calls, call `drain()` before `handleEvent`. Update tests accordingly.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SocketAnyListenersTest`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketAnyListenersTest.swift
git commit -m "Phase 4: addAnyListener / removeAnyListener / removeAllAnyListeners / anyListenerCount"
```

---

### Task 2: `prependAnyListener` + ordering tests

- [ ] **Step 1: Add failing tests**

Append:

```swift
    func testPrependAnyListenerFiresFirst() {
        var order: [Int] = []
        _ = socket.addAnyListener { _ in order.append(1) }
        _ = socket.addAnyListener { _ in order.append(2) }
        _ = socket.prependAnyListener { _ in order.append(0) }
        drain()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testRegistrationOrderPreserved() {
        var order: [Int] = []
        _ = socket.addAnyListener { _ in order.append(1) }
        _ = socket.addAnyListener { _ in order.append(2) }
        _ = socket.addAnyListener { _ in order.append(3) }
        drain()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(order, [1, 2, 3])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter testPrepend`
Expected: FAIL — `prependAnyListener` doesn't exist yet.

- [ ] **Step 3: Implement `prependAnyListener`**

In `Source/SocketIO/Client/SocketIOClient.swift`, near `addAnyListener`:

```swift
    /// Prepend a catch-all listener (fires before existing listeners). Returns
    /// a `UUID` handle. Mirrors JS `socket.prependAny(handler)`. Mutator
    /// serializes via `handleQueue.async`.
    @discardableResult
    open func prependAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.insert((id: id, handler: handler), at: 0)
        }
        return id
    }
```

- [ ] **Step 4: Run + commit**

```bash
swift test --filter SocketAnyListenersTest
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketAnyListenersTest.swift
git commit -m "Phase 4: prependAnyListener with ordering tests"
```

---

### Task 3: Dispatch-time edge cases (self-removal, mid-dispatch register)

- [ ] **Step 1: Add tests**

```swift
    func testListenerSelfRemovalDuringDispatch() {
        var ids: [UUID] = []
        var fired = [false, false, false]
        ids.append(socket.addAnyListener { _ in fired[0] = true })
        ids.append(socket.addAnyListener { [weak self] _ in
            fired[1] = true
            self?.socket.removeAnyListener(id: ids[1])  // remove self mid-dispatch
        })
        ids.append(socket.addAnyListener { _ in fired[2] = true })
        drain()

        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(fired, [true, true, true],
                       "self-removal must not break iteration; later listeners still fire")
    }

    func testListenerRegistersNewListenerMidDispatch() {
        var firedFirst = 0
        var firedSecond = 0
        _ = socket.addAnyListener { [weak self] _ in
            firedFirst += 1
            _ = self?.socket.addAnyListener { _ in firedSecond += 1 }
        }
        drain()

        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(firedFirst, 1)
        XCTAssertEqual(firedSecond, 0,
                       "newly-registered listener must NOT fire in current dispatch (snapshot semantics)")

        drain()
        socket.handleEvent("bar", data: [], isInternalMessage: false)
        XCTAssertEqual(firedSecond, 1, "newly-registered listener fires on next event")
    }
```

- [ ] **Step 2: Run + verify pass (snapshot iteration was already added in Task 1 Step 3)**

Run: `swift test --filter testListener`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketAnyListenersTest.swift
git commit -m "Phase 4: snapshot-iteration safety tests (self-removal + mid-dispatch register)"
```

---

### Task 4: E2E + ack/binary coverage

- [ ] **Step 1: Add E2E + extra unit tests**

Append:

```swift
    func testAckResponseDoesNotTriggerAnyListener() {
        var fired = 0
        _ = socket.addAnyListener { _ in fired += 1 }
        drain()
        socket.emitAck(1, with: ["x"])  // ack frame — should NOT trigger
        XCTAssertEqual(fired, 0)
    }
```

Create `Tests/TestSocketIO/E2E/AnyListenerE2ETest.swift`:

```swift
import XCTest
@testable import SocketIO

final class AnyListenerE2ETest: XCTestCase {
    var server: TestServerProcess!

    override func setUp() {
        super.setUp(); server = try! TestServerProcess.start()
    }
    override func tearDown() {
        server.stop(); super.tearDown()
    }

    func testAnyListenerCatchesServerEvents() {
        let manager = SocketManager(socketURL: server.url, config: [.log(false)])
        let socket = manager.defaultSocket
        let received = expectation(description: "any-listener fires")
        socket.on(clientEvent: .connect) { _, _ in
            // server-side fixture emits "hello" upon receiving "ping"
            socket.emit("ping")
        }
        _ = socket.addAnyListener { event in
            if event.event == "hello" { received.fulfill() }
        }
        socket.connect()
        wait(for: [received], timeout: 5)
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter AnyListener
git add Tests/TestSocketIO/SocketAnyListenersTest.swift Tests/TestSocketIO/E2E/AnyListenerE2ETest.swift
git commit -m "Phase 4: E2E + ack/binary edge cases for any-listeners"
```

---

### Task 5: PR

- [ ] **Step 1: CHANGELOG**

```markdown
### Added (Phase 4)
- `SocketIOClient.addAnyListener(_:)`, `prependAnyListener(_:)`, `removeAnyListener(id:)`, `removeAllAnyListeners()`, `anyListenerCount` — multi-listener `onAny` family matching JS API. Returns `UUID` handle for removal (Swift-idiomatic — JS uses handler-reference equality).
- Existing single-handler `onAny(_:)` preserved (back-compat — fires alongside new listeners).
```

- [ ] **Step 2: Open PR**

Branch: `phase-4-onany-family`. Title: `Phase 4: onAny family completion`.

```bash
git push -u origin phase-4-onany-family
gh pr create --title "Phase 4: onAny family completion" --body "$(cat <<'EOF'
## Summary
- Adds `addAnyListener` / `prependAnyListener` / `removeAnyListener(id:)` / `removeAllAnyListeners` / `anyListenerCount` on concrete `SocketIOClient`.
- Snapshot iteration in `dispatchEvent` so self-removal during dispatch is safe.
- All mutators serialize via `handleQueue.async`.
- Legacy `anyHandler` preserved.

## Test plan
- [x] add/remove/count basic
- [x] prepend ordering
- [x] registration order preserved across multiple `addAnyListener`
- [x] self-removal mid-dispatch
- [x] mid-dispatch register fires next event, not current
- [x] legacy `anyHandler` still fires
- [x] ack frames do NOT trigger any-listeners
- [x] E2E with server fixture

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
