//
//  TestSocketIOClientConfiguration.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 8/13/16.
//
//

import XCTest
@testable import SocketIO

class TestSocketIOClientConfiguration : XCTestCase {
    func testReplaceSameOption() {
        config.insert(.log(true))

        XCTAssertEqual(config.count, 2)

        switch config[0] {
        case let .log(log):
            XCTAssertTrue(log)
        default:
            XCTFail()
        }
    }

    func testIgnoreIfExisting() {
        config.insert(.forceNew(false), replacing: false)

        XCTAssertEqual(config.count, 2)

        switch config[1] {
        case let .forceNew(new):
            XCTAssertTrue(new)
        default:
            XCTFail()
        }
    }

    func testAutoConnectOption() {
        var config: SocketIOClientConfiguration = []
        config.insert(.autoConnect(true))

        XCTAssertEqual(config.count, 1)

        switch config[0] {
        case let .autoConnect(value):
            XCTAssertTrue(value)
        default:
            XCTFail("expected .autoConnect, got \(config[0])")
        }
    }

    func testAutoConnectDescription() {
        let option = SocketIOClientOption.autoConnect(false)
        XCTAssertEqual(option.description, "autoConnect")
    }

    func testAutoConnectValue() {
        let option = SocketIOClientOption.autoConnect(true)
        let value = option.getSocketIOOptionValue() as? Bool
        XCTAssertEqual(value, true)
    }

    var config = [] as SocketIOClientConfiguration

    override func setUp() {
        config = [.log(false), .forceNew(true)]

        super.setUp()
    }
}
