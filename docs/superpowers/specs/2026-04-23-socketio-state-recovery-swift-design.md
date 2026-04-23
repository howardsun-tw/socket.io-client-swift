# Socket.IO Connection State Recovery — Swift Client Implementation

- **Date:** 2026-04-23
- **Target repo:** `socket.io-client-swift` (master)
- **Reference:** `socket.io-client@4.8.x` (JavaScript), upstream `build/esm/socket.js`
- **Server ref:** `socket.io@4.8.x`, see [Connection State Recovery docs](https://socket.io/docs/v4/connection-state-recovery/). The offset is appended to outgoing packet args by the Socket.IO adapter layer: `socket.io-adapter/lib/in-memory-adapter.ts` → `SessionAwareAdapter.broadcast()` does `packet.data.push(id)` when `connectionStateRecovery` is enabled. This is the server-side behavior the Swift client's offset-capture logic depends on.
- **Spec status:** Approved for planning (v2, post-review)

## 1. Overview

Implement Connection State Recovery in the Swift client. The feature lets a socket briefly disconnect (transport drop, network blip) and reconnect within a server-configured window while preserving its `sid` and replaying missed server-to-client events.

Behavior MUST match `socket.io-client` JavaScript 4.8.x exactly, with two deliberate, documented divergences — see §6.1.

## 2. Goals / Non-goals

**Goals**
- Send `{pid, offset}` in the CONNECT payload when the socket has prior session state
- Expose `recovered: Bool` on `SocketIOClient` and include `"recovered"` in the `.connect` event payload (v3 only)
- Capture the per-event offset (last string argument, bounded length) on incoming `event` / `binaryEvent` packets
- Feature is live on Socket.IO v3 managers only; v2 path untouched (including `.connect` event shape)
- Strict end-to-end tests against a real socket.io@4.8.x Node server cover scenarios a1–a8

**Non-goals**
- No persistence of `_pid` / `_lastOffset` across app restarts (in-memory only, matches JS). Fields MUST NOT be included in any `Codable` / `NSCoding` serialization of `SocketIOClient`. A lint-style test pins this.
- No client-side opt-out flag (server decides whether recovery is enabled)
- No re-architecting of `SocketManager` or packet parsing
- No changes to `SocketIOClientOption`

## 3. Architecture

### 3.1 State ownership

All recovery state lives on `SocketIOClient` (the Swift analogue of JS `Socket`):

- `_pid: String?` — private session id returned by the server in the CONNECT ack. `nil` until first CONNECT ack.
- `_lastOffset: String?` — last known event offset. Only updated while `_pid != nil`.
- `public private(set) var recovered: Bool = false` — computed on every CONNECT ack.

Invariants:
- `recovered` is only `true` immediately after a CONNECT ack whose `pid` equals the prior `_pid`
- `_pid` is never cleared by explicit `disconnect()`, by `.disconnect` packet handling, or by `CONNECT_ERROR` (matches JS `destroy` behavior — see `socket.js:502-507` and `:624-658`). The only paths that write a non-nil `_pid` are v3 CONNECT ack handling; `clearRecoveryState()` is the only path that nulls `_pid` after it was set. v2 never sets a non-nil `_pid`.
- All internal access is on `manager.handleQueue`. Because `handlePacket` is `open` and part of the public `SocketIOClientSpec`, the existing rule documented at `SocketIOClient.swift:41` still applies to external callers (no new lock introduced).
- These fields MUST NOT participate in any serialization (non-persistable by contract)

### 3.2 Version gating

Recovery is entirely inert on v2 managers. All merge, capture, and `.connect` payload enrichment is gated on `manager?.version == .three`. On v2 the `.connect` event data shape remains byte-identical to pre-feature behavior: `[namespace]` when payload is nil, `[namespace, payload]` otherwise.

### 3.3 Offset bound (security hardening)

`_lastOffset` is server-controlled. A malicious or buggy server can push a multi-megabyte string that the client then echoes back on every handshake.

- Hard cap: **`_lastOffset` is recorded only if `last.utf8.count <= 256`**.
- If the last arg is a string longer than the cap, `_lastOffset` is NOT updated and a warning is logged via `DefaultSocketLogger`.
- Cap value is a compile-time `static let socketStateRecoveryMaxOffsetBytes = 256` on `SocketIOClient`, documented in a source comment.

### 3.4 Package layout

| File | Role |
|------|------|
| `Source/SocketIO/Client/SocketIOClient.swift` | adds state properties, merge helper, CONNECT ack handling, offset capture, internal `clearRecoveryState()` |
| `Source/SocketIO/Client/SocketIOClientSpec.swift` | exposes `recovered` on the public protocol |
| `Source/SocketIO/Manager/SocketManager.swift` | calls the socket's merge helper to get the effective CONNECT payload |
| `Tests/TestSocketIO/SocketStateRecoveryTest.swift` | new unit tests |
| `Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift` | new end-to-end tests |
| `Tests/TestSocketIO/E2E/TestServerProcess.swift` | Node subprocess harness |
| `Tests/TestSocketIO/E2E/Fixtures/server.js` | Node socket.io@4.8.x test server, loopback-bound + shared-secret auth on admin plane |
| `Tests/TestSocketIO/E2E/Fixtures/package.json` | pins `socket.io@^4.8.0` |

## 4. Components

### 4.1 `SocketIOClient`

**New properties** (`recovered` publicly readable; others internal for `@testable` visibility):

```swift
public private(set) var recovered: Bool = false
var _pid: String?
var _lastOffset: String?

static let socketStateRecoveryMaxOffsetBytes = 256
```

**Merge helper** — returns the effective CONNECT payload with pid/offset merged. A fresh dict is built so the caller's `connectPayload` is never mutated. **User-supplied keys take precedence** (matches JS `Object.assign({ pid, offset }, data)` — user `data` wins):

```swift
func currentConnectPayload() -> [String: Any]? {
    guard manager?.version == .three else { return connectPayload }
    guard let pid = _pid else { return connectPayload }
    var out: [String: Any] = ["pid": pid]
    if let offset = _lastOffset { out["offset"] = offset }
    if let user = connectPayload {
        for (k, v) in user { out[k] = v }       // user keys override pid/offset
    }
    return out
}
```

If user's `connectPayload` contains keys `pid` or `offset`, their values win and a warning is logged once per socket lifetime to aid debugging.

**Internal reset API** (for identity changes — see §6 note on cross-user session resume):

```swift
/// Clears the in-memory state used for Connection State Recovery.
/// Call this when the authenticated identity on this socket changes to
/// prevent resuming a prior session. Not required on `deinit`.
///
/// Safe to call on any manager version (no-op effect on v2 since v2 never
/// sets recovery state). Thread rule matches the rest of the class — must
/// be called on `manager.handleQueue`.
///
/// Subclass ordering: subclasses that override `disconnect()` and want to
/// auto-clear recovery state MUST call `clearRecoveryState()` BEFORE
/// `super.disconnect()`. The `.disconnect` client event fires synchronously
/// from `super.disconnect()`, and downstream observers may re-connect; if
/// pid/offset are cleared after super, observers see inconsistent state
/// (observer reads `recovered` after event, sees stale value, then a later
/// reconnect sends prior pid).
open func clearRecoveryState() {
    _pid = nil
    _lastOffset = nil
    recovered = false
}
```

**Modified `didConnect(toNamespace:payload:)`** — v3 enrichment gated; v2 behavior byte-identical to today:

```swift
open func didConnect(toNamespace namespace: String, payload: [String: Any]?) {
    guard status != .connected else { return }
    status = .connected
    sid = payload?["sid"] as? String

    let isV3 = manager?.version == .three
    if isV3 {
        let incomingPid = payload?["pid"] as? String
        recovered = (incomingPid != nil && _pid != nil && _pid == incomingPid)
        _pid = incomingPid
    } // else: v2 — never set _pid, never compute recovered

    let connectData: [Any]
    if isV3 {
        if var payload = payload {
            payload["recovered"] = recovered
            connectData = [namespace, payload]
        } else {
            connectData = [namespace, ["recovered": recovered]]
        }
    } else {
        connectData = payload == nil ? [namespace] : [namespace, payload!]  // unchanged
    }
    handleClientEvent(.connect, data: connectData)
}
```

**Modified `handlePacket(_:)`** — for `.event` / `.binaryEvent`, dispatch first (to match JS ordering in `emitEvent`), then capture. Args are not mutated.

```swift
case .event, .binaryEvent:
    handleEvent(packet.event, data: packet.args, isInternalMessage: false, withAck: packet.id)
    captureOffsetIfNeeded(from: packet.args)
```

```swift
private func captureOffsetIfNeeded(from args: [Any]) {
    guard manager?.version == .three, _pid != nil else { return }
    guard let last = args.last as? String else { return }
    guard last.utf8.count <= SocketIOClient.socketStateRecoveryMaxOffsetBytes else {
        DefaultSocketLogger.Logger.log(
            "Dropping oversized offset string (\(last.utf8.count) bytes)",
            type: logType
        )
        return
    }
    _lastOffset = last
}
```

Note: the dispatch-then-capture ordering matches JS `emitEvent`. A handler that re-enters `connect()` synchronously will see the pre-dispatch offset on its new CONNECT — same observable behavior as JS.

### 4.2 `SocketIOClientSpec`

Add only the read-only protocol requirement. `clearRecoveryState()` is **not** added to the protocol — doing so would be a source-breaking change for any external conformer. It lives on the concrete `SocketIOClient` class only (declared `open` for subclass override).

```swift
var recovered: Bool { get }
```

Callers that hold a `SocketIOClientSpec` reference and need to reset recovery state must down-cast to `SocketIOClient`. Documented in the public API docs for `clearRecoveryState`.

### 4.3 `SocketManager.connectSocket`

`connectSocket`'s `withPayload` parameter becomes effectively unused — both call sites in the codebase pass `socket.connectPayload`. Keep the parameter to avoid breaking public ABI, but document it as deprecated-in-fact and source-of-truth is now the socket.

```swift
open func connectSocket(_ socket: SocketIOClient, withPayload payload: [String: Any]? = nil) {
    guard status == .connected else { /* unchanged: triggers engine connect */ return }

    var payloadStr = ""
    let effective = socket.currentConnectPayload()
    if version.rawValue >= 3, let effective = effective {
        do {
            let payloadData = try JSONSerialization.data(withJSONObject: effective, options: .fragmentsAllowed)
            if let jsonString = String(data: payloadData, encoding: .utf8) {
                payloadStr = jsonString
            }
        } catch {
            DefaultSocketLogger.Logger.error("Failed to serialize CONNECT payload: \(error)", type: "SocketManager")
            // `.error` data is conventionally `[String]` across this library; avoid embedding
            // the raw Error (may not be JSON/log-safe downstream).
            socket.handleClientEvent(.error, data: [
                "connect payload serialization failed: \(error.localizedDescription)"
            ])
            return  // abort this connect attempt rather than silently dropping pid/offset
        }
    }

    engine?.send("0\(socket.nsp),\(payloadStr)", withData: [])
}
```

Failure mode change vs. today: JSON serialization errors are now surfaced via the `.error` client event and the connect attempt is aborted, instead of silently sending an empty payload. This prevents silent recovery loss on malformed `connectPayload`.

## 5. Data flow

### 5.1 Fresh connect (no prior pid)
1. `connect(withPayload:)` sets `connectPayload` and calls `manager.connectSocket(self, …)`
2. Manager JSON-serializes `currentConnectPayload()` → returns `connectPayload` as-is (pid is nil)
3. Server replies CONNECT `{sid, pid?}`
4. `didConnect(toNamespace:payload:)`:
   - v3: `_pid = payload["pid"] as? String`; `recovered = false` (prior pid was nil)
   - `.connect` event fires with `payload + {"recovered": false}` on v3, or the unmodified v2 shape

### 5.2 Incoming event (offset capture)
1. Engine delivers EVENT / BINARY_EVENT packet
2. `SocketIOClient.handlePacket` dispatches to user handlers with `packet.args` unchanged
3. `captureOffsetIfNeeded` runs post-dispatch; bounded-length String last-arg → updates `_lastOffset`

### 5.3 Transport drop + successful recovery
1. Engine closes transport abruptly (no DISCONNECT sent)
2. Manager's reconnect logic re-opens engine; `_engineDidOpen` (`SocketManager.swift:362`) iterates `nsps` and calls `connectSocket(socket, withPayload: socket.connectPayload)`
3. `connectSocket` ignores the fallback `payload` parameter and reads `socket.currentConnectPayload()` → `{pid, offset?, ...user keys}` (user keys win on collision)
4. Server matches pid within its `maxDisconnectionDuration`, replies CONNECT with same pid
5. `didConnect`: `recovered = true`, `_pid` unchanged
6. Server replays missed events → Path 5.2 advances `_lastOffset` per event

### 5.4 Explicit `socket.disconnect()` then `connect()`
- `disconnect()` → `leaveNamespace()` → `manager.disconnectSocket(self)` → engine sends `"1<nsp>,"` → `socket.didDisconnect(reason:)`
- `_pid` / `_lastOffset` are retained on the `SocketIOClient` instance, so the next `connect()` re-joins with the prior pid/offset still present in the outgoing CONNECT payload.
- Server-side `connectionStateRecovery` does not treat explicit namespace disconnect reason `"client namespace disconnect"` as recoverable. Result: reconnect succeeds, but as a fresh session (`recovered == false`, new `sid`, new server `pid`).
- If the application changes authenticated identity, the caller MUST call `clearRecoveryState()` before reconnecting (see §6 note 11) OR recreate the `SocketIOClient` via `manager.socket(forNamespace:)`.

## 6. Error handling and edges

1. **JSON serialization failure** — `.error` client event emitted; connect attempt aborted; caller can retry with a corrected payload.
2. **Server has recovery disabled** — CONNECT ack has no `pid`; `_pid = nil`; `recovered = false` always. Permanent no-op (matches JS `_pid = pid` always — undefined clears the field).
3. **v2 manager** — `currentConnectPayload` and `captureOffsetIfNeeded` short-circuit; `didConnect` v2 branch preserves original event shape exactly.
4. **Offset capture on internal events** — only runs from `.event` / `.binaryEvent` branch of `handlePacket`. Internal client events (`.connect`, `.disconnect`, …) never invoke it.
5. **Non-string last arg** — `args.last as? String` returns nil; `_lastOffset` unchanged. Matches JS `typeof === "string"`.
6. **Offset exceeds length cap** — `_lastOffset` NOT updated; warning logged. Divergence from JS, documented as a hardening measure (see §6.1).
7. **Binary events with offset** — `packet.args.last` is still a String (server appends after binary `Data`). Same capture path.
8. **Multi-namespace manager** — each `SocketIOClient` owns its own `_pid` / `_lastOffset`. No cross-namespace sharing.
9. **Thread safety** — internal reads/writes happen on `manager.handleQueue`. External callers invoking `open` APIs (e.g. subclasses overriding `handlePacket`) must follow the existing documented rule at `SocketIOClient.swift:41`.
10. **Reconnect with invalid pid** — server replies as fresh session; client `_pid` overwritten with new server pid; `recovered = false`.
11. **Cross-user session resume** — if the application changes the authenticated user but reuses the same `SocketIOClient` instance, the next CONNECT will carry the previous user's `pid`. The server will resume the prior session if still within the window. **Callers MUST either (a) create a new `SocketIOClient` via `manager.socket(forNamespace:)` or (b) call `socket.clearRecoveryState()` before re-authenticating**. This requirement is documented on `clearRecoveryState`, on `SocketIOClient` class doc, and in the changelog.
12. **CONNECT_ERROR after recovery attempt** — Swift `handlePacket` `.error` branch does NOT clear `_pid` (matches JS `destroy()`). A subsequent successful connect can still attempt recovery (server decides).
13. **Re-entrant handler during dispatch** — post-dispatch offset capture means a handler that synchronously triggers reconnect sends the pre-dispatch offset. Matches JS exactly.

### 6.1 Intentional divergences from JS

| # | Divergence | Rationale |
|---|-----------|-----------|
| D1 | Offset length cap (256 B) | Prevent malicious-server memory / handshake bloat; JS has no cap. |
| D2 | `.error` on CONNECT payload JSON failure | JS silently drops; Swift surfaces, caller can recover. |
| D3 | Public `clearRecoveryState()` API | JS has no equivalent; needed because Swift `SocketIOClient` survives `disconnect()` (no `destroy`-style instance removal). |

## 7. Security assumptions

- **Transport**: recovery assumes `wss://` or `https://` polling. On plaintext transports, a MITM can forge CONNECT acks to inject a chosen `pid`, tricking the client into resuming an attacker-selected session on next reconnect. The spec does not gate recovery off on `ws://`; the caller is responsible for TLS. This mirrors the standing assumption across the library.
- **pid is a session bearer** for the duration of the server's `maxDisconnectionDuration` window. Treat like a short-lived session cookie.
- **Non-persistable** — `_pid` / `_lastOffset` are explicitly excluded from any serialization of `SocketIOClient`. A test enforces that a Codable encode of a public `SocketIOClient` snapshot (if one is ever added) does not include these fields.

## 8. Testing strategy

Tests split into a fast unit layer and a strict end-to-end layer against a real Node server.

### 8.1 Unit tests — `Tests/TestSocketIO/SocketStateRecoveryTest.swift`

Feed packets directly into `SocketIOClient`. Assert state transitions, no network. `@testable import SocketIO` grants internal access to `_pid` / `_lastOffset`.

| ID | Setup | Action | Assertion |
|----|-------|--------|-----------|
| U1 | fresh v3 socket | inject CONNECT `{sid:"s1", pid:"p1"}` | `_pid=="p1"`, `recovered==false`, `.connect` payload includes `"recovered": false` |
| U2 | post-U1 | inject event `["msg","hello","offset-1"]` | `_lastOffset=="offset-1"`, handler sees all 3 args unchanged |
| U3 | post-U2 | inject event `["msg","hi"]` | `_lastOffset=="hi"` (any string last-arg is captured, matches JS) |
| U3b | post-U2 | inject event `["msg", 42]` | `_lastOffset` unchanged |
| U3c | post-U1 | inject event with 300-byte String last arg | `_lastOffset` unchanged; warning logged (D1 divergence) |
| U4 | post-U2 | call `currentConnectPayload()` with `connectPayload={"token":"t"}` | returns `{pid:"p1", offset:"offset-1", token:"t"}` |
| U4b | post-U2 | call `currentConnectPayload()` with `connectPayload={"pid":"usercustom"}` | returned dict: `result["pid"] as? String == "usercustom"`, `result["offset"] as? String == "offset-1"` (compare by key lookup; dict iteration order is not guaranteed in Swift) |
| U5 | post-U4 | inject CONNECT `{sid:"s2", pid:"p1"}` | `recovered==true`, `_pid=="p1"` |
| U6 | post-U5 | inject CONNECT `{sid:"s3", pid:"p2"}` | `recovered==false`, `_pid=="p2"` |
| U7 | fresh v3 socket (no CONNECT) | inject event `["msg","x","foo"]` | `_lastOffset==nil` (capture gated on `_pid != nil`) |
| U8 | v2 manager | call `currentConnectPayload()` | returns raw `connectPayload`, no pid/offset keys |
| U8b | v2 manager | inject CONNECT `{sid:"s1"}` with payload=nil | `.connect` event data equals `[nsp]` exactly (v2 shape preserved) |
| U8c | v2 manager | inject CONNECT `{sid:"s1"}` with payload=`{x:1}` | `.connect` event data equals `[nsp, {x:1}]` exactly |
| U9 | post-U1 | inject binaryEvent `["img", <Data>, "offset-b"]` | `_lastOffset=="offset-b"` |
| U10 | fresh v3 socket | inject CONNECT `{sid:"s1"}` (no pid) | `_pid==nil`, `recovered==false` |
| U11 | post-U5 | call `socket.clearRecoveryState()` | `_pid==nil`, `_lastOffset==nil`, `recovered==false` |
| U12 | post-U1 | inject CONNECT_ERROR (`.error` packet) | `_pid` unchanged (matches JS) |
| U13 | post-U2 | `socket.disconnect()` **only** (do not call `connect()` in unit test — would require a real engine; that path is covered by a4 e2e) | after disconnect: `_pid=="p1"`, `_lastOffset=="offset-1"` (fields survived disconnect). Then call `currentConnectPayload()` directly: result has `["pid"] as? String == "p1"` and `["offset"] as? String == "offset-1"` (a4 precondition — both pid AND offset retained and would be sent on next connect) |

### 8.2 End-to-end tests — `Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift`

Real `socket.io@4.8.x` Node server, managed per test via `TestServerProcess`.

**Harness** — `TestServerProcess`:
- `setUp`: if `node_modules` missing in `Fixtures/`, run `npm install`; then `node server.js` with `PORT=0`; read stdout for `READY port=<N> secret=<hex>`; expose both
- `tearDown`: SIGTERM; wait for exit; ensure port freed
- Binding: **loopback only** (`httpServer.listen(0, '127.0.0.1')`). Any non-loopback bind attempt is a test failure.
- Control-plane auth: server generates a 32-byte hex secret on startup; every `/admin/*` request MUST carry `X-Admin-Secret: <secret>`. Missing/wrong secret → 401.
- Host header allowlist: reject requests whose `Host` is not `127.0.0.1:<PORT>` or `localhost:<PORT>` (DNS-rebinding defense).
- No CORS headers emitted (deliberate — no browser origins are allowed to call admin endpoints).
- **Threat model for the test harness**: "trusted local user". The per-run secret is emitted on Node stdout (consumed by `TestServerProcess`). Any local process owned by the same user that can read the test runner's stdout / DerivedData logs / `lsof` the Node child can harvest it. This is acceptable for a test fixture; the harness MUST NOT be repurposed outside the test target. If that assumption ever becomes inadequate, move the secret to a 0600 temp file and pass the path.
- Log redaction: `pid` values are never written to stdout/stderr by the server; test assertions that need pid consume it via the authenticated `GET /admin/last-auth` call and redact before logging in Swift.
- Control plane (same port, `/admin/*`):
  - `POST /admin/kill-transport?sid=<sid>` → `io.sockets.sockets.get(sid).conn.close()` (abrupt, no DISCONNECT packet)
  - `POST /admin/emit?event=<e>&data=<jsonArray>[&binary=true]` → broadcasts the event; offset is appended by the socket.io adapter when recovery is enabled
  - `GET /admin/last-auth?sid=<sid>` → returns the raw CONNECT payload observed server-side (boolean `hasPid` plus full payload; used only by a5)
  - `POST /admin/shutdown`

**Server config** (`server.js`):
```js
import { Server } from "socket.io";
import http from "http";
import crypto from "crypto";
const SECRET = crypto.randomBytes(32).toString("hex");
const httpServer = http.createServer((req, res) => {
  if (!req.url?.startsWith("/admin/")) { res.writeHead(404).end(); return; }
  if (req.headers["x-admin-secret"] !== SECRET) { res.writeHead(401).end(); return; }
  const host = req.headers.host ?? "";
  if (!/^127\.0\.0\.1:|^localhost:/.test(host)) { res.writeHead(403).end(); return; }
  // ... route to handlers
});
const io = new Server(httpServer, {
  connectionStateRecovery: {
    maxDisconnectionDuration: 60_000,
    skipMiddlewares: true,
  },
});
httpServer.listen(0, "127.0.0.1", () => {
  const port = httpServer.address().port;
  console.log(`READY port=${port} secret=${SECRET}`);
});
```

| ID | Scenario | Steps | Assertion |
|----|----------|-------|-----------|
| a1 | Happy recovery | connect → receive 3 events → kill-transport → emit 2 events while disconnected → wait for reconnect | `recovered==true`, 2 missed events received in order, `sid` unchanged |
| a2 | Window expiry | start server with `maxDisconnectionDuration: 2000` → connect → kill-transport → wait 3 s → wait for reconnect | `recovered==false`, new `sid`, `_pid` equals new server pid |
| a3 | Fresh connect | connect | `recovered==false`, `_pid != nil` |
| a4 | Explicit disconnect | connect → receive 1 event → `socket.disconnect()` → `socket.connect()` within window | reconnect succeeds but `recovered==false`; new `sid`; new non-nil `_pid` |
| a5 | Payload merge | connect with auth `{token:"t"}` → kill → reconnect → `GET /admin/last-auth` | server observed `{token:"t", pid, offset}` on reconnect CONNECT; pid is redacted from Swift test logs |
| a6 | Offset advance | connect → server emits 5 events | `_lastOffset` equals each event's offset in turn |
| a7 | v2 no-op | v2-configured Swift client against an EIO=3 / socket.io@2 server fixture (separate `server-v2.js`) | no pid/offset sent; `recovered==false`; `.connect` event shape identical to pre-feature |
| a8 | Binary event recovery | same as a1 but missed events carry `Data` | binary data delivered intact; `_lastOffset` advances per event |

**Additional e2e cases (security hardening)**:

| ID | Scenario | Assertion |
|----|----------|-----------|
| a9 | Oversized offset | server emits event with 300-byte string last arg | client's `_lastOffset` unchanged; subsequent reconnect does NOT send the oversized string |
| a10 | Admin plane auth | test harness attempts admin request without secret | 401; test fails if accepted |

**Stability measures**:
- port 0 per test for isolation
- `XCTestExpectation` with 10 s timeouts
- `reconnectWait = 1` on `SocketManager` for fast reconnect
- `tearDown` force-kills the Node process even if a test throws

**Prerequisites**:
- `node >= 18` on the host
- first run installs fixtures via `npm install`; subsequent runs reuse `node_modules`
- `socket.io@2.x` also installed for a7 (separate `server-v2.js`)
- README and `CONTRIBUTING.md` note the requirement

## 9. Rollout

- One PR against `master`. Feature is inert on v2; the v3 path is additive except for the JSON-failure behavior change noted below.
- **Changelog — Unreleased**
  - *Features*: Connection State Recovery (v3) — new `SocketIOClient.recovered` read-only property; `.connect` event payload now carries `"recovered": Bool` on v3; new `clearRecoveryState()` method on `SocketIOClient` (see §6 note 11).
  - *Breaking (v3 only)*: `SocketManager.connectSocket` now surfaces `.error` and aborts the current connect attempt when the caller's `connectPayload` cannot be JSON-encoded (previously the connect was sent with an empty payload, silently dropping user auth). Callers relying on the silent fallback must supply a JSON-serializable dict. No change on v2.
  - *Divergences from `socket.io-client` JS 4.8.x* (documented in §6.1): 256-byte cap on captured `_lastOffset` (D1); `.error` on payload JSON failure (D2); explicit `clearRecoveryState()` API (D3).
- Version bump deferred to maintainer policy (pod/SPM). The breaking change suggests a minor bump at minimum.
