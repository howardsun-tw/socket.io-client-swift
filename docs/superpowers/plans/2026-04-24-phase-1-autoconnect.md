# Phase 1 — `.autoConnect(Bool)` Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `SocketIOClientOption.autoConnect(Bool)` config option that, when set to `true`, triggers `SocketManager.connect()` at the end of `init`. Default `false` preserves existing behavior.

**Architecture:** Plumb a new option case end-to-end (option enum → config parsing → manager property → init tail). `autoConnect:true` only auto-CONNECTs the manager's `defaultSocket` via `_engineDidOpen` — non-default namespaces created via `manager.socket(forNamespace:)` still require explicit `socket.connect()` (matches JS `Manager.autoConnect` which only opens the engine). Default `false` because flipping the existing default would silently change behavior for every current user.

**Tech Stack:** Swift 5.x, SwiftPM, XCTest. No new dependencies.

**Spec reference:** `docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md` Phase 1.

---

## File Structure

| File | Purpose |
|---|---|
| `Source/SocketIO/Client/SocketIOClientOption.swift` | Add `case autoConnect(Bool)`, description string, value extractor, equality |
| `Source/SocketIO/Manager/SocketManager.swift` | Add `public var autoConnect: Bool = false`; handle in `setConfigs`; invoke `connect()` at end of `init` if true |
| `Tests/TestSocketIO/SocketIOClientConfigurationTest.swift` | Test option round-trip through config |
| `Tests/TestSocketIO/SocketMangerTest.swift` | Test default (no auto), `autoConnect(true)` triggers connect, defaultSocket-only auto-join |

---

### Task 1: Add `autoConnect` case to `SocketIOClientOption`

**Files:**
- Modify: `Source/SocketIO/Client/SocketIOClientOption.swift` (add case + description + value)

- [ ] **Step 1: Write failing test for round-trip parsing**

Add to `Tests/TestSocketIO/SocketIOClientConfigurationTest.swift`:

```swift
    func testAutoConnectOption() {
        var config: SocketIOClientConfiguration = []
        config.insert(.autoConnect(true))

        XCTAssertEqual(config.count, 1)

        switch config[0] {
        case let .autoConnect(value):
            XCTAssertTrue(value)
        default:
            XCTFail("expected .autoConnect, got \(config[0])")
        }
    }

    func testAutoConnectDescription() {
        let option = SocketIOClientOption.autoConnect(false)
        XCTAssertEqual(option.description, "autoConnect")
    }

    func testAutoConnectValue() {
        let option = SocketIOClientOption.autoConnect(true)
        let value = option.getSocketIOOptionValue() as? Bool
        XCTAssertEqual(value, true)
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter TestSocketIOClientConfiguration`
Expected: 3 new tests fail with "type 'SocketIOClientOption' has no member 'autoConnect'"

- [ ] **Step 3: Add the `autoConnect` case**

In `Source/SocketIO/Client/SocketIOClientOption.swift`, add the case alphabetically (after `case enableSOCKSProxy(Bool)` around line 66, before `case forceNew(Bool)`):

```swift
    /// Whether the manager should automatically call `connect()` at the end of `init`.
    /// Default `false` to preserve existing behavior. JS `Manager` defaults to `true`;
    /// Swift inverts the default. When `true`, only the `defaultSocket` is auto-CONNECTed
    /// through `_engineDidOpen`. Sockets created later via `manager.socket(forNamespace:)`
    /// still require an explicit `socket.connect()` — matches JS where `Manager.autoConnect`
    /// only opens the engine, not arbitrary namespaces.
    case autoConnect(Bool)
```

In the same file, in the `description` switch (around line 124), add:

```swift
        case .autoConnect:
            description = "autoConnect"
```

In the `getSocketIOOptionValue()` switch (around line 178), add:

```swift
        case let .autoConnect(value):
            value as Any
```

Wait — the current pattern is `value = ...` then `return value`. Match the existing pattern. The actual addition (look for the right spot — after `case let .enableSOCKSProxy(socks):` and before `case let .forceNew(force):`):

```swift
        case let .autoConnect(autoConnect):
            value = autoConnect
```

**No `==` operator change needed.** The current `static func ==` (around `SocketIOClientOption.swift:237`) compares `lhs.description == rhs.description`, so adding the description string above is sufficient for equality.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TestSocketIOClientConfiguration`
Expected: All 3 new tests pass; existing tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Client/SocketIOClientOption.swift Tests/TestSocketIO/SocketIOClientConfigurationTest.swift
git commit -m "Phase 1: add SocketIOClientOption.autoConnect(Bool) case"
```

---

### Task 2: Wire `autoConnect` into `SocketManager`

**Files:**
- Modify: `Source/SocketIO/Manager/SocketManager.swift` (add property, parse in `setConfigs`, invoke `connect()` at end of `init`)
- Test: `Tests/TestSocketIO/SocketMangerTest.swift`

- [ ] **Step 1: Write failing test for default behavior (no auto)**

Add to `Tests/TestSocketIO/SocketMangerTest.swift` (find the existing test class — likely `TestSocketManager`):

```swift
    func testAutoConnectFalseByDefault() {
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [])
        XCTAssertFalse(manager.autoConnect)
        XCTAssertEqual(manager.status, .notConnected, "manager should not auto-connect by default")
    }

    func testAutoConnectExplicitFalse() {
        let manager = SocketManager(
            socketURL: URL(string: "http://localhost")!,
            config: [.autoConnect(false)]
        )
        XCTAssertFalse(manager.autoConnect)
        XCTAssertEqual(manager.status, .notConnected)
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter TestSocketManager`
Expected: 2 new tests fail with "value of type 'SocketManager' has no member 'autoConnect'"

- [ ] **Step 3: Add `autoConnect` property + `setConfigs` parsing**

In `Source/SocketIO/Manager/SocketManager.swift`, add a property near the existing public vars (around line 86, after `public var forceNew = false`):

```swift
    /// Whether the manager should automatically call `connect()` at the end of `init`.
    /// Default `false`. See `SocketIOClientOption.autoConnect` for full semantics.
    public var autoConnect: Bool = false
```

In `setConfigs(_:)` (around line 582), add a new case to the switch (after `case let .forceNew(new):`):

```swift
            case let .autoConnect(value):
                autoConnect = value
```

- [ ] **Step 4: Run tests to verify the default-false tests pass**

Run: `swift test --filter TestSocketManager`
Expected: `testAutoConnectFalseByDefault` and `testAutoConnectExplicitFalse` pass.

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Manager/SocketManager.swift Tests/TestSocketIO/SocketMangerTest.swift
git commit -m "Phase 1: parse SocketIOClientOption.autoConnect into SocketManager.autoConnect"
```

---

### Task 3: Trigger `connect()` at end of `init` when `autoConnect == true`

**Files:**
- Modify: `Source/SocketIO/Manager/SocketManager.swift:145-152` (`init`)
- Test: `Tests/TestSocketIO/SocketMangerTest.swift`

- [ ] **Step 1: Write failing test**

Add to `Tests/TestSocketIO/SocketMangerTest.swift`:

```swift
    func testAutoConnectTrueTriggersConnect() {
        let manager = SocketManager(
            socketURL: URL(string: "http://localhost")!,
            config: [.autoConnect(true)]
        )
        XCTAssertTrue(manager.autoConnect)
        XCTAssertEqual(manager.status, .connecting,
                       "autoConnect=true should put manager into .connecting immediately after init")
    }

    func testAutoConnectFalseExplicitDoesNotTrigger() {
        let manager = SocketManager(
            socketURL: URL(string: "http://localhost")!,
            config: [.autoConnect(false), .forceNew(true)]
        )
        XCTAssertEqual(manager.status, .notConnected)
        XCTAssertTrue(manager.forceNew, "forceNew should still be honored independently")
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter testAutoConnectTrueTriggersConnect`
Expected: FAIL — `status` is `.notConnected` not `.connecting` because `init` does not call `connect()`.

- [ ] **Step 3: Add `connect()` invocation at end of `init`**

In `Source/SocketIO/Manager/SocketManager.swift`, modify the existing `init` (around line 145-152). Current:

```swift
    public init(socketURL: URL, config: SocketIOClientConfiguration = []) {
        self._config = config
        self.socketURL = socketURL

        super.init()

        setConfigs(_config)
    }
```

Change to:

```swift
    public init(socketURL: URL, config: SocketIOClientConfiguration = []) {
        self._config = config
        self.socketURL = socketURL

        super.init()

        setConfigs(_config)

        if autoConnect {
            connect()
        }
    }
```

The `setConfigs(_config)` call has already populated `self.autoConnect` by the time the new check runs.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TestSocketManager`
Expected: All 4 autoConnect tests pass; no regressions in other manager tests.

- [ ] **Step 5: Commit**

```bash
git add Source/SocketIO/Manager/SocketManager.swift Tests/TestSocketIO/SocketMangerTest.swift
git commit -m "Phase 1: trigger SocketManager.connect() at end of init when autoConnect=true"
```

---

### Task 4: Verify defaultSocket-only auto-CONNECT (E2E)

**Files:**
- Test: `Tests/TestSocketIO/E2E/` (new file `AutoConnectE2ETest.swift`)

This test uses the existing `TestServerProcess` fixture to verify the spec's claim: `autoConnect:true` triggers CONNECT for `defaultSocket` but NOT for namespaces created later.

- [ ] **Step 1: Write the E2E test**

Create `Tests/TestSocketIO/E2E/AutoConnectE2ETest.swift`:

```swift
import XCTest
@testable import SocketIO

final class AutoConnectE2ETest: XCTestCase {
    var server: TestServerProcess!

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    func testAutoConnectJoinsDefaultSocket() {
        let manager = SocketManager(
            socketURL: server.url,
            config: [.autoConnect(true), .log(false)]
        )

        let connected = expectation(description: "defaultSocket connects")
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            connected.fulfill()
        }

        wait(for: [connected], timeout: 5)
        XCTAssertEqual(manager.defaultSocket.status, .connected)
    }

    func testAutoConnectDoesNotJoinNonDefaultNamespace() {
        let manager = SocketManager(
            socketURL: server.url,
            config: [.autoConnect(true), .log(false)]
        )

        // Wait for default socket to connect, so engine is open.
        let defaultReady = expectation(description: "defaultSocket ready")
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            defaultReady.fulfill()
        }
        wait(for: [defaultReady], timeout: 5)

        // Create non-default namespace; should NOT be auto-CONNECTed.
        let admin = manager.socket(forNamespace: "/admin")

        // Wait briefly to ensure no spontaneous CONNECT happens.
        let noSpontaneousConnect = expectation(description: "admin stays disconnected")
        noSpontaneousConnect.isInverted = true
        admin.on(clientEvent: .connect) { _, _ in
            noSpontaneousConnect.fulfill()
        }
        wait(for: [noSpontaneousConnect], timeout: 1)

        XCTAssertEqual(admin.status, .notConnected,
                       "non-default namespace must require explicit socket.connect()")

        // Sanity check: explicit connect does work.
        let adminConnected = expectation(description: "admin connects after explicit call")
        admin.on(clientEvent: .connect) { _, _ in
            adminConnected.fulfill()
        }
        admin.connect()
        wait(for: [adminConnected], timeout: 5)
    }

    func testAutoConnectFalseLeavesDefaultDisconnected() {
        let manager = SocketManager(
            socketURL: server.url,
            config: [.log(false)]  // autoConnect defaults false
        )

        let noConnect = expectation(description: "no auto-connect")
        noConnect.isInverted = true
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            noConnect.fulfill()
        }
        wait(for: [noConnect], timeout: 1)

        XCTAssertEqual(manager.status, .notConnected)
    }
}
```

- [ ] **Step 2: Run the E2E test (server must be available)**

Run: `swift test --filter AutoConnectE2ETest`
Expected: All 3 E2E tests pass.

If `TestServerProcess.url` doesn't exist in the codebase, check `Tests/TestSocketIO/E2E/TestServerProcess.swift` for the actual API and adapt accordingly.

- [ ] **Step 3: Commit**

```bash
git add Tests/TestSocketIO/E2E/AutoConnectE2ETest.swift
git commit -m "Phase 1: E2E test — autoConnect joins defaultSocket but not later namespaces"
```

---

### Task 5: Documentation — README + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (add `## Unreleased` entry)
- Modify: `README.md` (add a paragraph in the configuration section)

- [ ] **Step 1: Add CHANGELOG entry**

In `CHANGELOG.md`, under `## Unreleased` (create the section if absent), add:

```markdown
### Added
- `SocketIOClientOption.autoConnect(Bool)` — when `true`, `SocketManager.connect()` is invoked at the end of `init`. Default `false` preserves existing behavior. Only the `defaultSocket` is auto-CONNECTed; non-default namespaces created via `manager.socket(forNamespace:)` still require explicit `socket.connect()`. JS reference defaults to `true`; Swift inverts to preserve back-compat.
```

- [ ] **Step 2: Add README paragraph**

In `README.md`, find the configuration-options section (search for `forceNew` or `reconnects` to locate the table/list). Add an entry:

```markdown
### `autoConnect`

```swift
let manager = SocketManager(socketURL: url, config: [.autoConnect(true)])
// manager.defaultSocket is now in .connecting state.
```

When `true`, the manager calls `connect()` at the end of initialization. Defaults to `false` (Swift back-compat — JS reference defaults to `true`). Only the `defaultSocket` is auto-joined; namespaces created later via `manager.socket(forNamespace:)` still require explicit `socket.connect()`.
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "Phase 1: docs — autoConnect option in CHANGELOG + README"
```

---

### Task 6: Final verification — run full test suite

- [ ] **Step 1: Run all tests**

Run: `swift test`
Expected: All tests pass on macOS. No regressions in existing tests.

- [ ] **Step 2: Verify on Linux (if CI matrix includes Linux)**

If a Linux SwiftPM matrix is configured (check `.github/workflows/`), wait for CI to confirm. Otherwise run: `docker run --rm -v "$PWD:/work" -w /work swift:5.9 swift test` (if Docker available locally).

Expected: green on all matrix entries.

- [ ] **Step 3: Open PR**

Branch name: `phase-1-autoconnect`. PR title: `Phase 1: add SocketIOClientOption.autoConnect`. Body should reference the spec section and link to the design doc.

```bash
git push -u origin phase-1-autoconnect
gh pr create --title "Phase 1: add SocketIOClientOption.autoConnect" --body "$(cat <<'EOF'
## Summary
- Adds `SocketIOClientOption.autoConnect(Bool)` (default `false`).
- When `true`, `SocketManager.connect()` is invoked at the end of `init`.
- Only `defaultSocket` is auto-CONNECTed; non-default namespaces still require explicit `socket.connect()` (matches JS `Manager.autoConnect` semantics).

## Spec
docs/superpowers/specs/2026-04-24-socketio-gap-fill-design.md — Phase 1.

## Test plan
- [x] Unit: option round-trip, description, value extraction
- [x] Unit: `autoConnect` property defaults `false`; `setConfigs` parses the case
- [x] Unit: `init` triggers `connect()` only when `autoConnect == true`
- [x] E2E: `defaultSocket` auto-joins; `/admin` namespace does NOT auto-join until explicit `connect()`
- [x] E2E: `autoConnect:false` leaves `defaultSocket` in `.notConnected`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review Checklist (run before opening PR)

- [ ] Every spec requirement in Phase 1 has a task that implements it.
- [ ] No "TBD" / "TODO" / "fill in" placeholders.
- [ ] All file paths are absolute or repo-relative; line numbers verified against current source.
- [ ] All test names match exactly between "write test" and "run test" steps.
- [ ] CHANGELOG entry uses the format the project uses elsewhere (verify by inspecting last 2-3 entries).
