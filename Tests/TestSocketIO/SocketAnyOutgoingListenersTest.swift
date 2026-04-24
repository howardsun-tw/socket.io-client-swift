import XCTest
@testable import SocketIO

final class SocketAnyOutgoingListenersTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        let queue = DispatchQueue(label: "test.SocketAnyOutgoingListenersTest.handleQueue")
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    private func drain() {
        manager.handleQueue.sync { /* barrier */ }
    }

    func testAddAnyOutgoingListener() {
        var captured: SocketAnyEvent?
        let id = socket.addAnyOutgoingListener { event in captured = event }
        XCTAssertNotNil(id)
        drain()
        socket.emit("foo", "bar")
        XCTAssertEqual(captured?.event, "foo")
        XCTAssertEqual(captured?.items?.first as? String, "bar")
    }

    func testCountAndRemoveAll() {
        XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
        _ = socket.addAnyOutgoingListener { _ in }
        _ = socket.addAnyOutgoingListener { _ in }
        drain()
        XCTAssertEqual(socket.anyOutgoingListenerCount, 2)
        socket.removeAllAnyOutgoingListeners(); drain()
        XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
    }

    func testRemoveById() {
        var firedA = 0, firedB = 0
        let idA = socket.addAnyOutgoingListener { _ in firedA += 1 }
        _ = socket.addAnyOutgoingListener { _ in firedB += 1 }
        drain()
        socket.removeAnyOutgoingListener(id: idA); drain()
        socket.emit("foo", "x")
        XCTAssertEqual(firedA, 0)
        XCTAssertEqual(firedB, 1)
    }

    func testPrependFiresFirst() {
        var order: [Int] = []
        _ = socket.addAnyOutgoingListener { _ in order.append(1) }
        _ = socket.prependAnyOutgoingListener { _ in order.append(0) }
        drain()
        socket.emit("foo", "x")
        XCTAssertEqual(order, [0, 1])
    }

    func testReturnedUUIDsAreUnique() {
        let id1 = socket.addAnyOutgoingListener { _ in }
        let id2 = socket.addAnyOutgoingListener { _ in }
        let id3 = socket.prependAnyOutgoingListener { _ in }
        XCTAssertNotEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
        XCTAssertNotEqual(id2, id3)
    }

    func testRemoveUnknownIdNoop() {
        socket.removeAnyOutgoingListener(id: UUID())  // matches JS offAnyOutgoing
        drain()
    }
}
