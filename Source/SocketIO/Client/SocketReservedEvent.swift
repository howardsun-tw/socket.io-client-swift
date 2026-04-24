//
//  SocketReservedEvent.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// Reserved event names that user code is forbidden from emitting.
/// JS-aligned: `socket.io-client/lib/socket.ts` `RESERVED_EVENTS` — Swift drops
/// only `newListener`/`removeListener` (Node EventEmitter internals with no
/// Swift equivalent).
internal enum SocketReservedEvent {
    static let names: Set<String> = [
        "connect", "connect_error", "disconnect", "disconnecting"
    ]
}
