//
//  SocketParsable.swift
//  Socket.IO-Client-Swift
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

/// Defines that a type will be able to parse socket.io-protocol messages.
public protocol SocketParsable : AnyObject {
    // MARK: Methods

    /// Called when the engine has received some binary data that should be attached to a packet.
    ///
    /// Packets binary data should be sent directly after the packet that expects it, so there's confusion over
    /// where the data should go. Data should be received in the order it is sent, so that the correct data is put
    /// into the correct placeholder.
    ///
    /// - parameter data: The data that should be attached to a packet.
    func parseBinaryData(_ data: Data) -> SocketPacket?

    /// Called when the engine has received a string that should be parsed into a socket.io packet.
    ///
    /// - parameter message: The string that needs parsing.
    /// - returns: A completed socket packet if there is no more data left to collect.
    func parseSocketMessage(_ message: String) -> SocketPacket?
}

/// Errors that can be thrown during parsing.
public enum SocketParsableError : Error {
    // MARK: Cases

    /// Thrown when a packet received has an invalid data array, or is missing the data array.
    case invalidDataArray

    /// Thrown when an malformed packet is received.
    case invalidPacket

    /// Thrown when the parser receives an unknown packet type.
    case invalidPacketType
}

/// The most binary attachments one packet may declare. Same default as `maxAttachments` in the socket.io-parser
/// `Decoder`; a larger count is treated as a malformed packet.
private let maximumAttachments = 10

/// Says that a type will be able to buffer binary data before all data for an event has come in.
public protocol SocketDataBufferable : AnyObject {
    // MARK: Properties

    /// A list of packets that are waiting for binary data.
    ///
    /// The way that socket.io works all data should be sent directly after each packet.
    /// So this should ideally be an array of one packet waiting for data.
    ///
    /// **This should not be modified directly.**
    var waitingPackets: [SocketPacket] { get set }
}

public extension SocketParsable where Self: SocketManagerSpec & SocketDataBufferable {
    /// Parses a message from the engine, returning a complete SocketPacket or throwing.
    ///
    /// - parameter message: The message to parse.
    /// - returns: A completed packet, or throwing.
    internal func parseString(_ message: String) throws -> SocketPacket {
        // The packet header is ASCII, so a forward-only cursor over the UTF-8 bytes can neither run past the end
        // nor split a character, whatever the server sends.
        let bytes = Array(message.utf8)

        guard let first = bytes.first, let type = SocketPacket.PacketType(rawValue: Int(first) - 48) else {
            throw SocketParsableError.invalidPacketType
        }

        var cursor = 1

        func readDigits() -> Int? {
            let start = cursor

            while cursor < bytes.count && bytes[cursor] >= 48 && bytes[cursor] <= 57 {
                cursor += 1
            }

            return cursor > start ? Int(String(decoding: bytes[start..<cursor], as: UTF8.self)) : nil
        }

        var namespace = "/"
        var placeholders = -1

        if type.isBinary {
            guard let holders = readDigits(), holders <= maximumAttachments,
                  cursor < bytes.count, bytes[cursor] == UInt8(ascii: "-") else {
                throw SocketParsableError.invalidPacket
            }

            placeholders = holders
            cursor += 1
        }

        if cursor < bytes.count && bytes[cursor] == UInt8(ascii: "/") {
            let start = cursor

            while cursor < bytes.count && bytes[cursor] != UInt8(ascii: ",") {
                cursor += 1
            }

            namespace = String(decoding: bytes[start..<cursor], as: UTF8.self)

            if cursor < bytes.count {
                cursor += 1
            }
        }

        // An error packet carries no ack id; its payload may itself be a bare number.
        let id = type == .error ? -1 : readDigits() ?? -1

        guard cursor < bytes.count else {
            // An event has to name itself, and placeholders can only live in a payload.
            guard type != .event && !type.isBinary else {
                throw SocketParsableError.invalidDataArray
            }

            return SocketPacket(type: type, id: id, nsp: namespace, placeholders: placeholders)
        }

        var payload = bytes[cursor...]

        if (type == .error || type == .connect) && payload.first != UInt8(ascii: "[")
            && payload.last != UInt8(ascii: "]") {
            payload = [UInt8(ascii: "[")] + payload + [UInt8(ascii: "]")]
        }

        guard let data = (try? JSONSerialization.jsonObject(with: Data(payload), options: .mutableContainers))
                as? [Any] else {
            throw SocketParsableError.invalidDataArray
        }

        if type == .event || type == .binaryEvent {
            // Same rule as `Decoder.isPayloadValid` in socket.io-parser: without it the server could fire this
            // client's own `connect`/`disconnect` handlers, which are dispatched by event name.
            let isValidName: Bool

            switch data.first {
            case let number as NSNumber:
                // A JSON boolean is an NSNumber too, but it is not a number.
                isValidName = CFGetTypeID(number) != CFBooleanGetTypeID()
            case let string as String:
                isValidName = !SocketReservedEvent.names.contains(string)
            default:
                isValidName = false
            }

            guard isValidName else {
                throw SocketParsableError.invalidDataArray
            }
        }

        if placeholders > 0 && !SocketPacket.hasValidPlaceholders(data, count: placeholders) {
            throw SocketParsableError.invalidPacket
        }

        return SocketPacket(type: type, data: data, id: id, nsp: namespace, placeholders: placeholders)
    }

    /// Called when the engine has received a string that should be parsed into a socket.io packet.
    ///
    /// - parameter message: The string that needs parsing.
    /// - returns: A completed socket packet or nil if the packet is invalid.
    func parseSocketMessage(_ message: String) -> SocketPacket? {
        guard !message.isEmpty else { return nil }

        // Attachments follow their packet directly. socket.io-parser fails with "got plaintext data when
        // reconstructing a packet"; dropping the incomplete packet also keeps `waitingPackets` from growing.
        if !waitingPackets.isEmpty {
            DefaultSocketLogger.Logger.error("Got a text packet before all binary attachments; dropping the incomplete packet",
                                             type: "SocketParser")
            waitingPackets.removeAll()
        }

        DefaultSocketLogger.Logger.log("Parsing \(SocketLogRedaction.socketPacket(message))", type: "SocketParser")

        do {
            let packet = try parseString(message)

            DefaultSocketLogger.Logger.log("Decoded packet as: \(packet.type == .connect ? "connect to \(packet.nsp)" : packet.description)",
                                           type: "SocketParser")

            return packet
        } catch {
            DefaultSocketLogger.Logger.error("\(error): \(SocketLogRedaction.socketPacket(message))", type: "SocketParser")

            return nil
        }
    }

    /// Called when the engine has received some binary data that should be attached to a packet.
    ///
    /// Packets binary data should be sent directly after the packet that expects it, so there's confusion over
    /// where the data should go. Data should be received in the order it is sent, so that the correct data is put
    /// into the correct placeholder.
    ///
    /// - parameter data: The data that should be attached to a packet.
    /// - returns: A completed socket packet if there is no more data left to collect.
    func parseBinaryData(_ data: Data) -> SocketPacket? {
        guard !waitingPackets.isEmpty else {
            DefaultSocketLogger.Logger.error("Got data when not remaking packet", type: "SocketParser")

            return nil
        }

        // Should execute event?
        guard waitingPackets[waitingPackets.count - 1].addData(data) else { return nil }

        return waitingPackets.removeLast()
    }
}
