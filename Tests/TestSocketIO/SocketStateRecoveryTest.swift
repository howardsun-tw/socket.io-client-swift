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
}
