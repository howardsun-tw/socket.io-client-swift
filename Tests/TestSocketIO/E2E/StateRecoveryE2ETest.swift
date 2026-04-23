import XCTest
@testable import SocketIO

final class StateRecoveryE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var managers = [SocketManager]()
    private var pendingAuth = [ObjectIdentifier: [String: Any]]()

    override func tearDown() {
        server?.stop()
        server = nil
        managers.removeAll()
        pendingAuth.removeAll()
        super.tearDown()
    }

    // MARK: Helpers

    private func startServer(recoveryWindowMs: Int? = nil) throws {
        server = try TestServerProcess.start(recoveryWindowMs: recoveryWindowMs)
    }

    private func makeClient(auth: [String: Any]? = nil, forceNew: Bool = true)
        -> (SocketManager, SocketIOClient) {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        let config: SocketIOClientConfiguration = [.log(false), .reconnectWait(1), .forceNew(forceNew)]
        let manager = SocketManager(socketURL: url, config: config)
        managers.append(manager)
        let socket = manager.defaultSocket
        if let auth {
            pendingAuth[ObjectIdentifier(socket)] = auth
        }
        return (manager, socket)
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

    private func adminSocketIsLive(sid: String) throws -> Bool {
        let (status, body) = try server.admin("/admin/socket-live?sid=\(sid)", method: "GET")
        XCTAssertEqual(status, 200)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return try XCTUnwrap(obj?["live"] as? Bool)
    }

    private func waitUntilSocketNotLive(
        sid: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.05
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try !adminSocketIsLive(sid: sid) {
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let message = "timed out waiting for sid \(sid) to disappear from server live sockets"
        XCTFail(message)
        throw NSError(domain: "StateRecoveryE2ETest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func waitForConnect(_ socket: SocketIOClient, timeout: TimeInterval = 10) -> [String: Any]? {
        let expect = expectation(description: "connected")
        var capturedPayload: [String: Any]?
        socket.once(clientEvent: .connect) { data, _ in
            capturedPayload = data.dropFirst().first as? [String: Any]
            expect.fulfill()
        }
        let auth = pendingAuth.removeValue(forKey: ObjectIdentifier(socket))
        socket.connect(withPayload: auth)
        wait(for: [expect], timeout: timeout)
        return capturedPayload
    }

    func testA3_freshConnectReportsNotRecoveredButHasPid() throws {
        try startServer()
        let (_, socket) = makeClient()
        let payload = waitForConnect(socket)

        XCTAssertEqual(payload?["recovered"] as? Bool, false)
        XCTAssertNotNil(socket._pid, "server with recovery enabled must assign pid")
        XCTAssertFalse(socket.recovered)
    }

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

    func testA1_replayedMissedEventsCanArriveBeforeRecoveredConnect() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)

        let baseline = expectation(description: "3 baseline events")
        baseline.expectedFulfillmentCount = 3
        socket.on("pre") { _, _ in
            baseline.fulfill()
        }
        for i in 0..<3 { try adminEmit(event: "pre", args: ["pre-\(i)"]) }
        wait(for: [baseline], timeout: 10)

        let missedDelivered = expectation(description: "2 missed events delivered")
        missedDelivered.expectedFulfillmentCount = 2
        let recoveredConnect = expectation(description: "recovered connect")
        var eventOrder = [String]()
        var sawRecoveredConnect = false

        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            guard payload?["recovered"] as? Bool == true else { return }
            sawRecoveredConnect = true
            eventOrder.append("connect")
            recoveredConnect.fulfill()
        }
        socket.on("missed") { data, _ in
            if let body = data.first as? String {
                eventOrder.append("missed:\(body)")
            }
            missedDelivered.fulfill()
        }

        try adminKillTransport(sid: originalSid)
        try waitUntilSocketNotLive(sid: originalSid)
        try adminEmit(event: "missed", args: ["missed-0"])
        try adminEmit(event: "missed", args: ["missed-1"])

        wait(for: [missedDelivered, recoveredConnect], timeout: 15)
        let missed0Index = try XCTUnwrap(eventOrder.firstIndex(of: "missed:missed-0"))
        let missed1Index = try XCTUnwrap(eventOrder.firstIndex(of: "missed:missed-1"))
        let connectIndex = try XCTUnwrap(eventOrder.firstIndex(of: "connect"))
        XCTAssertLessThan(missed0Index, connectIndex)
        XCTAssertLessThan(missed1Index, connectIndex)
        XCTAssertTrue(sawRecoveredConnect)
    }

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

    func testA6_offsetsAdvanceAcrossAllBroadcastEvents() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)

        var offsets = [String]()
        let received5 = expectation(description: "received 5 events with offsets")
        received5.expectedFulfillmentCount = 5
        socket.on("msg") { data, _ in
            if let offset = data.last as? String {
                offsets.append(offset)
            }
            received5.fulfill()
        }

        for i in 0..<5 {
            try adminEmit(event: "msg", args: ["body-\(i)"])
        }
        wait(for: [received5], timeout: 10)

        XCTAssertEqual(offsets.count, 5, "all 5 events must include trailing String offsets")
        XCTAssertEqual(Set(offsets).count, 5, "offsets must change across broadcast events")
        XCTAssertEqual(socket._lastOffset, offsets.last)
    }
}
