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
}
