import XCTest
@testable import SocketIO
import Starscream

private extension SocketPacket {
    init(type: PacketType, nsp: String, placeholders: Int = 0, id: Int = -1, data: [Any]) {
        self.init(type: type, data: data, id: id, nsp: nsp, placeholders: placeholders)
    }
}

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

    // MARK: U2 — event with String last-arg updates _lastOffset

    func testU2_eventLastStringArgBecomesOffset() {
        socket._pid = "p1"
        let packet = SocketPacket(type: .event, data: ["msg", "hello", "offset-1"], id: -1, nsp: "/", placeholders: 0)
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-1")
    }

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

    // MARK: U3c — offset string exceeding cap is dropped (D1 divergence)

    func testU3c_oversizedOffsetStringIsDropped() {
        socket._pid = "p1"
        socket._lastOffset = "safe"
        let big = String(repeating: "x", count: 300)
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1, data: ["msg", big])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "safe", "offset > 256 bytes must not overwrite")
    }

    // MARK: U7 — capture is gated on _pid != nil

    func testU7_offsetNotCapturedWhenPidUnset() {
        XCTAssertNil(socket._pid)
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "foo", "offset-x"])
        socket.handlePacket(packet)

        XCTAssertNil(socket._lastOffset, "must not capture before server confirms recovery via pid")
    }

    // MARK: U9 — binaryEvent with String last-arg captures offset

    func testU9_binaryEventLastStringArgBecomesOffset() {
        socket._pid = "p1"
        let bin = Data([0x00, 0x01])
        let packet = SocketPacket(type: .binaryEvent, nsp: "/", placeholders: 0, id: -1,
                                  data: ["img", bin, "offset-b"])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-b")
    }

    // MARK: U9b — replay event during reconnect is delivered and advances offset

    func testU9b_replayEventDuringReconnectIsDeliveredAndCaptured() {
        socket._pid = "p1"
        socket.setTestStatus(.connecting)
        let expect = expectation(description: "replay event delivered")
        var received: [Any] = []
        socket.on("msg") { data, _ in
            received = data
            expect.fulfill()
        }

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "replayed", "offset-r"])
        socket.handlePacket(packet)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(received.first as? String, "replayed")
        XCTAssertEqual(received.last as? String, "offset-r")
        XCTAssertEqual(socket._lastOffset, "offset-r")
    }

    // MARK: U9c — replay event ack during reconnect is sent without not-connected error

    func testU9c_replayEventAckDuringReconnectIsSent() {
        let engine = CaptureEngine()
        manager.engine = engine
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        let expect = expectation(description: "replay event delivered")
        var errors = [[Any]]()
        socket.on(clientEvent: .error) { data, _ in
            errors.append(data)
        }
        socket.on("msg") { _, ack in
            ack.with("ok")
            expect.fulfill()
        }

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: 7,
                                  data: ["msg", "replayed", "offset-r"])
        socket.handlePacket(packet)

        waitForExpectations(timeout: 1)
        let expectedAck = SocketPacket.packetFromEmit(["ok"], id: 7, nsp: "/", ack: true).packetString
        XCTAssertEqual(engine.lastSent, expectedAck)
        XCTAssertTrue(errors.isEmpty, "ack path must not surface not-connected error during replay recovery")
    }

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

    // MARK: U11 — clearRecoveryState resets pid, offset, and recovered

    func testU11_clearRecoveryStateResetsAllFields() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.setTestRecovered(true)

        socket.clearRecoveryState()

        XCTAssertNil(socket._pid)
        XCTAssertNil(socket._lastOffset)
        XCTAssertFalse(socket.recovered)
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
        XCTAssertTrue(sent.hasPrefix("0/,"),
                      "expected \"0<nsp>,<json>\", got \(sent)")
        let jsonStart = sent.index(sent.startIndex, offsetBy: 3)
        let jsonStr = String(sent[jsonStart...])
        let data = Data(jsonStr.utf8)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["pid"] as? String, "p1")
        XCTAssertEqual(obj["offset"] as? String, "offset-1")
        XCTAssertEqual(obj["token"] as? String, "t")
    }

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

    // MARK: Public connect — invalid payload emits .error and clears pending connect state

    func testConnectWithInvalidPayloadEmitsErrorAndResetsStatus() {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)
        socket.setTestStatus(.notConnected)

        let expect = expectation(description: ".error fired")
        let noDisconnect = expectation(description: ".disconnect not fired")
        noDisconnect.isInverted = true
        var captured: [Any] = []
        socket.on(clientEvent: .error) { data, _ in
            captured = data
            expect.fulfill()
        }
        socket.on(clientEvent: .disconnect) { _, _ in
            noDisconnect.fulfill()
        }

        socket.connect(withPayload: ["bad": Date()], timeoutAfter: 0, withHandler: nil)

        waitForExpectations(timeout: 0.1)
        XCTAssertNil(engine.lastSent, "engine must NOT be sent to on serialization failure")
        let msg = captured.first as? String
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("serialization failed") ?? false)
        XCTAssertEqual(socket.status, .notConnected, "immediate connect failure must settle out of .connecting without disconnecting")
    }

    func testConnectWithInvalidPayloadStillFiresTimeoutHandlerWithoutDisconnecting() {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)
        socket.setTestStatus(.notConnected)

        let errorExpect = expectation(description: ".error fired")
        let timeoutExpect = expectation(description: "timeout handler fired")
        let noDisconnect = expectation(description: ".disconnect not fired")
        noDisconnect.isInverted = true
        var captured: [Any] = []

        socket.on(clientEvent: .error) { data, _ in
            captured = data
            errorExpect.fulfill()
        }
        socket.on(clientEvent: .disconnect) { _, _ in
            noDisconnect.fulfill()
        }

        socket.connect(withPayload: ["bad": Date()], timeoutAfter: 0.05, withHandler: {
            timeoutExpect.fulfill()
        })

        waitForExpectations(timeout: 0.2)
        XCTAssertNil(engine.lastSent, "engine must NOT send CONNECT or namespace leave packets on serialization failure")
        let msg = captured.first as? String
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("serialization failed") ?? false)
    }
}

/// Minimal engine stub for capturing `write` calls from `SocketManager.connectSocket`.
/// Mirrors the `TestEngine` pattern used in side-effect tests but records the last sent string.
final class CaptureEngine: SocketEngineSpec {
    weak var client: SocketEngineClient?
    private(set) var lastSent: String?
    let closed = false
    let compress = false
    let connected = true
    var connectParams: [String: Any]? = nil
    let cookies: [HTTPCookie]? = nil
    let engineQueue = DispatchQueue.main
    var extraHeaders: [String: String]? = nil
    let fastUpgrade = false
    let forcePolling = false
    let forceWebsockets = false
    let polling = false
    let probing = false
    let sid = ""
    let socketPath = ""
    let urlPolling = URL(string: "http://localhost/")!
    let urlWebSocket = URL(string: "http://localhost/")!
    let version: SocketIOVersion = .three
    let websocket = false
    let ws: WebSocket? = nil

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

    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) {
        lastSent = msg
        completion?()
    }
}
