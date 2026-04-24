//
//  SocketEngineWritableTest.swift
//  Socket.IO-Client-Swift
//
//  Phase 7 Task 1 — verify the `SocketEngineSpec.writable` default fail-safe.
//

import XCTest
import Starscream
@testable import SocketIO

/// A minimal `SocketEngineSpec` conformer that does NOT override `writable`.
/// Verifies the protocol's default fail-safe `false` returns. Most other
/// `SocketEngineSpec` requirements are stubbed.
private final class StubEngine: NSObject, SocketEngineSpec {
    weak var client: SocketEngineClient?
    var closed: Bool = false
    var compress: Bool = false
    var connected: Bool = true
    var connectParams: [String: Any]? = nil
    var cookies: [HTTPCookie]? = nil
    var engineQueue: DispatchQueue = DispatchQueue(label: "stub.engineQueue")
    var extraHeaders: [String: String]? = nil
    var fastUpgrade: Bool = false
    var forcePolling: Bool = false
    var forceWebsockets: Bool = false
    var polling: Bool = false
    var probing: Bool = false
    var sid: String = "stub-sid"
    var socketPath: String = "/socket.io/"
    var urlPolling: URL = URL(string: "http://localhost/")!
    var urlWebSocket: URL = URL(string: "ws://localhost/")!
    var version: SocketIOVersion = .three
    var websocket: Bool = true
    var ws: WebSocket? = nil

    required convenience init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.init()
        self.client = client
    }

    override init() {
        super.init()
    }

    func connect() {}
    func didError(reason: String) {}
    func disconnect(reason: String) {}
    func doFastUpgrade() {}
    func flushWaitingForPostToWebSocket() {}
    func parseEngineData(_ data: Data) {}
    func parseEngineMessage(_ message: String) {}
    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) {}
}

final class SocketEngineWritableTest: XCTestCase {
    func testProtocolDefaultIsFalse() {
        let stub = StubEngine()
        XCTAssertFalse(stub.writable, "default impl must return false (fail-safe)")
    }
}
