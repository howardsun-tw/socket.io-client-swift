//
//  SocketTimedEmitter.swift
//  Socket.IO-Client-Swift
//
//  Phase 9: per-emit ack with typed SocketAckError.
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

/// A chainable handle returned from `SocketIOClient.timeout(after:)` that emits
/// an event with a typed-error per-emit ack callback.
///
/// JS analogue: `socket.timeout(2000).emit("ev", arg, (err, data) => ...)`.
///
/// Usage:
/// ```swift
/// socket.timeout(after: 2).emit("ping") { err, data in
///     if let err = err as? SocketAckError { /* .timeout or .disconnected */ }
///     else { /* server ack data in `data` */ }
/// }
/// ```
///
/// **Threading:** the underlying registration runs on
/// `socket.manager.handleQueue`, so the timer is scheduled before the emit
/// funnel is invoked. This means a disconnected emit still fires `.timeout`
/// after `seconds` — matching JS `_registerAckCallback` semantics.
public struct SocketTimedEmitter {
    let socket: SocketIOClient
    let timeout: Double

    /// Variadic callback overload.
    public func emit(_ event: String, _ items: SocketData...,
                     ack: @escaping (Error?, [Any]) -> Void) {
        emit(event, with: items, ack: ack)
    }

    /// Array callback overload.
    public func emit(_ event: String, with items: [SocketData],
                     ack: @escaping (Error?, [Any]) -> Void) {
        socket.emitTimed(event: event, items: items, timeout: timeout, ack: ack)
    }

    /// Variadic async/throws overload.
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    public func emit(_ event: String, _ items: SocketData...) async throws -> [Any] {
        return try await emit(event, with: items)
    }

    /// Array async/throws overload.
    ///
    /// Throws `SocketAckError.timeout` / `.disconnected` for the corresponding
    /// fire reasons, or `CancellationError` if the awaiting `Task` is cancelled
    /// before the ack arrives.
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    public func emit(_ event: String, with items: [SocketData]) async throws -> [Any] {
        // Allocate the id eagerly so the cancellation handler can reference it.
        // Mirrors the existing legacy pattern: `currentAck` is mutated off-queue
        // by emitWithAck → createOnAck (see SocketIOClient.swift line ~287). The
        // ordering between emitTimed (which reads the id under handleQueue) and
        // any concurrent emitWithAck on another thread is therefore the same as
        // the existing baseline — not strictly serialized, but consistent with
        // the rest of the public API.
        let socket = self.socket
        let timeout = self.timeout
        // Note: when the pre-cancellation guard below fires, this `id` is
        // "leaked" — never registered with addTimedAck, never executed, never
        // cancelled. This is harmless: ack ids are a monotonically-incrementing
        // Int with no reuse, so a single skipped value has no observable cost.
        let id = socket.allocateAckId()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Pre-cancellation guard: per Apple docs, when
                // withTaskCancellationHandler is invoked on an already-cancelled
                // Task, `onCancel` runs IMMEDIATELY and synchronously BEFORE
                // this `operation` closure. That early cancel was enqueued on
                // handleQueue against an id that has not yet been registered,
                // so cancelTimedAck no-ops when the queue services it. Without
                // this short-circuit, emitTimed would then register the entry
                // with nothing left to fire it — and for `.timeout(after:
                // .infinity)` the continuation would deadlock forever. Resume
                // synchronously here so the caller observes CancellationError
                // and we never enter emitTimed at all.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                socket.emitTimed(event: event, items: items, timeout: timeout, ackId: id) { err, data in
                    if let err = err {
                        continuation.resume(throwing: err)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
        } onCancel: {
            // Route cancellation through the canonical one-shot fire site:
            // cancelTimedAck(fireWith:) invokes the callback with the supplied
            // error, and the callback resumes the continuation throwing
            // CancellationError. This keeps timer/ack/cancel paths atomic via
            // the entry's `fired` flag — there is no separate continuation
            // bookkeeping that could double-resume.
            //
            // Mid-await race note: when Task.cancel() arrives AFTER emitTimed
            // has enqueued addTimedAck (the common case), the serial
            // handleQueue enforces add-then-cancel ordering and this dispatch
            // delivers CancellationError through the registered callback. The
            // pre-cancellation case is handled by the Task.isCancelled guard
            // inside the operation closure above.
            socket.manager?.handleQueue.async {
                socket.ackHandlers.cancelTimedAck(id, fireWith: CancellationError())
            }
        }
    }
}
