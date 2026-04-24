//
// Created by Erik Little on 10/21/17.
//

import Dispatch
import Foundation
@testable import SocketIO
import XCTest

class SocketMangerTest : XCTestCase {
    func testManagerProperties() {
        XCTAssertNotNil(manager.defaultSocket)
        XCTAssertNil(manager.engine)
        XCTAssertFalse(manager.forceNew)
        XCTAssertEqual(manager.handleQueue, DispatchQueue.main)
        XCTAssertTrue(manager.reconnects)
        XCTAssertEqual(manager.reconnectWait, 10)
        XCTAssertEqual(manager.reconnectWaitMax, 30)
        XCTAssertEqual(manager.randomizationFactor, 0.5)
        XCTAssertEqual(manager.status, .notConnected)
    }

    func testSettingConfig() {
        let manager = SocketManager(socketURL: URL(string: "https://example.com/")!)

        XCTAssertEqual(manager.config.first!, .secure(true))

        manager.config = []

        XCTAssertEqual(manager.config.first!, .secure(true))
    }

    func testBackoffIntervalCalulation() {
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: -1), Double(manager.reconnectWaitMax))
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 0), 15)
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 1), 22.5)
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 2), 33.75)
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 50), Double(manager.reconnectWaitMax))
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 10000), Double(manager.reconnectWaitMax))

        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: -1), Double(manager.reconnectWait))
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 0), Double(manager.reconnectWait))
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 1), 15)
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 2), 22.5)
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 10000), Double(manager.reconnectWait))
    }

    func testManagerCallsConnect() {
        setUpSockets()

        socket.expectations[ManagerExpectation.didConnectCalled] = expectation(description: "The manager should call connect on the default socket")
        socket2.expectations[ManagerExpectation.didConnectCalled] = expectation(description: "The manager should call connect on the socket")

        socket.connect()
        socket2.connect()

        manager.fakeConnecting()
        manager.fakeConnecting(toNamespace: "/swift")

        waitForExpectations(timeout: 0.3)
    }

    func testManagerDoesNotCallConnectWhenConnectingWithLessThanOneReconnect() {
        setUpSockets()
        
        let expect = expectation(description: "The manager should not call connect on the engine")
        expect.isInverted = true
        
        let engine = TestEngine(client: manager, url: manager.socketURL, options: nil)
        
        engine.onConnect = {
            expect.fulfill()
        }
        manager.setTestStatus(.connecting)
        manager.setCurrentReconnect(currentReconnect: 0)
        manager.engine = engine
        
        manager.connect()

        waitForExpectations(timeout: 0.3)
    }
    
    func testManagerCallConnectWhenConnectingAndMoreThanOneReconnect() {
        setUpSockets()
        
        let expect = expectation(description: "The manager should call connect on the engine")
        let engine = TestEngine(client: manager, url: manager.socketURL, options: nil)
        
        engine.onConnect = {
            expect.fulfill()
        }
        manager.setTestStatus(.connecting)
        manager.setCurrentReconnect(currentReconnect: 1)
        manager.engine = engine
        
        manager.connect()

        waitForExpectations(timeout: 0.8)
    }

    func testManagerCallsDisconnect() {
        setUpSockets()

        socket.expectations[ManagerExpectation.didDisconnectCalled] = expectation(description: "The manager should call disconnect on the default socket")
        socket2.expectations[ManagerExpectation.didDisconnectCalled] = expectation(description: "The manager should call disconnect on the socket")

        socket2.on(clientEvent: .connect) {data, ack in
            self.manager.disconnect()
            self.manager.fakeDisconnecting()
        }

        socket.connect()
        socket2.connect()

        manager.fakeConnecting()
        manager.fakeConnecting(toNamespace: "/swift")

        waitForExpectations(timeout: 0.3)
    }

//    func testManagerEmitAll() {
//        setUpSockets()
//
//        socket.expectations[ManagerExpectation.emitAllEventCalled] = expectation(description: "The manager should emit an event to the default socket")
//        socket2.expectations[ManagerExpectation.emitAllEventCalled] = expectation(description: "The manager should emit an event to the socket")
//
//        socket2.on(clientEvent: .connect) {data, ack in
//            print("connect")
//            self.manager.emitAll("event", "testing")
//        }
//
//        socket.connect()
//        socket2.connect()
//
//        manager.fakeConnecting(toNamespace: "/swift")
//
//        waitForExpectations(timeout: 0.3)
//    }

    func testManagerSetsConfigs() {
        let queue = DispatchQueue(label: "testQueue")

        manager = TestManager(socketURL: URL(string: "http://localhost/")!, config: [
            .handleQueue(queue),
            .forceNew(true),
            .reconnects(false),
            .reconnectWait(5),
            .reconnectWaitMax(5),
            .randomizationFactor(0.7),
            .reconnectAttempts(5)
        ])

        XCTAssertEqual(manager.handleQueue, queue)
        XCTAssertTrue(manager.forceNew)
        XCTAssertFalse(manager.reconnects)
        XCTAssertEqual(manager.reconnectWait, 5)
        XCTAssertEqual(manager.reconnectWaitMax, 5)
        XCTAssertEqual(manager.randomizationFactor, 0.7)
        XCTAssertEqual(manager.reconnectAttempts, 5)
    }

    func testManagerRemovesSocket() {
        setUpSockets()

        manager.removeSocket(socket)

        XCTAssertNil(manager.nsps[socket.nsp])
    }

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

    func testConnectSocketUsesExplicitPayloadWithRecoveryState() throws {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)
        setUpSockets()

        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "stale"]

        manager.connectSocket(socket, withPayload: ["token": "fresh", "room": "lobby"])

        let sent = try XCTUnwrap(engine.lastSent)
        XCTAssertTrue(sent.hasPrefix("0/,"),
                      "expected \"0<nsp>,<json>\", got \(sent)")

        let jsonStart = sent.index(sent.startIndex, offsetBy: 3)
        let jsonStr = String(sent[jsonStart...])
        let data = Data(jsonStr.utf8)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["pid"] as? String, "p1")
        XCTAssertEqual(obj["offset"] as? String, "offset-1")
        XCTAssertEqual(obj["token"] as? String, "fresh")
        XCTAssertEqual(obj["room"] as? String, "lobby")
    }

    func testConnectSocketExplicitPayloadOverridesStoredSocketPayload() throws {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)
        setUpSockets()

        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "stale", "room": "old"]

        manager.connectSocket(socket, withPayload: ["token": "fresh"])

        let sent = try XCTUnwrap(engine.lastSent)
        let jsonStart = sent.index(sent.startIndex, offsetBy: 3)
        let jsonStr = String(sent[jsonStart...])
        let data = Data(jsonStr.utf8)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["token"] as? String, "fresh")
        XCTAssertNil(obj["room"], "stored socket payload must not leak into explicit connect payload")
        XCTAssertEqual(obj["pid"] as? String, "p1")
        XCTAssertEqual(obj["offset"] as? String, "offset-1")
    }

    func testConnectSocketPreservesExplicitPayloadUntilEngineOpens() throws {
        let engine = CaptureEngine()
        manager.engine = engine
        setUpSockets()

        socket.setTestStatus(.connecting)
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "stale", "room": "old"]

        manager.connectSocket(socket, withPayload: ["token": "fresh", "room": "lobby"])

        let openHandled = expectation(description: "engine open handled")
        manager.engineDidOpen(reason: "Connect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            openHandled.fulfill()
        }

        waitForExpectations(timeout: 0.5)

        let sent = try XCTUnwrap(engine.lastSent)
        let jsonStart = sent.index(sent.startIndex, offsetBy: 3)
        let jsonStr = String(sent[jsonStart...])
        let data = Data(jsonStr.utf8)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["token"] as? String, "fresh")
        XCTAssertEqual(obj["room"] as? String, "lobby")
        XCTAssertEqual(obj["pid"] as? String, "p1")
        XCTAssertEqual(obj["offset"] as? String, "offset-1")
    }

    private func setUpSockets() {
        socket = manager.testSocket(forNamespace: "/")
        socket2 = manager.testSocket(forNamespace: "/swift")
    }

    private var manager: TestManager!
    private var socket: TestSocket!
    private var socket2: TestSocket!

    override func setUp() {
        super.setUp()

        manager = TestManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false)])
        socket = nil
        socket2 = nil
    }
}

public enum ManagerExpectation: String {
    case didConnectCalled
    case didDisconnectCalled
    case emitAllEventCalled
}

public class TestManager: SocketManager {
    public func setCurrentReconnect(currentReconnect: Int) {
        self.currentReconnectAttempt = currentReconnect
    }
    
    public override func disconnect() {
        setTestStatus(.disconnected)
    }

    public func testSocket(forNamespace nsp: String) -> TestSocket {
        return socket(forNamespace: nsp) as! TestSocket
    }

    public func fakeDisconnecting() {
        engineDidClose(reason: "")
    }

    public func fakeConnecting(toNamespace nsp: String = "/") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Fake connecting
            self.parseEngineMessage("0\(nsp)")
        }
    }

    public override func socket(forNamespace nsp: String) -> SocketIOClient {
        // set socket to our test socket, the superclass method will get this from nsps
        nsps[nsp] = TestSocket(manager: self, nsp: nsp)

        return super.socket(forNamespace: nsp)
    }
}

public class TestSocket: SocketIOClient {
    public var expectations = [ManagerExpectation: XCTestExpectation]()

    public override func didConnect(toNamespace nsp: String, payload: [String: Any]?) {
        expectations[ManagerExpectation.didConnectCalled]?.fulfill()
        expectations[ManagerExpectation.didConnectCalled] = nil

        super.didConnect(toNamespace: nsp, payload: payload)
    }

    public override func didDisconnect(reason: String) {
        expectations[ManagerExpectation.didDisconnectCalled]?.fulfill()
        expectations[ManagerExpectation.didDisconnectCalled] = nil

        super.didDisconnect(reason: reason)
    }

    public override func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil) {
        expectations[ManagerExpectation.emitAllEventCalled]?.fulfill()
        expectations[ManagerExpectation.emitAllEventCalled] = nil
    }
}
