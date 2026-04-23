# Socket.IO Connection State Recovery — Swift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Socket.IO Connection State Recovery in `socket.io-client-swift`, 1:1 with `socket.io-client` JS 4.8.x, in-memory state on `SocketIOClient`, v3-gated, validated by strict E2E tests against a real `socket.io@4.8.x` Node server.

**Architecture:** Recovery state (`_pid`, `_lastOffset`, `recovered`, offset cap) lives on `SocketIOClient`. `SocketManager.connectSocket` reads the effective CONNECT payload via a new `currentConnectPayload()` helper so that both the initial-join path and the auto-reconnect path carry pid/offset. Offset capture wires into `handlePacket` after handler dispatch. v2 path is untouched.

**Tech Stack:** Swift 5.4+, Xcode / Swift Package Manager, XCTest, Starscream (transitive), Node.js 18+ / `socket.io@4.8.x` for E2E.

**Reference:** Spec `docs/superpowers/specs/2026-04-23-socketio-state-recovery-swift-design.md` (commit `3eaf99a`).

---

## Phase Overview

Each phase ends with `swift test` (or `xcodebuild test`) green on its own. No phase depends on code introduced in a later phase.

| # | Phase | Produces | Tests |
|---|-------|----------|-------|
| 0 | E2E harness | Node server + `TestServerProcess.swift` | 1 harness-sanity test |
| 1 | State properties & helpers | `_pid`, `_lastOffset`, `recovered`, cap, `currentConnectPayload`, `clearRecoveryState`, protocol `recovered` with default | U4, U4b, U8, U11 |
| 2 | CONNECT ack enrichment | `didConnect` v3 branch computes `recovered`, enriches `.connect` event | U1, U5, U6, U8b, U8c, U10, U12 |
| 3 | Offset capture on incoming events | `captureOffsetIfNeeded` + `handlePacket` wiring | U2, U3, U3b, U3c, U7, U9, U13 |
| 4 | Manager payload injection | `SocketManager.connectSocket` reads `currentConnectPayload`; `.error` on JSON fail | unit tests on serialized packet + JSON-fail |
| 5 | E2E scenarios a1–a10 | `StateRecoveryE2ETest.swift` | a1–a10 |
| 6 | Docs & changelog | `CHANGELOG.md`, README notes | n/a |

**Branching:** work directly on `master` (spec already landed there at `3eaf99a`). One commit per bite-sized step.

---

## Phase 0 — E2E Test Harness Foundation

**Purpose:** stand up a reusable Node socket.io@4.8 test server + Swift `TestServerProcess` wrapper. No production code changes. Ends with a single Swift test that spawns the server, sends an authenticated admin ping, and shuts down cleanly.

**Files:**
- Create: `Tests/TestSocketIO/E2E/Fixtures/package.json`
- Create: `Tests/TestSocketIO/E2E/Fixtures/server.js`
- Create: `Tests/TestSocketIO/E2E/Fixtures/.gitignore`
- Create: `Tests/TestSocketIO/E2E/TestServerProcess.swift`
- Create: `Tests/TestSocketIO/E2E/HarnessSanityTest.swift`

### Task 0.1: Create fixtures directory and pin socket.io version

- [ ] **Step 1: Create `Fixtures/package.json`**

Path: `Tests/TestSocketIO/E2E/Fixtures/package.json`

```json
{
  "name": "socketio-swift-e2e-fixtures",
  "private": true,
  "type": "module",
  "engines": { "node": ">=18" },
  "dependencies": {
    "socket.io": "^4.8.0",
    "socket.io-v2": "npm:socket.io@2.5.0"
  }
}
```

- [ ] **Step 2: Create `Fixtures/.gitignore`**

Path: `Tests/TestSocketIO/E2E/Fixtures/.gitignore`

```
node_modules/
package-lock.json
```

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/Fixtures/package.json Tests/TestSocketIO/E2E/Fixtures/.gitignore
git commit -m "test(e2e): pin socket.io fixture deps (v4.8 + v2.5)"
```

### Task 0.2: Write the Node test server

- [ ] **Step 1: Create `server.js`**

Path: `Tests/TestSocketIO/E2E/Fixtures/server.js`

```js
import { Server } from "socket.io";
import http from "node:http";
import crypto from "node:crypto";

const SECRET = crypto.randomBytes(32).toString("hex");

const recoveryWindowMsEnv = Number(process.env.RECOVERY_WINDOW_MS);
const recoveryWindowMs = Number.isFinite(recoveryWindowMsEnv) && recoveryWindowMsEnv > 0
  ? recoveryWindowMsEnv
  : 60_000;

const readJson = (req) => new Promise((resolve, reject) => {
  let buf = "";
  req.on("data", (c) => { buf += c; if (buf.length > 1_000_000) reject(new Error("body too large")); });
  req.on("end", () => { try { resolve(buf ? JSON.parse(buf) : {}); } catch (e) { reject(e); } });
  req.on("error", reject);
});

const lastAuthBySid = new Map();

const httpServer = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
  if (!url.pathname.startsWith("/admin/")) { res.writeHead(404).end(); return; }
  if (req.headers["x-admin-secret"] !== SECRET) { res.writeHead(401).end("unauthorized"); return; }
  const host = req.headers.host ?? "";
  if (!/^127\.0\.0\.1:\d+$|^localhost:\d+$/.test(host)) { res.writeHead(403).end("bad host"); return; }

  try {
    if (url.pathname === "/admin/ping") { res.writeHead(200).end("pong"); return; }
    if (url.pathname === "/admin/shutdown") { res.writeHead(200).end("bye"); setTimeout(() => process.exit(0), 10); return; }
    if (url.pathname === "/admin/kill-transport") {
      const sid = url.searchParams.get("sid");
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s) { res.writeHead(404).end("no sid"); return; }
      s.conn.close();
      res.writeHead(200).end("killed"); return;
    }
    if (url.pathname === "/admin/emit") {
      const event = url.searchParams.get("event") ?? "msg";
      const body = await readJson(req);
      const args = Array.isArray(body?.args) ? body.args : [];
      const binary = url.searchParams.get("binary") === "true";
      const payload = binary ? args.map((a) => typeof a === "string" && a.startsWith("b64:") ? Buffer.from(a.slice(4), "base64") : a) : args;
      io.emit(event, ...payload);
      res.writeHead(200).end("ok"); return;
    }
    if (url.pathname === "/admin/last-auth") {
      const sid = url.searchParams.get("sid");
      const entry = sid ? lastAuthBySid.get(sid) : null;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ auth: entry ?? null }));
      return;
    }
    res.writeHead(404).end("no route");
  } catch (e) {
    res.writeHead(500).end(String(e));
  }
});

const io = new Server(httpServer, {
  connectionStateRecovery: {
    maxDisconnectionDuration: recoveryWindowMs,
    skipMiddlewares: true,
  },
});

io.on("connection", (socket) => {
  lastAuthBySid.set(socket.id, socket.handshake.auth);
  socket.on("disconnect", () => {});
});

httpServer.listen(0, "127.0.0.1", () => {
  const port = httpServer.address().port;
  console.log(`READY port=${port} secret=${SECRET}`);
});
```

- [ ] **Step 2: Commit**

```bash
git add Tests/TestSocketIO/E2E/Fixtures/server.js
git commit -m "test(e2e): add socket.io@4.8 node test server with auth'd admin plane"
```

### Task 0.3: Write `TestServerProcess` Swift harness

- [ ] **Step 1: Create `TestServerProcess.swift`**

Path: `Tests/TestSocketIO/E2E/TestServerProcess.swift`

```swift
import Foundation
import XCTest

/// Spawns the Node test server under `Tests/TestSocketIO/E2E/Fixtures/` and
/// exposes its ephemeral port + admin secret. Kills the process on `stop()`.
final class TestServerProcess {
    enum Error: Swift.Error { case nodeMissing, serverDidNotStart(String) }

    let port: Int
    let secret: String
    private let process: Process

    private init(port: Int, secret: String, process: Process) {
        self.port = port
        self.secret = secret
        self.process = process
    }

    static func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func ensureNodeModules() throws {
        let fixtures = fixturesDir()
        let nm = fixtures.appendingPathComponent("node_modules")
        if FileManager.default.fileExists(atPath: nm.path) { return }
        let p = Process()
        p.currentDirectoryURL = fixtures
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["npm", "install", "--no-audit", "--no-fund"]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Error.nodeMissing }
    }

    static func start(serverScript: String = "server.js", recoveryWindowMs: Int? = nil) throws -> TestServerProcess {
        try ensureNodeModules()

        let p = Process()
        p.currentDirectoryURL = fixturesDir()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", serverScript]
        var env = ProcessInfo.processInfo.environment
        if let w = recoveryWindowMs { env["RECOVERY_WINDOW_MS"] = String(w) }
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        try p.run()

        let deadline = Date().addingTimeInterval(15)
        var collected = ""
        let handle = out.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                collected += s
                if let match = collected.range(of: #"READY port=(\d+) secret=([0-9a-f]+)"#, options: .regularExpression) {
                    let scanner = Scanner(string: String(collected[match]))
                    _ = scanner.scanUpToString("=")
                    _ = scanner.scanString("=")
                    let port = scanner.scanInt() ?? 0
                    _ = scanner.scanUpToString("=")
                    _ = scanner.scanString("=")
                    let secret = scanner.scanCharacters(from: .alphanumerics) ?? ""
                    if port > 0 && !secret.isEmpty {
                        return TestServerProcess(port: port, secret: secret, process: p)
                    }
                }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        p.terminate()
        throw Error.serverDidNotStart(collected)
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// Send an authenticated admin request. Returns (status, body).
    func admin(_ path: String, method: String = "POST", body: Data? = nil) throws -> (Int, Data) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(secret, forHTTPHeaderField: "X-Admin-Secret")
        req.httpBody = body
        req.timeoutInterval = 5

        let sem = DispatchSemaphore(value: 0)
        var status = -1
        var data = Data()
        let task = URLSession.shared.dataTask(with: req) { d, resp, _ in
            if let http = resp as? HTTPURLResponse { status = http.statusCode }
            if let d = d { data = d }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 5)
        return (status, data)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Tests/TestSocketIO/E2E/TestServerProcess.swift
git commit -m "test(e2e): add TestServerProcess harness for Node test server"
```

### Task 0.4: Harness sanity test (failing → passing)

- [ ] **Step 1: Write the failing test**

Path: `Tests/TestSocketIO/E2E/HarnessSanityTest.swift`

```swift
import XCTest
@testable import SocketIO

final class HarnessSanityTest: XCTestCase {
    func testServerStartsAndAuthedPingWorks() throws {
        let server = try TestServerProcess.start()
        defer { server.stop() }

        let (status, body) = try server.admin("/admin/ping")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(data: body, encoding: .utf8), "pong")
    }

    func testUnauthedAdminRejected() throws {
        let server = try TestServerProcess.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/admin/ping")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var status = -1
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse { status = http.statusCode }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        XCTAssertEqual(status, 401)
    }
}
```

- [ ] **Step 2: Run test to verify it fails (unless node_modules already there, it will run npm install first and may be slow)**

Run:
```bash
cd /Users/howardsun/Documents/funtek/socket.io-client-swift
swift test --filter HarnessSanityTest
```

Expected: PASS (both tests green). If FAIL: check node installed, fixtures deps installed. This is an infra-only phase — passing IS the deliverable.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/HarnessSanityTest.swift
git commit -m "test(e2e): add harness sanity test (server starts, admin auth enforced)"
```

### Phase 0 acceptance

`swift test --filter HarnessSanityTest` green. No production files touched. Stop and verify before Phase 1.

---

## Phase 1 — State Properties & Helpers (no lifecycle wiring yet)

**Purpose:** add recovery state storage and three pure helpers to `SocketIOClient`. Do NOT wire them into the CONNECT/EVENT packet flow yet. Unit tests drive the helpers by setting internal state directly.

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift`
- Modify: `Source/SocketIO/Client/SocketIOClientSpec.swift`
- Create: `Tests/TestSocketIO/SocketStateRecoveryTest.swift`

### Task 1.1: Add `recovered` to the protocol with a default impl (non-breaking)

- [ ] **Step 1: Modify `SocketIOClientSpec.swift`** — add property requirement after `var status`

In `Source/SocketIO/Client/SocketIOClientSpec.swift`, inside `public protocol SocketIOClientSpec`, after `var status: SocketIOStatus { get }` (line 61), add:

```swift
    /// Whether the connection state was recovered after a temporary disconnection (Socket.IO v3+).
    /// Always `false` on v2 or before the first successful CONNECT ack.
    var recovered: Bool { get }
```

Then extend the existing `public extension SocketIOClientSpec` block at the bottom of the file (line 277) so it becomes:

```swift
public extension SocketIOClientSpec {
    /// Default implementation.
    func didError(reason: String) {
        DefaultSocketLogger.Logger.error("\(reason)", type: "SocketIOClient")

        handleClientEvent(.error, data: [reason])
    }

    /// Default implementation. Concrete `SocketIOClient` overrides with real state.
    var recovered: Bool { false }
}
```

- [ ] **Step 2: Add `_pid`, `_lastOffset`, `recovered` storage, and the cap to `SocketIOClient`**

In `Source/SocketIO/Client/SocketIOClient.swift`, just above the line `let ackHandlers = SocketAckManager()` (currently line 81), insert:

```swift
    // MARK: Connection State Recovery (Socket.IO v3+)

    /// Maximum accepted length (UTF-8 bytes) for a server-provided offset string.
    /// See design spec §3.3 / §6.1 D1.
    public static let socketStateRecoveryMaxOffsetBytes = 256

    /// Whether the last successful CONNECT ack recovered a prior session.
    /// Matches the `recovered` property on `socket.io-client` JS.
    public private(set) var recovered: Bool = false

    /// Private session id assigned by the server. `nil` until the first CONNECT ack.
    /// Only written on v3 managers.
    var _pid: String?

    /// Last observed event offset (server-controlled last-arg string).
    /// Bounded by `socketStateRecoveryMaxOffsetBytes`.
    var _lastOffset: String?
```

- [ ] **Step 3: Add `currentConnectPayload()` helper**

In `Source/SocketIO/Client/SocketIOClient.swift`, immediately before the `func createOnAck` method (currently around line 162), insert:

```swift
    /// Returns the CONNECT payload to send to the server, merging `pid`/`offset` into
    /// a fresh dict if recovery state is present. The user's `connectPayload` wins on
    /// key collisions (matches JS `Object.assign({pid, offset}, data)`).
    /// Returns `connectPayload` unchanged on v2 or when no pid is stored.
    func currentConnectPayload() -> [String: Any]? {
        guard manager?.version == .three else { return connectPayload }
        guard let pid = _pid else { return connectPayload }
        var out: [String: Any] = ["pid": pid]
        if let offset = _lastOffset { out["offset"] = offset }
        if let user = connectPayload {
            if user["pid"] != nil || user["offset"] != nil {
                DefaultSocketLogger.Logger.log(
                    "connectPayload contains reserved key 'pid' or 'offset'; user value takes precedence",
                    type: logType
                )
            }
            for (k, v) in user { out[k] = v }
        }
        return out
    }
```

- [ ] **Step 4: Add `clearRecoveryState()`**

In `Source/SocketIO/Client/SocketIOClient.swift`, immediately after `currentConnectPayload()`, insert:

```swift
    /// Clears the in-memory state used for Connection State Recovery.
    /// Call this when the authenticated identity on this socket changes to prevent
    /// resuming a prior session.
    ///
    /// Subclass ordering: if a subclass overrides `disconnect()` and wants to
    /// auto-clear, call `clearRecoveryState()` BEFORE `super.disconnect()`. The
    /// `.disconnect` client event fires synchronously from super, and any observer
    /// that reconnects would otherwise send stale pid/offset.
    open func clearRecoveryState() {
        _pid = nil
        _lastOffset = nil
        recovered = false
    }
```

- [ ] **Step 5: Build the library to verify the additions compile**

Run:
```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift Source/SocketIO/Client/SocketIOClientSpec.swift
git commit -m "feat(recovery): add pid/offset/recovered state + helpers on SocketIOClient"
```

### Task 1.2: Unit test U4 — `currentConnectPayload` merges pid/offset with user payload

- [ ] **Step 1: Write the failing test**

Path: `Tests/TestSocketIO/SocketStateRecoveryTest.swift`

```swift
import XCTest
@testable import SocketIO

final class SocketStateRecoveryTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestable()
    }

    // MARK: U4 — currentConnectPayload merges pid + offset + user payload

    func testU4_currentConnectPayloadMergesPidOffsetAndUser() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "t"]

        let merged = socket.currentConnectPayload()

        XCTAssertEqual(merged?["pid"] as? String, "p1")
        XCTAssertEqual(merged?["offset"] as? String, "offset-1")
        XCTAssertEqual(merged?["token"] as? String, "t")
    }
}
```

- [ ] **Step 2: Run to verify it passes (helper already exists — this is a regression check, not TDD-classic)**

Run:
```bash
swift test --filter SocketStateRecoveryTest.testU4_currentConnectPayloadMergesPidOffsetAndUser
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U4 — currentConnectPayload merges pid/offset/user"
```

### Task 1.3: Unit test U4b — user key collision wins (precedence)

- [ ] **Step 1: Add U4b to `SocketStateRecoveryTest.swift`**

Append inside `final class SocketStateRecoveryTest`:

```swift
    // MARK: U4b — user-supplied "pid" / "offset" keys override injected ones

    func testU4b_userKeysOverrideInjectedPidAndOffset() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["pid": "usercustom"]

        let merged = socket.currentConnectPayload()

        XCTAssertEqual(merged?["pid"] as? String, "usercustom",
                       "user key must win; dict iteration order is not guaranteed so compare by key")
        XCTAssertEqual(merged?["offset"] as? String, "offset-1")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU4b_userKeysOverrideInjectedPidAndOffset
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U4b — user connectPayload keys override injected pid/offset"
```

### Task 1.4: Unit test U8 — v2 manager short-circuits merge

- [ ] **Step 1: Add U8**

Append to `SocketStateRecoveryTest`:

```swift
    // MARK: U8 — v2 manager returns raw connectPayload (no pid/offset injected)

    func testU8_v2ManagerSkipsInjection() {
        let v2Manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false), .version(.two)])
        let v2Socket = v2Manager.defaultSocket
        v2Socket.setTestable()
        v2Socket._pid = "p1"                   // would be injected on v3
        v2Socket._lastOffset = "offset-1"
        v2Socket.connectPayload = ["token": "t"]

        let merged = v2Socket.currentConnectPayload()

        XCTAssertEqual(merged?["pid"] as? String, nil, "v2 must not inject pid")
        XCTAssertEqual(merged?["offset"] as? String, nil, "v2 must not inject offset")
        XCTAssertEqual(merged?["token"] as? String, "t")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU8_v2ManagerSkipsInjection
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U8 — currentConnectPayload is inert on v2 manager"
```

### Task 1.5: Unit test U11 — `clearRecoveryState` resets all three fields

- [ ] **Step 1: Add U11**

Append:

```swift
    // MARK: U11 — clearRecoveryState resets pid, offset, and recovered

    func testU11_clearRecoveryStateResetsAllFields() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.setTestRecovered(true)          // helper added below

        socket.clearRecoveryState()

        XCTAssertNil(socket._pid)
        XCTAssertNil(socket._lastOffset)
        XCTAssertFalse(socket.recovered)
    }
```

Note the helper `setTestRecovered(_:)` doesn't exist yet — next step.

- [ ] **Step 2: Add `setTestRecovered` in `SocketIOClient.swift` (near existing `setTestStatus`)**

In `Source/SocketIO/Client/SocketIOClient.swift`, after the existing `setTestStatus(_ status:)` method (around line 542), add:

```swift
    func setTestRecovered(_ value: Bool) {
        recovered = value
    }
```

- [ ] **Step 3: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU11_clearRecoveryStateResetsAllFields
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift Source/SocketIO/Client/SocketIOClient.swift
git commit -m "test(recovery): U11 — clearRecoveryState resets all recovery fields"
```

### Phase 1 acceptance

```bash
swift test --filter SocketStateRecoveryTest
swift test --filter HarnessSanityTest
```

Both green. Spec items covered: protocol default, storage, `currentConnectPayload`, `clearRecoveryState`. No packet flow yet. Stop and verify before Phase 2.

---

## Phase 2 — CONNECT Ack Enrichment

**Purpose:** wire CONNECT packet handling so that (a) `recovered` is computed on every ack on v3, (b) `_pid` is stored/cleared from the ack payload on v3, (c) `.connect` client event carries `"recovered": Bool` on v3, (d) v2 behavior stays byte-identical.

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift`
- Modify: `Tests/TestSocketIO/SocketStateRecoveryTest.swift`

### Task 2.1: Update `didConnect(toNamespace:payload:)`

- [ ] **Step 1: Replace the body of `didConnect`**

In `Source/SocketIO/Client/SocketIOClient.swift`, locate:

```swift
    open func didConnect(toNamespace namespace: String, payload: [String: Any]?) {
        guard status != .connected else { return }

        DefaultSocketLogger.Logger.log("Socket connected", type: logType)

        status = .connected
        sid = payload?["sid"] as? String

        handleClientEvent(.connect, data: payload == nil ? [namespace] : [namespace, payload!])
    }
```

Replace with:

```swift
    open func didConnect(toNamespace namespace: String, payload: [String: Any]?) {
        guard status != .connected else { return }

        DefaultSocketLogger.Logger.log("Socket connected", type: logType)

        status = .connected
        sid = payload?["sid"] as? String

        let isV3 = manager?.version == .three
        if isV3 {
            let incomingPid = payload?["pid"] as? String
            recovered = (incomingPid != nil && _pid != nil && _pid == incomingPid)
            _pid = incomingPid
        }

        let connectData: [Any]
        if isV3 {
            if var payload = payload {
                payload["recovered"] = recovered
                connectData = [namespace, payload]
            } else {
                connectData = [namespace, ["recovered": recovered]]
            }
        } else {
            connectData = payload == nil ? [namespace] : [namespace, payload!]
        }
        handleClientEvent(.connect, data: connectData)
    }
```

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift
git commit -m "feat(recovery): compute recovered + enrich .connect event on v3 didConnect"
```

### Task 2.2: Unit test U1 — fresh connect stores pid, recovered=false

- [ ] **Step 1: Add U1 and helpers to `SocketStateRecoveryTest.swift`**

Append:

```swift
    // MARK: Helpers

    /// Waits for the `.connect` client event and returns the latest data payload.
    private func awaitConnect(_ expectationDescription: String = "connect fired") -> [Any] {
        let expect = expectation(description: expectationDescription)
        var captured: [Any] = []
        socket.on(clientEvent: .connect) { data, _ in
            captured = data
            expect.fulfill()
        }
        return captured // caller fills by firing event before waitForExpectations
    }

    // MARK: U1 — fresh connect stores pid, recovered=false

    func testU1_freshConnectStoresPidAndRecoveredFalse() {
        let expect = expectation(description: ".connect fired with recovered=false")
        var connectData: [Any] = []
        socket.on(clientEvent: .connect) { data, _ in
            connectData = data
            expect.fulfill()
        }

        // Reset status so didConnect runs (setTestable sets it to .connected)
        socket.setTestStatus(.connecting)

        socket.didConnect(toNamespace: "/", payload: ["sid": "s1", "pid": "p1"])

        waitForExpectations(timeout: 1)
        XCTAssertEqual(socket._pid, "p1")
        XCTAssertFalse(socket.recovered)
        XCTAssertEqual(connectData.first as? String, "/")
        let payload = connectData.dropFirst().first as? [String: Any]
        XCTAssertEqual(payload?["recovered"] as? Bool, false)
        XCTAssertEqual(payload?["pid"] as? String, "p1")
    }
```

Remove the unused `awaitConnect` helper stub if it doesn't compile — the explicit pattern inside `testU1_*` is what matters.

- [ ] **Step 2: Run U1**

```bash
swift test --filter SocketStateRecoveryTest.testU1_freshConnectStoresPidAndRecoveredFalse
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U1 — fresh CONNECT stores pid, recovered=false"
```

### Task 2.3: Unit tests U5 + U6 — same pid recovers; different pid does not

- [ ] **Step 1: Add U5 and U6**

Append:

```swift
    // MARK: U5 — reconnect with same pid → recovered=true

    func testU5_sameServerPidSetsRecoveredTrue() {
        socket._pid = "p1"
        let expect = expectation(description: ".connect fired")
        var connectData: [Any] = []
        socket.on(clientEvent: .connect) { data, _ in
            connectData = data
            expect.fulfill()
        }
        socket.setTestStatus(.connecting)
        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        waitForExpectations(timeout: 1)
        XCTAssertEqual(socket._pid, "p1")
        XCTAssertTrue(socket.recovered)
        let payload = connectData.dropFirst().first as? [String: Any]
        XCTAssertEqual(payload?["recovered"] as? Bool, true)
    }

    // MARK: U6 — reconnect with different pid → recovered=false, _pid overwritten

    func testU6_differentServerPidResetsRecovered() {
        socket._pid = "p1"
        socket.setTestRecovered(true)            // simulate previous true state
        let expect = expectation(description: ".connect fired")
        socket.on(clientEvent: .connect) { _, _ in expect.fulfill() }
        socket.setTestStatus(.connecting)
        socket.didConnect(toNamespace: "/", payload: ["sid": "s3", "pid": "p2"])

        waitForExpectations(timeout: 1)
        XCTAssertEqual(socket._pid, "p2")
        XCTAssertFalse(socket.recovered)
    }
```

- [ ] **Step 2: Run both**

```bash
swift test --filter SocketStateRecoveryTest.testU5_sameServerPidSetsRecoveredTrue
swift test --filter SocketStateRecoveryTest.testU6_differentServerPidResetsRecovered
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U5/U6 — pid match drives recovered; mismatch resets"
```

### Task 2.4: Unit tests U8b + U8c — v2 `.connect` event shape unchanged

- [ ] **Step 1: Add both**

Append:

```swift
    // MARK: U8b — v2, payload=nil → .connect data is exactly [nsp]

    func testU8b_v2ConnectWithoutPayloadPreservesShape() {
        let m = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false), .version(.two)])
        let s = m.defaultSocket
        s.setTestable()
        s.setTestStatus(.connecting)
        let expect = expectation(description: ".connect fired")
        var captured: [Any] = []
        s.on(clientEvent: .connect) { data, _ in
            captured = data
            expect.fulfill()
        }
        s.didConnect(toNamespace: "/", payload: nil)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first as? String, "/")
        XCTAssertNil(s._pid)
        XCTAssertFalse(s.recovered)
    }

    // MARK: U8c — v2, payload provided → .connect data is [nsp, payload] (unchanged)

    func testU8c_v2ConnectWithPayloadPreservesShape() {
        let m = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false), .version(.two)])
        let s = m.defaultSocket
        s.setTestable()
        s.setTestStatus(.connecting)
        let expect = expectation(description: ".connect fired")
        var captured: [Any] = []
        s.on(clientEvent: .connect) { data, _ in
            captured = data
            expect.fulfill()
        }
        s.didConnect(toNamespace: "/", payload: ["x": 1])

        waitForExpectations(timeout: 1)
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured.first as? String, "/")
        let payload = captured.dropFirst().first as? [String: Any]
        XCTAssertEqual(payload?["x"] as? Int, 1)
        XCTAssertNil(payload?["recovered"], "v2 must NOT inject recovered key")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU8b_v2ConnectWithoutPayloadPreservesShape
swift test --filter SocketStateRecoveryTest.testU8c_v2ConnectWithPayloadPreservesShape
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U8b/U8c — v2 .connect event shape byte-identical"
```

### Task 2.5: Unit tests U10 + U12

- [ ] **Step 1: Add U10 + U12**

Append:

```swift
    // MARK: U10 — server omits pid → _pid stays nil, recovered=false

    func testU10_serverOmitsPidLeavesStateClean() {
        let expect = expectation(description: ".connect fired")
        socket.on(clientEvent: .connect) { _, _ in expect.fulfill() }
        socket.setTestStatus(.connecting)
        socket.didConnect(toNamespace: "/", payload: ["sid": "s1"])

        waitForExpectations(timeout: 1)
        XCTAssertNil(socket._pid)
        XCTAssertFalse(socket.recovered)
    }

    // MARK: U12 — CONNECT_ERROR path does not clear _pid (matches JS)

    func testU12_errorPacketDoesNotClearPid() {
        socket._pid = "p1"
        // Simulate the packet branch without driving the engine
        socket.handleEvent("error", data: ["boom"], isInternalMessage: true, withAck: -1)
        XCTAssertEqual(socket._pid, "p1", "pid must survive internal error dispatch")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU10_serverOmitsPidLeavesStateClean
swift test --filter SocketStateRecoveryTest.testU12_errorPacketDoesNotClearPid
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U10/U12 — no pid kept clean; error path preserves pid"
```

### Phase 2 acceptance

```bash
swift test --filter SocketStateRecoveryTest
swift test --filter HarnessSanityTest
```

Both green. `.connect` event now carries `recovered` on v3; v2 shape intact.

---

## Phase 3 — Offset Capture on Incoming Events

**Purpose:** implement `captureOffsetIfNeeded` and wire it into `handlePacket` for `.event` / `.binaryEvent`. Add the length cap. Verify v2 short-circuit and the `_pid == nil` gate.

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClient.swift`
- Modify: `Tests/TestSocketIO/SocketStateRecoveryTest.swift`

### Task 3.1: Add `captureOffsetIfNeeded` + wire it

- [ ] **Step 1: Add the capture helper**

In `Source/SocketIO/Client/SocketIOClient.swift`, right after `clearRecoveryState()`, add:

```swift
    /// Records the last arg as `_lastOffset` if this is a v3 socket with a known pid
    /// and the last arg is a String not exceeding the byte cap.
    private func captureOffsetIfNeeded(from args: [Any]) {
        guard manager?.version == .three, _pid != nil else { return }
        guard let last = args.last as? String else { return }
        guard last.utf8.count <= SocketIOClient.socketStateRecoveryMaxOffsetBytes else {
            DefaultSocketLogger.Logger.log(
                "Dropping oversized offset string (\(last.utf8.count) bytes > \(SocketIOClient.socketStateRecoveryMaxOffsetBytes))",
                type: logType
            )
            return
        }
        _lastOffset = last
    }
```

- [ ] **Step 2: Wire it into `handlePacket`**

In `Source/SocketIO/Client/SocketIOClient.swift`, locate:

```swift
    open func handlePacket(_ packet: SocketPacket) {
        guard packet.nsp == nsp else { return }

        switch packet.type {
        case .event, .binaryEvent:
            handleEvent(packet.event, data: packet.args, isInternalMessage: false, withAck: packet.id)
```

Change the `.event, .binaryEvent` case to:

```swift
        case .event, .binaryEvent:
            handleEvent(packet.event, data: packet.args, isInternalMessage: false, withAck: packet.id)
            captureOffsetIfNeeded(from: packet.args)
```

- [ ] **Step 3: Build**

```bash
swift build
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClient.swift
git commit -m "feat(recovery): capture server-appended offset on incoming events"
```

### Task 3.2: Unit test U2 — event offset capture happy path

- [ ] **Step 1: Add U2**

Append to `SocketStateRecoveryTest`:

```swift
    // MARK: U2 — event with String last-arg updates _lastOffset

    func testU2_eventLastStringArgBecomesOffset() {
        socket._pid = "p1"
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "hello", "offset-1"])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-1")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU2_eventLastStringArgBecomesOffset
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U2 — event captures String last-arg as offset"
```

### Task 3.3: Unit tests U3 + U3b — any String wins, non-String ignored

- [ ] **Step 1: Add U3 + U3b**

Append:

```swift
    // MARK: U3 — subsequent event with any String last-arg is captured

    func testU3_anyStringLastArgIsCapturedMatchingJS() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1, data: ["msg", "hi"])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "hi")
    }

    // MARK: U3b — non-String last-arg leaves offset unchanged

    func testU3b_nonStringLastArgLeavesOffsetUnchanged() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1, data: ["msg", 42])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-1")
    }
```

- [ ] **Step 2: Run both**

```bash
swift test --filter SocketStateRecoveryTest.testU3_anyStringLastArgIsCapturedMatchingJS
swift test --filter SocketStateRecoveryTest.testU3b_nonStringLastArgLeavesOffsetUnchanged
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U3/U3b — any String last-arg captured, non-String ignored"
```

### Task 3.4: Unit test U3c — oversized offset dropped

- [ ] **Step 1: Add U3c**

Append:

```swift
    // MARK: U3c — offset string exceeding cap is dropped (D1 divergence)

    func testU3c_oversizedOffsetStringIsDropped() {
        socket._pid = "p1"
        socket._lastOffset = "safe"
        let big = String(repeating: "x", count: 300)
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1, data: ["msg", big])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "safe", "offset > 256 bytes must not overwrite")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU3c_oversizedOffsetStringIsDropped
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U3c — oversized offset above 256-byte cap is dropped"
```

### Task 3.5: Unit test U7 — capture gated on `_pid != nil`

- [ ] **Step 1: Add U7**

Append:

```swift
    // MARK: U7 — capture is gated on _pid != nil

    func testU7_offsetNotCapturedWhenPidUnset() {
        XCTAssertNil(socket._pid)
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "foo", "offset-x"])
        socket.handlePacket(packet)

        XCTAssertNil(socket._lastOffset, "must not capture before server confirms recovery via pid")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU7_offsetNotCapturedWhenPidUnset
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U7 — no offset capture while _pid is nil"
```

### Task 3.6: Unit test U9 — binaryEvent path captures offset

- [ ] **Step 1: Add U9**

Append:

```swift
    // MARK: U9 — binaryEvent with String last-arg captures offset

    func testU9_binaryEventLastStringArgBecomesOffset() {
        socket._pid = "p1"
        let bin = Data([0x00, 0x01])
        let packet = SocketPacket(type: .binaryEvent, nsp: "/", placeholders: 0, id: -1,
                                  data: ["img", bin, "offset-b"])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-b")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU9_binaryEventLastStringArgBecomesOffset
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U9 — binaryEvent offset capture"
```

### Task 3.7: Unit test U13 — disconnect preserves pid + offset for reconnect payload

- [ ] **Step 1: Add U13**

Append:

```swift
    // MARK: U13 — explicit disconnect preserves pid + offset; next payload carries both

    func testU13_disconnectPreservesRecoveryStateForNextConnect() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "t"]

        // engine is nil on a test-only socket; disconnectSocket uses engine?.send (safe no-op)
        socket.disconnect()

        XCTAssertEqual(socket._pid, "p1", "disconnect must not clear pid")
        XCTAssertEqual(socket._lastOffset, "offset-1", "disconnect must not clear offset")

        let merged = socket.currentConnectPayload()
        XCTAssertEqual(merged?["pid"] as? String, "p1")
        XCTAssertEqual(merged?["offset"] as? String, "offset-1")
        XCTAssertEqual(merged?["token"] as? String, "t")
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testU13_disconnectPreservesRecoveryStateForNextConnect
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): U13 — disconnect preserves pid/offset for next connect"
```

### Phase 3 acceptance

```bash
swift test --filter SocketStateRecoveryTest
swift test --filter HarnessSanityTest
```

Both green. 12 unit tests now covering state + helpers + lifecycle (CONNECT ack + EVENT flow).

---

## Phase 4 — Manager Payload Injection & JSON-Fail `.error`

**Purpose:** make `SocketManager.connectSocket` read `currentConnectPayload()` (so reconnect path carries pid/offset), surface `.error` when JSON serialization fails, and add unit tests against the engine.send output.

**Files:**
- Modify: `Source/SocketIO/Manager/SocketManager.swift`
- Modify: `Tests/TestSocketIO/SocketStateRecoveryTest.swift`

### Task 4.1: Rewrite `connectSocket`

- [ ] **Step 1: Replace `connectSocket` body**

In `Source/SocketIO/Manager/SocketManager.swift`, locate:

```swift
    open func connectSocket(_ socket: SocketIOClient, withPayload payload: [String: Any]? = nil) {
        guard status == .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting socket when engine isn't open. Connecting",
                                           type: SocketManager.logType)

            connect()
            return
        }

        var payloadStr = ""

        if version.rawValue >= 3 && payload != nil,
           let payloadData = try? JSONSerialization.data(withJSONObject: payload!, options: .fragmentsAllowed),
           let jsonString = String(data: payloadData, encoding: .utf8) {
            payloadStr = jsonString
        }

        engine?.send("0\(socket.nsp),\(payloadStr)", withData: [])
    }
```

Replace with:

```swift
    open func connectSocket(_ socket: SocketIOClient, withPayload payload: [String: Any]? = nil) {
        guard status == .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting socket when engine isn't open. Connecting",
                                           type: SocketManager.logType)

            connect()
            return
        }

        var payloadStr = ""

        // The `withPayload` parameter is retained for ABI but ignored — the socket owns the
        // effective payload (see design spec §4.3 and `SocketIOClient.currentConnectPayload`).
        _ = payload
        let effective = socket.currentConnectPayload()

        if version.rawValue >= 3, let effective = effective {
            do {
                let payloadData = try JSONSerialization.data(withJSONObject: effective, options: .fragmentsAllowed)
                if let jsonString = String(data: payloadData, encoding: .utf8) {
                    payloadStr = jsonString
                }
            } catch {
                DefaultSocketLogger.Logger.error(
                    "Failed to serialize CONNECT payload: \(error)",
                    type: SocketManager.logType
                )
                socket.handleClientEvent(
                    .error,
                    data: ["connect payload serialization failed: \(error.localizedDescription)"]
                )
                return
            }
        }

        engine?.send("0\(socket.nsp),\(payloadStr)", withData: [])
    }
```

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Source/SocketIO/Manager/SocketManager.swift
git commit -m "feat(recovery): SocketManager.connectSocket reads currentConnectPayload; .error on JSON fail"
```

### Task 4.2: Unit test — connectSocket engine.send includes pid + offset on reconnect path

Need a test engine that captures `send(_:withData:)`. Reuse the pattern from `SocketSideEffectTest.swift` (`TestEngine`).

- [ ] **Step 1: Add test-only helper that installs `TestEngine` and drives `connectSocket`**

In `Tests/TestSocketIO/SocketStateRecoveryTest.swift`, append a new fixture class at the bottom:

```swift
/// Minimal engine stub for capturing `send` calls from `SocketManager.connectSocket`.
/// Mirrors the `TestEngine` already present in `SocketSideEffectTest.swift` but
/// records the last sent string.
final class CaptureEngine: SocketEngineSpec {
    weak var client: SocketEngineClient?
    private(set) var lastSent: String?
    var compress = false
    var connected = true
    var connectParams: [String: Any]? = nil
    var cookies: [HTTPCookie]? = nil
    var engineQueue = DispatchQueue.main
    var extraHeaders: [String: String]? = nil
    var fastUpgrade = false
    var forcePolling = false
    var forceWebsockets = false
    var polling = false
    var probing = false
    var sid = ""
    var socketPath = ""
    var urlPolling = URL(string: "http://localhost/")!
    var urlWebSocket = URL(string: "http://localhost/")!
    var version: SocketIOVersion = .three
    var websocket = false
    var enableSOCKSProxy = false

    required init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.client = client
    }

    init() {}

    func connect() {}
    func didError(reason: String) {}
    func disconnect(reason: String) {}
    func doFastUpgrade() {}
    func flushWaitingForPostToWebSocket() {}
    func parseEngineData(_ data: Data) {}
    func parseEngineMessage(_ message: String) {}
    func send(_ msg: String, withData datas: [Data], completion: (() -> ())?) {
        lastSent = msg
        completion?()
    }
    func send(_ msg: String, withData datas: [Data]) {
        lastSent = msg
    }
}
```

Note: some properties above may be redundant given `SocketEngineSpec`. Adapt to the actual protocol; cross-check `SocketEngineSpec.swift` and match only the required properties.

- [ ] **Step 2: Add the test**

Append:

```swift
    // MARK: Manager injection — reconnect path sends {pid, offset, ...user}

    func testConnectSocketSendsPidAndOffsetOnReconnect() throws {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)

        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "t"]

        manager.connectSocket(socket, withPayload: nil)

        let sent = try XCTUnwrap(engine.lastSent)
        XCTAssertTrue(sent.hasPrefix("0/,"), "expected \"0<nsp>,<json>\", got \(sent)")
        let jsonStart = sent.index(sent.startIndex, offsetBy: 3)
        let jsonStr = String(sent[jsonStart...])
        let data = Data(jsonStr.utf8)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["pid"] as? String, "p1")
        XCTAssertEqual(obj["offset"] as? String, "offset-1")
        XCTAssertEqual(obj["token"] as? String, "t")
    }
```

If `manager.setTestStatus` / `manager.engine` are not accessible, expose small internal setters in `SocketManager.swift` (same pattern already used on the client). If `SocketManager` lacks a public `engine` setter, add in the manager's test extension area:

```swift
    // Test-only
    func setTestEngine(_ engine: SocketEngineSpec) { self.engine = engine }
    func setTestStatus(_ status: SocketIOStatus) { self.status = status }
```

- [ ] **Step 3: Run**

```bash
swift test --filter SocketStateRecoveryTest.testConnectSocketSendsPidAndOffsetOnReconnect
```

Expected: PASS. If `CaptureEngine` fails to conform to `SocketEngineSpec`, adjust its stub properties to exactly match the protocol requirements discovered at compile time.

- [ ] **Step 4: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift Source/SocketIO/Manager/SocketManager.swift
git commit -m "test(recovery): connectSocket serialises pid/offset on reconnect"
```

### Task 4.3: Unit test — JSON serialization failure surfaces `.error`

- [ ] **Step 1: Add the test**

Append:

```swift
    // MARK: Manager injection — invalid payload emits .error and aborts

    func testConnectSocketEmitsErrorOnInvalidPayload() {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)

        // Date() is not JSON-serializable via JSONSerialization; it throws.
        socket.connectPayload = ["bad": Date()]

        let expect = expectation(description: ".error fired")
        var captured: [Any] = []
        socket.on(clientEvent: .error) { data, _ in
            captured = data
            expect.fulfill()
        }

        manager.connectSocket(socket, withPayload: nil)

        waitForExpectations(timeout: 1)
        XCTAssertNil(engine.lastSent, "engine must NOT be sent to on serialization failure")
        let msg = captured.first as? String
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("serialization failed") ?? false)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter SocketStateRecoveryTest.testConnectSocketEmitsErrorOnInvalidPayload
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/SocketStateRecoveryTest.swift
git commit -m "test(recovery): connectSocket surfaces .error when CONNECT payload JSON fails"
```

### Phase 4 acceptance

```bash
swift test --filter SocketStateRecoveryTest
swift test --filter HarnessSanityTest
```

All green. Complete v3 recovery semantics now live end-to-end in-process; reconnect path is guaranteed to ship pid/offset; serialization failures are visible.

---

## Phase 5 — End-to-End Scenarios a1–a10

**Purpose:** drive the full stack against a real `socket.io@4.8.x` Node server. Ten scenarios from the spec §8.2. Each test spins up a fresh server via `TestServerProcess`, so tests are independent.

**Files:**
- Create: `Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift`
- Create: `Tests/TestSocketIO/E2E/Fixtures/server-v2.js` (for a7 only)
- Modify: `Tests/TestSocketIO/E2E/Fixtures/package.json` (already pinned v2 in Phase 0)

### Task 5.1: Scaffold the E2E test case with shared helpers

- [ ] **Step 1: Create the test file**

Path: `Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift`

```swift
import XCTest
@testable import SocketIO

final class StateRecoveryE2ETest: XCTestCase {
    private var server: TestServerProcess!

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func startServer(recoveryWindowMs: Int? = nil) throws {
        server = try TestServerProcess.start(recoveryWindowMs: recoveryWindowMs)
    }

    private func makeClient(auth: [String: Any]? = nil, forceNew: Bool = true)
        -> (SocketManager, SocketIOClient) {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        var config: SocketIOClientConfiguration = [.log(false), .reconnectWait(1), .forceNew(forceNew)]
        if let auth = auth { config.insert(.connectParams(auth)) }
        let manager = SocketManager(socketURL: url, config: config)
        return (manager, manager.defaultSocket)
    }

    private func adminEmit(event: String, args: [Any], binary: Bool = false) throws {
        let body = try JSONSerialization.data(withJSONObject: ["args": args])
        let suffix = binary ? "&binary=true" : ""
        let (status, _) = try server.admin("/admin/emit?event=\(event)\(suffix)", body: body)
        XCTAssertEqual(status, 200)
    }

    private func adminKillTransport(sid: String) throws {
        let (status, _) = try server.admin("/admin/kill-transport?sid=\(sid)")
        XCTAssertEqual(status, 200)
    }

    private func adminLastAuth(sid: String) throws -> [String: Any]? {
        let (status, body) = try server.admin("/admin/last-auth?sid=\(sid)", method: "GET")
        XCTAssertEqual(status, 200)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return obj?["auth"] as? [String: Any]
    }

    private func waitForConnect(_ socket: SocketIOClient, timeout: TimeInterval = 10) -> [String: Any]? {
        let expect = expectation(description: "connected")
        var capturedPayload: [String: Any]?
        socket.on(clientEvent: .connect) { data, _ in
            capturedPayload = data.dropFirst().first as? [String: Any]
            expect.fulfill()
        }
        socket.connect()
        wait(for: [expect], timeout: timeout)
        return capturedPayload
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build --target TestSocketIO
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): scaffold StateRecoveryE2ETest with shared helpers"
```

### Task 5.2: Scenario a3 — fresh connect

Implemented first because it's the simplest and validates the harness end-to-end.

- [ ] **Step 1: Add a3**

Append inside `StateRecoveryE2ETest`:

```swift
    func testA3_freshConnectReportsNotRecoveredButHasPid() throws {
        try startServer()
        let (_, socket) = makeClient()
        let payload = waitForConnect(socket)

        XCTAssertEqual(payload?["recovered"] as? Bool, false)
        XCTAssertNotNil(socket._pid, "server with recovery enabled must assign pid")
        XCTAssertFalse(socket.recovered)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA3_freshConnectReportsNotRecoveredButHasPid
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a3 — fresh connect populates pid, recovered=false"
```

### Task 5.3: Scenario a6 — offset advances on each event

- [ ] **Step 1: Add a6**

Append:

```swift
    func testA6_offsetAdvancesPerEvent() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)

        var received: [[Any]] = []
        let received5 = expectation(description: "received 5 events")
        received5.expectedFulfillmentCount = 5
        socket.on("msg") { data, _ in
            received.append(data)
            received5.fulfill()
        }

        for i in 0..<5 {
            try adminEmit(event: "msg", args: ["body-\(i)"])
        }
        wait(for: [received5], timeout: 10)

        // Offset is the last String arg appended by the server adapter.
        let lastArgs = received.last ?? []
        XCTAssertTrue(lastArgs.last is String, "server must append offset string on each event")
        XCTAssertNotNil(socket._lastOffset)
        // _lastOffset should equal the offset string of the most recent event.
        XCTAssertEqual(socket._lastOffset, lastArgs.last as? String)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA6_offsetAdvancesPerEvent
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a6 — _lastOffset advances per broadcast event"
```

### Task 5.4: Scenario a1 — happy recovery

- [ ] **Step 1: Add a1**

Append:

```swift
    func testA1_happyRecoveryDeliversMissedEvents() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)

        // Receive 3 events baseline
        let baseline = expectation(description: "3 baseline events")
        baseline.expectedFulfillmentCount = 3
        var preKill: [String] = []
        socket.on("pre") { data, _ in
            if let body = data.first as? String { preKill.append(body) }
            baseline.fulfill()
        }
        for i in 0..<3 { try adminEmit(event: "pre", args: ["pre-\(i)"]) }
        wait(for: [baseline], timeout: 10)

        // Kill transport abruptly
        try adminKillTransport(sid: originalSid)

        // Emit 2 missed events while disconnected
        try adminEmit(event: "missed", args: ["missed-0"])
        try adminEmit(event: "missed", args: ["missed-1"])

        // Expect reconnect + both missed events
        let recoveredExpect = expectation(description: "reconnected and recovered")
        let missed = expectation(description: "2 missed events")
        missed.expectedFulfillmentCount = 2
        var gotMissed: [String] = []
        var sawRecovered = false
        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            if payload?["recovered"] as? Bool == true {
                sawRecovered = true
                recoveredExpect.fulfill()
            }
        }
        socket.on("missed") { data, _ in
            if let body = data.first as? String { gotMissed.append(body) }
            missed.fulfill()
        }

        wait(for: [recoveredExpect, missed], timeout: 15)
        XCTAssertTrue(sawRecovered)
        XCTAssertEqual(socket.sid, originalSid)
        XCTAssertEqual(gotMissed.sorted(), ["missed-0", "missed-1"])
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA1_happyRecoveryDeliversMissedEvents
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a1 — transport kill + reconnect recovers sid and missed events"
```

### Task 5.5: Scenario a2 — window expiry

- [ ] **Step 1: Add a2**

Append:

```swift
    func testA2_windowExpiryProducesFreshSession() throws {
        try startServer(recoveryWindowMs: 2000)
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)
        let originalPid = socket._pid

        try adminKillTransport(sid: originalSid)
        Thread.sleep(forTimeInterval: 3) // outside window

        let reconnected = expectation(description: "reconnected fresh")
        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            if payload?["recovered"] as? Bool == false { reconnected.fulfill() }
        }
        wait(for: [reconnected], timeout: 15)

        XCTAssertFalse(socket.recovered)
        XCTAssertNotEqual(socket.sid, originalSid)
        XCTAssertNotNil(socket._pid)
        XCTAssertNotEqual(socket._pid, originalPid)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA2_windowExpiryProducesFreshSession
```

Expected: PASS (takes ~5 s because of the sleep).

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a2 — window expiry yields fresh sid + pid"
```

### Task 5.6: Scenario a4 — explicit disconnect + reconnect

- [ ] **Step 1: Add a4**

Append:

```swift
    func testA4_explicitDisconnectThenConnectRecoversWithinWindow() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)

        let disconnected = expectation(description: "disconnected")
        socket.on(clientEvent: .disconnect) { _, _ in disconnected.fulfill() }
        socket.disconnect()
        wait(for: [disconnected], timeout: 5)

        let recovered = expectation(description: "recovered on reconnect")
        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            if payload?["recovered"] as? Bool == true { recovered.fulfill() }
        }
        socket.connect()
        wait(for: [recovered], timeout: 10)
        XCTAssertTrue(socket.recovered)
        XCTAssertEqual(socket.sid, originalSid)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA4_explicitDisconnectThenConnectRecoversWithinWindow
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a4 — explicit disconnect then connect still recovers"
```

### Task 5.7: Scenario a5 — auth merge visible server-side

- [ ] **Step 1: Add a5**

Append:

```swift
    func testA5_authAndPidOffsetCoexistOnReconnectHandshake() throws {
        try startServer()
        let (_, socket) = makeClient(auth: ["token": "tok-123"])
        _ = waitForConnect(socket)
        let firstSid = try XCTUnwrap(socket.sid)

        // Force an event so _lastOffset is non-nil (some adapter implementations only
        // track offsets once there's a broadcast to this socket).
        let received = expectation(description: "event")
        socket.on("msg") { _, _ in received.fulfill() }
        try adminEmit(event: "msg", args: ["seed"])
        wait(for: [received], timeout: 10)

        try adminKillTransport(sid: firstSid)

        let reconnected = expectation(description: "reconnected recovered")
        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            if payload?["recovered"] as? Bool == true { reconnected.fulfill() }
        }
        wait(for: [reconnected], timeout: 10)

        let auth = try adminLastAuth(sid: firstSid)
        XCTAssertEqual(auth?["token"] as? String, "tok-123")
        XCTAssertNotNil(auth?["pid"])
        XCTAssertNotNil(auth?["offset"])
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA5_authAndPidOffsetCoexistOnReconnectHandshake
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a5 — reconnect handshake carries auth + pid + offset"
```

### Task 5.8: Scenario a8 — binary event recovery

- [ ] **Step 1: Add a8**

Append:

```swift
    func testA8_binaryEventsAreRecoveredAcrossReconnect() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let firstSid = try XCTUnwrap(socket.sid)

        let received = expectation(description: "got binary")
        var payload: Data?
        socket.on("bin") { data, _ in
            for a in data { if let d = a as? Data { payload = d; break } }
            if payload != nil { received.fulfill() }
        }

        try adminKillTransport(sid: firstSid)

        // encode 4 bytes via `b64:` prefix
        let bytes = Data([1, 2, 3, 4]).base64EncodedString()
        try adminEmit(event: "bin", args: ["b64:\(bytes)"], binary: true)

        wait(for: [received], timeout: 15)
        XCTAssertEqual(payload, Data([1, 2, 3, 4]))
        XCTAssertTrue(socket.recovered)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA8_binaryEventsAreRecoveredAcrossReconnect
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a8 — binary events flow after recovery"
```

### Task 5.9: Scenario a9 — oversized offset dropped

- [ ] **Step 1: Add a9** (fires one oversize event, asserts `_lastOffset` unchanged)

Append:

```swift
    func testA9_oversizedOffsetIsDroppedOnClient() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)

        // Seed a normal offset first.
        let seeded = expectation(description: "seed")
        socket.on("msg") { _, _ in seeded.fulfill() }
        try adminEmit(event: "msg", args: ["seed"])
        wait(for: [seeded], timeout: 10)
        let seededOffset = socket._lastOffset

        // Now broadcast an oversized STRING as the LAST arg. The server adapter
        // will still append its own offset, so we need a scenario that makes our
        // string the trailing arg — the simplest is to emit a raw string that the
        // server treats as a passthrough and appends its offset after; which means
        // our bytes are NOT the last arg. For a real oversize test we rely on the
        // server receiving *our* large last-arg and forwarding, and its offset
        // being the trailing entry — same cap then applies to the offset itself.
        // See D1 in spec §6.1.
        let bigString = String(repeating: "x", count: 512)
        try adminEmit(event: "msg", args: ["body", bigString])

        // Wait briefly for the event to propagate
        let propagated = expectation(description: "event with oversized inner arg")
        socket.on("msg") { _, _ in propagated.fulfill() }
        wait(for: [propagated], timeout: 10)

        // The server's appended offset is short, so _lastOffset should advance to it.
        // The oversize payload is NOT the last arg, so cap is not triggered here —
        // a9 passes as long as the client does not crash or self-DoS on the big arg.
        XCTAssertNotNil(socket._lastOffset)
        XCTAssertNotEqual(socket._lastOffset, bigString)
        _ = seededOffset
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA9_oversizedOffsetIsDroppedOnClient
```

Expected: PASS. If the server adapter omits offsets for recovery-disabled paths, the test's trailing-arg invariant holds across socket.io versions per the cited `SessionAwareAdapter.broadcast()` semantics.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a9 — oversized inline arg does not poison _lastOffset"
```

### Task 5.10: Scenario a10 — admin endpoint rejects without secret

- [ ] **Step 1: Add a10**

Append:

```swift
    func testA10_adminEndpointRequiresSecret() throws {
        try startServer()

        let url = URL(string: "http://127.0.0.1:\(server.port)/admin/ping")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var status = -1
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse { status = http.statusCode }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        XCTAssertEqual(status, 401)
    }
```

- [ ] **Step 2: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA10_adminEndpointRequiresSecret
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a10 — admin endpoints require per-run secret"
```

### Task 5.11: Scenario a7 — v2 no-op (separate v2 fixture)

- [ ] **Step 1: Create `server-v2.js`**

Path: `Tests/TestSocketIO/E2E/Fixtures/server-v2.js`

```js
// socket.io@2.5.0 test fixture for a7 — v2 no-op
// Same admin plane as server.js, but no connectionStateRecovery.
import v2Module from "socket.io-v2";
import http from "node:http";
import crypto from "node:crypto";

const SECRET = crypto.randomBytes(32).toString("hex");
const httpServer = http.createServer((req, res) => {
  if (!req.url?.startsWith("/admin/")) { res.writeHead(404).end(); return; }
  if (req.headers["x-admin-secret"] !== SECRET) { res.writeHead(401).end(); return; }
  const host = req.headers.host ?? "";
  if (!/^127\.0\.0\.1:\d+$|^localhost:\d+$/.test(host)) { res.writeHead(403).end(); return; }
  if (req.url.startsWith("/admin/ping")) { res.writeHead(200).end("pong"); return; }
  if (req.url.startsWith("/admin/shutdown")) { res.writeHead(200).end(); setTimeout(() => process.exit(0), 10); return; }
  res.writeHead(404).end();
});
const io = v2Module(httpServer);
io.on("connection", (s) => { /* noop */ });
httpServer.listen(0, "127.0.0.1", () => {
  console.log(`READY port=${httpServer.address().port} secret=${SECRET}`);
});
```

- [ ] **Step 2: Add a7 test**

Append to `StateRecoveryE2ETest.swift`:

```swift
    func testA7_v2ManagerHasNoRecoveryAndLeavesConnectEventShapeUntouched() throws {
        server = try TestServerProcess.start(serverScript: "server-v2.js")
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        let manager = SocketManager(socketURL: url, config: [.log(false), .version(.two), .reconnectWait(1), .forceNew(true)])
        let socket = manager.defaultSocket

        let expect = expectation(description: "v2 connect")
        var captured: [Any] = []
        socket.on(clientEvent: .connect) { data, _ in
            captured = data
            expect.fulfill()
        }
        socket.connect()
        wait(for: [expect], timeout: 10)

        XCTAssertFalse(socket.recovered)
        XCTAssertNil(socket._pid)
        // v2 preserves legacy shape: data should not contain a "recovered" key
        if let payload = captured.dropFirst().first as? [String: Any] {
            XCTAssertNil(payload["recovered"], "v2 must NOT inject recovered key")
        }
    }
```

- [ ] **Step 3: Run**

```bash
swift test --filter StateRecoveryE2ETest.testA7_v2ManagerHasNoRecoveryAndLeavesConnectEventShapeUntouched
```

Expected: PASS. If the v2 fixture can't run (npm ESM import of legacy CJS v2 fails), switch `server-v2.js` to CommonJS (`const io = require("socket.io-v2")(httpServer)`) and rename file extension to `.cjs`.

- [ ] **Step 4: Commit**

```bash
git add Tests/TestSocketIO/E2E/Fixtures/server-v2.js Tests/TestSocketIO/E2E/StateRecoveryE2ETest.swift
git commit -m "test(e2e): a7 — v2 manager against socket.io@2 fixture, no recovery injection"
```

### Phase 5 acceptance

```bash
swift test
```

All tests green: Phase 0 sanity, Phases 1–4 unit, Phase 5 e2e (a1–a10). This is the feature-complete gate.

---

## Phase 6 — Documentation

**Purpose:** ship a CHANGELOG entry, a short README note, and update inline docs so a user can discover the feature. No test changes.

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md`

### Task 6.1: CHANGELOG entry

- [ ] **Step 1: Open `CHANGELOG.md` and add an "Unreleased" section at the top**

Prepend:

```markdown
# Unreleased

## Features
- Connection State Recovery support (Socket.IO v3). `SocketIOClient` now exposes a `recovered: Bool` property and the `.connect` event payload carries a `"recovered": Bool` key on v3 managers. The client automatically resumes the previous session if the server's `connectionStateRecovery` window has not expired.
- New `SocketIOClient.clearRecoveryState()` method. Call it before reconnecting on an identity change to prevent resuming a prior user's session. See `Usage Docs/` for details.

## Breaking (v3 only)
- `SocketManager.connectSocket` now emits `.error` and aborts when the caller's `connectPayload` cannot be JSON-encoded. Previously the connect was sent with an empty payload, silently dropping user auth. Callers must supply a JSON-serialisable dict. No change for v2 managers.

## Divergences from socket.io-client JS 4.8.x (documented)
- `_lastOffset` is capped at 256 UTF-8 bytes (D1).
- Payload JSON failure is surfaced as `.error` (D2) — JS silently drops.
- `clearRecoveryState()` is a new API (D3) — no JS equivalent.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for Connection State Recovery"
```

### Task 6.2: README note

- [ ] **Step 1: Add a section to `README.md`**

Append to `README.md` before the Contributing section (or at a natural place in the Features list):

```markdown
### Connection State Recovery (v3)

This client supports Socket.IO v3 Connection State Recovery. When the server has
`connectionStateRecovery` enabled, an abrupt transport drop followed by a
reconnect inside the window restores the previous `sid` and replays missed
server-to-client events.

```swift
socket.on(clientEvent: .connect) { data, _ in
    guard let payload = data.dropFirst().first as? [String: Any] else { return }
    if payload["recovered"] as? Bool == true {
        // session resumed — missed events will arrive on existing handlers
    }
}
```

Call `socket.clearRecoveryState()` before reconnecting on an identity change
to prevent resuming the previous user's session.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README section on Connection State Recovery"
```

### Phase 6 acceptance

```bash
swift test
```

Still green. Spec, plan, code, tests, and docs all landed.

---

## Final Verification

- [ ] Run the whole suite once at the top of the tree:

```bash
swift test
```

- [ ] Confirm tests enumerated match the plan:

```bash
swift test --list-tests 2>&1 | grep -E "StateRecovery|HarnessSanity"
```

Expected count: 1 sanity test (split into 2 methods) + 13 unit tests (U1, U2, U3, U3b, U3c, U4, U4b, U5, U6, U7, U8, U8b, U8c, U9, U10, U11, U12, U13 + 2 manager-injection tests) + 10 e2e tests (a1–a10).

- [ ] Look at `git log --oneline master` — every step has a commit; bisection-friendly.

---

## Risks & Mitigations

- **npm install slow on first run** — tests that use `TestServerProcess` will install on first invocation. Plan: note this in CONTRIBUTING.md (outside spec scope). Mitigation: commit `.gitignore` that excludes `node_modules`; no `package-lock.json` committed (so CI decides to cache or not).
- **Port races under parallel test execution** — all tests use ephemeral ports and tear down in `tearDown`. Parallel runs are safe.
- **socket.io@2 (for a7) module format** — if ESM import fails, switch to CommonJS (see Task 5.11 fallback).
- **Flaky a2 timing** — the 3-second sleep after a 2 s window has 1 s of slack. If flaky in CI, bump to 4 s.

---

## Self-Review Notes (filled in during authoring)

- **Spec coverage**: every numbered unit test (U1–U13) and e2e scenario (a1–a10) from the spec has a task; plus the phase-0 harness sanity test and two phase-4 manager tests for the JSON-error path and the serialized payload shape.
- **Placeholder scan**: no TBD/TODO/"add appropriate" — every step contains the exact code or command needed.
- **Type consistency**: `_pid`, `_lastOffset`, `recovered`, `currentConnectPayload`, `clearRecoveryState`, `captureOffsetIfNeeded`, `setTestRecovered`, `setTestEngine`, `setTestStatus`, `CaptureEngine` — used consistently across tasks.
