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
        let packet = SocketPacket(type: .event, data: ["msg", "hi"], id: -1, nsp: "/", placeholders: 0)
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "hi")
    }

    // MARK: U3b — non-String last-arg leaves offset unchanged

    func testU3b_nonStringLastArgLeavesOffsetUnchanged() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        let packet = SocketPacket(type: .event, data: ["msg", 42], id: -1, nsp: "/", placeholders: 0)
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-1")
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
}
