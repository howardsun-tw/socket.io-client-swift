//
//  SocketVolatileEmitter.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// JS-aligned volatile-emit chain. Drops the packet if the engine transport
/// is not writable. Does NOT fire `.error`, outgoing listeners, or buffer.
/// JS: `socket.io-client/lib/socket.ts emit()` body — gates on
/// `transport.writable`, not on `status`.
///
/// No `emit(... ack:)` overload — JS allows `socket.volatile.emit("e", arg, cb)`
/// but the callback is orphaned in `this.acks` on drop. Swift omits the API
/// to prevent the orphan bug. Listed under JS-divergence policy category 3.
public struct SocketVolatileEmitter {
    let socket: SocketIOClient

    public func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil) {
        emit(event, with: items, completion: completion)
    }

    public func emit(_ event: String, with items: [SocketData], completion: (() -> ())? = nil) {
        do {
            let mapped = [event] + (try items.map { try $0.socketRepresentation() })
            socket.emitVolatile(mapped, completion: completion)
        } catch {
            DefaultSocketLogger.Logger.error(
                "Error creating socketRepresentation for volatile emit: \(event), \(items)",
                type: "SocketVolatileEmitter"
            )
            socket.handleClientEvent(.error, data: [event, items, error])
        }
    }
}
