import XCTest
@testable import SocketIO

final class SocketActiveTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
    }

    func testActiveFalseAfterInit() {
        XCTAssertFalse(socket.active, "active must be false before any connect()")
    }

    func testActiveTrueAfterConnect() {
        socket.connect()
        XCTAssertTrue(socket.active, "active must be true immediately after connect()")
    }

    func testActiveTrueAfterConnectWithPayload() {
        socket.connect(withPayload: ["x": 1])
        XCTAssertTrue(socket.active)
    }

    func testActiveTrueAfterConnectWithTimeout() {
        socket.connect(withPayload: nil, timeoutAfter: 1, withHandler: nil)
        XCTAssertTrue(socket.active)
    }

    func testActiveFalseAfterUserDisconnect() {
        socket.connect()
        XCTAssertTrue(socket.active)
        socket.disconnect()
        XCTAssertFalse(socket.active, "user disconnect() must flip active false")
    }

    func testActiveSurvivesDidDisconnect() {
        // didDisconnect simulates engine-close / transport error / reconnect cycle.
        // Must NOT clear active (matches JS — subs live across reconnect cycles).
        socket.connect()
        XCTAssertTrue(socket.active)
        socket.didDisconnect(reason: "Got Disconnect")
        XCTAssertTrue(socket.active, "didDisconnect must NOT flip active false; only user disconnect() does")
    }

    func testActiveCycleConnectDisconnectConnect() {
        socket.connect()
        socket.disconnect()
        socket.connect()
        XCTAssertTrue(socket.active, "active must come back true on second connect()")
    }

    /// JS-aligned: receipt of a server DISCONNECT packet runs `destroy()`,
    /// which clears `subs` (=> `active = false`). Engine-close + auto-reconnect
    /// is the carve-out, but explicit server-initiated disconnect is terminal
    /// from the namespace socket's perspective.
    func testActiveFalseAfterServerDisconnectPacket() {
        socket.connect()
        XCTAssertTrue(socket.active)
        socket.handlePacket(SocketPacket(type: .disconnect, data: [], nsp: "/"))
        XCTAssertFalse(socket.active, "server DISCONNECT packet must flip active false (matches JS destroy())")
    }

    /// JS-aligned: receipt of CONNECT_ERROR runs `destroy()`. The server
    /// refused this namespace; the manager will not auto-rejoin without an
    /// explicit `socket.connect()`.
    func testActiveFalseAfterConnectErrorPacket() {
        socket.connect()
        XCTAssertTrue(socket.active)
        socket.handlePacket(SocketPacket(type: .error, data: ["unauthorized"], nsp: "/"))
        XCTAssertFalse(socket.active, "CONNECT_ERROR packet must flip active false (matches JS destroy())")
    }
}
