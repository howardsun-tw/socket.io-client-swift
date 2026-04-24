//
//  SocketVolatileTest.swift
//  Socket.IO-Client-Swift
//
//  Phase 7 Task 3 — behavior tests for the volatile-emit gate. Drives a
//  `MockEngine` whose `writable` flag is test-controlled, then asserts the
//  expected drop / pass-through behavior of `socket.volatile.emit(...)`.
//
//  JS reference: `socket.io-client/lib/socket.ts emit()` body —
//      const discardPacket = this.flags.volatile && !this.io.engine?.transport?.writable;
//
//  Drop must be silent: no `.error`, no outgoing-listener fire, no buffering.
//

import XCTest
@testable import SocketIO

final class SocketVolatileTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var mockEngine: MockEngine!

    override func setUp() {
        super.setUp()
        let queue = DispatchQueue(label: "test.SocketVolatileTest.handleQueue")
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.log(false), .handleQueue(queue)])
        mockEngine = MockEngine()
        manager.engine = mockEngine
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        mockEngine = nil
        manager = nil
        super.tearDown()
    }

    /// Block until any work already enqueued on `handleQueue` has run.
    private func drain() { manager.handleQueue.sync { } }

    func testVolatileEmitWhileWritableSends() {
        mockEngine.writable = true
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1,
                       "writable transport: volatile sends")
    }

    func testVolatileEmitWhileNotWritableDrops() {
        mockEngine.writable = false
        var errorFired = 0
        socket.on(clientEvent: .error) { _, _ in errorFired += 1 }
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 0,
                       "not-writable: volatile must drop, no engine.send")
        XCTAssertEqual(errorFired, 0,
                       "volatile drop must NOT fire .error (JS-aligned)")
    }

    func testNonVolatileEmitWhileNotWritableSurfacesErrorOrSends() {
        // Non-volatile emit on a not-writable transport: the volatile gate
        // is bypassed (volatile=false). The connected-state guard then runs;
        // since status==.connected here, the packet still goes through.
        // (Swift currently has no outbound buffer; this matches existing
        // behavior pre-Phase 7.)
        mockEngine.writable = false
        socket.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1,
                       "non-volatile emit still calls engine.send (Swift backcompat)")
    }

    func testVolatileEmitWhileNotConnectedDrops() {
        // Volatile gate fires BEFORE the connected check, so even with a
        // disconnected status a not-writable transport drops the packet
        // silently (the connected-check would also drop it, but via .error —
        // we want to assert the volatile path short-circuits cleanly).
        socket.setTestStatus(.disconnected)
        mockEngine.writable = false
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 0)
    }

    func testReservedNameViaVolatileStillSendsWhenWritable() {
        // No reserved-event guard on this branch (Phase 2 not merged).
        // Volatile path itself is not aware of reserved names — it just
        // routes through the funnel which (on master) doesn't check.
        mockEngine.writable = true
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1)
    }

    func testVolatileEmitArrayForm() {
        mockEngine.writable = true
        socket.volatile.emit("foo", with: ["a", "b"])
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1)
    }

    func testVolatileCompletionFiresEvenOnDrop() {
        mockEngine.writable = false
        var completed = false
        socket.volatile.emit("foo", "x") { completed = true }
        // The completion is hopped onto handleQueue.async — drain twice to
        // wait for both the emit work and the wrapped completion hop.
        drain()
        drain()
        XCTAssertTrue(completed,
                      "completion must fire even on drop (caller contract)")
    }
}
