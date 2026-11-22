import XCTest
@testable import SocketIO

final class ReservedEventE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var manager: SocketManager!

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        manager?.disconnect()
        manager = nil
        server.stop()
        super.tearDown()
    }

    /// The event frames the server has read from this client's connection, before its decoder sees them.
    private func eventFrames(engineSid: String) throws -> (total: Int, reserved: Int) {
        let (status, body) = try server.admin("/admin/event-frames?sid=\(engineSid)", method: "GET")
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Int])
        return (try XCTUnwrap(json["total"]), try XCTUnwrap(json["reserved"]))
    }

    func testReservedEmitsAreNotWrittenToTheConnection() throws {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:\(server.port)")!, config: [.log(false)])
        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")
        socket.once(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        for name in ["connect", "connect_error", "disconnect", "disconnecting"] {
            socket.emit(name, "x")
        }

        // Frames arrive in order, so once the ack for this later emit is back the server has read everything
        // that was written before it.
        let acked = expectation(description: "server ack")
        socket.timeout(after: 3).emit("ping") { err, _ in
            XCTAssertNil(err)
            acked.fulfill()
        }
        wait(for: [acked], timeout: 4)

        let frames = try eventFrames(engineSid: try XCTUnwrap(manager.engine?.sid))
        XCTAssertEqual(frames.total, 1, "only the ping event may have been written")
        XCTAssertEqual(frames.reserved, 0)
    }
}
