//
//  SocketReservedEvent.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// Reserved event names: user code is forbidden from emitting them, and the parser drops incoming events that
/// carry them (`Decoder.isPayloadValid` in socket.io-parser).
/// JS-aligned: `socket.io-client/lib/socket.ts` `RESERVED_EVENTS` — Swift drops
/// only `newListener`/`removeListener` (Node EventEmitter internals with no
/// Swift equivalent).
internal enum SocketReservedEvent {
    static let names: Set<String> = [
        "connect", "connect_error", "disconnect", "disconnecting"
    ]
}
