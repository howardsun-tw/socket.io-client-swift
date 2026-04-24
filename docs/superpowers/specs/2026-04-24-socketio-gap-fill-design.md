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

Risk-ascending order by **preference**, not technical dependency. Earliest phases are isolated, low-risk additions that establish the per-phase template (config plumbing, changelog format, test scaffolding). Phase 9 (per-emit timed ack) is sequenced last because it is the highest-implementation-complexity item, but only Phase 2 is a real prerequisite for it; if customer demand dictates, 9 can move earlier. Hard prerequisites are listed in the table.

| # | Phase | Risk | Hard Deps | Notes |
|---|---|---|---|---|
| 1 | `.autoConnect(Bool)` config | low | — | Default `false` (preserves current behavior). |
| 2 | Reserved event name guard | low | — | Additive: DEBUG assert + release log; emit still proceeds. Guard installed in internal `emit(_ data:[Any]...)` so it covers `SocketRawView.emit` too. |
| 3 | `socket.active` property | low | — | Derived getter; reads `status` and `manager.reconnecting`. |
| 4 | `onAny` family completion (add/prepend/remove/list) | medium | — | New multi-listener storage on concrete `SocketIOClient` only. |
| 5 | `onAnyOutgoing` family | medium | 2 | Hooks the same internal `emit` path Phase 2 instruments. Concrete class only. |
| 6 | `socket.send()` / `"message"` | low | — | Thin wrappers over `emit("message", ...)`. |
| 7 | `socket.volatile.emit(...)` | medium | 5 | Reuses the listener-registration mechanism from Phase 5 (volatile drop does **not** fire outgoing per JS — see Phase 7 Behavior). |
| 8 | `auth` function form | high | — | Async-callback provider invoked per connect/reconnect. Provider gating moves into `_engineDidOpen`. |
| 9 | `socket.timeout(after:).emit(..., ack:)` per-emit ack + err-first | high | 2 | Reserved guard interaction; otherwise independent. Could ship after Phase 2 if customer demand dictates. |

Phase 9 is sequenced last by **preference** (highest implementation complexity), not technical dependency — only Phase 2 is a hard prerequisite. Re-ordering is allowed.

## Cross-cutting Constraints

- **Compatibility:** No public type/method removed or renamed. All new methods are additive on the concrete `SocketIOClient` / `SocketManager` classes. New requirements added to the public protocol `SocketIOClientSpec` are a source-breaking change for third-party conformers (they must implement the new requirement). To stay strictly additive, new methods that depend on private storage on `SocketIOClient` (Phases 4, 5) are added on the concrete class **only**, not on the protocol. Phases 3 (derived getter), 6 (thin wrapper delegating to existing protocol methods), and 9 (`timeout(after:)` returning a `SocketTimedEmitter` that holds the conformer via the protocol type) ship default impls. Phase 8 `setAuth` / `clearAuth` extend the protocol with `fatalError` default impls — silent no-op defaults would let third-party conformers silently ignore auth installation, which is a worse failure mode than a loud trap.
- **Threading:** The library is documented as not thread-safe — all calls must originate on `handleQueue`. New APIs preserve this contract; async/callback overloads explicitly hop results back to `handleQueue` before invoking user code.
- **Logging:** New code uses `DefaultSocketLogger.Logger` for parity with existing layers. Auth payloads are **not** redacted in this design (JS-aligned — see Phase 8 "Logging" section). Consumers requiring redaction can implement a custom `SocketLogger` conformer.
- **Versioning:** Patch/minor release on v16 line. CHANGELOG entry per phase. Protocol-additive phases (3, 6, 8, 9) call out source-compat impact in their CHANGELOG entry.
- **Test parity:** Every phase test plan enumerates JS reference tests by name and ports them. Each phase additionally lists Swift-only stricter edge cases (concurrency, identity swap, reconnection mid-flight, oversized data, namespace isolation, v2/v3 protocol parity).
- **Concurrency posture:** Codebase has zero existing `Sendable` / `actor` / `async` adoption. New async overloads are added without `@Sendable` annotations on closures that capture non-`Sendable` types like `[String: Any]`; they internally hop to `handleQueue` and use `withTaskCancellationHandler` where cancellation is meaningful (Phase 9). Adoption of strict concurrency is out-of-scope.
- **No new third-party dependencies** introduced in any phase.
- **JS-divergence policy:** when this spec deviates from `socket.io-client` (JS) reference behavior, the divergence is explicitly justified inline. Three categories of justified divergence in this design:
  1. **Defensive guards JS lacks** that would mask real bugs in Swift (idempotency token in Phase 8 — JS sends duplicate CONNECT on multi-callback; Logger redaction in Phase 8 — JS logs auth tokens in `debug` output unredacted). These are Swift-side improvements; document as "stricter than JS, intentional."
  2. **Swift-idiomatic mappings** of JS string-typed signals (Phase 9 `SocketAckError.timeout` / `.disconnected` enum cases map to JS's two distinct Error `message` strings — same semantic distinction, more idiomatic).
  3. **Swift concurrency overloads** that have no JS counterpart (Phase 8 `async throws` auth overload, Phase 9 `async throws` ack overload). These are pure additions for Swift consumers.

  Anything **not** in those three categories must match JS exactly. If a reviewer proposed a behavior we considered and rejected as JS-divergent without justification, it is recorded in **Reviewer Pushback Notes**.

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
        "connect", "connect_error", "disconnect"
    ]
}
```
JS-aligned: `socket.io-client/lib/socket.ts:169-177` defines the reserved set as `connect, connect_error, disconnect, disconnecting, newListener, removeListener`. The Swift list drops `disconnecting` (server-side concept, not exposed on this client) and `newListener`/`removeListener` (Node EventEmitter internals with no Swift equivalent). Other Swift `SocketClientEvent` cases (`error`, `ping`, `pong`, `reconnect`, `reconnectAttempt`, `statusChange`, `websocketUpgrade`) are **not** reserved in JS — those are manager-level signals, not user-emit names — so they are not added here.

### Behavior (additive)
Inside the internal `emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, completion:)` (the single funnel that all public emit overloads, `emitWithAck`, and `SocketRawView.emit` route through):
- If `data.first as? String` ∈ reserved and `isAck == false` → `assertionFailure("...")` (DEBUG only) + `DefaultSocketLogger.Logger.error(...)` (always).
- Emit **still proceeds**. Release runtime behavior is unchanged; only a log line is added.

Installing the guard at the internal funnel rather than at the public `emit(_:with:completion:)` entry ensures `SocketRawView.emit` (which calls the internal funnel directly, bypassing the public entry) is also covered with no duplication.

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — internal `emit(_ data:[Any], ...)` (around line 454) calls new private helper `warnIfReserved(_ event:)` at the top of the function (after the `status == .connected` guard, before packet build).

### Data flow
internal emit entry → `warnIfReserved` → existing packet build/send (unchanged).

### Error handling
`assertionFailure` in DEBUG only. No throw, no early return. Documentation steers users to `clientEvent:` API variants for listener registration.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "should throw on reserved event names" — Swift cannot throw without breaking emit signature; mirrored as logger-error assertion in release tests.
- **Swift-only:**
  - Each reserved name: `emit(name, "x")` → logger receives error; `emitWithAck(name, "x").timingOut(...)` same.
  - `SocketRawView.emit([reserved, "x"])` also triggers the warning (verifies guard placement at internal funnel).
  - Case sensitivity: `"Connect"`, `"CONNECT"` do **not** trigger.
  - Whitespace variants (`" connect"`) do **not** trigger.
  - Mixed sequence (reserved + normal) — normal emit still flows correctly.
  - Outbound ack frames (`emitAck` / `isAck == true`) do **not** trigger the guard even if their first item happens to be a reserved string.
  - v2 manager and v3 manager: behavior identical.
  - Non-default namespace (`/admin`): behavior identical.

---

## Phase 3 — `socket.active` property

### Background — name collision
`SocketIOStatus` already exposes a Bool property `active` (`SocketIOStatus.swift:47-49`) that reports whether the status enum represents a live state. The new socket-level `active` is a **separate, namespace-scoped** signal. Doc-comment must explicitly distinguish: `socket.active` answers "is this client trying to maintain a connection (connecting/connected/reconnecting)?" while `socket.status.active` answers "is this status enum a live state?".

### API
```swift
public extension SocketIOClient {
    var active: Bool { get }
}
```

JS reference (`socket.io-client/lib/socket.ts` `get active()` returns `!!this.subs`) tracks **whether the socket is currently subscribed to its manager** — set inside `connect()` (when `subEvents()` populates `this.subs`) and torn down inside user-initiated `disconnect()`. It is independent of `status` and reconnect state: during the brief disconnected-but-reconnecting window JS still returns `true` (the socket is still wired into manager events).

Swift mirror: maintain a per-`SocketIOClient` Bool that flips `true` at the start of user-initiated `connect()` and `false` inside user-initiated `disconnect()`. Do **not** derive from `status` or `manager.reconnecting` — those return wrong answers in the disconnected-mid-reconnect window.

```swift
public private(set) var active: Bool = false  // on SocketIOClient concrete class
// connect():    self.active = true   (set before engine work begins)
// disconnect(): self.active = false  (set on the user-initiated path only —
//               socket-level engine disconnect/reconnect cycles must NOT clear it)
```

Concrete-class only (no `SocketIOClientSpec` requirement). Same rationale as Phase 4/5: protocol default impls cannot reach private storage; growing the protocol is source-breaking. Third-party conformers can roll their own equivalent.

**No `SocketManagerSpec.reconnecting` promotion.** A previous revision proposed promoting `SocketManager.reconnecting` to `public private(set)` and adding a `SocketManagerSpec` requirement so the `active` default impl could read it. That is dropped — the JS-correct formula does not consult any reconnecting flag, so the promotion is dead code introduced for the wrong reason. `SocketManager.reconnecting` stays `private`. No `SocketManagerSpec` change.

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — new `public private(set) var active: Bool = false`. In `connect(timeoutAfter:withHandler:)` (and any other user-facing `connect` path), set `self.active = true` before invoking the manager. In the user-initiated `disconnect()` (the public method, not internal `didDisconnect` paths driven by engine close/reconnect), set `self.active = false`.
- **Critically:** `didDisconnect` triggered by engine close, transport error, or any reconnect-cycle internal disconnect must **not** flip `active` to false. Only user-initiated `disconnect()` does. This matches JS where `subs` lives across reconnect cycles.

### Data flow
Pure stored Bool. Read in O(1). No derivation.

### Error handling
None.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "active" segment:
  - `active === true` after `connect()`, before engine open
  - `active === true` after engine open
  - `active === true` during reconnect cycle (engine closed, manager still trying)
  - `active === false` only after user-initiated `disconnect()`
- **Swift-only:**
  - `init` (no connect) → `active == false`.
  - `connect()` immediately → `active == true` (before engineDidOpen fires).
  - `engineDidOpen` → still `active == true`.
  - User-initiated `disconnect()` → `active == false`.
  - **Engine-level disconnect during reconnect cycle:** simulate `engineDidClose` followed by reconnect attempt → `active` remains `true` throughout the cycle (this is the case the previous formula got wrong).
  - `clearRecoveryState()` does not affect `active`.
  - Multiple namespaces: each socket's `active` independent (disconnecting `/admin` does not affect `/`).
  - `connect()` → `disconnect()` → `connect()` → `active == true` again.
  - Doc-comment distinguishes `socket.active` (lifecycle) from `socket.status.active` (current status enum is a live state).

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
- **No additions to `SocketIOClientSpec`.** Storage lives on the concrete class as `private`; protocol-default impls cannot reach it. New methods are concrete-class only. Trade-off: third-party `SocketIOClientSpec` conformers don't get this API for free, but back-compat is preserved (the protocol doesn't grow new requirements). If protocol-level access is needed later, a follow-up phase can add an opt-in sub-protocol or make the storage protocol-required.

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
- `Source/SocketIO/Client/SocketIOClient.swift:emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, completion:)` (around line 464) — fire outgoing listeners **after** the existing `status == .connected` guard, immediately before `engine.send` writes the packet. This is **JS-aligned**: per `socket.io-client/lib/socket.ts:234-239`, `notifyOutgoingListeners(packet)` is invoked inside the `else if (isConnected)` branch — only when the packet is actually about to leave the client. Disconnected emits, volatile drops, and not-writable transports do **not** fire outgoing.
- **No additions to `SocketIOClientSpec`.** Same rationale as Phase 4 — concrete-class only.

### Data flow
`emit(event, items)` → reserved guard (Phase 2) → existing `status == .connected` guard → packet build → outgoing listeners (snapshot iteration) → `engine.send`.

### Key decisions
- Outgoing listeners fire **after** the connected-state guard and **immediately before** `engine.send` (JS-aligned per `socket.io-client/lib/socket.ts:234-239` — `notifyOutgoingListeners` runs inside the `isConnected` branch).
- Ack response emits (`emitAck`, identified by `isAck == true`) do **not** trigger outgoing listeners (JS-aligned).
- The current Swift code does **not** buffer outbound emits while disconnected — `SocketManager.waitingPackets` is the inbound binary-reassembly buffer, not an outbound queue. Disconnected non-volatile emits surface a `.error` to user code today; that behavior is preserved.
- **Disconnected emit:** outgoing listener does **not** fire (matches JS — listener only fires on actual send).
- **Volatile drop (Phase 7):** outgoing listener does **not** fire (JS `discardPacket` branch returns before `notifyOutgoingListeners`, per `socket.ts:230-232`).

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
  - Disconnected-emit case: outgoing **does not fire** (matches JS — listener only fires on actual send). The existing `.error` event still surfaces. No buffering.
  - `volatile.emit(...)` (Phase 7) drop case: outgoing **does not fire** (matches JS — `discardPacket` branch skips `notifyOutgoingListeners`).
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
- JS gate (`socket.io-client/lib/socket.ts`, current `main` ~`:443-447`):
  ```js
  const isTransportWritable = this.io.engine?.transport?.writable;
  const discardPacket = this.flags.volatile && !isTransportWritable;
  ```
  Drop predicate is `volatile && !transport.writable` — **independent of `status`**. A connected-but-not-writable transport (mid-handshake, mid-upgrade, backpressure window) drops volatile packets; a non-volatile emit on the same not-writable transport gets buffered into JS's `sendBuffer` (which Swift does not currently maintain — see Phase 5 note).
- **Swift exposure problem:** `SocketEngineSpec` exposes only `connected: Bool`; `transport.writable` has no Swift equivalent. Resolution requires one of:
  1. **Add `var writable: Bool { get }` to `SocketEngineSpec`** (additive protocol requirement) and wire it through to the underlying transport in `SocketEngine` / `SocketEnginePollable` / WebSocket transport. This is the JS-faithful path. Concrete sites: `SocketEngine.swift` exposes `postWait`-queued writes; `writable` should reflect "can the underlying transport accept a write right now without queuing." For WebSocket: forward the underlying socket's writable state. For polling: `false` while a POST is in flight, `true` otherwise.
  2. **Document an explicit JS-divergence approximation:** `volatile && !(socket.status == .connected && engine.connected)`. This is strictly looser than JS (drops more aggressively — anything not yet `.connected` drops, which JS would gate purely on transport.writable). Mark this as a category-1 justified divergence ("Swift-side simplification: `transport.writable` not yet surfaced in `SocketEngineSpec`") in the JS-divergence policy.

  **Recommended:** option 1. Phase 7 ships gated on adding `writable` to `SocketEngineSpec`. If that surface change is judged out-of-scope for Phase 7, fall back to option 2 with the divergence explicitly enumerated.
- **Volatile + `.connecting` behavior is governed by writability, not status.** A volatile emit while `status == .connecting` but transport is writable goes through; while `status == .connected` but transport is not writable (rare — backpressure or mid-upgrade) drops. Tests must exercise both axes.
- Non-volatile emit while transport not writable: existing Swift behavior preserved (currently surfaces `.error` event; JS would buffer into `sendBuffer`). Volatile differs by suppressing the `.error` event.
- Outgoing catch-all listener (Phase 5) **does not fire** on volatile drop. JS-aligned: per `socket.io-client/lib/socket.ts` (current `main` ~`:443-451`), the `discardPacket` early-return precedes `notifyOutgoingListeners`. Analytics/observability sinks attached via `addAnyOutgoingListener` do **not** observe dropped packets — consistent with "outgoing listeners observe what reaches the wire."

### Volatile + ack callback caveat
JS allows `socket.volatile.emit("e", arg, cb)` (volatile chained with an ack callback). On drop, JS's `_registerAckCallback` has already registered the callback before the discard check, so the callback ends up orphaned in `this.acks` (`socket.ts:219-226`) — it never fires unless either a server ack arrives later (impossible since packet wasn't sent) or the `socket.timeout(...)` wrapper exists and fires `disconnected`/`timeout` later via `_clearAcks`.

Swift behavior in this design:
- `socket.volatile.emit(...)` does NOT accept an ack callback in its public API (no `cb` parameter on `SocketVolatileEmitter.emit`). Users who want timeout-protected volatile must explicitly chain: there is no `socket.volatile.timeout(ms).emit(...)` chain — Swift omits this combination because volatile + timeout has the same orphaning hazard JS has.
- If a user routes a timed ack through volatile via a future API extension, the Phase 9 `clearTimedAcks(reason: .disconnected)` cleanup on disconnect will fire orphaned callbacks with `.disconnected`, matching JS's `_clearAcks` for `withError` callbacks.

### Components touched
- New file `Source/SocketIO/Client/SocketVolatileEmitter.swift`.
- `Source/SocketIO/Client/SocketIOClient.swift` — `var volatile` getter (one-line extension).
- `Source/SocketIO/Client/SocketIOClient.swift` — internal `emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, volatile: Bool = false, completion:)` adds new parameter (default `false` for back-compat). The internal funnel is `internal`, not `private`, and is reached by every emit path (`emit`, `emitWithAck`, `SocketRawView.emit`); audit all in-module call sites for the new default-argument behavior.
- **Gate predicate (option 1, recommended):** `if volatile && !(manager?.engine?.writable ?? false) { Logger.log(...); return }` — log + return without firing outgoing listeners and without surfacing `.error`.
- **`SocketEngineSpec` change (option 1):** add `var writable: Bool { get }` requirement. Implement on `SocketEngine` by forwarding the active transport's writable state. For WebSocket transport, forward the underlying `Starscream`/`URLSessionWebSocketTask` writable signal (or maintain an internal `isWriting` flag toggled around `write` calls). For polling transport, `writable = !isFetchingResponse && !isPolling`. Default impl on protocol: `false` (so any conformer that doesn't override is treated as never-writable for volatile purposes — fail-safe).
- **Fallback (option 2, if engine surface change is rejected):** `if volatile && !(status == .connected && (manager?.engine?.connected ?? false)) { ... }`. Document under JS-divergence policy as category 1.

### Data flow
```
volatile.emit(event, items)
  → socket.emit(... volatile: true)
  → reserved guard (Phase 2)
  → if volatile && !engine.writable: log + drop + return  (no .error, no outgoing fire — JS-aligned)
  → if !volatile && !connected: existing .error event path (unchanged, no outgoing fire)
  → if connected (and writable, or non-volatile): outgoing listeners (Phase 5) fire → packet build → engine.send
```

### Error handling
Drop is normal flow, not an error. Debug-level log records the drop.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "volatile":
  - `should discard packets sent in disconnected state`
  - `should send packets sent while connected`
  - volatile drops do not interfere with non-volatile emit buffering
- **JS-parity (writability axis is the gate):**
  - Connected + writable: volatile sends.
  - Connected + transport not writable (forced via test hook on `SocketEngine.writable`): volatile **drops**.
  - Disconnected (engine not connected → transport not writable): volatile drops.
  - Non-volatile emit while connected + not writable: existing `.error` path preserved (no buffering in Swift today; differs from JS which would buffer — flagged in Phase 5 buffer note).
- **Swift-only:**
  - `status == .connecting` (post-`connect()`, pre-engine-open) → engine not yet writable → volatile drops.
  - Volatile emit at the instant transport flips from not-writable → writable — deterministic via test hook.
  - During reconnect cycle (engine closed mid-cycle) → not writable → volatile drops.
  - User-initiated `disconnect()` → not writable → volatile drops.
  - Volatile drop does **not** fire outgoing listener (Phase 5) — JS-aligned (current `socket.ts` `~:443-451`).
  - Volatile drop still passes through reserved guard (Phase 2).
  - Volatile drop does **not** surface a `.error` client-event (differentiating behavior vs non-volatile disconnected emits).
  - v2 + v3 manager parity.
  - Namespace `/admin` volatile drop does not affect `/`.
  - `clearRecoveryState()` is independent of volatile.
  - 1000 volatile emits during disconnect → no memory growth (no buffering).
  - **`SocketEngineSpec.writable` default impl returns `false`:** verify a custom `SocketEngineSpec` conformer that doesn't override `writable` causes all volatile emits to drop (fail-safe).
  - **If option 2 fallback is shipped:** test must replace the `transport.writable` axis with the `status == .connected && engine.connected` axis and the JS-divergence is enumerated in the policy section.

---

## Phase 8 — `auth` function form

### Why
Tokens expire; reconnects need fresh credentials. Current Swift accepts only static `[String: Any]?` and reuses the cached payload across reconnect attempts.

### API
```swift
public typealias SocketAuthCallback = ([String: Any]?) -> Void
public typealias SocketAuthProvider = (@escaping SocketAuthCallback) -> Void

public extension SocketIOClient {
    /// Install a callback-form auth provider. Invoked on `handleQueue` for every
    /// CONNECT (initial + every reconnect attempt). JS-aligned behavior: if the
    /// callback is invoked multiple times within one attempt, each call sends a
    /// CONNECT packet (matches `socket.io-client/lib/socket.ts:686-707` which
    /// does not deduplicate). Callers should invoke the callback exactly once.
    func setAuth(_ provider: @escaping SocketAuthProvider)

    /// Remove the installed provider. After clearing, subsequent CONNECT attempts
    /// fall back to the static `connect(withPayload:)` payload (or no auth).
    /// Cancels any in-flight async provider `Task` (Swift-only addition; JS
    /// callback-form has no equivalent cancellation surface).
    func clearAuth()

    /// Async variant (Swift-only addition — JS reference does not await `auth`
    /// returning a Promise). The closure is *not* annotated `@Sendable` because
    /// `[String: Any]` is not `Sendable`. The closure runs in a `Task { ... }`
    /// retained by the socket (cancelled on `clearAuth`/`disconnect`) and the
    /// result is hopped back to `handleQueue` before being delivered. Throws →
    /// fail-closed: `handleClientEvent(.error, data: [error.localizedDescription])`
    /// fires (user `.on(clientEvent: .error)` listener invoked); CONNECT not sent.
    /// This is a Swift-only error path — JS callback-form has no thrown-error analog.
    func setAuth(_ provider: @escaping () async throws -> [String: Any]?)
}
```
Static `connect(withPayload:)` is preserved. When a provider is installed, the provider takes precedence and the static payload is ignored. A `Logger.error` line is emitted at install time noting the precedence; no per-attempt re-warning (JS-aligned: JS doesn't have this scenario at all because `auth` is set once at construction, so there is nothing in JS to mirror; we pick the minimum-noise behavior).

**No `setAuthDeadline` API.** JS-aligned: `socket.io-client/lib/socket.ts:686-707` (`onopen` → `this.auth(cb)`) imposes no deadline at the Socket layer. A hanging provider in JS leaves the socket in `connecting` until the user-supplied `connect(timeoutAfter:)` (or the equivalent JS Manager `timeout`) fires. Swift adopts the same posture: users who need timeout protection must use `connect(timeoutAfter:)`. This is documented as a known constraint, not a bug. (See **Reviewer Pushback Notes** for why we rejected the previously-proposed `setAuthDeadline` default of 10 s.)

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift`
  - new `private var authProvider: SocketAuthProvider?`
  - new `private var pendingAuthTask: Task<Void, Never>?` — retained reference to the in-flight async provider Task. `cancel()`-ed on `clearAuth()`, on `setAuth(...)` replacing the provider, and on `didDisconnect`. (Swift-only — JS callback-form provider has no Task lifetime to manage.)
  - public `setAuth` / `clearAuth` (callback and async overloads).
  - new internal hook `resolveConnectPayload(explicit:completion:)` — given the optional static payload, either calls completion immediately (no provider) or invokes the provider on `handleQueue` and forwards the result via completion. **No idempotency token / no multi-call guard:** matching JS, if the provider's callback is invoked multiple times, completion is invoked multiple times and multiple CONNECT packets are sent. Documented as "match JS bug; do not paper over."
  - The completion closure re-checks `socket.status == .connecting` (NOT a token check — purely a defensive read against the live status). If the user disconnected mid-await, the late completion drops **with** a `Logger.log("auth result discarded; socket no longer .connecting", type: "SocketIOClient")` line so consumers can correlate the drop in diagnostics. No `.error` clientEvent on this path — the user already drove the disconnect, so surfacing an additional `.error` would be noise. This is implementation-necessary for Swift's async overload (the awaited result lands later than the user's `disconnect()` could), not a behavior addition relative to JS — JS's synchronous callback can't race the same way because it has no async-await surface.
- `Source/SocketIO/Manager/SocketManager.swift`
  - **Provider gating must cover both CONNECT-write sites:**
    1. `_engineDidOpen` (around `SocketManager.swift:405-419`) — fires CONNECT for each namespaced socket when the engine becomes ready. Wrap the existing `connectSocket(socket, withPayload: consumePendingConnectPayload(for: socket))` call in `socket.resolveConnectPayload(explicit: pending) { resolved in self.connectSocket(socket, withPayload: resolved) }`.
    2. `connectSocket(_:withPayload:)` (around `SocketManager.swift:208-257`) — the early branch that fires CONNECT immediately when `manager.status == .connected` (e.g., a new namespace socket added to a live manager). Same `resolveConnectPayload` wrapping required here; otherwise providers are silently bypassed for already-connected managers.
  - On `tryReconnect` → `_tryReconnect` → `connect()`, `_engineDidOpen` re-fires and the provider is naturally re-invoked per attempt.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — three protocol requirements (`setAuth` callback form, `setAuth` async form, `clearAuth`). Default impls: **`fatalError("setAuth is only supported on concrete SocketIOClient")`**. Silent no-op defaults would let third-party conformers silently ignore auth installation, which is worse than a loud trap. Conformers must override or accept the trap when the API is called on them.

### Data flow (provider mode)
```
connect() (or tryReconnect → connect)
  → status = .connecting
  → engine.connect (transport)
  → engine open → manager._engineDidOpen (or connectSocket already-connected branch)
  → for each socket in nsps where socket.status == .connecting:
       socket.resolveConnectPayload(explicit: pending) { resolved in
         // completion runs on handleQueue; re-checks live status only:
         guard socket.status == .connecting else { return }
         manager.connectSocket(socket, withPayload: resolved)
       }
  → resolveConnectPayload internals (provider mode):
       - invoke provider on handleQueue (sync callback or async-wrapper Task)
       - on provider callback OR Task result-hop:
           - completion(resolved payload OR nil if provider returned nil)
           - (no idempotency check — JS doesn't dedupe; multi-callback → multi-CONNECT)
       - on async-path throw: handleClientEvent(.error, data: [error.localizedDescription], isInternalMessage: false)
         → user's .on(clientEvent: .error) fires
         → CONNECT NOT sent; completion NOT called
         (Swift-only fail-closed behavior; JS would never have entered this path)
```

### Key decisions
- Provider callback dispatched on `handleQueue`. Async provider runs in `Task { ... }`; result hop back to `handleQueue` via explicit `dispatch`.
- **No deadline (JS-aligned).** Hanging provider blocks CONNECT indefinitely; users protect against this with `connect(timeoutAfter:)`. Documented in API doc-comment of `setAuth` and in README.
- **No multi-callback dedup (JS-aligned).** If the user-supplied provider invokes `cb` more than once, each call triggers a CONNECT packet send — matching JS reference exactly. Tests verify the JS behavior is reproduced; tests can also exercise stricter Swift-only assertions (e.g., that the Swift wrapper does not crash on multi-callback) but the implementation does not guard.
- Synchronous provider callback is allowed (`{ cb in cb([:]) }`).
- Async overload runs the closure in `Task { ... }` retained by the socket; the result is hopped back to `handleQueue`. The closure is **not** `@Sendable`-annotated. The retained `Task` is `cancel()`ed when the socket disconnects, when `clearAuth` is called, or when `setAuth` replaces the provider mid-flight. (Swift-only addition — JS has no Task to cancel.)
- **Coexistence:** when both `withPayload` and `setAuth` are used, the provider wins. A `Logger.error` line is emitted at `setAuth` install time noting the precedence. No per-attempt re-warn (low-noise default; no JS counterpart to mirror).
- **Identity-swap convention:** documented pattern `socket.disconnect(); socket.clearRecoveryState(); socket.clearAuth(); socket.setAuth(newProvider); socket.connect()`. All five calls run synchronously on `handleQueue`. Implementation does not introduce extra fencing primitives beyond the `Task.cancel()` already required for async-overload Task cleanup. An atomic `resetIdentity(authProvider:)` API was considered and deferred — see Reviewer Pushback Notes / Out of Scope.
- **v2 manager:** the v2 path in `SocketManager.connectSocket` (gated by `version.rawValue >= 3` around line 225) drops payloads on the floor today. Provider-mode `setAuth` is therefore a v3-only feature; on v2 managers:
  - `setAuth` logs `Logger.error("setAuth has no effect on v2 (.connect protocol) managers; auth payload will be dropped on every CONNECT", type: "SocketIOClient")` at install time, AND
  - **on every CONNECT attempt where a provider is installed but the manager is v2,** fires `handleClientEvent(.error, data: ["setAuth provider installed on v2 manager — auth bypassed for this CONNECT"], isInternalMessage: false)` so the user's `.on(clientEvent: .error)` listener observes the silent bypass per-attempt. This is necessary because users only learn about install-time logs once but reconnect cycles can run indefinitely; per-attempt surfacing prevents a buried log line from masking every subsequent reconnect.
  - The provider closure itself is **never invoked** on v2 (no Task started; no callback fired). This matches today's behavior of static payloads on v2 (also dropped).
  - Justification (Swift-only divergence vs JS): JS reference has no v2/v3 split; the v2 path is a Swift-side legacy. Surfacing per-attempt via `handleClientEvent(.error, ...)` is added to satisfy the project's "no silent failure" posture rather than to mirror JS.

### Logging
JS reference (`socket.io-client`, `debug` package) does **not** redact `auth` payloads in debug logs. Per the "implementation must match JS" rule, Swift does not introduce a redaction layer for CONNECT-packet logging in this design. Consumers controlling log verbosity must treat the existing `Logger` output as potentially containing credentials when running with verbose log levels — same posture as JS.

(A previous revision proposed a Swift-side redaction contract; that has been removed to maintain JS parity. Consumers who need redaction can implement a custom `SocketLogger` conformer that masks payload content; the existing logger plug-in surface supports this.)

### Error handling
| Condition | User-facing channel | Behavior |
|---|---|---|
| Provider returns `nil` | none | CONNECT sent without auth (anonymous connect — JS-aligned) |
| Provider never invokes callback | none | Socket stays in `.connecting` until `connect(timeoutAfter:)` fires or user disconnects (JS-aligned; no Swift-side deadline) |
| Provider invokes callback multiple times | none | Multiple CONNECT packets sent (JS-aligned; matches `_sendConnectPacket` behavior) |
| Provider callback arrives after user `disconnect()` | `Logger.log` (diagnostic only) | `socket.status == .connecting` guard returns false → CONNECT not sent. Diagnostic log line emitted; no `.error` clientEvent (user already drove the disconnect) |
| Async provider throws | `handleClientEvent(.error, data: [error.localizedDescription])` → user's `.on(clientEvent: .error)` fires | CONNECT not sent. Swift-only fail-closed (no JS equivalent — JS doesn't await Promises) |
| v2 manager + provider installed | install: `Logger.error`. Per-CONNECT: `handleClientEvent(.error, data: [...])` → user's `.on(clientEvent: .error)` fires | Provider never invoked; CONNECT sent without auth. Swift-only divergence (v2/v3 split is Swift-side legacy) |

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "auth attribute" + "connection-state-recovery" (auth path):
  - `should send auth payload` (static)
  - `should support function auth attribute` (provider form)
  - `should re-send auth on reconnection` (provider re-invoked)
  - provider returns empty → server receives no auth
- **JS-parity (implementation match required):**
  - `setAuth { cb in cb(["token": "abc"]) }` → server `connection.handshake.auth == {token: "abc"}`.
  - Forced reconnect → provider re-invoked per attempt (counter assertion).
  - Provider returns `nil` → server receives no auth.
  - Provider never callbacks → socket stays in `.connecting` indefinitely; only `connect(timeoutAfter:)` (if user passed it) breaks the wait. **No Swift-side deadline fires.**
  - Provider invokes callback twice → server receives **two** CONNECT packets. Test asserts JS-parity exactly (matches `socket.io-client/lib/socket.ts` `_sendConnectPacket` being called per-callback without dedup).
  - `setAuth` then `connect(withPayload: ["x": 1])` → provider wins; static payload ignored. `Logger.error` line emitted at `setAuth` install time only (not per attempt).
  - Multiple namespaces on shared manager: each socket's auth provider independent.
- **Swift-only (tests can be stricter than JS):**
  - Async overload `setAuth { try await fetchToken() }` → equivalent observable behavior; throws → `handleClientEvent(.error)` fires user's `.on(clientEvent: .error)` listener (assert callback observed) + CONNECT not sent (Swift-only fail-closed).
  - **Async cancellation:** `setAuth(asyncProvider)` then `disconnect()` mid-fetch → retained `Task` is `cancel()`-ed; no CONNECT, no crash, no late completion. (No JS counterpart.)
  - **Async cancellation on replacement:** `setAuth(provider1)` then immediately `setAuth(provider2)` mid-fetch → `provider1`'s Task cancelled; `provider2` runs on next attempt.
  - **Async overload from `@MainActor` context** — completion delivered on `handleQueue`; no actor-isolation violation. Verified via `dispatch_specific` key inside the result-hop closure.
  - `clearAuth` then reconnect → no auth payload (provider removed); cancels in-flight async Task if any.
  - Provider executes on `handleQueue` (verified via `dispatch_specific` key) — applies to both callback-form and async-form.
  - Provider callback **after** user `disconnect()` → completion's `socket.status == .connecting` guard suppresses CONNECT send AND emits the `Logger.log("auth result discarded; socket no longer .connecting")` diagnostic line. Tests assert both: no CONNECT on the wire AND the log line was emitted. Tests verify this for both callback-form and async-form.
  - Identity-swap sequence (disconnect + clearRecoveryState + clearAuth + setAuth + connect) → fresh token used on next CONNECT; recovery state not reused; outstanding timed acks (Phase 9) cleared via Phase 9's `clearTimedAcks` on disconnect.
  - **v2 manager error-channel coverage:** install `setAuth` on v2 manager → install-time `Logger.error` line emitted (asserted via test logger). Then trigger 3 reconnect cycles → user's `.on(clientEvent: .error)` listener invoked exactly 3 times with the per-attempt bypass message. Provider closure invocation counter == 0 (provider truly never invoked).
  - Provider gating point 2 verification: create namespace `/admin` on an already-`.connected` manager → `connectSocket` early branch fires CONNECT, provider IS invoked (otherwise this path silently bypasses `setAuth`).

---

## Phase 9 — `socket.timeout(after:).emit(..., ack:)` per-emit ack + err-first

### Why
Highest-value gap. Existing `emitWithAck().timingOut()` signals timeout via the magic string `SocketAckStatus.noAck`, which is weakly typed and easy to miss.

### API
```swift
/// Idiomatic Swift mapping of JS's two distinct ack-failure Error message strings:
/// - `.timeout`     ↔ JS `new Error("operation has timed out")`   (timer elapsed)
/// - `.disconnected` ↔ JS `new Error("socket has been disconnected")` (clearAcks on disconnect)
/// Same observable behavior as JS; just a Swift type-system improvement over string-matching.
public enum SocketAckError: Error, Equatable {
    case timeout
    case disconnected
}

public extension SocketIOClient {
    func timeout(after seconds: Double) -> SocketTimedEmitter
}

public struct SocketTimedEmitter {
    // Storage is the protocol type so the protocol default impl can return
    // a SocketTimedEmitter wrapping any conformer (not just concrete SocketIOClient).
    let socket: SocketIOClientSpec
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

    // Async (Swift-modern, no JS counterpart)
    public func emit(_ event: String, _ items: SocketData...) async throws -> [Any]
    public func emit(_ event: String, with items: [SocketData]) async throws -> [Any]
}
```
Existing `emitWithAck(...).timingOut(after:)` preserved verbatim.

**Timeout-value validation (JS-aligned):** matches `socket.io-client/lib/socket.ts:239-249` which passes the user-supplied `Double` straight to `setTimeoutFn` with no validation. Swift `SocketTimedEmitter`:
- `seconds <= 0`: schedules the timer for the next `handleQueue` tick (JS behavior — `setTimeout` clamps `0` and negatives to "next tick"). Effectively immediate timeout.
- `seconds == .infinity`: schedules `DispatchWorkItem` with `.now() + .infinity` — clamps to a far-future deadline; effectively no-timer behavior. (Swift `DispatchTime` arithmetic on `.infinity` is well-defined: it saturates at `DispatchTime.distantFuture`. Implementation must verify this on macOS/iOS/Linux.)
- Very large positive `Double`: same — saturates at `DispatchTime.distantFuture`.
- **No `precondition`.** No rejection. JS-aligned.

### Components touched
- New file `Source/SocketIO/Ack/SocketAckError.swift`.
- New file `Source/SocketIO/Ack/SocketTimedEmitter.swift`.
- `Source/SocketIO/Client/SocketIOClient.swift` — `timeout(after:) -> SocketTimedEmitter` (one-line extension); `didDisconnect` updated to clear timed acks (see below).
- `Source/SocketIO/Ack/SocketAckManager.swift` — **parallel storage** alongside the existing `Set<SocketAck>`:
  - existing `acks: Set<SocketAck>` (callback type `AckCallback = ([Any]) -> ()`, around line 73) — **untouched**. Legacy `OnAckCallback.timingOut(after:)` continues to use this storage.
  - new `timedAcks: [Int: TimedAckEntry]` keyed by ack id, where `TimedAckEntry` wraps `(Error?, [Any]) -> Void`, the scheduled `DispatchWorkItem`, and a one-shot `fired` flag.
  - new internal APIs (all four perform their storage mutation inside `handleQueue.async { ... }` to enforce single-queue access regardless of caller — `Task.cancel()` from `@MainActor` reaches `cancelTimedAck` synchronously off `handleQueue`, so the `async` wrapping is implementation-required, not just defensive):
    - `addTimedAck(_ id: Int, callback: @escaping (Error?, [Any]) -> Void, timeout: Double)` — registers, schedules timer.
    - `executeTimedAck(_ id: Int, with items: [Any])` — called from `handleAck`; one-shot guard.
    - `cancelTimedAck(_ id: Int)` — cancels timer + removes entry; used by async overload's `withTaskCancellationHandler`. Does NOT fire the callback (the continuation handles that).
    - `clearTimedAcks(reason: SocketAckError)` — fires all outstanding callbacks with the given error and clears storage. Called from `didDisconnect` (`reason: .disconnected` — JS-aligned per `socket.ts:855-893` `_clearAcks` for `withError` callbacks) and from `clearRecoveryState` (`reason: .disconnected`). **No `Logger.warning` in current logger** — uses `Logger.log` or `Logger.error` only.
  - `handleAck` (caller side, in `SocketIOClient.handleAck` around line 496-502): try `executeTimedAck` first; on miss, dispatch to legacy `executeAck`. Implementation must guarantee an ack id is in **exactly one** of the two sets, never both, by routing all new id allocations through the new path when called from `SocketTimedEmitter`, and through the legacy path when called from `OnAckCallback`. Both paths share the same `currentAck` counter on `SocketIOClient` so id uniqueness is preserved.
- `Source/SocketIO/Client/SocketIOClient.swift:handleAck` — try `executeTimedAck` first; on miss, dispatch to legacy `executeAck` (existing behavior).
- `Source/SocketIO/Client/SocketIOClient.swift:didDisconnect` (around line 330) — call `ackHandlers.clearTimedAcks(reason: .disconnected)` so outstanding timed-ack closures don't leak across the disconnect. JS-aligned: `socket.ts:855-893` `_clearAcks` fires `withError` callbacks with the disconnect Error on `onclose`.
- `Source/SocketIO/Client/SocketIOClient.swift:clearRecoveryState` (around line 225) — same call (`reason: .disconnected`) to clear timed acks on identity swap.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — `timeout(after:)` protocol requirement + default impl `func timeout(after seconds: Double) -> SocketTimedEmitter { SocketTimedEmitter(socket: self, timeout: seconds) }`. The emitter stores `SocketIOClientSpec` (not the concrete class), so the default impl works against any conformer; concrete operations on the emitter (`emit`) are dispatched through the protocol's `emit`/`emitWithAck` requirements which conformers already implement.

The legacy `OnAckCallback` path is **not** modified; it does not delegate to the new internal. This keeps `OnAckCallback.timingOut(after: -1)` and `timingOut(after: 0)` semantics untouched.

**No outstanding-acks cap (JS-aligned).** JS does not impose a per-socket or per-manager limit; `this.acks` in `socket.io-client/lib/socket.ts` is unbounded. Per the "implementation must match JS" rule, Swift does not introduce a cap either. (A previous revision proposed a 10 000-entry cap with 80% warning; removed for JS parity. If profiling later shows real DoS exposure, this can be promoted from Out of Scope as an opt-in `SocketIOClientOption`.)

### Data flow
```
socket.timeout(after: 5).emit("e", x, ack: cb)
  → SocketTimedEmitter.emit
  → socket internal emit(..., ack: id) — new ack id registered via addTimedAck
  → SocketAckManager.addTimedAck(id, callback: cb, timeout: 5)
       - schedules DispatchWorkItem on handleQueue.asyncAfter(deadline: .now() + 5)
  → server ack arrives → handleAck → SocketAckManager.executeTimedAck(id, [...])
       - one-shot guard, cancels DispatchWorkItem, removes entry, calls cb(nil, [...])
  → OR timer fires first → DispatchWorkItem body
       - one-shot guard, removes entry, calls cb(.timeout, [])
```
Async overload wraps the callback in `withCheckedThrowingContinuation` + `withTaskCancellationHandler`. Cancellation handler calls a new `SocketAckManager.cancelTimedAck(_ id:)` that fires the continuation with `CancellationError` and removes the entry.

### Key decisions
- **Disconnected emit:** the current Swift code does not buffer outbound emits (`emit(_ data:[Any]...)` line 468 surfaces `.error` and returns). For the new timed-ack path, an emit issued while disconnected surfaces the same `.error` event. JS-aligned behavior for the ack callback: JS would register the callback in `this.acks` and let the timer eventually fire (or `_clearAcks` fire it on the never-arriving disconnect signal). Swift matches: register in `timedAcks`, schedule timer, let the timer fire `.timeout` naturally. **No special-case immediate fire.** (Test verifies callback fires after the timeout duration, not before.)
- **Volatile + timeout is unsupported as a chained API** (no `socket.volatile.timeout(ms).emit(...)` chain). JS reference also has no such chain — users who try `socket.volatile.emit("e", arg, cb)` get the JS bug of an orphaned callback. Swift documents this as unsupported and does not provide the chain.
- **Duplicate ack response from server:** JS silently drops the late ack via `typeof ack !== "function"` lookup miss after `delete this.acks[id]` (`socket.ts:863-866`). Swift matches: lookup in `timedAcks` after first execution removes the entry; subsequent lookup misses, debug-log "bad ack id", no callback re-fire.
- **All callbacks dispatched on `handleQueue`** via the `handleQueue.async { ... }` wrapping inside the four manager APIs.
- **Async cancellation:** `withTaskCancellationHandler` invokes `cancelTimedAck`; the continuation resumes throwing `CancellationError` immediately; ack registration is removed. The async overload result is delivered on `handleQueue` (the continuation's resume call hops there explicitly). This is a Swift-only addition required for sane Task cancellation; no JS counterpart.
- **No timeout-value validation (JS-aligned).** `seconds < 0` clamps to "fire on next tick"; `seconds == .infinity` saturates at `DispatchTime.distantFuture`; no precondition/rejection. Matches `socket.io-client/lib/socket.ts:239-249`.
- **Outstanding timed acks during identity swap (`clearRecoveryState`)** and on `didDisconnect`: all fire `.disconnected` and are cleared. JS-aligned per `socket.ts:855-893` `_clearAcks` firing `withError` callbacks with `new Error("socket has been disconnected")` on `onclose`. (Note: legacy `acks` storage is **not** cleared by Swift on disconnect — this matches JS, which only clears `withError`-wrapped callbacks. Bare ack callbacks are orphaned in JS and remain orphaned in Swift's legacy path.)

### Error handling
| Condition | Behavior |
|---|---|
| Server acks within timeout | `cb(nil, data)` |
| Timeout elapses, no ack | `cb(.timeout, [])` |
| Late server ack arrives after timeout fired | Silently dropped; debug-log "bad ack id"; no double callback (JS-aligned per `socket.ts:863-866`) |
| Socket disconnects while waiting | `clearTimedAcks(reason: .disconnected)` fires all pending callbacks with `.disconnected` and removes them (JS-aligned per `socket.ts:855-893`) |
| `clearRecoveryState` called while waiting | Same as disconnect (`.disconnected`) |
| Reconnect mid-flight | Old ack id callbacks already cleared by the disconnect path; new emits register fresh ids |
| Emit issued while disconnected | `.error` event surfaced (existing Swift behavior); ack callback registered, timer scheduled, fires `.timeout` after duration (JS-aligned — no special-case immediate fire) |
| `seconds < 0` | Treated as 0 — fires on next `handleQueue` tick (JS-aligned) |
| `seconds == .infinity` or very large | Saturates at `DispatchTime.distantFuture` — effectively no-timer (JS-aligned) |

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "Acknowledgements" + "timeout":
  - `should add the ack as the last argument`
  - `should fire the callback when the server acks`
  - `should timeout when the server does not ack` — JS provides `Error` with `message: "operation has timed out"`; Swift uses `SocketAckError.timeout`.
  - `should still call the callback after the timeout` — late ack does not re-fire.
- **JS-parity (implementation match required):**
  - `socket.timeout(after: 1).emit("ping") { err, data in ... }` server `(cb) => cb("pong")` → `cb(nil, ["pong"])` within 1 s.
  - Server never acks → `cb(.timeout, [])` after 1 s.
  - Late server ack after timeout → callback **not** re-invoked (JS silently drops).
  - Multi-arg ack `cb("a", "b", 1)` → `cb(nil, ["a", "b", 1])`.
  - `timeout(after: 0)` → fires on next tick (JS parity — `setTimeout(_, 0)` schedules next tick).
  - `timeout(after: -1)` → fires on next tick (JS parity — `setTimeout(_, -1)` clamped to 0).
  - `timeout(after: .infinity)` → no timer effectively fires (JS parity — clamped to far future).
  - **Disconnected emit:** issuing `socket.timeout(after: 1).emit("ping", ack: cb)` while `status != .connected` → `.error` event surfaced (existing Swift behavior); `cb(.timeout, [])` fires after 1 s (NOT immediately — matches JS letting the timer run).
  - **Disconnect mid-wait:** issue timed emit while connected, then call `socket.disconnect()` before server acks → `clearTimedAcks(reason: .disconnected)` fires `cb(.disconnected, [])` immediately. JS-aligned (`socket.ts:_clearAcks` for `withError` callbacks).
  - Reconnect after disconnect-mid-wait → previous ack ids cleared; new emits register fresh ids; previous cb not re-fired.
  - Reserved name `timeout(after: 1).emit("connect", ...)` triggers Phase 2 reserved guard.
  - v2 manager: identical semantics.
  - Namespace `/admin` timed emit does not affect `/` ack manager (separate `SocketAckManager` per `SocketIOClient`).
- **Swift-only (tests can be stricter than JS):**
  - Async overload `let r = try await socket.timeout(after: 1).emit("ping")` — same observable result; `do/catch SocketAckError.timeout` for timer; `do/catch SocketAckError.disconnected` for disconnect-mid-wait.
  - Async cancellation via `Task { ... }.cancel()` before ack arrives → throws `CancellationError`; ack registration cleared (verify `timedAcks.count == 0` after cancellation). Swift-only — no JS equivalent.
  - Async overload from `@MainActor` context — completion delivered on `handleQueue`; no actor-isolation violation. Verified via `dispatch_specific` key inside the result-hop closure.
  - 100 concurrent timed emits — ack ids unique; no cross-talk.
  - Race: timer firing instant exactly as server ack arrives — first fire wins; the other becomes a `cancelTimedAck`/lookup-miss no-op (one-shot guard).
  - Identity swap (`clearRecoveryState` + new auth) clears outstanding timed acks via `clearTimedAcks(reason: .disconnected)` (verified by capturing all callback invocations during the swap).
  - **Storage isolation (Swift-side correctness check beyond JS):** legacy `emitWithAck(...).timingOut(after: 1) { data in }` and new `socket.timeout(after: 1).emit(...) { err, data in }` issued back-to-back share no storage; verify `acks.count` and `timedAcks.count` independently after each registration and after each completion.
  - **Queue affinity (Swift-side):** `Task.cancel()` triggered from `@MainActor` while `didDisconnect` fires from a background context — both reach `cancelTimedAck` / `clearTimedAcks` which dispatch via `handleQueue.async`; no crash, no double callback, `timedAcks.count == 0` after both settle.
  - Memory: 1000 timeout/ack cycles → both `acks` and `timedAcks` cleaned; no leak (Instruments / `weak` reference assertion).

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
- Each phase that adds public API surface earns a minor bump on merge (Phases 1, 3, 4, 5, 6, 7, 8, 9). Phase 2 ships as a patch bump (guard-only logging; no new public symbol).
- No `major` bump; no `breaking` changelog entries permitted in this design's scope.

## Out of Scope (Tracked for Future)

- Pluggable parser interface (msgpack-parser).
- WebTransport transport.
- Engine-layer events (`drain`, `packet`, `packetCreate`).
- `disconnect` reason as structured object (currently `String`).
- Packet-level `{ retries }` policy.
- Typed-events helper.
- **Outbound emit buffering** while disconnected. Current Swift drops disconnected emits with a `.error` event; JS reference buffers them. Adding an outbound buffer is a behavior change with replay/duplication implications and is out of scope for this round (would require its own design pass).
- **Atomic `socket.resetIdentity(authProvider:)` API.** A security reviewer recommended a single primitive replacing the documented `disconnect + clearRecoveryState + clearAuth + setAuth + connect` sequence. Deferred: in this revision, no Swift-side idempotency token is added (per the "implementation must match JS" rule), so the rationale rests on the existing JS-equivalent invariants — single-queue access on `handleQueue`, no outbound buffer to mis-route. If a concrete race surfaces in practice, promote to its own phase.
- **Adoption of strict Swift concurrency** (`Sendable`, actors, `@MainActor`). New async overloads in Phases 8 and 9 are added without adopting strict concurrency; the project's existing GCD-based threading model is preserved.
- **Manager-level auth** (vs Socket-level) — JS reference does not expose `auth` on `Manager`, only on `Socket`. No gap exists.
- **`recovered` vs `wasRecovered` naming reconciliation** — Swift already uses `recovered` (matches JS); no rename needed.
- **Outstanding-acks cap as opt-in `SocketIOClientOption.ackOverflowPolicy(.reject | .warn)`.** JS reference is unbounded; Swift matches. If profiling later shows DoS exposure for a real consumer, this can become an opt-in configuration in a follow-up phase.
- **Auth provider deadline as opt-in `setAuthDeadline(_:)`.** JS reference has no Socket-layer deadline; Swift matches. If a real consumer needs timeout protection beyond `connect(timeoutAfter:)`, this can become an opt-in API in a follow-up phase.
- **Logger redaction layer for auth payloads.** JS reference does not redact in `debug` output; Swift matches. Consumers who require redaction can implement a custom `SocketLogger` conformer that masks payload content; the existing logger plug-in surface supports this.

## Reviewer Pushback Notes

Findings raised during review that were considered and **not** acted on, with rationale. The "implementation must match JS reference" rule (added during round-2 review) is the determining factor for several of these.

- **"v2 manager auth contradiction"** (pr-review round 1): claim was that the existing `connectSocket` sends payload on v2. Verification (`SocketManager.swift:225`) shows the JSON-payload branch is gated by `version.rawValue >= 3` — v2 already drops payloads. Phase 8 "v2 = no-op + warning" matches existing behavior. No spec change.
- **"Phase 3 status-race test is padding"** (pr-review round 1): the test asserts the `active` getter is safe under the documented single-queue contract. Kept.
- **"Phase 6 empty-`send()` test is padding"** (pr-review round 1): the test verifies the variadic→`emit("message")` zero-arg path produces a valid wire packet. Kept.
- **"Manager-level auth missing from Out of Scope"** (pr-review round 1): JS reference does not expose Manager-level auth. Listed in Out of Scope.
- **"`recovered` vs `wasRecovered` mismatch"** (pr-review round 1): both Swift and JS already use `recovered`. No mismatch.
- **"Phase 1 should not rely on doc-only for the `autoConnect` JS/Swift default inversion"** (pr-review round 1): rejected. Default `false` preserves bit-identical legacy Swift behavior; the only behavior change is opt-in `true`. Doc-only is the right ceiling because there is no current behavior to "warn about." A debug log on every `init` would be noise.
- **"Add `setAuthDeadline(_:)` with default 10 s"** (security round 1): rejected per JS-parity rule. JS reference imposes no Socket-layer auth deadline (`socket.io-client/lib/socket.ts:686-707`). A Swift-side deadline would diverge without justification. Use `connect(timeoutAfter:)` for timeout protection.
- **"Add 10 000 outstanding-acks cap with 80% warning"** (security + pr-review round 1): rejected per JS-parity rule. JS `this.acks` is unbounded. The cap was also flagged as a legitimate-traffic DoS surface (a buggy SDK could saturate it and silently break host emits). Removed; tracked as future opt-in.
- **"Add `precondition` rejecting `< 0`, `.infinity`, `> 3600` on `socket.timeout(after:)`"** (multiple round 1): rejected per JS-parity rule. JS passes all values straight to `setTimeout` with no validation; negative clamps to 0 (next tick), `Infinity` saturates. Swift matches.
- **"Add idempotency token to dedupe multi-callback auth provider invocations"** (security + codex round 1): rejected per JS-parity rule (added in round-2 user clarification: implementation must match JS exactly). JS does not deduplicate; calling `cb` twice sends two CONNECT packets. Swift matches. Test asserts JS-parity (server receives two CONNECTs).
- **"Add Logger redaction contract for auth payloads"** (security round 1): rejected per JS-parity rule. JS does not redact in `debug` output. Swift matches. Consumers who need redaction can implement a custom `SocketLogger` conformer.
- **"Outgoing catch-all listener fires before connected-state guard so disconnected emits are observed"** (round 1, my own original design): rejected per JS verification — JS fires `notifyOutgoingListeners` AFTER the connected check, only on actual send (`socket.io-client/lib/socket.ts:234-239`). Spec corrected.
- **"Volatile drop still fires outgoing listener"** (round 1, my own original design): rejected per JS verification — JS `discardPacket` branch returns BEFORE `notifyOutgoingListeners` (`socket.ts:230-232`). Volatile drop does not fire outgoing. Spec corrected.
