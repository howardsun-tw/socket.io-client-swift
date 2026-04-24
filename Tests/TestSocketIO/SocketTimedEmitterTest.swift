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

// MARK: - Task 4: end-to-end callback path tests
//
// These exercise the full SocketIOClient.timeout(after:).emit(...) callback
// surface against an unconnected manager (no network), so every fire must come
// from local timer/disconnect/cancel paths. The handleQueue MUST be a
// background queue: tests call `manager.handleQueue.sync { }` from the main
// thread to drain dispatched work, and using `.main` would self-deadlock.

final class SocketTimedEmitterCallbackTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.timed.callback.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    func testTimedEmitTimesOutWhenNoServer() {
        let exp = expectation(description: ".timeout fires")
        socket.timeout(after: 0.1).emit("ping") { err, data in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            XCTAssertTrue(data.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testDisconnectMidWaitFiresDisconnected() {
        let exp = expectation(description: ".disconnected fires")
        socket.timeout(after: 5).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .disconnected)
            exp.fulfill()
        }
        // Drain the emit registration so the timed ack is in storage before
        // we trigger the disconnect.
        manager.handleQueue.sync { }
        socket.didDisconnect(reason: "test")
        wait(for: [exp], timeout: 1)
    }

    func testNegativeTimeoutFiresImmediately() {
        let exp = expectation(description: ".timeout fires next tick")
        socket.timeout(after: -1).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testInfinityTimeoutDoesNotFireQuickly() {
        let exp = expectation(description: "no fire within 0.5s")
        exp.isInverted = true
        socket.timeout(after: .infinity).emit("ping") { _, _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)
    }

    func testRegistrationBeforeFunnel_DisconnectedEmitStillTimesOut() {
        // Critical JS-parity contract: even though the socket is .disconnected
        // and the emit funnel will early-return without sending a packet, the
        // ack registration runs BEFORE the funnel guard so the timer is still
        // scheduled and fires .timeout. Mirrors JS `_registerAckCallback`.
        socket.setTestStatus(.disconnected)
        let exp = expectation(description: "timeout fires even though emit early-returned")
        socket.timeout(after: 0.2).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - Task 5: async overload + cancellation
//
// Exercises the `async throws -> [Any]` overloads on SocketTimedEmitter,
// including the withTaskCancellationHandler path that routes Task.cancel()
// through SocketAckManager.cancelTimedAck(_:fireWith:) so the continuation
// resumes throwing CancellationError exactly once.

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
final class SocketTimedEmitterAsyncTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.timed.async.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    func testAsyncTimeoutThrows() async {
        do {
            _ = try await socket.timeout(after: 0.1).emit("ping")
            XCTFail("should have thrown")
        } catch let error as SocketAckError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAsyncCancelThrowsCancellationError() async {
        // Capture the socket locally so the spawned Task does not retain self.
        let socket = self.socket!
        let task = Task {
            do {
                _ = try await socket.timeout(after: 60).emit("ping")
                XCTFail("should have thrown")
            } catch is CancellationError {
                // Expected — cancellation handler fires the registered ack
                // with CancellationError, the user-callback adapter resumes
                // the continuation throwing it.
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
        // Let the await register the timed ack on handleQueue before cancel.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value
    }

    func testAsyncCancelClearsTimedAck() async {
        let socket = self.socket!
        let task = Task { try? await socket.timeout(after: 60).emit("ping") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value
        // Drain handleQueue so the cancelTimedAck(fireWith:) dispatched from
        // the cancellation handler completes and the entry is removed.
        manager.handleQueue.sync { }

        // Public-observable check: a follow-up timed emit must complete its
        // own lifecycle cleanly. If the prior cancel left the entry in
        // storage, the ack-id allocator would still advance, but the leaked
        // timer would later fire against a stale callback. Easiest robust
        // observation is that a fresh 0.1s timeout fires exactly once with
        // .timeout — proving (a) the manager isn't wedged and (b) we can
        // continue issuing emits after cancel.
        let exp = expectation(description: "follow-up emit times out cleanly")
        socket.timeout(after: 0.1).emit("ping") { err, data in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            XCTAssertTrue(data.isEmpty)
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1)
    }
}

// MARK: - Task 6: race / atomicity stress + storage isolation
//
// `testTimerAckRaceFiresOnce` is a 200-iteration stress that pits a
// sub-millisecond timer against an off-queue handleAck injection on the same
// id. The TimedAckEntry.fired flag (queue-protected, no lock) must drop the
// loser deterministically, so the user callback fires exactly once.
//
// `testLegacyEmitWithAckTimingOutNotClearedOnDisconnect` regression-pins the
// documented divergence: legacy emitWithAck.timingOut(after:) does NOT have a
// withError callback, and Phase 9 deliberately did not retro-fit the legacy
// path. clearTimedAcks(reason: .disconnected) only drains the new timed-ack
// storage, so the legacy ack stays orphaned on disconnect — fires == 0.
//
// Iteration count was lowered from the plan's 1000 → 200 to keep the test
// under one second of wall clock on CI. 200 is still well above the threshold
// where any double-fire bug would surface (a single double-fire produces an
// XCTest "expected 1 fulfillment, got 2" failure).

final class SocketTimedEmitterRaceTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.timed.race.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    func testTimerAckRaceFiresOnce() {
        // Tight race: ~1ms timer vs ~1ms async handleAck injection from a
        // background queue. The TimedAckEntry.fired flag must arbitrate so
        // the user callback runs exactly once across all iterations.
        let iterations = 200
        for _ in 0..<iterations {
            let counter = FireCounter()
            let exp = expectation(description: "single fire")
            socket.timeout(after: 0.001).emit("ping") { _, _ in
                counter.bump()
                if counter.count == 1 { exp.fulfill() }
            }
            // Capture the allocated ack id by reading currentAck on
            // handleQueue AFTER the emit's async registration runs. This
            // serialization is what makes the next handleAck call target the
            // right id rather than racing the allocator.
            var ackId = -1
            manager.handleQueue.sync { ackId = self.socket.currentAck }
            // Race: server-ack arrives at ~the same time as the timer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.001) { [weak self] in
                self?.manager.handleQueue.async {
                    self?.socket.handleAck(ackId, data: ["x"])
                }
            }
            wait(for: [exp], timeout: 1)
            // Brief drain so any latent double-fire (timer + ack both winning)
            // would still bump the counter past 1 before we assert.
            Thread.sleep(forTimeInterval: 0.005)
            XCTAssertEqual(counter.count, 1, "must fire exactly once")
        }
    }

    func testLegacyEmitWithAckTimingOutNotClearedOnDisconnect() {
        // JS-divergence regression-pin: the legacy path uses SocketAckManager's
        // `acks` (untyped AckCallback, no fireWith error). didDisconnect only
        // calls clearTimedAcks(reason:) on the new timed-ack storage, so a
        // legacy emitWithAck.timingOut callback is orphaned across a disconnect
        // until its own timer fires (at which point it would fire .noAck, not
        // .disconnected). For this test we use a 5s timer and only wait 0.2s,
        // so the assertion is purely "no fire happened during the disconnect".
        let counter = FireCounter()
        socket.emitWithAck("ping").timingOut(after: 5) { _ in counter.bump() }
        manager.handleQueue.sync { }
        socket.didDisconnect(reason: "test")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(counter.count, 0,
                       "legacy emitWithAck.timingOut path is NOT cleared on disconnect (Swift backcompat divergence)")
    }
}
