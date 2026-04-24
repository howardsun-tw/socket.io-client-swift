//
//  SocketTimedEmitterTest.swift
//  Socket.IO-Client-Swift
//
//  Phase 9: tests for the parallel timed-ack storage on SocketAckManager.
//

import XCTest
@testable import SocketIO

final class SocketTimedAckManagerTest: XCTestCase {
    var ackManager: SocketAckManager!
    var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        ackManager = SocketAckManager()
        queue = DispatchQueue(label: "test.handle")
    }

    override func tearDown() {
        ackManager = nil
        queue = nil
        super.tearDown()
    }

    func testAddTimedAckFires() {
        let exp = expectation(description: "callback")
        queue.sync {
            ackManager.addTimedAck(1, on: queue,
                                   callback: { err, data in
                                       XCTAssertNil(err)
                                       XCTAssertEqual(data.first as? String, "ok")
                                       exp.fulfill()
                                   },
                                   timeout: 60)
        }
        queue.async { self.ackManager.executeTimedAck(1, with: ["ok"]) }
        wait(for: [exp], timeout: 1)
    }

    func testTimedAckTimesOut() {
        let exp = expectation(description: "timeout")
        queue.sync {
            ackManager.addTimedAck(2, on: queue,
                                   callback: { err, _ in
                                       XCTAssertEqual(err as? SocketAckError, .timeout)
                                       exp.fulfill()
                                   },
                                   timeout: 0.1)
        }
        wait(for: [exp], timeout: 1)
    }

    func testCancelTimedAck() {
        let exp = expectation(description: "callback NOT fired")
        exp.isInverted = true
        queue.sync {
            ackManager.addTimedAck(3, on: queue,
                                   callback: { _, _ in exp.fulfill() },
                                   timeout: 0.5)
        }
        queue.async { self.ackManager.cancelTimedAck(3) }
        // 1s > 0.5s timeout, but cancel removes it before the timer fires.
        wait(for: [exp], timeout: 1)
    }

    func testCancelTimedAckWithErrorFiresCallback() {
        // Bundle 1 deviation from plan: cancelTimedAck supports an optional
        // `fireWith:` error so async cancellation can deliver CancellationError
        // through the same one-shot path that timeout/disconnect use.
        let exp = expectation(description: "callback fires with CancellationError")
        queue.sync {
            ackManager.addTimedAck(7, on: queue,
                                   callback: { err, data in
                                       XCTAssertTrue(err is CancellationError)
                                       XCTAssertTrue(data.isEmpty)
                                       exp.fulfill()
                                   },
                                   timeout: 60)
        }
        queue.async {
            self.ackManager.cancelTimedAck(7, fireWith: CancellationError())
        }
        wait(for: [exp], timeout: 1)
    }

    func testClearTimedAcksFiresAllWithReason() {
        let exp = expectation(description: "both fire .disconnected")
        exp.expectedFulfillmentCount = 2
        queue.sync {
            ackManager.addTimedAck(4, on: queue, callback: { err, _ in
                XCTAssertEqual(err as? SocketAckError, .disconnected); exp.fulfill()
            }, timeout: 60)
            ackManager.addTimedAck(5, on: queue, callback: { err, _ in
                XCTAssertEqual(err as? SocketAckError, .disconnected); exp.fulfill()
            }, timeout: 60)
        }
        queue.async { self.ackManager.clearTimedAcks(reason: .disconnected) }
        wait(for: [exp], timeout: 1)
    }

    func testOneShotGuard() {
        let exp = expectation(description: "first execute fires once")
        let firesBox = FireCounter()
        queue.sync {
            ackManager.addTimedAck(6, on: queue,
                                   callback: { _, _ in
                                       firesBox.bump()
                                       exp.fulfill()
                                   },
                                   timeout: 60)
        }
        queue.async { self.ackManager.executeTimedAck(6, with: ["a"]) }
        queue.async { self.ackManager.executeTimedAck(6, with: ["b"]) } // duplicate
        wait(for: [exp], timeout: 1)
        queue.sync { } // drain
        XCTAssertEqual(firesBox.count, 1, "duplicate must be silently dropped")
    }
}

/// Tiny counter helper kept outside the test class so the closure capture is unambiguous.
private final class FireCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
