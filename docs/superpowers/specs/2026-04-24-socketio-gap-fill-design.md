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
| 1 | `.autoConnect(Bool)` config | low | — | Default `false` (preserves current behavior). Auto-CONNECT only for `defaultSocket`; non-default namespaces still require `socket.connect()`. |
| 2 | Reserved event name guard | low | — | DEBUG `assertionFailure` + release `handleClientEvent(.error)` + early-return (no packet written). Guard installed in internal `emit(_ data:[Any]...)` so it covers `SocketRawView.emit` too. |
| 3 | `socket.active` property | low | — | Lifecycle Bool flipped at user `connect()`/`disconnect()` (matches JS `!!this.subs`). Concrete class only. |
| 4 | `onAny` family completion (add/prepend/remove/list) | medium | — | New multi-listener storage on concrete `SocketIOClient` only. Mutators serialize via `handleQueue.async`. |
| 5 | `onAnyOutgoing` family | medium | 2 | Hooks the same internal `emit` path Phase 2 instruments. Concrete class only. Mutators serialize via `handleQueue.async`. |
| 6 | `socket.send()` / `"message"` | low | — | Thin wrappers over `emit("message", ...)`. `sendWithAck.timingOut` retains legacy `SocketAckStatus.noAck` path; users wanting typed errors should use Phase 9 `socket.timeout(after:).emit(..., ack:)`. |
| 7 | `socket.volatile.emit(...)` | medium | — | Independent of Phases 4/5. Interaction with Phase 5 outgoing listeners specified (volatile drop does **not** fire them). Requires `SocketEngineSpec.writable` (option 1) or status-based fallback (option 2). |
| 8 | `auth` function form | high | — | Async-callback provider invoked per connect/reconnect. Provider gating in both CONNECT-write sites; `writeConnectPacket` raw writer breaks recursion; `authGeneration` token guards stale-callback race. |
| 9 | `socket.timeout(after:).emit(..., ack:)` per-emit ack + err-first | high | 2 | Reserved guard interaction; otherwise independent. Could ship after Phase 2 if customer demand dictates. |

Phase 9 is sequenced last by **preference** (highest implementation complexity), not technical dependency — only Phase 2 is a hard prerequisite. Re-ordering is allowed.

## Cross-cutting Constraints

- **Compatibility:** No public type/method removed or renamed. All new methods are additive on the concrete `SocketIOClient` / `SocketManager` classes. New requirements added to the public protocol `SocketIOClientSpec` are a source-breaking change for third-party conformers (they must implement the new requirement). To stay strictly additive, new methods that depend on private storage on `SocketIOClient` (Phases 3, 4, 5, 8) are added on the concrete class **only**, not on the protocol. Phases 6 (thin wrapper delegating to existing protocol methods) and 9 (`timeout(after:)` returning a `SocketTimedEmitter` that holds the conformer via the protocol type) ship default impls on the protocol. **Phase 8 `setAuth` / `clearAuth` are concrete-class-only — NOT added to `SocketIOClientSpec`.** A previous revision proposed `fatalError` protocol defaults, but a runtime trap on a previously-safe call site is more breaking than the protocol surface itself; concrete-class-only avoids the trap entirely and lets third-party conformers ignore the API without crashing.
- **Threading:** The library is documented as not thread-safe — all calls must originate on `handleQueue`. New APIs preserve this contract; async/callback overloads explicitly hop results back to `handleQueue` before invoking user code.
- **Logging:** New code uses `DefaultSocketLogger.Logger` for parity with existing layers. Auth payloads are **not** redacted in this design (JS-aligned — see Phase 8 "Logging" section). Consumers requiring redaction can implement a custom `SocketLogger` conformer.
- **Versioning:** Patch/minor release on v16 line. CHANGELOG entry per phase. Protocol-additive phases (3, 6, 8, 9) call out source-compat impact in their CHANGELOG entry.
- **Test parity:** Every phase test plan enumerates JS reference tests by name and ports them. Each phase additionally lists Swift-only stricter edge cases (concurrency, identity swap, reconnection mid-flight, oversized data, namespace isolation, v2/v3 protocol parity).
- **Concurrency posture:** Codebase has zero existing `Sendable` / `actor` / `async` adoption. New async overloads are added without `@Sendable` annotations on closures that capture non-`Sendable` types like `[String: Any]`; they internally hop to `handleQueue` and use `withTaskCancellationHandler` where cancellation is meaningful (Phase 9). Adoption of strict concurrency is out-of-scope.
- **No new third-party dependencies** introduced in any phase.
- **JS-divergence policy:** when this spec deviates from `socket.io-client` (JS) reference behavior, the divergence is explicitly justified inline. Categories of justified divergence in this design:
  1. **Swift-idiomatic mappings** of JS API constraints that cannot translate verbatim:
     - Phase 2 reserved-event guard: JS throws an Error from `emit()`; Swift cannot throw without breaking the existing emit signature, so the user-visible signal is `handleClientEvent(.error, ...)` (semantically equivalent — user code observes the violation; wire behavior is identical: no packet written).
     - Phase 9 `SocketAckError.timeout` / `.disconnected` enum cases map to JS's two distinct `Error.message` strings — same semantic distinction, more idiomatic.
     - Phase 4/5 catch-all listener handle is `UUID`-keyed (JS uses handler-reference equality; Swift closures lack identity).
  2. **Swift concurrency overloads** that have no JS counterpart and are pure additions:
     - Phase 8 `async throws` auth overload (JS `auth` is sync-callback only).
     - Phase 9 `async throws` ack overload (JS callback only).
     - Both add fail-closed throw paths that surface via `handleClientEvent(.error, ...)` or thrown error — no JS analog because JS doesn't await Promises in these positions.
  3. **Stricter Swift-only API constraints** (preventing API surfaces that JS allows but that have known bugs):
     - Phase 7: `socket.volatile.emit(...)` does NOT accept an ack callback. JS allows the chain (`socket.volatile.emit("e", arg, cb)`), but `_registerAckCallback` registers the callback before the discard check, so on drop the callback is orphaned. Swift refuses the API surface to prevent the orphan bug.
  4. **Preserved Swift legacy behaviors** that JS handles differently, kept for back-compat:
     - Phase 1 / Phase 5 / Phase 9: pre-connect (`status != .connected`) non-volatile emits surface `.error` clientEvent in Swift today; JS would buffer into `sendBuffer`. Outbound buffering is Out of Scope; existing Swift behavior preserved across all touched phases.
     - Phase 9 legacy `OnAckCallback.timingOut` path uses `SocketAckStatus.noAck` magic-string and is NOT cleared on disconnect (matches JS behavior where bare ack callbacks are also orphaned on disconnect — only `withError`-flagged callbacks are cleared via `_clearAcks`).
     - Phase 2 `SocketClientEvent` cases (`error`, `ping`, `pong`, `reconnect`, etc.) are NOT in the reserved set — only `connect, connect_error, disconnect, disconnecting` are reserved (matching JS client-side set, minus Node-only `newListener`/`removeListener`).
  5. **Swift-side error-channel additions where JS is silent** (project's "no silent failure" posture, applied only where the JS event would happen at all):
     - Phase 8 v2 manager + provider: per-CONNECT `handleClientEvent(.error, ...)` (JS has no v2/v3 split; the matrix is Swift-only).
     - Phase 8 async-throw: `handleClientEvent(.error, ...)` on async provider failure (JS has no async path).
     - Phase 8 late async-result drop: `Logger.log` diagnostic line (no equivalent JS race).

  Anything **not** in those five categories must match JS exactly. If a reviewer proposed a behavior we considered and rejected as JS-divergent without justification, it is recorded in **Reviewer Pushback Notes**.

- **Error-surface taxonomy.** Three distinct user-visible channels exist; phases must specify which channel fires for each error condition:
  1. **`DefaultSocketLogger.Logger.{log, error}`** — diagnostic only; not user-facing. Use for implementation traces, never as the sole signal for a user-actionable event.
  2. **`handleClientEvent(.error, data: [...], isInternalMessage: false)`** — user `.on(clientEvent: .error)` listeners fire. Use for any event the user must learn about asynchronously (auth failure, reserved-event violation, v2-bypass, etc.).
  3. **Per-emit ack callback** (Phase 9 only) — `cb(SocketAckError, [])`. Use only for ack-specific timeouts/disconnects affecting that specific emit.

  Each phase's "Error handling" section pins the channel for every condition.

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

### CONNECT-write coverage
There are **two** sites where a CONNECT packet (Socket.IO frame, distinct from the engine open) can be written:
1. `SocketManager.connect()` → engine open → `_engineDidOpen` (~`SocketManager.swift:405-419`) — fires CONNECT for every `nsps` socket already in `.connecting`.
2. `SocketIOClient.joinNamespace()` → `SocketManager.connectSocket(_:withPayload:)` (~`:208-257`) — fires CONNECT immediately for sockets created against an already-`.connected` manager (post-engine-open namespace joins).

`autoConnect:true` only triggers `SocketManager.connect()` — that is sufficient for the **default namespace `defaultSocket`**, which is created in `SocketManager.init` and reaches `_engineDidOpen` via path 1. Sockets the user creates via `manager.socket(forNamespace:)` after init still go through path 2 explicitly when the user later calls `socket.connect()`. **`autoConnect:true` does NOT auto-connect non-default namespace sockets** — they remain user-controlled, matching JS where `Manager.autoConnect` only opens the engine, not arbitrary namespaces.

If the user calls `manager.socket(forNamespace:)` BEFORE the engine completes its open and BEFORE calling `socket.connect()`, no CONNECT fires until the user calls `socket.connect()` — same as JS. Document this in Phase 1's API doc-comment to forestall confusion ("autoConnect opens the manager engine; namespaces still require `socket.connect()` unless you're using the default namespace which is auto-joined").

### Data flow
`init` → `setConfigs(config)` → if `autoConnect == true` → `connect()` → `addEngine` → `engine.connect` → engine open → `_engineDidOpen` → CONNECT for `defaultSocket`. Non-default namespaces created later still need explicit `socket.connect()`.

### Error handling
No new error paths. `connect()` failure modes unchanged (`engineDidError`).

**Pre-connect emit behavior (preserved, JS-divergent):** when `autoConnect:false` and the user calls `socket.emit(...)` before `socket.connect()`, the existing Swift behavior surfaces a `.error` clientEvent (the `status == .connected` guard fails). JS would buffer into `sendBuffer` and replay on connect. Spec preserves Swift's existing behavior — outbound buffering is out of scope (see Out of Scope section). Phase 1 doc-comment must mention this so users adopting `autoConnect:false` aren't surprised.

### Testing
- **JS-mirrored:** `socket.io-client/test/connection.ts` "should auto connect by default" — Swift inverts default; mirror by asserting that `[.autoConnect(true)]` reproduces the same auto-connect behavior for the default namespace.
- **Swift-only:**
  - `SocketManager(url, config: [])` → status `.notConnected` immediately after init.
  - `SocketManager(url, config: [.autoConnect(true)])` → status `.connecting` immediately after init.
  - `[.autoConnect(false), .forceNew(true)]` combined → no auto-connect, `forceNew` honored on later manual `connect()`.
  - **Default namespace auto-CONNECT:** `[.autoConnect(true)]` → after engine open, `defaultSocket.status == .connected` (CONNECT was sent via path 1).
  - **Non-default namespace NOT auto-CONNECTed:** `manager.socket(forNamespace: "/admin")` (no `socket.connect()` call) + `[.autoConnect(true)]` → after engine open, `/admin` socket stays `.notConnected` (path 2 only fires on explicit `socket.connect()`).
  - Pre-`connect()` emit under `autoConnect:false` → `.error` clientEvent fires (existing behavior preserved; documented).

---

## Phase 2 — Reserved event name guard

### API
Internal helper:
```swift
internal enum SocketReservedEvent {
    static let names: Set<String> = [
        "connect", "connect_error", "disconnect", "disconnecting"
    ]
}
```
JS-aligned: `socket.io-client/lib/socket.ts` (current `main` `RESERVED_EVENTS`) defines the client-side set as `connect, connect_error, disconnect, disconnecting, newListener, removeListener`. The Swift list keeps the first four — including `disconnecting`, which IS a client-side guard in JS (the `emit()` throw at `socket.ts` checks against the same set; `disconnecting` is not server-only as a previous revision claimed). The Swift list drops only `newListener`/`removeListener` (Node EventEmitter internals with no Swift equivalent). Other Swift `SocketClientEvent` cases (`error`, `ping`, `pong`, `reconnect`, `reconnectAttempt`, `statusChange`, `websocketUpgrade`) are **not** in the JS client-emit reserved set so they are not added here.

### Behavior (JS-aligned — early return; no packet written)
Inside the internal `emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, completion:)` (the single funnel that all public emit overloads, `emitWithAck`, and `SocketRawView.emit` route through):
- If `data.first as? String` ∈ reserved and `isAck == false`:
  1. `assertionFailure("\"\(event)\" is a reserved event name")` (DEBUG only — matches JS throw in dev surfaces).
  2. `handleClientEvent(.error, data: ["\"\(event)\" is a reserved event name"], isInternalMessage: false)` so user `.on(clientEvent: .error)` listeners observe the violation. JS surfaces this via thrown Error reaching the user's try/catch; Swift cannot throw without breaking emit signatures, so the equivalent user-visible signal is the `.error` clientEvent. (`DefaultSocketLogger.Logger` is a diagnostic channel only; not user-facing.)
  3. **Early return — no packet built, no `engine.send` call.** This matches JS where the throw aborts before any wire write.
- This is a strict equivalent of JS's "throw and abort" with the only divergence being the channel of user-visible signal (clientEvent vs thrown Error). Documented under JS-divergence policy as category 2 (Swift-idiomatic mapping of an unbreakable API constraint).

Installing the guard at the internal funnel rather than at the public `emit(_:with:completion:)` entry ensures `SocketRawView.emit` (which calls the internal funnel directly, bypassing the public entry) is also covered with no duplication.

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — internal `emit(_ data:[Any], ...)` (around line 454) calls new private helper `failIfReserved(_ event:) -> Bool` at the top of the function (BEFORE the `status == .connected` guard so the reserved check applies even pre-connect, matching JS where `emit()` throws regardless of connection state). If `true`, the funnel returns early.

### Data flow
internal emit entry → `failIfReserved` → (if reserved: assert/clientEvent + return) → existing `status == .connected` guard → packet build/send.

### Error handling
- DEBUG: `assertionFailure` (development-time loud failure, equivalent to JS throw in dev).
- Release: `handleClientEvent(.error, data:)` (user-visible) + early return.
- No packet written in either case — strict JS-parity on wire behavior.

### Testing
- **JS-mirrored:** `socket.io-client/test/socket.ts` "should throw on reserved event names" — Swift mirrors as: `.on(clientEvent: .error)` listener fires AND no packet observed on server side. The "throw" is replicated as the clientEvent surfacing path.
- **JS-parity (wire behavior must match):**
  - `emit("connect", "x")` → server receives **no** event packet (verify via E2E with server-side counter).
  - All four reserved names (`connect`, `connect_error`, `disconnect`, `disconnecting`) trigger the same — server receives no packet.
  - Reserved emit pre-connect (status `.notConnected`) still triggers guard — JS throws regardless of connection state.
- **Swift-only:**
  - Each reserved name: `.on(clientEvent: .error)` listener invoked once with the reserved-name message string.
  - `emitWithAck("connect", "x").timingOut(after: 1) { ... }` — guard fires; ack callback never invoked (no server interaction).
  - `SocketRawView.emit(["connect", "x"])` also triggers the guard (verifies guard placement at internal funnel).
  - Case sensitivity: `"Connect"`, `"CONNECT"` do **not** trigger.
  - Whitespace variants (`" connect"`) do **not** trigger.
  - Mixed sequence (reserved + normal) — reserved aborts; subsequent normal emit still flows.
  - Outbound ack frames (`emitAck` / `isAck == true`) do **not** trigger the guard even if their first item happens to be a reserved string.
  - v2 manager and v3 manager: behavior identical.
  - Non-default namespace (`/admin`): behavior identical.
  - DEBUG build: `assertionFailure` triggers (verified via XCTest debug-only path).
  - Release build (RELEASE configuration): no assertion crash; clientEvent + early-return path verified.

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
/// Count of currently-registered any-listeners (excludes the legacy `anyHandler`).
/// JS counterpart: `socket.listenersAny()` returns the handler array; Swift returns
/// just the count because closures lack identity (the `UUID` handle is the only
/// stable identifier we have, and exposing it as a list adds no JS-equivalent value).
public var anyListenerCount: Int { get }
```

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — new `private var anyListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []`; new methods.
- `Source/SocketIO/Client/SocketIOClient.swift:dispatchEvent(_:data:withAck:)` — after existing `anyHandler?(...)` call, iterate **snapshot** of `anyListeners` and invoke each.
- **Threading contract:** all four mutator methods (`addAnyListener`, `prependAnyListener`, `removeAnyListener`, `removeAllAnyListeners`) and the `anyListenerIds` getter wrap their work in `handleQueue.async { ... }`. Existing `on/off/onAny` mutate without queue assertions today, but the new APIs MUST serialize to avoid array-mutation races (the dispatch loop iterates a snapshot taken under `handleQueue`, so writes from off-queue would corrupt the array if not serialized). Add `dispatchPrecondition(condition: .onQueue(handleQueue))` inside `dispatchEvent`'s snapshot creation.
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
/// Count of currently-registered any-outgoing-listeners. Same JS-parity rationale
/// as Phase 4's `anyListenerCount` — JS `socket.listenersAnyOutgoing()` returns
/// the handler array; Swift returns count.
public var anyOutgoingListenerCount: Int { get }
```
No legacy single-value counterpart — direct multi-listener model.

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift` — new `private var anyOutgoingListeners: [(id: UUID, handler: ...)] = []`.
- `Source/SocketIO/Client/SocketIOClient.swift:emit(_ data:[Any], ack:Int?, binary:Bool, isAck:Bool, completion:)` (around line 464) — fire outgoing listeners **after** the existing `status == .connected` guard, immediately before `engine.send` writes the packet. This is **JS-aligned**: per `socket.io-client/lib/socket.ts` (current `main` ~`:443-451`), `notifyOutgoingListeners(packet)` is invoked inside the `else if (isConnected)` branch — only when the packet is actually about to leave the client. Disconnected emits, volatile drops, and not-writable transports do **not** fire outgoing.
- **Threading contract:** mirror Phase 4 — all four mutator methods wrap in `handleQueue.async { ... }`; the emit-path snapshot is taken under `handleQueue` (the internal funnel already runs there); `dispatchPrecondition(condition: .onQueue(handleQueue))` inside the snapshot site.
- **No additions to `SocketIOClientSpec`.** Same rationale as Phase 4 — concrete-class only.

### Outbound buffer / `emitBuffered` interaction (forward-looking)
JS additionally fires outgoing listeners during **buffered-emit replay**: `socket.io-client/lib/socket.ts emitBuffered()` (current `main` ~`:849-852`) iterates `sendBuffer` on (re)connect and calls `notifyOutgoingListeners(packet)` for each replayed packet. This means a packet emitted while disconnected fires its outgoing listener at **replay time** (when it actually reaches the wire), not at original `emit()` time.

Swift currently has no outbound `sendBuffer`, so this code path does not exist. **However:** if outbound buffering is added in a future phase (currently Out of Scope), the implementer MUST fire outgoing listeners on replay, not on original disconnected emit. Phase 5 documents this so the future buffering implementer doesn't accidentally fire-on-emit (which would diverge from JS).

### Data flow
`emit(event, items)` → reserved guard (Phase 2) → existing `status == .connected` guard → packet build → outgoing listeners (snapshot iteration) → `engine.send`.

### Key decisions
- Outgoing listeners fire **after** the connected-state guard and **immediately before** `engine.send` (JS-aligned per `socket.io-client/lib/socket.ts` `emit()` body, current `main` ~`:443-454` — `notifyOutgoingListeners` runs inside the `else if (isConnected)` branch).
- Ack response emits (`emitAck`, identified by `isAck == true`) do **not** trigger outgoing listeners (JS-aligned).
- The current Swift code does **not** buffer outbound emits while disconnected — `SocketManager.waitingPackets` is the inbound binary-reassembly buffer, not an outbound queue. Disconnected non-volatile emits surface a `.error` to user code today; that behavior is preserved.
- **Disconnected emit:** outgoing listener does **not** fire (matches JS — listener only fires on actual send).
- **Volatile drop (Phase 7):** outgoing listener does **not** fire (JS `discardPacket` early-return precedes `notifyOutgoingListeners`, per `socket.ts` `emit()` ~`:443-451`).

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
- **JS-divergence callout for `sendWithAck.timingOut`:** `socket.sendWithAck("x").timingOut(after: 1) { data in ... }` routes through the **legacy** `OnAckCallback.timingOut` path. Timeout is signaled via `data == [SocketAckStatus.noAck.rawValue]` (magic string), NOT via `SocketAckError.timeout`. Disconnect-mid-wait does NOT clear it (legacy path divergence — see Phase 9 Key decisions). Users wanting typed errors and disconnect-clearing must use `socket.timeout(after: 1).emit("message", ack: ...)` (Phase 9 path) instead.
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
JS allows `socket.volatile.emit("e", arg, cb)` (volatile chained with an ack callback). On drop, JS's `_registerAckCallback` (current `main` `socket.ts` ~`:464-492`) has already registered the callback before the discard check (~`:443-447`), so the callback ends up orphaned in `this.acks` — it never fires unless either a server ack arrives later (impossible since packet wasn't sent) or the `socket.timeout(...)` wrapper exists and fires `disconnected`/`timeout` later via `_clearAcks`.

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
Drop is normal flow, not an error. `Logger.log("volatile packet dropped (transport not writable)", type: "SocketIOClient")` records the drop. Uses `Logger.log` (not the nonexistent `Logger.debug`/`Logger.warning`); routes nowhere user-facing — see Error-surface taxonomy. No `handleClientEvent(.error)` (volatile drop is the user-requested behavior, not an error).

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

// On concrete SocketIOClient (NOT SocketIOClientSpec — see Components touched):
public extension SocketIOClient {
    /// Install a callback-form auth provider. Invoked on `handleQueue` for every
    /// CONNECT (initial + every reconnect attempt). JS-aligned behavior: if the
    /// callback is invoked multiple times within one attempt, each call sends a
    /// CONNECT packet (matches JS `socket.io-client/lib/socket.ts` `onopen()` →
    /// `this.auth(cb)` which does not deduplicate). Callers should invoke the
    /// callback exactly once.
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

**No `setAuthDeadline` API.** JS-aligned: `socket.io-client/lib/socket.ts` `onopen()` (current `main` ~`:617-626`) calls `this.auth(cb)` without a deadline at the Socket layer. A hanging provider in JS leaves the socket in `connecting` until the user-supplied `connect(timeoutAfter:)` (or the equivalent JS Manager `timeout`) fires. Swift adopts the same posture: users who need timeout protection must use `connect(timeoutAfter:)`. This is documented as a known constraint, not a bug. (See **Reviewer Pushback Notes** for why we rejected the previously-proposed `setAuthDeadline` default of 10 s.)

### Components touched
- `Source/SocketIO/Client/SocketIOClient.swift`
  - new `private var authProvider: SocketAuthProvider?`
  - new `private var pendingAuthTask: Task<Void, Never>?` — retained reference to the in-flight async provider Task. `cancel()`-ed on `clearAuth()`, on `setAuth(...)` replacing the provider, and on `didDisconnect`. (Swift-only — JS callback-form provider has no Task lifetime to manage.)
  - public `setAuth` / `clearAuth` (callback and async overloads).
  - new internal hook `resolveConnectPayload(explicit:completion:)` — given the optional static payload, either calls completion immediately (no provider) or invokes the provider on `handleQueue` and forwards the result via completion. **No idempotency token / no multi-call guard:** matching JS, if the provider's callback is invoked multiple times, completion is invoked multiple times and multiple CONNECT packets are sent. Documented as "match JS bug; do not paper over."
  - **Per-connect generation token** (`private var authGeneration: UInt64 = 0`). Bumped on every entry to `connect()`, on `clearAuth()`, and on each `setAuth(...)` call. The completion closure captures the snapshot generation at provider-invocation time and drops if it no longer matches the live `authGeneration`. This handles the identity-swap race:
    ```
    socket.disconnect()             // status -> .disconnected
    socket.clearAuth()              // authGeneration += 1
    socket.setAuth(newProvider)     // authGeneration += 1
    socket.connect()                // authGeneration += 1; provider invoked with token T
    // OLD provider's late callback arrives with stale token T-3 -> dropped
    ```
  - Status-only check (`socket.status == .connecting`) is INSUFFICIENT: after `disconnect; clearAuth; setAuth(new); connect()`, the new attempt is `.connecting` so the OLD provider's stale callback would pass a status check and send stale CONNECT. The generation token guards against this.
  - When the late completion drops (token mismatch OR status mismatch), emit `Logger.log("auth result discarded; generation mismatch or socket no longer .connecting", type: "SocketIOClient")` so consumers can correlate the drop in diagnostics. No `.error` clientEvent on this path — the user already drove the disconnect or replaced the provider, so surfacing `.error` would be noise.
  - This is implementation-necessary for Swift's async overload (the awaited result lands later than the user's `disconnect()` / `clearAuth()` could), not a behavior addition relative to JS — JS's synchronous callback can't race the same way because it has no async-await surface.
- `Source/SocketIO/Manager/SocketManager.swift`
  - **Extract a raw CONNECT writer to avoid recursion.** Refactor `connectSocket(_:withPayload:)` into two methods:
    - `connectSocket(_:withPayload:)` — the user-facing/dispatch entry (called from `joinNamespace`). Wraps the resolution; calls the writer.
    - `writeConnectPacket(_:withPayload:)` — pure-write method that builds and emits the CONNECT frame. **Does NOT consult any auth provider.** Idempotent on the wire side.
  - **Provider gating must cover both CONNECT-write sites and call only the raw writer after resolution:**
    1. `_engineDidOpen` (~`SocketManager.swift:405-419`) — for each namespaced socket in `.connecting`: `socket.resolveConnectPayload(explicit: pending) { resolved in self.writeConnectPacket(socket, withPayload: resolved) }`.
    2. `connectSocket(_:withPayload:)` early branch (~`:208-257`) when `manager.status == .connected`: `socket.resolveConnectPayload(explicit: pending) { resolved in self.writeConnectPacket(socket, withPayload: resolved) }`.
  - **Why the raw-writer split is mandatory:** if the resolution closure called `connectSocket` (the dispatch entry) instead of `writeConnectPacket`, the inner `connectSocket` would re-enter `resolveConnectPayload`, re-invoke the provider, and either deadlock or send N CONNECT packets per provider invocation. Direct call to `writeConnectPacket` breaks the recursion.
  - On `tryReconnect` → `_tryReconnect` → `connect()`, `_engineDidOpen` re-fires and the provider is naturally re-invoked per attempt (via the resolution wrapper, not by `writeConnectPacket` directly).
- **No additions to `SocketIOClientSpec`.** `setAuth` (callback + async forms) and `clearAuth` are concrete-class-only on `SocketIOClient`. Same rationale as Phases 3/4/5: the storage (`authProvider`, `pendingAuthTask`, `authGeneration`) lives on the concrete class as `private`; protocol-default impls cannot reach it; growing the protocol with `fatalError` defaults converts a previously-safe call site on third-party conformers into a runtime crash. Third-party `SocketIOClientSpec` conformers don't get this API for free, but they don't crash either. If protocol-level access is needed later, a follow-up phase can add an opt-in sub-protocol.

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
- Provider callback dispatched on `handleQueue`. Async provider runs in `Task { ... }`; result hop back to `handleQueue` via **`handleQueue.async { ... }` — never `handleQueue.sync`**. Sync would deadlock when `_engineDidOpen` (which itself runs on `handleQueue`) is the caller invoking `resolveConnectPayload`.
- **Per-connect generation token** (see Components touched). All late completions check `currentGeneration == capturedGeneration` AND `socket.status == .connecting` before sending CONNECT. Mismatch → drop + diagnostic log.
- **No deadline (JS-aligned).** Hanging provider blocks CONNECT indefinitely; users protect against this with `connect(timeoutAfter:)`. Documented in API doc-comment of `setAuth` and in README.
- **No multi-callback dedup (JS-aligned).** If the user-supplied provider invokes `cb` more than once, each call triggers a CONNECT packet send — matching JS reference exactly. Tests verify the JS behavior is reproduced; tests can also exercise stricter Swift-only assertions (e.g., that the Swift wrapper does not crash on multi-callback) but the implementation does not guard.
- Synchronous provider callback is allowed (`{ cb in cb([:]) }`).
- Async overload runs the closure in `Task { ... }` retained by the socket; the result is hopped back to `handleQueue`. The closure is **not** `@Sendable`-annotated. The retained `Task` is `cancel()`ed when the socket disconnects, when `clearAuth` is called, or when `setAuth` replaces the provider mid-flight. (Swift-only addition — JS has no Task to cancel.)
- **Coexistence:** when both `withPayload` and `setAuth` are used, the provider wins. A `Logger.error` line is emitted at `setAuth` install time noting the precedence. No per-attempt re-warn (low-noise default; no JS counterpart to mirror).
- **Identity-swap convention:** documented pattern `socket.disconnect(); socket.clearRecoveryState(); socket.clearAuth(); socket.setAuth(newProvider); socket.connect()`. All five calls run synchronously on `handleQueue`. Implementation does not introduce extra fencing primitives beyond the `Task.cancel()` already required for async-overload Task cleanup. An atomic `resetIdentity(authProvider:)` API was considered and deferred — see Reviewer Pushback Notes / Out of Scope.
- **State-recovery merge (`pid`/`offset`) interaction.** JS `_sendConnectPacket(data)` (current `main` `socket.ts` ~`:634-641`) merges `{pid, offset}` into the auth payload when recovery state is set: `data: this._pid ? Object.assign({pid, offset}, data) : data`. The provider-resolved payload (or static `withPayload` payload) goes into the SAME merge step on Swift — the resolved value is passed as the `data` argument to whatever Swift function builds the CONNECT packet, and the existing `pid`/`offset` injection runs on the merged result. **The provider does NOT bypass recovery merge.** This is critical for state-recovery + provider coexistence: a provider returning `["token": "abc"]` on a recovering socket sends CONNECT with `{pid: ..., offset: ..., token: "abc"}`, exactly mirroring JS.
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
  - Provider returns `nil` → server receives no auth. **Wire-shape parity:** capture the CONNECT packet on the wire and assert it is byte-identical to the CONNECT packet produced by static `connect(withPayload: nil)`. Both must omit the `data` field (or set it to `null`/`undefined` — whatever JS produces for the same case).
  - Provider never callbacks → socket stays in `.connecting` indefinitely; only `connect(timeoutAfter:)` (if user passed it) breaks the wait. **No Swift-side deadline fires.**
  - Provider invokes callback twice → server receives **two** CONNECT packets. Test asserts JS-parity exactly (matches JS `_sendConnectPacket` being called per-callback without dedup).
  - `setAuth` then `connect(withPayload: ["x": 1])` → provider wins; static payload ignored. `Logger.error` line emitted at `setAuth` install time only (not per attempt).
  - **Recovery-merge interaction:** with state-recovery active (`_pid` + `_lastOffset` set after a prior session), `setAuth { cb in cb(["token": "abc"]) }` → CONNECT auth on the wire is `{pid: ..., offset: ..., token: "abc"}` (provider payload merged with recovery metadata). Static `connect(withPayload: ["token": "abc"])` against the same recovering socket produces an identical wire packet — provider must not bypass the merge step.
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
  - **Recursion guard:** verify `writeConnectPacket` is the only function called from `resolveConnectPayload`'s completion (instrument with a counter that asserts `connectSocket` dispatch entry is NOT re-entered from inside the resolution path).
  - **Identity-swap stale-auth race (generation token):** install `provider1` that delays its callback by 500ms; immediately call `disconnect(); clearAuth(); setAuth(provider2); connect()`; let `provider2` resolve immediately. Assert: only `provider2`'s payload reaches the wire as CONNECT auth; `provider1`'s late callback is dropped (verified via captured `Logger.log` "generation mismatch" line) and does NOT trigger an additional CONNECT packet. Server-side counter sees exactly one CONNECT for `provider2`.
  - **Generation token bumps on every relevant call:** verify `setAuth` (twice in a row), `clearAuth`, and `connect()` each bump `authGeneration` (via `dispatch_specific` test hook reading the counter).

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

**Timeout-value validation (JS-aligned):** matches JS `socket.io-client/lib/socket.ts` (current `main`, the timeout-flag emit path) which passes the user-supplied number straight to `this.io.setTimeoutFn(...)` with no validation. Swift `SocketTimedEmitter`:
- `seconds <= 0`: schedules the timer for the next `handleQueue` tick (JS behavior — `setTimeout` clamps `0` and negatives to "next tick"). Effectively immediate timeout.
- `seconds == .infinity`: implementation MUST clamp explicitly to `DispatchTime.distantFuture` rather than relying on `DispatchTime.now() + .infinity` arithmetic (Swift `DispatchTimeInterval.seconds(Int)` cannot represent `.infinity` and `DispatchTime + Double` overflow behavior is platform-dependent — verified to differ between macOS/iOS Foundation and swift-corelibs-foundation). Concrete implementation: `let deadline: DispatchTime = seconds.isFinite ? .now() + seconds : .distantFuture`. Effectively no-timer behavior.
- Very large finite positive `Double`: same explicit clamp via `seconds.isFinite` guard.
- **No `precondition`.** No rejection. JS-aligned.

**Manager-overridable timer hook (Out of Scope, JS-divergent surface):** JS uses `this.io.setTimeoutFn(...)` (`socket.io-client/lib/socket.ts` `_registerAckCallback`) which is a manager-overridable injection point — JS tests swap it for deterministic timing. Swift uses `handleQueue.asyncAfter(...)` directly with no swap-in surface. This means Swift tests must rely on real wall-clock or `setTestStatus`-style hooks rather than a `setTimeoutFn` injection. If deterministic timing surfaces become a test-stability issue, adding a `SocketIOClientOption.timerProvider(_:)` is tracked under Out of Scope; not added in this design.

### Components touched
- New file `Source/SocketIO/Ack/SocketAckError.swift`.
- New file `Source/SocketIO/Ack/SocketTimedEmitter.swift`.
- `Source/SocketIO/Client/SocketIOClient.swift` — `timeout(after:) -> SocketTimedEmitter` (one-line extension); `didDisconnect` updated to clear timed acks (see below).
- `Source/SocketIO/Ack/SocketAckManager.swift` — **parallel storage** alongside the existing `Set<SocketAck>`:
  - existing `acks: Set<SocketAck>` (callback type `AckCallback = ([Any]) -> ()`, around line 73) — **untouched**. Legacy `OnAckCallback.timingOut(after:)` continues to use this storage.
  - new `timedAcks: [Int: TimedAckEntry]` keyed by ack id, where `TimedAckEntry` wraps `(Error?, [Any]) -> Void`, the scheduled `DispatchWorkItem`, and a one-shot `fired` flag.
  - new internal APIs (all four perform their storage mutation inside `handleQueue.async { ... }` to enforce single-queue access regardless of caller — `Task.cancel()` from `@MainActor` reaches `cancelTimedAck` synchronously off `handleQueue`, so the `async` wrapping is implementation-required, not just defensive). Each entry uses a `fired: Bool` one-shot flag; the (`check fired → set fired → mutate storage → cancel timer if any → invoke callback or resume continuation`) sequence runs as a single `handleQueue.async` block — no operation interleaves with another path against the same id:
    - `addTimedAck(_ id: Int, callback: @escaping (Error?, [Any]) -> Void, timeout: Double)` — registers, schedules timer. Caller (`SocketTimedEmitter.emit`) MUST invoke this BEFORE routing through the internal emit funnel so the disconnected-emit path still gets a deterministic timer fire.
    - `executeTimedAck(_ id: Int, with items: [Any])` — called from `handleAck`; one-shot guard via `fired` flag.
    - `cancelTimedAck(_ id: Int)` — cancels timer + removes entry; used by async overload's `withTaskCancellationHandler`. Does NOT fire the callback (the continuation handles that). One-shot `fired` flag check ensures cancellation cannot double-fire after timer already fired.
    - `clearTimedAcks(reason: SocketAckError)` — fires all outstanding callbacks with the given error and clears storage. Called from `didDisconnect` (`reason: .disconnected` — JS-aligned per current `main` `socket.ts` `_clearAcks` ~`:679-693` for `withError` callbacks) and from `clearRecoveryState` (`reason: .disconnected`, Swift-only path). Iterates a snapshot of `timedAcks` so individual entries' `fired` flag can be checked atomically. Does NOT touch the legacy `acks: Set<SocketAck>` storage.
    - **No `Logger.warning`** in current logger — uses `Logger.log` (diagnostic) or `Logger.error` only. User-facing errors from this layer route via `handleClientEvent(.error, ...)` if applicable; bad-ack-id lookup miss uses `Logger.log` only.
  - `handleAck` (caller side, in `SocketIOClient.handleAck` around line 496-502): try `executeTimedAck` first; on miss, dispatch to legacy `executeAck`. Implementation must guarantee an ack id is in **exactly one** of the two sets, never both, by routing all new id allocations through the new path when called from `SocketTimedEmitter`, and through the legacy path when called from `OnAckCallback`. Both paths share the same `currentAck` counter on `SocketIOClient` so id uniqueness is preserved.
- `Source/SocketIO/Client/SocketIOClient.swift:handleAck` — try `executeTimedAck` first; on miss, dispatch to legacy `executeAck` (existing behavior).
- `Source/SocketIO/Client/SocketIOClient.swift:didDisconnect` (around line 330) — call `ackHandlers.clearTimedAcks(reason: .disconnected)` so outstanding timed-ack closures don't leak across the disconnect. JS-aligned: `socket.ts` `_clearAcks()` (current `main` ~`:679-693`) fires `withError` callbacks with `new Error("socket has been disconnected")` on `onclose`.
- `Source/SocketIO/Client/SocketIOClient.swift:clearRecoveryState` (around line 225) — same call (`reason: .disconnected`) to clear timed acks on identity swap.
- `Source/SocketIO/Client/SocketIOClientSpec.swift` — `timeout(after:)` protocol requirement + default impl `func timeout(after seconds: Double) -> SocketTimedEmitter { SocketTimedEmitter(socket: self, timeout: seconds) }`. The emitter stores `SocketIOClientSpec` (not the concrete class), so the default impl works against any conformer; concrete operations on the emitter (`emit`) are dispatched through the protocol's `emit`/`emitWithAck` requirements which conformers already implement.

The legacy `OnAckCallback` path is **not** modified; it does not delegate to the new internal. This keeps `OnAckCallback.timingOut(after: -1)` and `timingOut(after: 0)` semantics untouched.

**No outstanding-acks cap (JS-aligned).** JS does not impose a per-socket or per-manager limit; `this.acks` in `socket.io-client/lib/socket.ts` is unbounded. Per the "implementation must match JS" rule, Swift does not introduce a cap either. (A previous revision proposed a 10 000-entry cap with 80% warning; removed for JS parity. If profiling later shows real DoS exposure, this can be promoted from Out of Scope as an opt-in `SocketIOClientOption`.)

### Data flow
```
socket.timeout(after: 5).emit("e", x, ack: cb)
  → SocketTimedEmitter.emit
  → handleQueue.async {
      let id = socket.nextAckId()                    // allocate FIRST
      ackHandlers.addTimedAck(id, callback: cb, timeout: 5)  // register BEFORE wire path
      socket internal emit(..., ack: id)             // funnel runs reserved guard +
                                                     // status-connected guard;
                                                     // if disconnected, .error fires
                                                     // but ack is already registered,
                                                     // so timer will eventually fire .timeout
    }
  → SocketAckManager.addTimedAck(id, callback: cb, timeout: 5)
       - schedules DispatchWorkItem on handleQueue.asyncAfter(deadline: .now() + 5)
  → server ack arrives → handleAck → SocketAckManager.executeTimedAck(id, [...])
       - one-shot guard, cancels DispatchWorkItem, removes entry, calls cb(nil, [...])
  → OR timer fires first → DispatchWorkItem body
       - one-shot guard, removes entry, calls cb(.timeout, [])
```

**Critical ordering:** `addTimedAck` MUST be called BEFORE the internal emit funnel runs. If the funnel's `status == .connected` guard fails and emits `.error` + early-returns BEFORE the ack is registered, the timer would never be scheduled and `cb(.timeout, [])` would never fire, leaving the user's callback orphaned. By registering first, the disconnected-emit case still gets a deterministic timer fire (matching JS — JS registers via `_registerAckCallback` before the `discardPacket`/`isConnected` branch).

Async overload wraps the callback in `withCheckedThrowingContinuation` + `withTaskCancellationHandler`. **Atomic cancellation contract:** the cancellation handler dispatches via `handleQueue.async`, and the entire `(check fired flag → set fired flag → remove entry → cancel timer → resume continuation)` sequence runs as a single block on `handleQueue`. The timer-fire and ack-arrival paths use the same atomic sequence with the same `fired` flag. **The continuation's `resume` is called exactly once across all three paths (cancellation, timer, server ack)** — guaranteed by the one-shot `fired` flag protected by `handleQueue` serialization.

**Queue affinity for the async overload's caller:** `withCheckedThrowingContinuation` resumes the awaiting coroutine on the Swift Concurrency cooperative pool, NOT on `handleQueue`. The spec **does not guarantee** the awaiting `Task` resumes on `handleQueue` — that would require a custom `Executor` which is out of scope. What IS guaranteed: the internal transition from timer/ack/cancellation back into `timedAcks` storage uses `handleQueue.async`. The user's `let r = try await ...` continues on whatever executor the `Task` was started on.

### Key decisions
- **Disconnected emit:** the current Swift code does not buffer outbound emits (the internal funnel surfaces `.error` and returns). For the new timed-ack path, the existing `.error` clientEvent is preserved (Swift back-compat divergence vs JS — JS would buffer instead). The timed-ack callback is registered BEFORE the funnel runs (see Data flow), so the timer fires `.timeout` after the user-supplied duration. **Both signals reach the user**: the legacy `.error` event AND the deferred `cb(.timeout, [])`. This is a documented JS-divergence (JS only fires the timer; no `.error`) — kept for back-compat with the existing Swift behavior of disconnected emits. Listed in the JS-divergence policy under category 4.
- **Volatile + timeout is unsupported as a chained API** (no `socket.volatile.timeout(ms).emit(...)` chain). JS reference also has no such chain — users who try `socket.volatile.emit("e", arg, cb)` get the JS bug of an orphaned callback. Swift documents this as unsupported and does not provide the chain. Listed in the JS-divergence policy under category 3.
- **Duplicate ack response from server:** JS silently drops the late ack via lookup-miss after `delete this.acks[id]` (current `main` `socket.ts` `~:803-815`). Swift matches: lookup in `timedAcks` after first execution removes the entry; subsequent lookup misses, `Logger.log("bad ack id", type: "SocketAckManager")` (diagnostic only — `Logger.log`, NOT `handleClientEvent(.error)`), no callback re-fire.
- **Late server ack dispatch lookup channel:** must use `Logger.log` (diagnostic), NEVER `handleClientEvent(.error, ...)`. Escalating to `.error` clientEvent would diverge from JS's `debug()` package output.
- **All callbacks dispatched on `handleQueue`** via the `handleQueue.async { ... }` wrapping inside the four manager APIs. **Atomic transition** — see Data flow's atomic cancellation contract.
- **Async cancellation:** `withTaskCancellationHandler` invokes `cancelTimedAck`; the continuation is resumed exactly once via the one-shot `fired` flag protected by `handleQueue` serialization. Ack registration is removed atomically with the resume. This is a Swift-only addition required for sane Task cancellation; no JS counterpart.
- **`withCheckedThrowingContinuation` resume queue:** internal storage transitions use `handleQueue.async`. The awaiting `Task`'s resumption queue is not enforced (Swift Concurrency cooperative pool default). Spec does not claim to deliver async results on `handleQueue` — that would require a custom `Executor` and is out of scope.
- **No timeout-value validation (JS-aligned).** `seconds < 0` clamps to "fire on next tick"; `seconds == .infinity` saturates at `DispatchTime.distantFuture`; no precondition/rejection.
- **Outstanding timed acks on `didDisconnect`:** fire `.disconnected` and clear. JS-aligned per current `main` `socket.ts` `_clearAcks` (~`:679-693`) firing `withError` callbacks with `new Error("socket has been disconnected")` on `onclose`.
- **Outstanding timed acks on `clearRecoveryState`:** Swift-only path (no JS counterpart — JS has no `clearRecoveryState`). Calling while connected fires `.disconnected` for all outstanding `timedAcks` even though the socket is still connected. **Rationale for re-using `.disconnected`:** the user's intent in calling `clearRecoveryState` is "drop all session-bound replay state and start fresh," which is operationally equivalent to a disconnect for any callback that was waiting on a session-specific ack id. Adding a separate `.recoveryStateCleared` case would require users to handle two code paths for what is functionally the same outcome (callback no longer reachable). The reused signal is documented in the Phase 9 doc-comment so users aren't surprised. (If a future consumer needs to distinguish, `case .recoveryStateCleared` can be added additively without breaking the binary mapping.)
- **Legacy `OnAckCallback.timingOut` clearing on disconnect:** JS clears `withError`-flagged callbacks on disconnect; JS `emitWithAck` sets `withError = true` (`socket.ts` `_registerAckCallback`), so JS DOES fire its callback with the disconnected Error on `_clearAcks`. Swift's legacy `OnAckCallback.timingOut` path stores via the legacy `acks: Set<SocketAck>` and is NOT touched by `clearTimedAcks`. **Documented divergence (category 4):** Swift's legacy `emitWithAck(...).timingOut(after:) { data in }` callbacks remain orphaned on disconnect (the legacy code emits `[SocketAckStatus.noAck.rawValue]` only via the timer fire, never via disconnect). Users who need disconnect-clearing must migrate to `socket.timeout(after:).emit(..., ack:)` (Phase 9 path). Listed in the JS-divergence policy under category 4 with explicit migration guidance in the Phase 9 doc-comment / README.

### Error handling
| Condition | User-facing channel(s) | Behavior |
|---|---|---|
| Server acks within timeout | per-emit ack callback | `cb(nil, data)` |
| Timeout elapses, no ack | per-emit ack callback | `cb(.timeout, [])` |
| Late server ack arrives after timeout fired | `Logger.log` (diagnostic only) | Silently dropped; "bad ack id"; no double callback (JS-aligned) |
| Socket disconnects while waiting (timed-ack path) | per-emit ack callback | `clearTimedAcks(reason: .disconnected)` fires `cb(.disconnected, [])` (JS-aligned) |
| Socket disconnects while waiting (legacy `emitWithAck.timingOut` path) | none | Callback orphaned; not cleared. **JS-divergent** (JS clears `withError`-flagged callbacks). Documented; migration guidance: use `socket.timeout(after:).emit(..., ack:)` |
| `clearRecoveryState` called while waiting | per-emit ack callback | Same as disconnect (`.disconnected`). Swift-only path |
| Reconnect mid-flight | none additional | Old ack id callbacks already cleared by the disconnect path; new emits register fresh ids |
| Emit issued while disconnected | `handleClientEvent(.error)` (legacy Swift behavior preserved) AND per-emit ack callback after `seconds` | `.error` event fires immediately (existing Swift behavior); ack callback registered BEFORE funnel (see Data flow), timer scheduled, fires `cb(.timeout, [])` after duration. **JS-divergent** (JS only fires the timer; Swift fires both). Documented under JS-divergence policy category 4 |
| `seconds < 0` | per-emit ack callback | Treated as 0 — fires on next `handleQueue` tick (JS-aligned) |
| `seconds == .infinity` or very large | per-emit ack callback | Saturates at `DispatchTime.distantFuture` — effectively no-timer (JS-aligned) |
| Async overload `Task.cancel()` mid-wait | thrown `CancellationError` | One-shot atomic transition: cancel timer, remove entry, resume continuation throwing. Swift-only |

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
  - **Atomic cancellation:** `Task.cancel()` race with simultaneous server-ack arrival — exactly one of `(thrown CancellationError, normal return)` reaches the awaiter, never both. Verified by stress test (1000 iterations) — `cb` invocation count == 1 for every iteration.
  - **Atomic cancellation race with timer:** `Task.cancel()` race with timer firing — same one-shot guarantee. Stress test 1000 iterations.
  - **`addTimedAck` placement:** verify ack registration occurs BEFORE the internal emit funnel runs. Test: emit while disconnected → `.error` clientEvent fires AND `timedAcks.count == 1` immediately AND `cb(.timeout, [])` fires after the timeout duration. If registration happened after the `.error` early-return, `timedAcks.count` would be 0 and `cb` would never fire — that's the failure this test catches.
  - Async overload from `@MainActor` context — verify the awaiter resumes correctly (no deadlock, no actor-isolation violation). **Spec does NOT claim the awaiter resumes on `handleQueue`** — verify only that result is delivered correctly; do NOT assert `dispatch_specific` key on the awaiter side.
  - 100 concurrent timed emits — ack ids unique; no cross-talk.
  - Race: timer firing instant exactly as server ack arrives — first fire wins; the other becomes a `cancelTimedAck`/lookup-miss no-op (one-shot guard).
  - Identity swap (`clearRecoveryState`) clears outstanding timed acks via `clearTimedAcks(reason: .disconnected)`. Documented as Swift-only (no JS counterpart). `cb(.disconnected, [])` fires for every outstanding timed-ack at swap time.
  - **Storage isolation (Swift-side correctness check beyond JS):** legacy `emitWithAck(...).timingOut(after: 1) { data in }` and new `socket.timeout(after: 1).emit(...) { err, data in }` issued back-to-back share no storage; verify `acks.count` and `timedAcks.count` independently after each registration and after each completion.
  - **Legacy emitWithAck disconnect divergence (regression-pin):** issue `emitWithAck("e").timingOut(after: 5) { data in ... }`, then `disconnect()` immediately. Assert: callback is **NOT** invoked with `[SocketAckStatus.noAck.rawValue]` on disconnect (legacy path is orphaned by design — Swift back-compat). Then verify the timer-based fire occurs at +5s with `[SocketAckStatus.noAck.rawValue]`. This pins the JS-divergence so future "fix" attempts don't break legacy users.
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

Findings raised during review that were considered and **not** acted on, with rationale. The "implementation must match JS reference" rule (round-2 user clarification) is the determining factor for most of these.

**Round 1/2 findings (kept for history):**

- **"v2 manager auth contradiction"** (pr-review round 1): claim was that the existing `connectSocket` sends payload on v2. Verification (`SocketManager.swift:225`) shows the JSON-payload branch is gated by `version.rawValue >= 3` — v2 already drops payloads. Phase 8 v2 path matches existing behavior; round-3 added per-attempt `handleClientEvent(.error)` so the silent bypass is now user-observable.
- **"Phase 3 status-race test is padding"** (pr-review round 1): the test asserts the `active` getter is safe under the documented single-queue contract. Kept.
- **"Phase 6 empty-`send()` test is padding"** (pr-review round 1): the test verifies the variadic→`emit("message")` zero-arg path produces a valid wire packet. Kept.
- **"Manager-level auth missing from Out of Scope"** (pr-review round 1): JS reference does not expose Manager-level auth. Listed in Out of Scope.
- **"`recovered` vs `wasRecovered` mismatch"** (pr-review round 1): both Swift and JS already use `recovered`. No mismatch.
- **"Phase 1 should not rely on doc-only for the `autoConnect` JS/Swift default inversion"** (pr-review round 1): rejected. Default `false` preserves bit-identical legacy Swift behavior; the only behavior change is opt-in `true`. Doc-only is the right ceiling.
- **"Add `setAuthDeadline(_:)` with default 10 s"** (security round 1): rejected per JS-parity. JS reference imposes no Socket-layer auth deadline. Use `connect(timeoutAfter:)` for timeout protection.
- **"Add 10 000 outstanding-acks cap with 80% warning"** (security + pr-review round 1): rejected per JS-parity. JS `this.acks` is unbounded.
- **"Add `precondition` rejecting `< 0`, `.infinity`, `> 3600` on `socket.timeout(after:)`"** (multiple round 1): rejected per JS-parity. JS passes all values straight to `setTimeout`.
- **"Add idempotency token to dedupe multi-callback auth provider invocations"** (security + codex round 1): rejected per JS-parity. JS does not deduplicate; calling `cb` twice sends two CONNECT packets.
- **"Add Logger redaction contract for auth payloads"** (security round 1): rejected per JS-parity. JS does not redact in `debug` output.
- **"Outgoing catch-all listener fires before connected-state guard so disconnected emits are observed"** (round 1, original design): rejected per JS verification — JS fires `notifyOutgoingListeners` AFTER the connected check.
- **"Volatile drop still fires outgoing listener"** (round 1, original design): rejected per JS verification — JS `discardPacket` branch returns BEFORE `notifyOutgoingListeners`.

**Round 3 findings — accepted:**

- **"Phase 3 `socket.active` formula wrong"** (round 3 JS-parity audit): JS `get active() { return !!this.subs }` tracks lifecycle (connect→disconnect), not status. Spec rewritten — `active` is now a stored Bool flipped at user `connect()`/`disconnect()`, NOT derived from `status`/`reconnecting`. The previously-proposed `SocketManagerSpec.reconnecting` promotion was dropped (was added for the wrong reason).
- **"Phase 7 volatile gate predicate wrong"** (round 3 JS-parity audit + Codex): JS gates `discardPacket = volatile && !transport.writable`, not `!connected`. Spec adds `SocketEngineSpec.writable` (option 1, recommended) with status-based fallback (option 2) explicitly enumerated as a category-1 divergence if engine surface change is rejected.
- **"Phase 2 missing `disconnecting` in reserved set"** (round 3 JS-parity audit): JS client-side reserved set includes `disconnecting`. Added.
- **"Phase 2 spec says emit still proceeds; JS throws"** (round 3 JS-parity audit): rewrote semantics to early-return + `handleClientEvent(.error)` (Swift-idiomatic mapping of JS throw — wire behavior identical: no packet).
- **"Phase 8 deferred CONNECT recurses"** (round 3 Codex): extracted `writeConnectPacket(_:withPayload:)` raw writer; `resolveConnectPayload` completion calls only the raw writer.
- **"Phase 8 identity-swap stale auth"** (round 3 Codex): added `authGeneration` token; status-only check was insufficient for the `disconnect; clearAuth; setAuth(new); connect()` sequence.
- **"Phase 9 cancellation can double-resume"** (round 3 Codex): atomic `fired` flag protected by `handleQueue` serialization; one-shot resume guarantee across timer/ack/cancel paths.
- **"Phase 9 `addTimedAck` must run before connected guard"** (round 3 coherence): registration moved into `SocketTimedEmitter.emit` BEFORE the funnel call so disconnected emits still get a deterministic timer fire (matches JS `_registerAckCallback` ordering).
- **"Phase 9 `withCheckedThrowingContinuation` queue claim unachievable"** (round 3 coherence): removed the "completion delivered on `handleQueue`" claim from async overload; only internal storage transitions are queue-pinned.
- **"Phase 8 `fatalError` protocol default is breaking"** (round 3 coherence): dropped `SocketIOClientSpec` additions for `setAuth`/`clearAuth`; concrete-class only.
- **"Phase 4/5 `anyListenerIds: [UUID]` no JS parity"** (round 3 coherence): renamed to `anyListenerCount: Int` / `anyOutgoingListenerCount: Int` (JS `listenersAny()` returns handler array; Swift count is a closer Swift-idiomatic mapping than UUID list).
- **"Phase 8 async-throw `.error` channel unspecified"** (round 3 silent-failure): pinned to `handleClientEvent(.error, data: [error.localizedDescription], isInternalMessage: false)`.
- **"Phase 8 late async result silently dropped"** (round 3 silent-failure): added `Logger.log` diagnostic line on drop.
- **"Phase 8 v2 + provider silent per-attempt bypass"** (round 3 silent-failure): added per-CONNECT `handleClientEvent(.error, ...)` so user observes each silent bypass.
- **"Phase 8 recovery-merge interaction unspecified"** (round 3 JS-parity): added explicit `pid`/`offset` merge step note + wire-shape parity test.
- **"Phase 1 second CONNECT path coverage"** (round 3 Codex): documented `_engineDidOpen` vs `connectSocket` early-branch gating; clarified `autoConnect:true` only auto-CONNECTs `defaultSocket`.

**Round 3 findings — rejected (for record):**

- **"Add `case .recoveryStateCleared` to `SocketAckError`"** (round 3 silent-failure M5): rejected. Reusing `.disconnected` matches user intent (callback no longer reachable); adding a separate case forces users to handle two paths for the same operational outcome. Future-additive if a real consumer needs it.
- **"Drop the `SocketEngineSpec.writable` requirement and use status-based gate only"** (alternative offered to round 3 BLOCKER #8): rejected as default; option 1 (writable surface) is the JS-faithful path. Option 2 status-based fallback is documented as a category-1 divergence available if the engine surface change is judged out-of-scope.
- **"Phase 9 disconnected timed-emit double-signal (`.error` + `cb(.timeout)`) — suppress the `.error`"** (round 3 silent-failure H4): rejected as a Swift-side back-compat preservation. The `.error` is the existing Swift behavior of disconnected emits; suppressing it would break callers relying on the legacy signal. Documented under JS-divergence category 4 with explicit rationale.

**Stale citation cleanup (round 3 JS-parity #6/#18):** all spec citations to JS `socket.io-client/lib/socket.ts` line numbers have been updated to current `main` ranges. Format changed from "exact line" to "function name + approximate line range" so future JS-source movement does not re-stale the spec. If a citation is still stale, re-verify against the latest `main` blob and update the line-range hint.
