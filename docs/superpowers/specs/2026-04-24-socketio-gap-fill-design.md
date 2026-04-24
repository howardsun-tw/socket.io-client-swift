# Socket.IO-Client-Swift — JS Reference Gap Fill (Application-Layer)

**Date:** 2026-04-24
**Scope:** Application-layer API alignment with `socket.io-client` (JS reference, github.com/socketio/socket.io). Transport, parser pluggability, and engine-layer features are out of scope for this round.
**Compatibility posture:** Additive only. No breaking changes; default behaviors preserved. New API surface coexists with existing API.

## Goals

1. Close the application-layer gap between `socket.io-client-swift` and `socket.io-client` (JS) for nine identified items.
2. Each item ships as one independent phase (independent PR, independent changelog entry).
3. For every phase, test coverage must mirror the corresponding JS reference tests and add stricter Swift-side edge cases.

## Non-Goals

- Pluggable parser (msgpack etc.) — defer.
- WebTransport / engine-layer events (`drain`, `packetCreate`) — defer.
- Major version bump — keep on v16.x line.
- Changing `emitWithAck(...).timingOut(...)` semantics — kept verbatim, new API added alongside.

## Phasing Strategy

Risk-ascending order. Earliest phases are isolated, low-risk additions that establish the per-phase template (config plumbing, changelog format, test scaffolding). Highest-coupling work (per-emit timed ack) lands last so earlier phases are not blocked by it.

| # | Phase | Risk | Notes |
|---|---|---|---|
| 1 | `.autoConnect(Bool)` config | low | Default `false` (preserves current behavior). |
| 2 | Reserved event name guard | low | Additive: DEBUG assert + release log; emit still proceeds. |
| 3 | `socket.active` property | low | Pure derived getter. |
| 4 | `onAny` family completion (add/prepend/remove/list) | medium | New multi-listener storage alongside legacy `anyHandler`. |
| 5 | `onAnyOutgoing` family | medium | Mirrors Phase 4 on emit path. |
| 6 | `socket.send()` / `"message"` | low | Thin wrappers over `emit("message", ...)`. |
| 7 | `socket.volatile.emit(...)` | medium | Drop-when-disconnected emit; outgoing listeners still fire. |
| 8 | `auth` function form | high | Async-callback provider invoked per connect/reconnect. |
| 9 | `socket.timeout(after:).emit(..., ack:)` per-emit ack + err-first | high | Most behavior-coupled item; lands last. |

## Cross-cutting Constraints

- **Compatibility:** No public type/method removed or renamed. All new methods are additive. New protocol requirements ship with default implementations so third-party `SocketIOClientSpec` conformers don't break.
- **Threading:** All callbacks dispatch on `handleQueue` (existing convention).
- **Logging:** New code uses `DefaultSocketLogger.Logger` for parity with existing layers.
- **Versioning:** Patch/minor release on v16 line. CHANGELOG entry per phase.
- **Test parity:** Every phase test plan enumerates JS reference tests by name and ports them. Each phase additionally lists Swift-only stricter edge cases (concurrency, identity swap, reconnection mid-flight, oversized data, namespace isolation, v2/v3 protocol parity).

---

## Phase 1 — `.autoConnect(Bool)` config

### API
```swift
public enum SocketIOClientOption {
    case autoConnect(Bool)   // new
}
```
Default `false`. Setting `true` triggers `connect()` at end of `SocketManager.init`.

**Note:** JS Manager defaults `autoConnect: true`; Swift inverts to preserve current behavior. Document in README and inline doc-comment.

### Components touched
- `Source/SocketIO/Client/SocketIOClientOption.swift` — new case + raw key.
- `Source/SocketIO/Client/SocketIOClientConfiguration.swift` — extension parses raw key.
- `Source/SocketIO/Manager/SocketManager.swift` — new `public var autoConnect: Bool = false`; `setConfigs` writes it; `init` tail invokes `connect()` when `autoConnect == true`.

### Data flow
`init` → `setConfigs(config)` → if `autoConnect` then `connect()` → `addEngine` → `engine.connect`.

### Error handling
No new error paths. `connect()` failure modes unchanged (`engineDidError`).

### Testing
- **JS-mirrored:** `socket.io-client/test/connection.ts` "should auto connect by default" — Swift inverts default; mirror by asserting that `[.autoConnect(true)]` reproduces the same auto-connect behavior.
- **Swift-only:**
  - `SocketManager(url, config: [])` → status `.notConnected` immediately after init.
  - `SocketManager(url, config: [.autoConnect(true)])` → status `.connecting` immediately after init.
  - `[.autoConnect(false), .forceNew(true)]` combined → no auto-connect, `forceNew` honored on later manual `connect()`.

---

## Phase 2 — Reserved event name guard

### API
Internal helper:
```swift
internal enum SocketReservedEvent {
    static let names: Set<String> = [
        "connect", "disconnect", "error", "ping", "pong",
        "reconnect", "reconnectAttempt", "statusChange", "websocketUpgrade"
    ]
}
```
Pulled from `SocketClientEvent` raw values.

### Behavior (additive)
At entry of `emit(_:with:completion:)` and `emitWithAck(_:with:)`:
- If event name ∈ reserved → `assertionFailure("...")` (DEBUG only) + `DefaultSocketLogger.Logger.error(...)` (always).
- Emit **still proceeds**. Release runtime behavior is unchanged; only a log line is added.

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — entry of `emit(_:with:completion:)` (line 386 region) and `emitWithAck(_:with:)` (line 440 region) call new private helper `warnIfReserved(_ event:)`.

### Data flow
emit entry → `warnIfReserved` → existing packet build/send (unchanged).

### Error handling
`assertionFailure` in DEBUG only. No throw, no early return. Documentation steers users to `clientEvent:` API variants for listener registration.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "should throw on reserved event names" — Swift cannot throw without breaking emit signature; mirrored as logger-error assertion in release tests.
- **Swift-only:**
  - Each reserved name: `emit(name, "x")` → logger receives error; `emitWithAck(name, "x").timingOut(...)` same.
  - Case sensitivity: `"Connect"`, `"CONNECT"` do **not** trigger.
  - Whitespace variants (`" connect"`) do **not** trigger.
  - Mixed sequence (reserved + normal) — normal emit still flows correctly.
  - v2 manager and v3 manager: behavior identical.
  - Non-default namespace (`/admin`): behavior identical.

---

## Phase 3 — `socket.active` property

### API
```swift
public extension SocketIOClientSpec {
    var active: Bool { get }
}
```
Default impl on protocol:
```swift
var active: Bool {
    return status == .connected
        || status == .connecting
        || manager?.status == .reconnecting
}
```

### Components touched
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — new requirement + default implementation.

### Data flow
Pure derived getter. Reads existing `status` and `manager?.status`.

### Error handling
None.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "active" segment — `active === true` when connecting/connected/reconnecting; `false` after `socket.disconnect()`.
- **Swift-only:**
  - `init` (no connect) → `active == false`.
  - `connect()` then `engineDidOpen` → `active == true`.
  - User-initiated `disconnect()` → `active == false`.
  - Manager `tryReconnect` in flight → `active == true`.
  - `clearRecoveryState()` does not affect `active`.
  - Multiple namespaces: each socket's `active` independent (disconnecting `/admin` does not affect `/`).
  - Status-transition race: reading `active` during status flip does not crash.

---

## Phase 4 — `onAny` family completion

### Background
Current Swift `onAny(handler)` stores **one** closure (replaces). JS `onAny` appends to a list. Matching JS naming would break Swift back-compat, so additive new API is introduced alongside.

### API (new methods, additive)
```swift
// Existing — semantics unchanged:
public private(set) var anyHandler: ((SocketAnyEvent) -> ())?
open func onAny(_ handler: @escaping (SocketAnyEvent) -> ())  // still replaces single handler

// New:
@discardableResult
open func addAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID
@discardableResult
open func prependAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID
open func removeAnyListener(id: UUID)
open func removeAllAnyListeners()
public var anyListenerIds: [UUID] { get }
```

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — new `private var anyListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []`; new methods.
- `Source/SocketIO/Client/SocketIOClient.swift:dispatchEvent(_:data:withAck:)` — after existing `anyHandler?(...)` call, iterate snapshot of `anyListeners` and invoke each.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — protocol additions with default implementations.

### Data flow
event arrival → `handleEvent` → `dispatchEvent` → `anyHandler?` (legacy single) → `anyListeners` (snapshot iteration) → named handlers.

### Error handling
- `removeAnyListener(id:)` with unknown id: silent no-op (matches JS `offAny`).

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "catch-all listener":
  - `should support catch-all listener`
  - `should unregister with offAny()`
  - `prependAny` ordering
  - multi-listener invocation order
- **Swift-only:**
  - Three `addAnyListener` calls → invoked in registration order.
  - `prependAnyListener` → invoked first.
  - `removeAnyListener(id:)` → that listener silenced; others unaffected.
  - `removeAllAnyListeners` → all silenced.
  - Returned UUIDs are unique.
  - Legacy `anyHandler` still fires alongside new listeners (back-compat).
  - Listener self-removal during dispatch: no crash; later listeners in the same dispatch still fire.
  - Listener registers another listener mid-dispatch: new listener does **not** fire in current dispatch (snapshot iteration); fires on next event.
  - Concurrent add/remove from multiple threads: serialized by `handleQueue`; no race.
  - Ack packets do **not** trigger any-listeners (parity with named-event behavior).
  - Binary events trigger any-listeners.
  - Namespace isolation: `/admin` listener does not see `/` events.

---

## Phase 5 — `onAnyOutgoing` family

### API (mirrors Phase 4 on emit path)
```swift
@discardableResult
open func addAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID
@discardableResult
open func prependAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID
open func removeAnyOutgoingListener(id: UUID)
open func removeAllAnyOutgoingListeners()
public var anyOutgoingListenerIds: [UUID] { get }
```
No legacy single-value counterpart — direct multi-listener model.

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — new `private var anyOutgoingListeners: [(id: UUID, handler: ...)] = []`.
- `Source/SocketIO/Client/SocketIOClient.swift:emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, completion:)` (line 454 region) — extract event name (`data[0]`) and remaining items, fire outgoing listeners (snapshot) **before** packet build.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — protocol additions with default no-op.

### Data flow
`emit(event, items)` → reserved guard (Phase 2) → outgoing listeners (always) → packet build → `engine.send` or `waitingPackets`.

### Key decisions
- Outgoing listeners fire **before** packet construction (JS-aligned).
- Ack response emits (`emitAck`) do **not** trigger outgoing listeners (JS-aligned).
- Buffered emits (sent while disconnected → `waitingPackets`): outgoing listener fires once at enqueue time, **not** again at flush.
- Volatile emits (Phase 7) that are dropped: outgoing listener still fires (JS-aligned).

### Error handling
None.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "outgoing catch-all":
  - `should support catch-all listener for outgoing packets`
  - `prependAnyOutgoing` ordering
  - `offAnyOutgoing` removal
  - ack responses excluded
- **Swift-only:**
  - `emit("foo", "x")` → outgoing listener receives `SocketAnyEvent(event: "foo", items: ["x"])`.
  - Multi-listener ordering, prepend, remove parity with Phase 4.
  - `emitAck(_:with:)` does not trigger outgoing listeners.
  - Returned UUIDs unique.
  - Disconnected-emit case: outgoing fires at enqueue; reconnect flush does **not** re-fire.
  - `volatile.emit(...)` (Phase 7) still triggers outgoing.
  - `emitWithAck(...).timingOut(...)` triggers outgoing; internal ack id is not exposed to listener.
  - Listener invokes `socket.emit(...)` inside handler: no infinite recursion (snapshot iteration; new listener call enqueues a fresh emit).
  - Binary emit (items contain `Data`) triggers outgoing.
  - Namespace isolation: `/` outgoing listener does not see `/admin` emits.

---

## Phase 6 — `socket.send()` / `"message"` shortcut

### API
```swift
open func send(_ items: SocketData..., completion: (() -> ())? = nil)
open func send(with items: [SocketData], completion: (() -> ())? = nil)
open func sendWithAck(_ items: SocketData...) -> OnAckCallback
open func sendWithAck(with items: [SocketData]) -> OnAckCallback
```

Pure sugar:
```swift
open func send(_ items: SocketData..., completion: (() -> ())? = nil) {
    emit("message", with: items, completion: completion)
}
```

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — four thin wrappers (~20 LOC).
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — four protocol requirements with default impls delegating to `emit`/`emitWithAck`.

### Data flow
`send(...)` → `emit("message", ...)` → existing path.

### Error handling
None new. Reserved-name guard (Phase 2) sees `"message"` — not in reserved set; passes through.

### Reception
No new API. `socket.on("message") { data, _ in }` already works. README adds a paragraph mapping server `socket.send(...)` ↔ client `on("message")`.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "send":
  - `should send and receive messages`
  - `send(payload, callback)` ack
  - multi-arg send
- **Swift-only:**
  - `socket.send("hello")` → server `on("message")` receives `"hello"`.
  - `socket.send("a", "b", 1)` → server receives `["a", "b", 1]`.
  - `socket.sendWithAck("ping").timingOut(after: 1) { data in }` → ack received.
  - `socket.send(with: items, completion: { ... })` → completion fires after packet write.
  - `send` is observably equivalent to `emit("message", ...)` (same payload, same order on server).
  - `send` triggers outgoing catch-all listener (Phase 5) with event name `"message"`.
  - Empty items `socket.send()` → server receives empty args; no crash.
  - Binary `send(Data(...))` → server receives buffer correctly.
  - v2 + v3 manager parity.
  - Namespace `/admin` send only routes to `/admin`.

---

## Phase 7 — `socket.volatile.emit(...)`

### API (chained property, JS-aligned)
```swift
public extension SocketIOClient {
    var volatile: SocketVolatileEmitter { SocketVolatileEmitter(socket: self) }
}

public struct SocketVolatileEmitter {
    let socket: SocketIOClient
    public func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil)
    public func emit(_ event: String, with items: [SocketData], completion: (() -> ())? = nil)
}
```
No `volatileWithAck` — JS does not provide one. Volatile + ack semantics conflict (drop ⇒ ack never returns).

### Behavior
- If `socket.status == .connected` and engine writable → send normally.
- Otherwise → drop. **Not** enqueued in `waitingPackets`. **Not** replayed on reconnect.
- Outgoing catch-all listener (Phase 5) **still fires** before drop check (JS-aligned).

### Components touched
- New file `Source/SocketIO/Client/SocketVolatileEmitter.swift`.
- `Source/SocketIO/Client/SocketIOClient.swift` — `var volatile` getter (one-line extension).
- `Source/SocketIO/Client/SocketIOClient.swift` — internal `emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, volatile: Bool = false, completion:)` adds new parameter (default `false` for back-compat). Inside `emit`: if `volatile && status != .connected`, fire outgoing listeners then log debug + return.

### Data flow
```
volatile.emit(event, items)
  → socket.emit(... volatile: true)
  → reserved guard
  → outgoing listeners (always)
  → if volatile && !connected: log + drop + return
  → packet build → engine.send / waitingPackets
```

### Error handling
Drop is normal flow, not an error. Debug-level log records the drop.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "volatile":
  - `should discard packets sent in disconnected state`
  - `should send packets sent while connected`
  - volatile drops do not interfere with non-volatile emit buffering
- **Swift-only:**
  - `status == .connecting` (post-`connect()`, pre-ack) → volatile drops (parity with "not connected" semantics).
  - Volatile emit at the instant connect ack arrives — deterministic via `setTestStatus`.
  - `status == .reconnecting` → volatile drops.
  - User-initiated `disconnect()` → volatile drops.
  - Volatile drop still fires outgoing listener (Phase 5).
  - Volatile drop still passes through reserved guard (Phase 2).
  - v2 + v3 manager parity.
  - Namespace `/admin` volatile drop does not affect `/` buffered packets.
  - `clearRecoveryState()` is independent of volatile.
  - 1000 volatile emits during disconnect → no memory growth (no buffering).

---

## Phase 8 — `auth` function form

### Why
Tokens expire; reconnects need fresh credentials. Current Swift accepts only static `[String: Any]?` and reuses the cached payload across reconnect attempts.

### API
```swift
public typealias SocketAuthCallback = ([String: Any]?) -> Void
public typealias SocketAuthProvider = (@escaping SocketAuthCallback) -> Void

public extension SocketIOClient {
    func setAuth(_ provider: @escaping SocketAuthProvider)
    func clearAuth()
    func setAuth(_ provider: @escaping @Sendable () async -> [String: Any]?)
}
```
Static `connect(withPayload:)` is preserved. When a provider is installed, the provider takes precedence and the static payload is ignored (with logged warning).

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift`
  - new `private var authProvider: SocketAuthProvider?`
  - public `setAuth` / `clearAuth` (callback and async overloads)
  - `connect()` path: when calling `manager.connectSocket(self)`, if provider exists, invoke provider; the CONNECT packet is sent only once the callback fires.
- `Source/SocketIO/Manager/SocketManager.swift`
  - extract `_sendConnectPacket(socket:payload:)` from existing `connectSocket(_:withPayload:)` so `SocketIOClient` controls the timing.
  - `tryReconnect` path naturally re-invokes the provider per reconnect (no caching).
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — four protocol requirements with default no-op implementations.

### Data flow (provider mode)
```
connect()
  → status = .connecting
  → engine.connect (transport)
  → engineDidOpen → manager.connectSocket(self)
  → if authProvider:
       invoke provider on handleQueue
       callback → _sendConnectPacket(payload: returned)
  → else:
       _sendConnectPacket(payload: static)
```

### Key decisions
- Provider callback dispatched on `handleQueue`.
- Provider has no built-in timeout. If the callback never fires, the existing connect-timeout path (`connect(withPayload:timeoutAfter:withHandler:)`) handles cleanup; recovery buffer cleanup from commit `e77d332` already covers this.
- Synchronous provider callback is allowed (`{ cb in cb([:]) }`).
- Async overload internally wraps to callback form for unified handling.
- Coexistence: when both `withPayload` and `setAuth` are used, provider wins; emit logged warning.

### Error handling
- Provider returns `nil` → CONNECT sent without auth.
- Provider never invokes callback → connect-timeout path triggers.
- Provider invokes callback multiple times → only first call is honored (idempotent flag); subsequent calls ignored.
- Provider invokes callback after socket disconnect → status check; CONNECT not sent.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "auth attribute" + "connection-state-recovery" (auth path):
  - `should send auth payload` (static)
  - `should support function auth attribute` (provider form)
  - `should re-send auth on reconnection` (provider re-invoked)
  - provider returns empty → server receives no auth
- **Swift-only:**
  - `setAuth { cb in cb(["token": "abc"]) }` → server `connection.handshake.auth == {token: "abc"}`.
  - Forced reconnect → provider re-invoked (counter assertion).
  - Async overload `setAuth { await fetchToken() }` → equivalent behavior.
  - `clearAuth` then reconnect → no auth payload.
  - Provider executes on `handleQueue` (verified via `dispatch_specific`).
  - Provider callback invoked twice → second invocation silently ignored; server receives only one CONNECT.
  - Provider never callbacks → `connect(timeoutAfter: 1.0, ...)` path times out; handler fires; status returns to `.notConnected`.
  - Provider callback racing with user `disconnect()` — disconnected socket does not send CONNECT.
  - Identity swap: `clearRecoveryState() + clearAuth() + setAuth(newProvider)` then reconnect → fresh token used; recovery state not reused (cross-phase interaction).
  - Multiple namespaces on shared manager: each socket's auth provider independent.
  - `connect(withPayload: ["x": 1])` then `setAuth(...)` → provider wins; logged warning.
  - Thread safety: concurrent reconnect triggers (synthetic) → provider invoked exactly once per attempt.
  - v2 manager: v2 protocol does not transmit CONNECT auth payload; provider is no-op + warning.

---

## Phase 9 — `socket.timeout(after:).emit(..., ack:)` per-emit ack + err-first

### Why
Highest-value gap. Existing `emitWithAck().timingOut()` signals timeout via the magic string `SocketAckStatus.noAck`, which is weakly typed and easy to miss.

### API
```swift
public enum SocketAckError: Error, Equatable {
    case timeout
    case notConnected   // reserved; not used by this phase, see Key decisions
}

public extension SocketIOClient {
    func timeout(after seconds: Double) -> SocketTimedEmitter
}

public struct SocketTimedEmitter {
    let socket: SocketIOClient
    let timeout: Double

    // Callback (err-first, JS-aligned)
    public func emit(
        _ event: String,
        _ items: SocketData...,
        ack: @escaping (Error?, [Any]) -> Void
    )
    public func emit(
        _ event: String,
        with items: [SocketData],
        ack: @escaping (Error?, [Any]) -> Void
    )

    // Async (Swift-modern)
    public func emit(_ event: String, _ items: SocketData...) async throws -> [Any]
    public func emit(_ event: String, with items: [SocketData]) async throws -> [Any]
}
```
Existing `emitWithAck(...).timingOut(after:)` preserved verbatim.

### Components touched
- New file `Source/SocketIO/Ack/SocketAckError.swift`.
- New file `Source/SocketIO/Ack/SocketTimedEmitter.swift`.
- `Source/SocketIO/Client/SocketIOClient.swift` — `timeout(after:) -> SocketTimedEmitter` (one-line extension).
- `Source/SocketIO/Ack/SocketAckManager.swift` — new internal `addAck(_ id: Int, callback: @escaping (Error?, [Any]) -> Void, timeout: Double)`. Existing `OnAckCallback` path delegates to this internally; behavior of legacy callers unchanged.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — `timeout(after:)` protocol requirement + default impl.

### Data flow
```
socket.timeout(after: 5).emit("e", x, ack: cb)
  → SocketTimedEmitter.emit
  → socket internal emit(..., ack: id) — new ack id registered
  → SocketAckManager.addAck(id, callback: cb, timeout: 5)
  → handleQueue.asyncAfter(5) { if !fired: cb(.timeout, []) }
  → server ack arrives → handleAck → SocketAckManager.executeAck(id, [...]) → cb(nil, [...])
```
Async overload wraps the callback in `withCheckedThrowingContinuation`.

### Key decisions
- Disconnected-emit: the packet enters `waitingPackets` (JS-aligned). The timer still runs; if reconnect doesn't complete in time, callback fires `.timeout`. `.notConnected` is not used by this phase — reserved enum case for future explicit policy.
- Volatile + timeout is unsupported (no `volatile.timeout` API). Documented.
- Duplicate ack response (defensive): only first response honored; subsequent ignored with warning log.
- All callbacks dispatched on `handleQueue`.
- Async cancellation: `Task.cancel()` immediately throws `CancellationError`; ack registration is removed (no leak).
- Outstanding timed acks during identity swap (`clearRecoveryState`): all fire `.timeout` and are cleared, consistent with commit `3c2b5d7`'s recovery replacement logic.

### Error handling
| Condition | Behavior |
|---|---|
| Server acks within timeout | `cb(nil, data)` |
| Timeout elapses, no ack | `cb(.timeout, [])` |
| Late ack arrives after timeout fired | Ignored; no double callback |
| Socket disconnects while waiting | Existing behavior — no callback unless timeout fires |
| Reconnect mid-flight | Old ack id invalidated; timeout still fires |

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "Acknowledgements" + "timeout":
  - `should add the ack as the last argument`
  - `should fire the callback when the server acks`
  - `should timeout when the server does not ack` — JS provides `Error` with `message: "operation has timed out"`; Swift uses `SocketAckError.timeout`.
  - `should still call the callback after the timeout` — late ack does not re-fire.
- **Swift-only:**
  - `socket.timeout(after: 1).emit("ping") { err, data in ... }` server `(cb) => cb("pong")` → `cb(nil, ["pong"])` within 1 s.
  - Server never acks → `cb(.timeout, [])` after 1 s.
  - Late ack after timeout → callback **not** re-invoked.
  - Async overload `let r = try await socket.timeout(after: 1).emit("ping")` — same semantics; `do/catch SocketAckError.timeout`.
  - Multi-arg ack `cb("a", "b", 1)` → `cb(nil, ["a", "b", 1])`.
  - `timeout(after: 0)` → fires immediately (JS parity).
  - 100 concurrent timed emits — ack ids unique; no cross-talk.
  - Race: timeout firing instant exactly as server ack arrives — first fire wins; the other is no-op.
  - Disconnected emit (enters `waitingPackets`) → reconnect → server acks → `cb(nil, ...)`. If reconnect exceeds timeout → `cb(.timeout, [])` first; later server ack ignored.
  - Async cancellation via `Task { ... }.cancel()` before ack arrives → throws `CancellationError`; ack registration cleared.
  - Async overload from `@MainActor` context — callback dispatch to `handleQueue` correct; no actor isolation violation.
  - `timeout: .infinity` / very large value — no `asyncAfter` overflow; ack waits indefinitely.
  - Negative timeout → `precondition` rejects.
  - Reserved name `timeout(after: 1).emit("connect", ...)` triggers Phase 2 reserved guard.
  - Triggers outgoing catch-all listener (Phase 5) with correct event name.
  - v2 manager: identical semantics.
  - Namespace `/admin` timed emit does not affect `/` ack manager.
  - Identity swap (`clearRecoveryState` + new auth) clears outstanding timed acks (no stale callbacks).
  - Memory: 1000 timeout/ack cycles → `SocketAckManager.acks` dict cleaned; no leak.
  - Thread safety: invocation from background queue → internally dispatched to `handleQueue`; no crash.

---

## Test Strategy (cross-cutting)

For every phase:

1. **Enumerate JS reference tests.** Search `packages/socket.io-client/test/` in the JS repo for the feature. List each by file:test-name in the phase's testing section.
2. **Port every relevant case.** Unit tests under `Tests/TestSocketIO/`. E2E tests under `Tests/TestSocketIO/E2E/` when server interaction is required (use existing `TestServerProcess` fixture).
3. **Add Swift-only edge cases.** Concurrency, identity swap, reconnect mid-flight, malformed/oversized payloads, namespace isolation, v2/v3 protocol parity.
4. **CI gate.** A phase is not complete until both JS-mirrored and Swift-extra suites pass on iOS, macOS, and Linux SwiftPM matrix.

## Documentation

- Each phase ships with:
  - CHANGELOG entry under `## Unreleased`.
  - README section update if the new API is user-facing top-level (Phases 1, 6, 7, 8, 9 qualify).
  - Inline doc-comments matching existing style.
- A migration appendix in README maps JS `socket.io-client` API to Swift API for the nine items.

## Release Plan

- Each phase is one PR. Merge order = phase order.
- Cumulative version: minor bump after Phase 4 lands (first new public type). Subsequent phases are minor bumps when adding API surface.
- No `major` bump; no `breaking` changelog entries permitted in this design's scope.

## Out of Scope (Tracked for Future)

- Pluggable parser interface (msgpack-parser).
- WebTransport transport.
- Engine-layer events (`drain`, `packet`, `packetCreate`).
- `disconnect` reason as structured object (currently `String`).
- Packet-level `{ retries }` policy.
- Typed-events helper.
