import XCTest
@testable import SocketIO

final class StateRecoveryE2ETest: XCTestCase {
    private var server: TestServerProcess!

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func startServer(recoveryWindowMs: Int? = nil) throws {
        server = try TestServerProcess.start(recoveryWindowMs: recoveryWindowMs)
    }

    private func makeClient(auth: [String: Any]? = nil, forceNew: Bool = true)
        -> (SocketManager, SocketIOClient) {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        var config: SocketIOClientConfiguration = [.log(false), .reconnectWait(1), .forceNew(forceNew)]
        if let auth = auth { config.insert(.connectParams(auth)) }
        let manager = SocketManager(socketURL: url, config: config)
        return (manager, manager.defaultSocket)
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
        socket.on(clientEvent: .connect) { data, _ in
            capturedPayload = data.dropFirst().first as? [String: Any]
            expect.fulfill()
        }
        socket.connect()
        wait(for: [expect], timeout: timeout)
        return capturedPayload
    }
}
