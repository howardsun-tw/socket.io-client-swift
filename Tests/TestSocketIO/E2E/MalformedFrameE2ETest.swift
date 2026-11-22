import XCTest
@testable import SocketIO

/// The server writes frames that a conforming Socket.IO server never sends. The client must drop each one and
/// keep using the same connection.
final class MalformedFrameE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var manager: SocketManager!

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        // The tests fail on `.disconnect`, so the handlers go before the connection does.
        manager?.defaultSocket.removeAllHandlers()
        manager?.disconnect()
        manager = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func connectedSocket() -> SocketIOClient {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        manager = SocketManager(socketURL: url, config: [.log(false), .reconnects(false)])
        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")
        socket.once(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)
        return socket
    }

    private func writeRaw(_ frames: [String], to socket: SocketIOClient) throws {
        let sid = try XCTUnwrap(socket.sid)
        let body = try JSONSerialization.data(withJSONObject: ["frames": frames])
        let (status, _) = try server.admin("/admin/write-raw?sid=\(sid)", body: body)
        XCTAssertEqual(status, 200)
    }

    /// Frames arrive in order, so an ack for an emit sent after them proves the client processed every one of
    /// them and is still connected.
    private func assertAckRoundTrip(on socket: SocketIOClient) {
        let acked = expectation(description: "server ack")
        socket.timeout(after: 3).emit("ping") { err, data in
            XCTAssertNil(err)
            XCTAssertEqual(data.first as? String, "pong")
            acked.fulfill()
        }
        wait(for: [acked], timeout: 4)
    }

    func testMalformedFramesAreDroppedAndTheConnectionSurvives() throws {
        let socket = connectedSocket()
        socket.on(clientEvent: .disconnect) { _, _ in XCTFail("a malformed frame must not drop the connection") }
        socket.on("e") { _, _ in XCTFail("a malformed frame must not be delivered") }

        try writeRaw([
            "2", "21", "2[]", "2\u{1F600}", "5", "51-", "511-[\"e\"]",
            "51-[\"e\",{\"_placeholder\":true,\"num\":7}]", "b64:AAEC",
            "51-[\"e\",{\"_placeholder\":true,\"num\":\"0\"}]", "b64:AAEC",
        ], to: socket)

        assertAckRoundTrip(on: socket)
        XCTAssertEqual(socket.status, .connected)
    }

    func testServerCannotTriggerReservedClientEvents() throws {
        let socket = connectedSocket()
        socket.on(clientEvent: .connect) { _, _ in XCTFail("server-sent \"connect\" must not reach handlers") }
        socket.on(clientEvent: .disconnect) { _, _ in XCTFail("server-sent \"disconnect\" must not reach handlers") }

        try writeRaw(["2[\"connect\"]", "2[\"disconnect\",\"spoofed\"]"], to: socket)

        assertAckRoundTrip(on: socket)
        XCTAssertEqual(socket.status, .connected)
    }

    func testBinaryEventWithZeroAttachmentsIsDelivered() throws {
        let socket = connectedSocket()
        let received = expectation(description: "zero-attachment binary event")
        socket.on("zero") { data, _ in
            XCTAssertEqual(data.first as? String, "ok")
            received.fulfill()
        }

        try writeRaw(["50-[\"zero\",\"ok\"]"], to: socket)

        wait(for: [received], timeout: 3)
    }
}
