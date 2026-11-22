import XCTest
@testable import SocketIO

private final class RecordingLogger: SocketLogger {
    var log = true

    private let lock = NSLock()
    private var recorded = [String]()

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func log(_ message: @autoclosure () -> String, type: String) { record(message()) }
    func error(_ message: @autoclosure () -> String, type: String) { record(message()) }

    private func record(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(line)
    }
}

final class TransportHardeningE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var manager: SocketManager!
    private var previousLogger: SocketLogger!

    override func setUp() {
        super.setUp()
        previousLogger = DefaultSocketLogger.Logger
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        manager?.defaultSocket.removeAllHandlers()
        manager?.disconnect()
        manager = nil
        server?.stop()
        server = nil
        DefaultSocketLogger.Logger = previousLogger
        super.tearDown()
    }

    private func makeManager(_ config: SocketIOClientConfiguration) -> SocketManager {
        var config = config
        config.insert(.reconnects(false))
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:\(server.port)")!, config: config)
        return manager
    }

    private func assertAckRoundTrip(on socket: SocketIOClient) {
        let acked = expectation(description: "server ack")
        socket.timeout(after: 3).emit("ping") { err, data in
            XCTAssertNil(err)
            XCTAssertEqual(data.first as? String, "pong")
            acked.fulfill()
        }
        wait(for: [acked], timeout: 4)
    }

    // MARK: Log redaction

    @discardableResult
    private func assertCredentialsStayOutOfTheLog(transport: SocketIOClientOption, wroteLine: String,
                                                  file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let logger = RecordingLogger()
        let socket = makeManager([.logger(logger), transport, .connectParams(["token": "QUERY-SENTINEL"])]).defaultSocket
        let connected = expectation(description: "connect")
        socket.once(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect(withPayload: ["token": "AUTH-SENTINEL"])
        wait(for: [connected], timeout: 5)
        assertAckRoundTrip(on: socket)

        let sid = try XCTUnwrap(socket.sid)
        let (_, body) = try server.admin("/admin/last-auth?sid=\(sid)", method: "GET")
        let auth = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["auth"] as? [String: Any]
        XCTAssertEqual(auth?["token"] as? String, "AUTH-SENTINEL", "the server must still receive the payload",
                       file: file, line: line)

        let pid = try XCTUnwrap(socket._pid, "the fixture enables connection state recovery", file: file, line: line)
        let lines = logger.lines

        for secret in ["QUERY-SENTINEL", "AUTH-SENTINEL", pid] {
            XCTAssertEqual(lines.filter({ $0.contains(secret) }), [], file: file, line: line)
        }

        // The lines that used to carry the secrets are still written, with the secret replaced.
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix(wroteLine) && $0.contains(SocketLogRedaction.placeholder) }),
                      "no redacted \"\(wroteLine)\" line in \(lines)", file: file, line: line)
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("Parsing 0") && $0.contains(SocketLogRedaction.placeholder) }),
                      file: file, line: line)

        return lines
    }

    func testCredentialsStayOutOfTheLogOverPolling() throws {
        let lines = try assertCredentialsStayOutOfTheLog(transport: .forcePolling(true), wroteLine: "Created POST string: 40")
        // The logger is process-wide, so it also records managers that earlier tests left running.
        let polls = lines.filter({ $0.hasPrefix("Doing polling") && $0.contains(":\(server.port)/") })

        XCTAssertFalse(polls.isEmpty)
        XCTAssertTrue(polls.allSatisfy({ $0.contains("token=REDACTED") && $0.contains("transport=polling") }), "\(polls)")
    }

    func testCredentialsStayOutOfTheLogOverWebSocket() throws {
        let lines = try assertCredentialsStayOutOfTheLog(transport: .forceWebsockets(true), wroteLine: "Sending ws: 0")
        let upgrades = lines.filter({ $0.hasPrefix("Handling event: websocketUpgrade") })

        // The handshake response headers can hold a `Set-Cookie`.
        XCTAssertFalse(upgrades.isEmpty)
        XCTAssertEqual(upgrades.filter({ $0.contains("Sec-WebSocket-Accept") }), [])
    }

    // MARK: Polling response limit

    private func assertEndlessPollingResponseIsCancelled(gzip: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let socket = makeManager([
            .log(false), .forcePolling(true), .path("/admin/endless/"), .extraHeaders(["X-Admin-Secret": server.secret]),
            .connectParams(["gzip": gzip ? "1" : "0"]), .maximumPollingResponseBytes(256 * 1024),
        ]).defaultSocket
        let failed = expectation(description: "engine error")
        socket.on(clientEvent: .error) { data, _ in
            XCTAssertEqual(data.first as? String, "Polling response is larger than maximumPollingResponseBytes (262144)",
                           file: file, line: line)
            failed.fulfill()
        }
        socket.connect()

        // The server keeps the body open for 30 seconds, so only a cancelled request reports this early.
        wait(for: [failed], timeout: 5)
    }

    func testOversizedPollingResponseIsCancelledWhileItArrives() {
        assertEndlessPollingResponseIsCancelled(gzip: false)
    }

    func testOversizedPollingResponseIsMeasuredAfterDecompression() {
        assertEndlessPollingResponseIsCancelled(gzip: true)
    }

    func testPollingResponsesUnderTheLimitAreDelivered() {
        let socket = makeManager([.log(false), .forcePolling(true), .maximumPollingResponseBytes(256 * 1024)]).defaultSocket
        let connected = expectation(description: "connect")
        socket.once(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        assertAckRoundTrip(on: socket)
    }
}
