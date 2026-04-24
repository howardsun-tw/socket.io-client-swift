# Phase 5 — `onAnyOutgoing` Family Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `addAnyOutgoingListener` / `prependAnyOutgoingListener` / `removeAnyOutgoingListener(id:)` / `removeAllAnyOutgoingListeners` / `anyOutgoingListenerCount`. Listeners fire **after** the connected-state guard and **immediately before** `engine.send` — JS-aligned (only on actual send; not on disconnected/volatile-drop).

**Architecture:** Mirror Phase 4's storage on concrete `SocketIOClient`. Hook in the internal `emit` funnel (`SocketIOClient.swift:454`) inside the connected branch, before `engine.send`. Skip when `isAck == true`. Mutators serialize via `handleQueue.async`. Snapshot iteration.

**Hard dep:** Phase 2 (the funnel must already have the reserved-event guard).

**Tech Stack:** Swift 5.x, SwiftPM, XCTest.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 5.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Client/SocketIOClient.swift` | Add storage + 5 methods + outgoing fire site in `emit` funnel |
| `Tests/TestSocketIO/SocketAnyOutgoingListenersTest.swift` (new) | Unit tests |

---

### Task 1: Storage + add/prepend/remove/count

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift`
- Test: `Tests/TestSocketIO/SocketAnyOutgoingListenersTest.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SocketIO

final class SocketAnyOutgoingListenersTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    private func drain() { manager.handleQueue.sync { } }

    func testAddAnyOutgoingListener() {
        var captured: SocketAnyEvent?
        let id = socket.addAnyOutgoingListener { event in captured = event }
        XCTAssertNotNil(id)
        drain()
        socket.emit("foo", "bar")
        XCTAssertEqual(captured?.event, "foo")
    }

    func testCountAndRemoveAll() {
        XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
        _ = socket.addAnyOutgoingListener { _ in }
        _ = socket.addAnyOutgoingListener { _ in }
        drain()
        XCTAssertEqual(socket.anyOutgoingListenerCount, 2)
        socket.removeAllAnyOutgoingListeners(); drain()
        XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
    }

    func testRemoveById() {
        var firedA = 0, firedB = 0
        let idA = socket.addAnyOutgoingListener { _ in firedA += 1 }
        _ = socket.addAnyOutgoingListener { _ in firedB += 1 }
        drain()
        socket.removeAnyOutgoingListener(id: idA); drain()
        socket.emit("foo", "x")
        XCTAssertEqual(firedA, 0)
        XCTAssertEqual(firedB, 1)
    }

    func testPrependFiresFirst() {
        var order: [Int] = []
        _ = socket.addAnyOutgoingListener { _ in order.append(1) }
        _ = socket.prependAnyOutgoingListener { _ in order.append(0) }
        drain()
        socket.emit("foo", "x")
        XCTAssertEqual(order, [0, 1])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SocketAnyOutgoingListenersTest`
Expected: All fail with "no member 'addAnyOutgoingListener'".

- [ ] **Step 3: Implement storage + methods**

Near the Phase 4 storage in `SocketIOClient.swift`:

```swift
    private var anyOutgoingListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []
```

Methods (mirror Phase 4 exactly, swapping `Outgoing` into the names):

```swift
    @discardableResult
    open func addAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.append((id: id, handler: handler))
        }
        return id
    }

    @discardableResult
    open func prependAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.insert((id: id, handler: handler), at: 0)
        }
        return id
    }

    open func removeAnyOutgoingListener(id: UUID) {
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.removeAll { $0.id == id }
        }
    }

    open func removeAllAnyOutgoingListeners() {
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.removeAll(keepingCapacity: false)
        }
    }

    public var anyOutgoingListenerCount: Int {
        return anyOutgoingListeners.count
    }
```

Tests still fail: emit doesn't fire the listeners yet. Continue to Task 2.

- [ ] **Step 4: Commit (storage + methods only)**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift Tests/TestSocketIO/SocketAnyOutgoingListenersTest.swift
git commit -m "Phase 5: storage + add/prepend/remove/count for any-outgoing-listeners"
```

---

### Task 2: Wire into internal `emit` funnel — fire after connected guard, before engine.send

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift:454-480` (internal `emit` funnel)

- [ ] **Step 1: Add the fire site**

In the internal `emit` funnel, after the `status == .connected` guard and after the `SocketPacket.packetFromEmit` line but **before** `manager?.engine?.send(...)`:

```swift
        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: isAck, checkForBinary: binary)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting: \(str), Ack: \(isAck)", type: logType)

        // Fire any-outgoing listeners — JS-aligned: AFTER connected guard,
        // ONLY on actual send; ack frames bypass.
        if !isAck, let event = data.first as? String {
            let snapshot = anyOutgoingListeners
            let items = Array(data.dropFirst())
            for entry in snapshot {
                entry.handler(SocketAnyEvent(event: event, items: items))
            }
        }

        manager?.engine?.send(str, withData: packet.binary, completion: wrappedCompletion)
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter SocketAnyOutgoingListenersTest`
Expected: All four pass.

- [ ] **Step 3: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift
git commit -m "Phase 5: fire any-outgoing listeners in emit funnel (post-connected guard, pre-send)"
```

---

### Task 3: Negative cases — disconnected emit, ack frames, volatile (Phase 7 forward-compat)

- [ ] **Step 1: Add tests**

```swift
    func testDisconnectedEmitDoesNotFireOutgoing() {
        var fired = 0
        _ = socket.addAnyOutgoingListener { _ in fired += 1 }
        drain()
        socket.setTestStatus(.disconnected)
        socket.emit("foo", "x")  // surfaces .error, no packet, no outgoing fire
        XCTAssertEqual(fired, 0, "outgoing listener must NOT fire on disconnected emit (JS-aligned)")
    }

    func testAckFramesDoNotFireOutgoing() {
        var fired = 0
        _ = socket.addAnyOutgoingListener { _ in fired += 1 }
        drain()
        socket.emitAck(1, with: ["x"])
        XCTAssertEqual(fired, 0, "ack response frames must not fire outgoing listeners")
    }

    func testNamespaceIsolation() {
        // /admin outgoing listener does not see / events.
        let admin = manager.socket(forNamespace: "/admin")
        admin.setTestStatus(.connected)
        var defaultFired = 0
        var adminFired = 0
        _ = socket.addAnyOutgoingListener { _ in defaultFired += 1 }
        _ = admin.addAnyOutgoingListener { _ in adminFired += 1 }
        drain()
        socket.emit("foo", "x")
        XCTAssertEqual(defaultFired, 1)
        XCTAssertEqual(adminFired, 0)
    }
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SocketAnyOutgoingListenersTest
git add Tests/TestSocketIO/SocketAnyOutgoingListenersTest.swift
git commit -m "Phase 5: negative cases — disconnected/ack/namespace do not fire outgoing"
```

---

### Task 4: PR

- [ ] **Step 1: CHANGELOG**

```markdown
### Added (Phase 5)
- `SocketIOClient.addAnyOutgoingListener(_:)`, `prependAnyOutgoingListener(_:)`, `removeAnyOutgoingListener(id:)`, `removeAllAnyOutgoingListeners()`, `anyOutgoingListenerCount` — outgoing-side catch-all listeners. Fire only on actual `engine.send` (after connected-state guard); ack response frames bypass. JS-aligned per `socket.io-client/lib/socket.ts` `emit()` body.
```

- [ ] **Step 2: PR**

```bash
git push -u origin phase-5-onany-outgoing
gh pr create --title "Phase 5: onAnyOutgoing family" --body "..."
```
