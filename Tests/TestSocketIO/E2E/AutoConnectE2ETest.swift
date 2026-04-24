import XCTest
@testable import SocketIO

final class AutoConnectE2ETest: XCTestCase {
    var server: TestServerProcess!
    var serverURL: URL { URL(string: "http://127.0.0.1:\(server.port)")! }

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    func testAutoConnectJoinsDefaultSocket() {
        let manager = SocketManager(
            socketURL: serverURL,
            config: [.autoConnect(true), .log(false)]
        )

        let connected = expectation(description: "defaultSocket connects")
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            connected.fulfill()
        }

        wait(for: [connected], timeout: 5)
        XCTAssertEqual(manager.defaultSocket.status, .connected)
    }

    func testAutoConnectDoesNotJoinNonDefaultNamespace() {
        let manager = SocketManager(
            socketURL: serverURL,
            config: [.autoConnect(true), .log(false)]
        )

        // Wait for default socket to connect (engine open).
        let defaultReady = expectation(description: "defaultSocket ready")
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            defaultReady.fulfill()
        }
        wait(for: [defaultReady], timeout: 5)

        // Create non-default namespace post-engine-open; must NOT auto-CONNECT.
        let admin = manager.socket(forNamespace: "/admin")

        // Inverted expectation: assert NO spontaneous connect within 1s.
        let noSpontaneousConnect = expectation(description: "admin stays disconnected")
        noSpontaneousConnect.isInverted = true
        admin.on(clientEvent: .connect) { _, _ in
            noSpontaneousConnect.fulfill()
        }
        wait(for: [noSpontaneousConnect], timeout: 1)

        XCTAssertNotEqual(admin.status, .connected,
                          "non-default namespace must require explicit socket.connect()")

        // Sanity: explicit connect works.
        let adminConnected = expectation(description: "admin connects after explicit call")
        admin.on(clientEvent: .connect) { _, _ in
            adminConnected.fulfill()
        }
        admin.connect()
        wait(for: [adminConnected], timeout: 5)
    }

    func testAutoConnectFalseLeavesDefaultDisconnected() {
        let manager = SocketManager(
            socketURL: serverURL,
            config: [.log(false)]  // autoConnect defaults false
        )

        let noConnect = expectation(description: "no auto-connect")
        noConnect.isInverted = true
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            noConnect.fulfill()
        }
        wait(for: [noConnect], timeout: 1)

        XCTAssertEqual(manager.status, .notConnected)
    }
}
