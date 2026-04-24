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

| # | Phase | Risk | Hard Deps | Notes |
|---|---|---|---|---|
| 1 | `.autoConnect(Bool)` config | low | — | Default `false` (preserves current behavior). |
| 2 | Reserved event name guard | low | — | Additive: DEBUG assert + release log; emit still proceeds. Guard installed in internal `emit(_ data:[Any]...)` so it covers `SocketRawView.emit` too. |
| 3 | `socket.active` property | low | — | Derived getter; reads `status` and `manager.reconnecting`. |
| 4 | `onAny` family completion (add/prepend/remove/list) | medium | — | New multi-listener storage on concrete `SocketIOClient` only. |
| 5 | `onAnyOutgoing` family | medium | 2 | Hooks the same internal `emit` path Phase 2 instruments. Concrete class only. |
| 6 | `socket.send()` / `"message"` | low | — | Thin wrappers over `emit("message", ...)`. |
| 7 | `socket.volatile.emit(...)` | medium | 5 | Outgoing listener invariant ("fires before drop") requires Phase 5. |
| 8 | `auth` function form | high | — | Async-callback provider invoked per connect/reconnect. Provider gating moves into `_engineDidOpen`. |
| 9 | `socket.timeout(after:).emit(..., ack:)` per-emit ack + err-first | high | 2 | Reserved guard interaction; otherwise independent. Could ship after Phase 2 if customer demand dictates. |

Phase 9 is sequenced last by **preference** (highest implementation complexity), not technical dependency — only Phase 2 is a hard prerequisite. Re-ordering is allowed.

## Cross-cutting Constraints

- **Compatibility:** No public type/method removed or renamed. All new methods are additive on the concrete `SocketIOClient` / `SocketManager` classes. New requirements added to the public protocol `SocketIOClientSpec` are a source-breaking change for third-party conformers (they must implement the new requirement). To stay strictly additive, new methods that depend on private storage on `SocketIOClient` (Phases 4, 5) are added on the concrete class **only**, not on the protocol. Phases that *can* ship a meaningful default impl (Phase 3 derived getter, Phase 6 thin wrapper, Phase 8 `setAuth`/`clearAuth` no-op, Phase 9 `timeout(after:)` returning a no-op `SocketTimedEmitter`) extend the protocol with default impls.
- **Threading:** The library is documented as not thread-safe — all calls must originate on `handleQueue`. New APIs preserve this contract; async/callback overloads explicitly hop results back to `handleQueue` before invoking user code.
- **Logging:** New code uses `DefaultSocketLogger.Logger` for parity with existing layers. **Auth payloads are never logged** — see Phase 8 redaction contract.
- **Versioning:** Patch/minor release on v16 line. CHANGELOG entry per phase. Protocol-additive phases (3, 6, 8, 9) call out source-compat impact in their CHANGELOG entry.
- **Test parity:** Every phase test plan enumerates JS reference tests by name and ports them. Each phase additionally lists Swift-only stricter edge cases (concurrency, identity swap, reconnection mid-flight, oversized data, namespace isolation, v2/v3 protocol parity).
- **Concurrency posture:** Codebase has zero existing `Sendable` / `actor` / `async` adoption. New async overloads are added without `@Sendable` annotations on closures that capture non-`Sendable` types like `[String: Any]`; they internally hop to `handleQueue` and use `withTaskCancellationHandler` where cancellation is meaningful (Phase 9). Adoption of strict concurrency is out-of-scope.
- **No new third-party dependencies** introduced in any phase.

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
public extension SocketIOClientSpec {
    var active: Bool { get }
}
```
Default impl on protocol:
```swift
var active: Bool {
    if status == .connected || status == .connecting { return true }
    return manager?.reconnecting == true
}
```
Reconnect state lives on `SocketManager.reconnecting: Bool` (internal flag) — `SocketIOStatus` has no `.reconnecting` case, so we read the manager flag directly. If `SocketManager.reconnecting` is `internal`, expose a `public var reconnecting: Bool { get }` accessor on `SocketManagerSpec` as part of this phase.

### Components touched
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — new requirement + default implementation.
- `Source/SocketIO/Manager/SocketManagerSpec.swift` — expose `reconnecting: Bool` getter (if not already public).
- `Source/SocketIO/Manager/SocketManager.swift` — make `reconnecting` storage backed by a public getter (the setter stays internal).

### Data flow
Pure derived getter. Reads existing `status` and `manager?.reconnecting`.

### Error handling
None.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "active" segment — `active === true` when connecting/connected/reconnecting; `false` after `socket.disconnect()`.
- **Swift-only:**
  - `init` (no connect) → `active == false`.
  - `connect()` then `engineDidOpen` → `active == true`.
  - User-initiated `disconnect()` → `active == false`.
  - Manager `tryReconnect` in flight (synthetic — set `manager.reconnecting = true` via test hook) → `active == true`.
  - `clearRecoveryState()` does not affect `active`.
  - Multiple namespaces: each socket's `active` independent (disconnecting `/admin` does not affect `/`).
  - Doc-comment / API surface verifies that `socket.active` and `socket.status.active` are documented as distinct.

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
- `Source/SocketIO/Client/SocketIOClient.swift:emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, completion:)` (around line 454) — extract event name (`data[0]`) and remaining items, fire outgoing listeners (snapshot) **after** Phase 2's reserved guard but **before** the existing `status == .connected` guard. This ordering means listeners observe outbound emit attempts even when the emit is rejected for being disconnected (matches JS, where outgoing catch-all fires before send-or-drop branches).
- **No additions to `SocketIOClientSpec`.** Same rationale as Phase 4 — concrete-class only.

### Data flow
`emit(event, items)` → reserved guard (Phase 2) → outgoing listeners (always, snapshot) → existing `status == .connected` guard → packet build → `engine.send`.

### Key decisions
- Outgoing listeners fire **before** packet construction (JS-aligned) and **before** the connected-state guard. Listeners therefore observe attempted emits that the existing code rejects with `.error` (e.g., emitting while disconnected on a non-volatile path).
- Ack response emits (`emitAck`, identified by `isAck == true`) do **not** trigger outgoing listeners (JS-aligned).
- The current Swift code does **not** buffer outbound emits while disconnected — `SocketManager.waitingPackets` is the inbound binary-reassembly buffer, not an outbound queue. Disconnected non-volatile emits surface a `.error` to user code today; that behavior is preserved. Outgoing listeners fire once at the call site, regardless of whether the emit reaches the wire.
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
  - Disconnected-emit case: outgoing fires at the call site even though the existing code surfaces a `.error` and never reaches the wire. No buffering, no re-fire on reconnect.
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
- Otherwise → drop. (No outbound buffer exists in the current code; non-volatile disconnected emits already drop with a `.error` event. Volatile drop differs by suppressing the `.error` event — that is the user-visible distinction.)
- Outgoing catch-all listener (Phase 5) **still fires** before drop check (JS-aligned). See **Observability caveat** below.

### Observability caveat (additive but documentation-relevant)
Outgoing catch-all listeners (Phase 5) are commonly attached for analytics, audit, or debug logging. Volatile drops still pass through these listeners — the packet never reaches the network, but it does reach every outgoing listener including any third-party SDK the host app integrated. Apps relying on `volatile` to suppress observation must understand: only the network send is suppressed. README and Phase 7 inline doc-comment must call this out explicitly.

### Components touched
- New file `Source/SocketIO/Client/SocketVolatileEmitter.swift`.
- `Source/SocketIO/Client/SocketIOClient.swift` — `var volatile` getter (one-line extension).
- `Source/SocketIO/Client/SocketIOClient.swift` — internal `emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, volatile: Bool = false, completion:)` adds new parameter (default `false` for back-compat). The internal funnel is `internal`, not `private`, and is reached by every emit path (`emit`, `emitWithAck`, `SocketRawView.emit`); audit all in-module call sites for the new default-argument behavior. Inside `emit`: if `volatile && status != .connected`, fire outgoing listeners (Phase 5), suppress the `.error` event the non-volatile path would emit, log debug + return.

### Data flow
```
volatile.emit(event, items)
  → socket.emit(... volatile: true)
  → reserved guard (Phase 2)
  → outgoing listeners (Phase 5, always fire)
  → if volatile && !connected: log + drop + return  (no .error event surfaced)
  → if !volatile && !connected: existing .error event path (unchanged)
  → packet build → engine.send
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
  - During reconnect (manager `reconnecting == true`) → volatile drops.
  - User-initiated `disconnect()` → volatile drops.
  - Volatile drop still fires outgoing listener (Phase 5).
  - Volatile drop still passes through reserved guard (Phase 2).
  - Volatile drop does **not** surface a `.error` client-event (this is the differentiating behavior vs non-volatile disconnected emits).
  - v2 + v3 manager parity.
  - Namespace `/admin` volatile drop does not affect `/` (no shared queue exists, but verify no cross-namespace state mutated).
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
    /// Install a callback-form auth provider. Invoked on `handleQueue` for every
    /// CONNECT (initial + every reconnect attempt). The callback must be invoked
    /// exactly once per invocation; subsequent calls are ignored.
    func setAuth(_ provider: @escaping SocketAuthProvider)

    /// Remove the installed provider. After clearing, subsequent CONNECT attempts
    /// fall back to the static `connect(withPayload:)` payload (or no auth).
    func clearAuth()

    /// Async variant. The closure is *not* annotated `@Sendable` because
    /// `[String: Any]` is not `Sendable`; the closure is invoked from a
    /// `Task { ... }` retained by the socket and the result is hopped back to
    /// `handleQueue` before being delivered to the internal flow.
    func setAuth(_ provider: @escaping () async throws -> [String: Any]?)

    /// Configure how long to wait for a provider callback before treating the
    /// CONNECT as failed. Default 10 seconds. Applied per-attempt independent of
    /// `connect(timeoutAfter:)`. Pass `0` to disable (not recommended).
    func setAuthDeadline(_ seconds: Double)
}
```
Static `connect(withPayload:)` is preserved. When a provider is installed, the provider takes precedence and the static payload is ignored (logged once per socket lifetime, not per attempt, to avoid log spam).

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift`
  - new `private var authProvider: SocketAuthProvider?`
  - new `private var authDeadline: Double = 10.0`
  - new `private var pendingAuthAttemptToken: UUID?` — idempotency token for the current in-flight provider invocation; `clearAuth()` and `disconnect()` invalidate it so late callbacks become no-ops.
  - public `setAuth` / `clearAuth` / `setAuthDeadline` (callback and async overloads).
  - new internal hook `resolveConnectPayload(explicit:completion:)` — given the optional static payload, either calls completion immediately (no provider) or invokes the provider and forwards its result (or fires the deadline path).
- `Source/SocketIO/Manager/SocketManager.swift`
  - **Move provider gating into `_engineDidOpen`** (around `SocketManager.swift:387-403`), which is the actual site that dispatches the CONNECT packet for each namespaced socket. The `SocketIOClient.connect()` → `joinNamespace` → `connectSocket` path only buffers a payload into `pendingConnectPayloads` while the engine is still opening; CONNECT writes happen later from `_engineDidOpen`.
  - In `_engineDidOpen`, before calling `connectSocket(socket, withPayload: consumePendingConnectPayload(for: socket))`, call `socket.resolveConnectPayload(explicit: pending) { resolved in self.connectSocket(socket, withPayload: resolved) }`.
  - On `tryReconnect` → `_tryReconnect` → `connect()`, the same `_engineDidOpen` re-fires; provider is naturally re-invoked per attempt.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — four protocol requirements with default no-op implementations (defaults are safe: a conformer that doesn't implement `setAuth` simply has no provider; the static payload path continues to work).

### Data flow (provider mode)
```
connect() (or tryReconnect → connect)
  → status = .connecting
  → engine.connect (transport)
  → engine open → manager._engineDidOpen
  → for each socket in nsps:
       socket.resolveConnectPayload(explicit: pending) { resolved in
         manager.connectSocket(socket, withPayload: resolved)
       }
  → resolveConnectPayload internals (provider mode):
       - generate new UUID, store as pendingAuthAttemptToken
       - dispatch provider on handleQueue (sync or async wrapper)
       - schedule deadline timer (handleQueue.asyncAfter(authDeadline))
       - on first callback (provider's or deadline's, whichever wins):
           - check pendingAuthAttemptToken still matches → if not, drop
           - clear pendingAuthAttemptToken
           - if deadline won: fire .error, do NOT send CONNECT, set status to .disconnected
           - if provider won: completion(resolved payload)
```

### Key decisions
- Provider callback dispatched on `handleQueue`.
- **Provider has a default 10 s deadline** (independent of `connect(timeoutAfter:)`). Without this, a hanging provider leaves the socket stuck in `.connecting` forever even when the user-facing `connect()` (no-timeout) overload is used. The deadline is per-attempt; on reconnect the provider gets a fresh deadline. Configurable via `setAuthDeadline(_:)`; `0` disables.
- Synchronous provider callback is allowed (`{ cb in cb([:]) }`).
- Async overload runs the closure in `Task { ... }` retained by the socket; the result is hopped back to `handleQueue`. Errors from the async provider map to deadline behavior (`.error` + abort connect — fail-closed). The closure is **not** `@Sendable`-annotated; reasoning above. The retained `Task` is cancelled when the socket disconnects, when `clearAuth` is called, or when the deadline fires.
- Coexistence: when both `withPayload` and `setAuth` are used, provider wins; one-time logged warning per socket lifetime (tracked via `private var didWarnAboutCoexistence: Bool`).
- **Identity-swap convention** is preserved as the documented pattern: `socket.disconnect(); socket.clearRecoveryState(); socket.clearAuth(); socket.setAuth(newProvider); socket.connect()`. All five calls run synchronously on `handleQueue` so they cannot interleave with manager callbacks. (Reviewer requested an atomic `resetIdentity(authProvider:)` API; deferred to Out of Scope pending evidence of a real interleave path — see Reviewer Pushback Notes below.)
- **v2 manager:** the v2 path in `SocketManager.connectSocket` (gated by `version.rawValue >= 3` around line 225) drops payloads on the floor today. Provider-mode `setAuth` is therefore a v3-only feature; on v2 managers, calling `setAuth` logs a warning at install time and the provider is never invoked. This matches today's behavior of static payloads on v2 (also dropped).

### Logging redaction contract (security)
- The auth dictionary returned by the provider is **never** passed to `DefaultSocketLogger.Logger`.
- The CONNECT packet construction site (`SocketManager.swift:256` region — `engine.send("0\(socket.nsp),\(payloadStr)", ...)` and the corresponding `Logger.log("Emitting: \(str), Ack: ...")` calls) must redact the JSON body for CONNECT packets specifically. Implementation: at the logging call site, if the packet is a CONNECT (type 0) with a non-empty payload, log `"0<nsp>,<redacted>"` instead of the raw payload string.
- `assertionFailure` and `Logger.error` messages added by this phase MUST NOT include the resolved payload, key names, or any value from it.
- Test assertion: capture logger transcript during a connect with a provider returning `["token": "abc"]`; assert the transcript contains no occurrence of `"abc"` or `"token"`.

### Error handling
- Provider returns `nil` → CONNECT sent without auth (treated as anonymous connect).
- Provider never invokes callback → deadline timer fires → `.error` event surfaced, CONNECT not sent, status returns to `.disconnected`, idempotency token invalidated.
- Provider invokes callback multiple times → only first call is honored (idempotency token check); subsequent calls dropped silently.
- Provider invokes callback after socket disconnect or after `clearAuth` → idempotency token mismatch → drop.
- Async provider throws → treated as deadline failure (`.error` + abort connect, fail-closed).

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "auth attribute" + "connection-state-recovery" (auth path):
  - `should send auth payload` (static)
  - `should support function auth attribute` (provider form)
  - `should re-send auth on reconnection` (provider re-invoked)
  - provider returns empty → server receives no auth
- **Swift-only:**
  - `setAuth { cb in cb(["token": "abc"]) }` → server `connection.handshake.auth == {token: "abc"}`.
  - Forced reconnect → provider re-invoked (counter assertion verifies one invocation per attempt).
  - Async overload `setAuth { try await fetchToken() }` → equivalent behavior; throws → `.error` event + abort.
  - `clearAuth` then reconnect → no auth payload.
  - Provider executes on `handleQueue` (verified via `dispatch_specific` key).
  - Provider callback invoked twice → second invocation silently ignored; server receives one CONNECT.
  - Provider never callbacks → after `setAuthDeadline(1)` and `connect()` (no `timeoutAfter`) → after 1 s, `.error` event fires, status `.disconnected`, no CONNECT on the wire.
  - Provider callback racing with user `disconnect()` — disconnected socket invalidates idempotency token; CONNECT not sent even if callback arrives later.
  - Identity-swap sequence (disconnect + clearRecoveryState + clearAuth + setAuth + connect) → fresh token used; recovery state not reused; outstanding timed acks (Phase 9) cleared.
  - Multiple namespaces on shared manager: each socket's auth provider independent.
  - `connect(withPayload: ["x": 1])` then `setAuth(...)` → provider wins; one logged warning per socket (verify second `connect` cycle does not re-warn).
  - **Logger redaction:** capture transcript across full connect cycle with provider returning `["token": "secret123"]`; assert transcript contains no `"secret123"` and no `"token"`.
  - **Deadline:** `setAuthDeadline(0.1)` + provider that delays 1 s → after 0.1 s, `.error` fires; provider's late callback is dropped.
  - **Async cancellation:** `setAuth(asyncProvider)` then `disconnect()` mid-fetch → retained `Task` is cancelled; no CONNECT, no crash, no late callback.
  - v2 manager: `setAuth` logs warning at install time; provider is never invoked across the lifetime of the manager.

---

## Phase 9 — `socket.timeout(after:).emit(..., ack:)` per-emit ack + err-first

### Why
Highest-value gap. Existing `emitWithAck().timingOut()` signals timeout via the magic string `SocketAckStatus.noAck`, which is weakly typed and easy to miss.

### API
```swift
public enum SocketAckError: Error, Equatable {
    case timeout
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
- `Source/SocketIO/Client/SocketIOClient.swift` — `timeout(after:) -> SocketTimedEmitter` (one-line extension); `didDisconnect` updated to clear timed acks (see below).
- `Source/SocketIO/Ack/SocketAckManager.swift` — **parallel storage** alongside the existing `Set<SocketAck>`:
  - existing `acks: Set<SocketAck>` (callback type `AckCallback = ([Any]) -> ()`, line 73 region) — untouched. Legacy `OnAckCallback.timingOut(after:)` continues to use this storage.
  - new `timedAcks: [Int: TimedAckEntry]` keyed by ack id, where `TimedAckEntry` wraps `(Error?, [Any]) -> Void`, the scheduled `DispatchWorkItem`, and a one-shot `fired` flag.
  - new internal API `addTimedAck(_ id: Int, callback: @escaping (Error?, [Any]) -> Void, timeout: Double)` — registers, schedules timer, returns immediately.
  - new internal API `executeTimedAck(_ id: Int, with items: [Any])` — called from `handleAck` alongside the legacy `executeAck`. Idempotent: only first invocation per id fires the callback and cancels the timer.
  - new internal API `clearTimedAcks(reason: SocketAckError)` — fires all outstanding callbacks with the given error and clears storage. Called from `SocketIOClient.didDisconnect` and `clearRecoveryState`.
  - `handleAck` lookup attempts `timedAcks` first; on miss falls back to the legacy `acks` path (or vice versa — implementation must guarantee an ack id is in exactly one of the two sets, never both).
- `Source/SocketIO/Client/SocketIOClient.swift:handleAck` — try `executeTimedAck` first; on miss, dispatch to legacy `executeAck` (existing behavior).
- `Source/SocketIO/Client/SocketIOClient.swift:didDisconnect` (line 336 region) — call `ackHandlers.clearTimedAcks(reason: .timeout)` so outstanding timed-ack closures don't leak across the disconnect.
- `Source/SocketIO/Client/SocketIOClient.swift:clearRecoveryState` (line 231 region) — same call to clear timed acks on identity swap.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — `timeout(after:)` protocol requirement + default impl that returns a `SocketTimedEmitter` wrapping the conformer.

The legacy `OnAckCallback` path is **not** modified; it does not delegate to the new internal. This keeps `OnAckCallback.timingOut(after: -1)` and `timingOut(after: 0)` semantics untouched (no precondition crash, no behavioral surprise for existing callers).

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
- **Disconnected emit:** the current Swift code does not buffer outbound emits (`emit(_ data:[Any]...)` line 468 surfaces `.error` and returns). For the new timed-ack path, an emit issued while disconnected surfaces the same `.error` event AND immediately fires the callback with `.timeout` (no point waiting for an ack that can never arrive). Documented in the error-handling table below.
- **Volatile + timeout is unsupported** (no `volatile.timeout` API). Documented.
- **Duplicate ack response** (defensive): only first response honored; subsequent ignored with warning log.
- **All callbacks dispatched on `handleQueue`.**
- **Async cancellation:** `withTaskCancellationHandler` invokes `cancelTimedAck`; the continuation resumes throwing `CancellationError` immediately; ack registration is removed (no leak). The async overload result is delivered on `handleQueue` (the continuation's resume call hops there explicitly).
- **Timeout value validation:** the new `SocketTimedEmitter` enforces `seconds >= 0 && seconds < 3600` via `precondition`. `0` means "fire immediately" (matches JS `timeout(0)`). `.infinity` and very large values are rejected to bound resource retention. The legacy `OnAckCallback.timingOut(after:)` is **not** changed and continues to accept arbitrary `Double` (back-compat).
- **Outstanding-ack cap:** soft cap of `10_000` outstanding timed acks per socket. At 80% (`8_000`) emit a `Logger.warning`; at the cap, new `addTimedAck` calls fire the callback immediately with `.timeout` and emit a `Logger.error`. Prevents pathological accumulation (DoS surface).
- **Outstanding timed acks during identity swap (`clearRecoveryState`)** and on `didDisconnect`: all fire `.timeout` and are cleared. Aligns with commit `3c2b5d7`'s recovery replacement logic.

### Error handling
| Condition | Behavior |
|---|---|
| Server acks within timeout | `cb(nil, data)` |
| Timeout elapses, no ack | `cb(.timeout, [])` |
| Late ack arrives after timeout fired | Ignored; no double callback |
| Socket disconnects while waiting | `clearTimedAcks(reason: .timeout)` fires all pending callbacks with `.timeout` and removes them |
| `clearRecoveryState` called while waiting | Same as disconnect |
| Reconnect mid-flight | Old ack id invalidated by the disconnect-clear; new emits register fresh ids |
| Emit issued while disconnected | `.error` event surfaced (existing behavior); callback fires `.timeout` immediately |
| `seconds < 0` or `seconds >= 3600` | `precondition` failure (debug + release) |
| Outstanding cap reached (10 000) | New emit's callback fires `.timeout` immediately; logged at error level |

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
  - **Disconnected emit:** issuing `socket.timeout(after: 1).emit("ping", ack: cb)` while `status != .connected` → `.error` event surfaced (existing behavior, preserved); `cb(.timeout, [])` fires immediately on the same dispatch tick. Server never receives the packet.
  - **Disconnect mid-wait:** issue timed emit while connected, then call `socket.disconnect()` before server acks → `clearTimedAcks` fires `cb(.timeout, [])`; subsequent reconnect + late server ack does nothing.
  - Async cancellation via `Task { ... }.cancel()` before ack arrives → throws `CancellationError`; ack registration cleared (verify `timedAcks.count == 0` after cancellation).
  - Async overload from `@MainActor` context — callback delivered on `handleQueue`; no actor isolation violation. Verified by reading `dispatch_specific` key inside the async result.
  - `timeout: .infinity` → `precondition` failure.
  - `timeout: -1` → `precondition` failure (new API only; legacy `OnAckCallback.timingOut(after: -1)` still accepted).
  - `timeout: 3600` → accepted; `timeout: 3600.0001` → `precondition` failure.
  - Reserved name `timeout(after: 1).emit("connect", ...)` triggers Phase 2 reserved guard.
  - Triggers outgoing catch-all listener (Phase 5) with correct event name.
  - v2 manager: identical semantics.
  - Namespace `/admin` timed emit does not affect `/` ack manager (separate `SocketAckManager` per `SocketIOClient`).
  - Identity swap (`clearRecoveryState` + new auth) clears outstanding timed acks via `clearTimedAcks(reason: .timeout)` (verified by capturing all callback invocations during the swap).
  - **Outstanding cap:** register 8 000 timed emits (no acks) → no warning; register 8 001st → `Logger.warning` captured; register 10 001st → callback fires `.timeout` immediately, `Logger.error` captured.
  - **Storage isolation:** legacy `emitWithAck(...).timingOut(after: 1) { data in }` and new `socket.timeout(after: 1).emit(...) { err, data in }` issued back-to-back share no storage; verify `acks.count` and `timedAcks.count` independently after each.
  - Memory: 1000 timeout/ack cycles → both `acks` and `timedAcks` cleaned; no leak (Instruments / `weak` reference assertion).
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
- **Atomic `socket.resetIdentity(authProvider:)` API.** A security reviewer recommended a single primitive replacing the documented `disconnect + clearRecoveryState + clearAuth + setAuth + connect` sequence. Deferred pending evidence of a real interleave path: all five calls run synchronously on `handleQueue`, no outbound buffer exists (so no in-flight packet to mis-attribute), and the codebase contract requires single-queue access. If a concrete race surfaces (e.g., a manager-driven reconnect callback racing the swap), promote this to its own phase.
- **Adoption of strict Swift concurrency** (`Sendable`, actors, `@MainActor`). New async overloads in Phases 8 and 9 are added without adopting strict concurrency; the project's existing GCD-based threading model is preserved.
- **Manager-level auth** (vs Socket-level) — JS reference does not expose `auth` on `Manager`, only on `Socket`. No gap exists.
- **`recovered` vs `wasRecovered` naming reconciliation** — Swift already uses `recovered` (matches JS); no rename needed.

## Reviewer Pushback Notes

Findings raised during review that were considered and **not** acted on, with rationale:

- **"v2 manager auth contradiction"** (pr-review): claim was that the existing `connectSocket` sends payload on v2. Verification (`SocketManager.swift:225`) shows the JSON-payload branch is gated by `version.rawValue >= 3` — v2 already drops payloads. The Phase 8 "v2 = no-op + warning" stance matches existing behavior. No spec change.
- **"Phase 3 status-race test is padding"** (pr-review): the test asserts the `active` getter is safe under the documented single-queue contract. It is a small but real regression target for the queue-safety invariant. Kept.
- **"Phase 6 empty-`send()` test is padding"** (pr-review): the test verifies the variadic→`emit("message")` zero-arg path produces a valid wire packet. Real regression target. Kept.
- **"Manager-level auth missing from Out of Scope"** (pr-review): JS reference does not expose Manager-level auth. No gap. Listed in Out of Scope above for clarity.
- **"`recovered` vs `wasRecovered` mismatch"** (pr-review): both Swift and JS already use `recovered`. No mismatch.
