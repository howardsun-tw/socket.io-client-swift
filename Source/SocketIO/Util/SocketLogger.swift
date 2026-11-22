//
//  SocketLogger.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 4/11/15.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation

/// Represents a class will log client events.
public protocol SocketLogger : AnyObject {
    // MARK: Properties

    /// Whether to log or not
    var log: Bool { get set }

    // MARK: Methods

    /// Normal log messages
    ///
    /// - parameter message: The message being logged. Can include `%@` that will be replaced with `args`
    /// - parameter type: The type of entity that called for logging.
    /// - parameter args: Any args that should be inserted into the message. May be left out.
    func log(_ message: @autoclosure () -> String, type: String)

    /// Error Messages
    ///
    /// - parameter message: The message being logged. Can include `%@` that will be replaced with `args`
    /// - parameter type: The type of entity that called for logging.
    /// - parameter args: Any args that should be inserted into the message. May be left out.
    func error(_ message: @autoclosure () -> String, type: String)
}

public extension SocketLogger {
    /// Default implementation.
    func log(_ message: @autoclosure () -> String, type: String) {
        guard log else { return }

        abstractLog("LOG", message: message(), type: type)
    }

    /// Default implementation.
    func error(_ message: @autoclosure () -> String, type: String) {
        guard log else { return }

        abstractLog("ERROR", message: message(), type: type)
    }

    private func abstractLog(_ logType: String, message: @autoclosure () -> String, type: String) {
        // `type` can hold a namespace name, so it must not be part of the format string.
        NSLog("%@ %@: %@", logType, type, message())
    }
}

class DefaultSocketLogger : SocketLogger {
    static var Logger: SocketLogger = DefaultSocketLogger()

    var log = false
}

/// Removes credentials from text that is about to be logged. The logger is process-wide and logs are often shared
/// when debugging, so a log line must not carry what the application authenticates with: the CONNECT payload
/// (`auth` going out, the session-recovery `pid` coming in) and the query values from `connectParams`.
/// Event payloads are logged as they are.
enum SocketLogRedaction {
    static let placeholder = "<redacted>"

    /// - parameter packet: A Socket.IO packet. Only a CONNECT packet (type 0) is changed.
    static func socketPacket(_ packet: String) -> String {
        guard packet.first == "0" else { return packet }

        var payload = packet.dropFirst()

        if payload.first == "/" {
            guard let comma = payload.firstIndex(of: ",") else { return packet }

            payload = payload[payload.index(after: comma)...]
        }

        return payload.isEmpty ? packet : String(packet.dropLast(payload.count)) + placeholder
    }

    /// - parameter packet: An Engine.IO packet with its type digit. Only a message packet (type 4) is changed.
    static func enginePacket(_ packet: String) -> String {
        return packet.first == "4" ? "4" + socketPacket(String(packet.dropFirst())) : packet
    }

    /// Keeps the query values that Engine.IO itself adds and hides every other one, plus any user info.
    static func url(_ url: URL?) -> String {
        guard let url = url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "nil"
        }

        components.user = nil
        components.password = nil
        components.queryItems = components.queryItems?.map({item in
            guard !["EIO", "transport", "sid", "b64"].contains(item.name) else { return item }

            // In a bare `?token` the name is the secret.
            return item.value == nil ? URLQueryItem(name: "REDACTED", value: nil)
                                     : URLQueryItem(name: item.name, value: "REDACTED")
        })

        return components.string ?? "nil"
    }
}
