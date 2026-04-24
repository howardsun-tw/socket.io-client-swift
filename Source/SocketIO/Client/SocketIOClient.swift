//
//  SocketIOClient.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 11/23/14.
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

import Dispatch
import Foundation

/// Callback used by an auth provider to deliver its resolved payload (or `nil`)
/// back to the client for the upcoming CONNECT packet.
public typealias SocketAuthCallback = ([String: Any]?) -> Void

/// Auth provider type. Invoked on `manager.handleQueue` for every CONNECT
/// (initial + every reconnect). Mirrors the JS callback-form `auth(cb)`.
public typealias SocketAuthProvider = (@escaping SocketAuthCallback) -> Void

/// Represents a socket.io-client.
///
/// Clients are created through a `SocketManager`, which owns the `SocketEngineSpec` that controls the connection to the server.
///
/// For example:
///
/// ```swift
/// // Create a socket for the /swift namespace
/// let socket = manager.socket(forNamespace: "/swift")
///
/// // Add some handlers and connect
/// ```
///
/// **NOTE**: The client is not thread/queue safe, all interaction with the socket should be done on the `manager.handleQueue`
///
open class SocketIOClient: NSObject, SocketIOClientSpec {
    // MARK: Properties

    /// The namespace that this socket is currently connected to.
    ///
    /// **Must** start with a `/`.
    public let nsp: String

    /// A handler that will be called on any event.
    public private(set) var anyHandler: ((SocketAnyEvent) -> ())?

    /// Storage for the multi-listener `onAny` family. UUID-keyed because Swift
    /// closures lack identity. Mutators serialize via `handleQueue.async`.
    private var anyListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []

    /// Storage for the `onAnyOutgoing` family. UUID-keyed because closures lack
    /// identity. Mutators serialize via `handleQueue.async`.
    private var anyOutgoingListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []

    /// The array of handlers for this socket.
    public private(set) var handlers = [SocketEventHandler]()

    /// The manager for this socket.
    public private(set) weak var manager: SocketManagerSpec?

    /// A view into this socket where emits do not check for binary data.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.rawEmitView.emit("myEvent", myObject)
    /// ```
    ///
    /// **NOTE**: It is not safe to hold on to this view beyond the life of the socket.
    public private(set) lazy var rawEmitView = SocketRawView(socket: self)

    /// The status of this client.
    public private(set) var status = SocketIOStatus.notConnected {
        didSet {
            handleClientEvent(.statusChange, data: [status, status.rawValue])
        }
    }

    /// Whether the socket is currently subscribed to its manager. Mirrors JS
    /// `socket.io-client/lib/socket.ts` `get active() { return !!this.subs }`.
    /// Flipped `true` at the start of `connect()`, and `false` on the three
    /// JS `destroy()` paths: user `disconnect()`, server-initiated DISCONNECT
    /// packet, and CONNECT_ERROR packet receipt. Survives engine-close +
    /// reconnect cycles — `didDisconnect(reason:)` itself does NOT clear it,
    /// because the manager will auto-reconnect and re-issue CONNECT. Distinct
    /// from `socket.status.active` which reports whether the current status
    /// enum is a live state.
    public private(set) var active: Bool = false

    /// The id of this socket.io connect. This is different from the sid of the engine.io connection.
    public private(set) var sid: String?

    // MARK: Connection State Recovery (Socket.IO v3+)

    /// Maximum accepted length (UTF-8 bytes) for a server-provided offset string.
    /// See design spec §3.3 / §6.1 D1.
    public static let socketStateRecoveryMaxOffsetBytes = 256

    /// Whether the last successful CONNECT ack recovered a prior session.
    /// Matches the `recovered` property on `socket.io-client` JS.
    public private(set) var recovered: Bool = false

    /// Private session id assigned by the server. `nil` until the first CONNECT ack.
    /// Only written on v3 managers.
    var _pid: String?

    /// Last observed event offset (server-controlled last-arg string).
    /// Bounded by `socketStateRecoveryMaxOffsetBytes`.
    var _lastOffset: String?

    let ackHandlers = SocketAckManager()
    var connectPayload: [String: Any]?

    private(set) var currentAck = -1

    private lazy var logType = "SocketIOClient{\(nsp)}"
    private var bufferedRecoveryReplayEvents = [(event: String, data: [Any], ack: Int)]()

    // MARK: Auth provider state

    /// Installed auth provider (callback-form, or async-form wrapped to callback).
    /// Invoked on `manager.handleQueue` for every CONNECT.
    private var authProvider: SocketAuthProvider?

    /// Internal flag for `SocketManager._engineDidOpen` to detect that the v2
    /// root-namespace short-circuit should still surface the v2-bypass `.error`.
    /// Without this, the v2 root-nsp path never reaches `resolveConnectPayload`
    /// (where the bypass guard normally fires).
    internal var hasAuthProvider: Bool { authProvider != nil }

    /// Type-erased cancel handle for the in-flight async auth `Task`. Storing the
    /// raw `Task<...>` would require iOS 13 / macOS 10.15 availability on the
    /// property declaration; capturing `task.cancel` here keeps the property
    /// availability-neutral and confines the `Task` reference to the async
    /// overload of `setAuth(_:)`.
    private var pendingAuthTask: (() -> Void)?

    /// Monotonic generation token bumped on `connect`, `setAuth`, and `clearAuth`.
    /// Async auth results captured under one generation are discarded if the
    /// generation has moved on by the time they hop back to `handleQueue`.
    private var authGeneration: UInt64 = 0

    // MARK: Initializers

    /// Type safe way to create a new SocketIOClient. `opts` can be omitted.
    ///
    /// - parameter manager: The manager for this socket.
    /// - parameter nsp: The namespace of the socket.
    public init(manager: SocketManagerSpec, nsp: String) {
        self.manager = manager
        self.nsp = nsp

        super.init()
    }

    /// :nodoc:
    deinit {
        DefaultSocketLogger.Logger.log("Client is being released", type: logType)
    }

    // MARK: Methods

    /// Connect to the server. The same as calling `connect(timeoutAfter:withHandler:)` with a timeout of 0.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    ///
    /// - parameter withPayload: An optional payload sent on connect
    open func connect(withPayload payload: [String: Any]? = nil) {
        self.active = true
        connect(withPayload: payload, timeoutAfter: 0, withHandler: nil)
    }

    /// Connect to the server. If we aren't connected after `timeoutAfter` seconds, then `withHandler` is called.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    ///
    /// - parameter withPayload: An optional payload sent on connect
    /// - parameter timeoutAfter: The number of seconds after which if we are not connected we assume the connection
    ///                           has failed. Pass 0 to never timeout.
    /// - parameter handler: The handler to call when the client fails to connect.
    open func connect(withPayload payload: [String: Any]? = nil, timeoutAfter: Double, withHandler handler: (() -> ())?) {
        self.active = true
        assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

        guard let manager = self.manager, status != .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting on an already connected socket", type: logType)
            return
        }

        self.authGeneration &+= 1

        status = .connecting

        joinNamespace(withPayload: payload)

        switch manager.version {
        case .three:
            break
        case .two where manager.status == .connected && nsp == "/":
            // We might not get a connect event for the default nsp, fire immediately
            didConnect(toNamespace: nsp, payload: nil)

            return
        case _:
            break
        }

        guard timeoutAfter != 0 else { return }

        manager.handleQueue.asyncAfter(deadline: DispatchTime.now() + timeoutAfter) {[weak self] in
            guard let this = self, this.status == .connecting || this.status == .notConnected else { return }
            if this.status == .connecting {
                DefaultSocketLogger.Logger.log("Timeout: Socket not connected, so setting to disconnected", type: this.logType)

                this.clearBufferedRecoveryReplayEvents()
                this.status = .disconnected
                this.leaveNamespace()
            } else {
                DefaultSocketLogger.Logger.log("Timeout: Socket already reset before connect completed", type: this.logType)
            }

            handler?()
        }
    }

    /// Returns the CONNECT payload to send to the server, merging `pid`/`offset` into
    /// a fresh dict if recovery state is present. The user's `connectPayload` wins on
    /// key collisions (matches JS `Object.assign({pid, offset}, data)`).
    /// Returns `connectPayload` unchanged on v2 or when no pid is stored.
    func currentConnectPayload() -> [String: Any]? {
        guard manager?.version == .three else { return connectPayload }
        guard let pid = _pid else { return connectPayload }
        var out: [String: Any] = ["pid": pid]
        if let offset = _lastOffset { out["offset"] = offset }
        if let user = connectPayload {
            if user["pid"] != nil || user["offset"] != nil {
                DefaultSocketLogger.Logger.log(
                    "connectPayload contains reserved key 'pid' or 'offset'; user value takes precedence",
                    type: logType
                )
            }
            for (k, v) in user { out[k] = v }
        }
        return out
    }

    /// Clears the in-memory state used for Connection State Recovery: `_pid`,
    /// `_lastOffset`, `recovered`, and any buffered replay packets from a prior
    /// session that have not yet been flushed by `didConnect()`. Also fails any
    /// outstanding Phase 9 timed-ack callbacks with `SocketAckError.disconnected`.
    ///
    /// Call this when the authenticated identity on this socket changes, to
    /// prevent a subsequent reconnect from resuming the prior session's stream.
    ///
    /// **Scope of protection.** This clears *in-memory* state only. It does NOT
    /// fence packets that have already been dispatched to app handlers, nor
    /// packets that the server will deliver for the still-live transport after
    /// this call returns but before the next CONNECT ack. For a clean identity
    /// boundary, callers should also `disconnect()` and reconnect (or create a
    /// fresh socket) rather than relying on `clearRecoveryState()` alone.
    ///
    /// **Timed-ack side effect (Swift-only, no JS counterpart).** Outstanding
    /// `timeout(after:).emit(...)` callbacks are fired with
    /// `SocketAckError.disconnected`. The user's intent on `clearRecoveryState()`
    /// — drop session-bound state — is operationally equivalent to disconnect
    /// for any callback waiting on a session-specific ack id: the id allocator
    /// is per-socket and a successor session would never deliver an ack for an
    /// id issued by the prior session. Dispatched on `handleQueue` so the clear
    /// runs serialized with add/execute/cancel (the entry's `fired` flag is
    /// queue-protected, not lock-protected).
    ///
    /// Subclass ordering: if a subclass overrides `disconnect()` and wants to
    /// auto-clear, call `clearRecoveryState()` BEFORE `super.disconnect()`. The
    /// `.disconnect` client event fires synchronously from super, and any observer
    /// that reconnects would otherwise send stale pid/offset.
    open func clearRecoveryState() {
        _pid = nil
        _lastOffset = nil
        recovered = false
        clearBufferedRecoveryReplayEvents()

        // Phase 9: fail any in-flight timed acks with .disconnected. See
        // `didDisconnect` for the matching post-disconnect drain; this call
        // mirrors that behavior for the identity-swap path so a session-bound
        // ack id issued before the swap cannot dangle waiting on a successor
        // session that would never reuse it.
        manager?.handleQueue.async { [weak self] in
            self?.ackHandlers.clearTimedAcks(reason: .disconnected)
        }
    }

    /// Records the last arg as `_lastOffset` if this is a v3 socket with a known pid
    /// and the last arg is a String not exceeding the byte cap.
    private func captureOffsetIfNeeded(from args: [Any]) {
        guard manager?.version == .three, _pid != nil else { return }
        guard let last = args.last as? String else { return }
        guard last.utf8.count <= SocketIOClient.socketStateRecoveryMaxOffsetBytes else {
            DefaultSocketLogger.Logger.log(
                "Dropping oversized offset string (\(last.utf8.count) bytes > \(SocketIOClient.socketStateRecoveryMaxOffsetBytes))",
                type: logType
            )
            return
        }
        _lastOffset = last
    }

    /// Recovery replay packets may arrive before the reconnect CONNECT ack. In that
    /// window the client is still `.connecting`, but v3 reconnect state is already
    /// present via `_pid` from the previous session.
    private var canProcessRecoveryReplayEvents: Bool {
        guard manager?.version == .three, _pid != nil else { return false }
        return status == .connecting
    }

    private func dispatchEvent(_ event: String, data: [Any], withAck ack: Int) {
        DefaultSocketLogger.Logger.log("Handling event: \(event) with data: \(data)", type: logType)

        anyHandler?(SocketAnyEvent(event: event, items: data))

        // Snapshot the list so a listener's self-removal during dispatch doesn't
        // mutate the iteration. Snapshot is cheap (array of tuples).
        let snapshot = anyListeners
        for entry in snapshot {
            entry.handler(SocketAnyEvent(event: event, items: data))
        }

        for handler in handlers where handler.event == event {
            handler.executeCallback(with: data, withAck: ack, withSocket: self)
        }
    }

    private func bufferRecoveryReplayEvent(_ packet: SocketPacket) {
        bufferedRecoveryReplayEvents.append((event: packet.event, data: packet.args, ack: packet.id))
    }

    private func flushBufferedRecoveryReplayEvents() {
        guard !bufferedRecoveryReplayEvents.isEmpty else { return }

        let bufferedEvents = bufferedRecoveryReplayEvents
        bufferedRecoveryReplayEvents.removeAll(keepingCapacity: false)

        for event in bufferedEvents {
            guard status == .connected else { break }
            handleEvent(event.event, data: event.data, isInternalMessage: false, withAck: event.ack)
            captureOffsetIfNeeded(from: event.data)
        }
    }

    private func clearBufferedRecoveryReplayEvents() {
        bufferedRecoveryReplayEvents.removeAll(keepingCapacity: false)
    }

    func createOnAck(_ items: [Any], binary: Bool = true) -> OnAckCallback {
        currentAck += 1

        return OnAckCallback(ackNumber: currentAck, items: items, socket: self)
    }

    /// Called when the client connects to a namespace. If the client was created with a namespace upfront,
    /// then this is only called when the client connects to that namespace.
    ///
    /// - parameter toNamespace: The namespace that was connected to.
    open func didConnect(toNamespace namespace: String, payload: [String: Any]?) {
        guard status != .connected else { return }

        DefaultSocketLogger.Logger.log("Socket connected", type: logType)
        sid = payload?["sid"] as? String

        let isV3 = manager?.version == .three
        if isV3 {
            let incomingPid = payload?["pid"] as? String
            recovered = (incomingPid != nil && _pid != nil && _pid == incomingPid)
            _pid = incomingPid
        }

        let connectData: [Any]
        if isV3 {
            if var payload = payload {
                payload["recovered"] = recovered
                connectData = [namespace, payload]
            } else {
                connectData = [namespace, ["recovered": recovered]]
            }
        } else {
            connectData = payload == nil ? [namespace] : [namespace, payload!]
        }

        status = .connected
        flushBufferedRecoveryReplayEvents()
        guard status == .connected else { return }
        handleClientEvent(.connect, data: connectData)
    }

    /// Called when the client has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        guard status != .disconnected else { return }

        DefaultSocketLogger.Logger.log("Disconnected: \(reason)", type: logType)

        clearBufferedRecoveryReplayEvents()
        status = .disconnected
        sid = ""

        handleClientEvent(.disconnect, data: [reason])

        // Phase 9: fail any in-flight timed acks with .disconnected. Dispatched
        // to handleQueue so the clear runs serialized with add/execute/cancel
        // (the entry's `fired` flag is queue-protected, not lock-protected).
        // Placed after handleClientEvent so the .disconnect notification fires
        // before user ack callbacks observe the disconnected reason — matches
        // the JS sequence where the socket emits 'disconnect' before draining
        // ack callbacks.
        manager?.handleQueue.async { [weak self] in
            self?.ackHandlers.clearTimedAcks(reason: .disconnected)
        }
    }

    /// Clears a failed in-flight connect attempt without sending namespace leave packets.
    func abortPendingConnect() {
        guard status == .connecting else { return }

        clearBufferedRecoveryReplayEvents()
        status = .notConnected
    }

    /// Disconnects the socket.
    ///
    /// This will cause the socket to leave the namespace it is associated to, as well as remove itself from the
    /// `manager`.
    open func disconnect() {
        self.active = false
        DefaultSocketLogger.Logger.log("Closing socket", type: logType)

        leaveNamespace()
    }

    /// Send an event to the server, with optional data items and optional write completion handler.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    open func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil)  {
        emit(event, with: items, completion: completion)
    }
    
    /// Send an event to the server, with optional data items and optional write completion handler.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    open func emit(_ event: String, with items: [SocketData], completion: (() -> ())?) {
        
        do {
            emit([event] + (try items.map({ try $0.socketRepresentation() })), completion: completion)
        } catch {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, error])
        }
    }

    /// Sends a message to the server, requesting an ack.
    ///
    /// **NOTE**: It is up to the server send an ack back, just calling this method does not mean the server will ack.
    /// Check that your server's api will ack the event being sent.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// Example:
    ///
    /// ```swift
    /// socket.emitWithAck("myEvent", 1).timingOut(after: 1) {data in
    ///     ...
    /// }
    /// ```
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - returns: An `OnAckCallback`. You must call the `timingOut(after:)` method before the event will be sent.
    open func emitWithAck(_ event: String, _ items: SocketData...) -> OnAckCallback {
        emitWithAck(event, with: items)
    }
    
    /// Sends a message to the server, requesting an ack.
    ///
    /// **NOTE**: It is up to the server send an ack back, just calling this method does not mean the server will ack.
    /// Check that your server's api will ack the event being sent.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// Example:
    ///
    /// ```swift
    /// socket.emitWithAck("myEvent", 1).timingOut(after: 1) {data in
    ///     ...
    /// }
    /// ```
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - returns: An `OnAckCallback`. You must call the `timingOut(after:)` method before the event will be sent.
    open func emitWithAck(_ event: String, with items: [SocketData]) -> OnAckCallback {

        do {
            return createOnAck([event] + (try items.map({ try $0.socketRepresentation() })))
        } catch {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, error])

            return OnAckCallback(ackNumber: -1, items: [], socket: self)
        }
    }

    /// JS-aligned `socket.send(...)` — sugar for `emit("message", ...)`.
    /// Server-side receives via `socket.on("message", ...)`.
    ///
    /// - parameter items: The items to send with the `"message"` event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    open func send(_ items: SocketData..., completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    /// Array form of `send`.
    ///
    /// - parameter items: The items to send with the `"message"` event.
    /// - parameter completion: Callback called on transport write completion.
    open func send(with items: [SocketData], completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    /// JS-aligned `socket.send(...)` returning an ack callback. Sugar for
    /// `emitWithAck("message", ...)`.
    ///
    /// **NOTE**: The returned `OnAckCallback.timingOut(after:)` chain still uses
    /// the magic-string `SocketAckStatus.noAck` for timeouts and is not cleared
    /// on disconnect (see Phase 9 spec section). Users wanting typed errors and
    /// disconnect-clearing should use Phase 9's
    /// `socket.timeout(after:).emit("message", ack:)` instead (when available).
    ///
    /// - parameter items: The items to send with the `"message"` event. May be left out.
    /// - returns: An `OnAckCallback`. You must call `timingOut(after:)` before the event will be sent.
    open func sendWithAck(_ items: SocketData...) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }

    /// Array form of `sendWithAck`.
    ///
    /// - parameter items: The items to send with the `"message"` event.
    /// - returns: An `OnAckCallback`. You must call `timingOut(after:)` before the event will be sent.
    open func sendWithAck(with items: [SocketData]) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }

    /// Volatile-emit chain. Packets are dropped if the engine transport is not
    /// writable (no `.error`, no outgoing listener, no buffer). See
    /// `SocketVolatileEmitter` for full semantics.
    public var volatile: SocketVolatileEmitter {
        return SocketVolatileEmitter(socket: self)
    }

    /// Internal entry — routes through the funnel with `volatile: true`. Marked
    /// `internal` so users go through the chain.
    internal func emitVolatile(_ data: [Any], completion: (() -> ())? = nil) {
        emit(data, ack: nil, binary: true, isAck: false, volatile: true, completion: completion)
    }

    func emit(_ data: [Any],
              ack: Int? = nil,
              binary: Bool = true,
              isAck: Bool = false,
              volatile: Bool = false,
              completion: (() -> ())? = nil
    ) {
        // wrap the completion handler so it always runs async via handlerQueue
        let wrappedCompletion: (() -> ())? = (completion == nil) ? nil : {[weak self] in
            guard let this = self else { return }
            this.manager?.handleQueue.async {
                completion!()
            }
        }

        // Reserved-event guard — fires BEFORE the connected-state check, matching JS
        // where `emit()` throws regardless of connection state. isAck=true frames
        // (ack response packets) bypass the guard because their first item is the
        // ack id, not an event name.
        if !isAck, failIfReserved(data) {
            wrappedCompletion?()
            return
        }

        // Phase 7: volatile gate — JS-aligned per `socket.io-client/lib/socket.ts`
        // `emit()` body which sets `discardPacket = volatile && !transport.writable`.
        // Drop is silent: no .error, no outgoing listener fire, no buffering.
        if volatile, !(manager?.engine?.writable ?? false) {
            DefaultSocketLogger.Logger.log(
                "volatile packet dropped (transport not writable)",
                type: logType
            )
            wrappedCompletion?()
            return
        }

        guard status == .connected else {
            wrappedCompletion?()
            handleClientEvent(.error, data: ["Tried emitting when not connected"])
            return
        }

        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: isAck, checkForBinary: binary)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting: \(str), Ack: \(isAck)", type: logType)

        // Fire any-outgoing listeners — JS-aligned per `socket.io-client/lib/socket.ts`
        // `emit()` body (~`:443-454`): fires AFTER connected guard, ONLY on actual send.
        // Ack response frames bypass: their first item is the ack id, not an event name.
        if !isAck, let event = data.first as? String {
            let snapshot = anyOutgoingListeners
            let items = Array(data.dropFirst())
            for entry in snapshot {
                entry.handler(SocketAnyEvent(event: event, items: items))
            }
        }

        manager?.engine?.send(str, withData: packet.binary, completion: wrappedCompletion)
    }

    /// Returns `true` if the first element of `data` is a reserved event name.
    /// On hit: assertionFailure (DEBUG, non-XCTest) + handleClientEvent(.error)
    /// for user-visible signal. Wire behavior matches JS `emit()` throw —
    /// caller must early-return so no packet is written.
    private func failIfReserved(_ data: [Any]) -> Bool {
        guard let event = data.first as? String,
              SocketReservedEvent.names.contains(event) else {
            return false
        }
        let message = "\"\(event)\" is a reserved event name"
        #if DEBUG
        if NSClassFromString("XCTest") == nil {
            assertionFailure(message)
        }
        #endif
        handleClientEvent(.error, data: [message])
        return true
    }

    /// Call when you wish to tell the server that you've received the event for `ack`.
    ///
    /// **You shouldn't need to call this directly.** Instead use an `SocketAckEmitter` that comes in an event callback.
    ///
    /// - parameter ack: The ack number.
    /// - parameter with: The data for this ack.
    open func emitAck(_ ack: Int, with items: [Any]) {
        emit(items, ack: ack, binary: true, isAck: true)
    }

    /// Called when socket.io has acked one of our emits. Causes the corresponding ack callback to be called.
    ///
    /// - parameter ack: The number for this ack.
    /// - parameter data: The data sent back with this ack.
    open func handleAck(_ ack: Int, data: [Any]) {
        guard status == .connected else { return }

        DefaultSocketLogger.Logger.log("Handling ack: \(ack) with data: \(data)", type: logType)

        // Phase 9: try the timed-ack path first; both are no-ops on a missing
        // id, so the double-call is safe. Ack ids are unique across both stores
        // because both legacy emitWithAck and timed emit use the same
        // `currentAck += 1` allocator.
        ackHandlers.executeTimedAck(ack, with: data)
        ackHandlers.executeAck(ack, with: data)
    }

    /// Called on socket.io specific events.
    ///
    /// - parameter event: The `SocketClientEvent`.
    /// - parameter data: The data for this event.
    open func handleClientEvent(_ event: SocketClientEvent, data: [Any]) {
        handleEvent(event.rawValue, data: data, isInternalMessage: true)
    }

    /// Called when we get an event from socket.io.
    ///
    /// - parameter event: The name of the event.
    /// - parameter data: The data that was sent with this event.
    /// - parameter isInternalMessage: Whether this event was sent internally. If `true` it is always sent to handlers.
    /// - parameter ack: If > 0 then this event expects to get an ack back from the client.
    open func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int = -1) {
        guard status == .connected || isInternalMessage else { return }
        dispatchEvent(event, data: data, withAck: ack)
    }

    /// Causes a client to handle a socket.io packet. The namespace for the packet must match the namespace of the
    /// socket.
    ///
    /// - parameter packet: The packet to handle.
    open func handlePacket(_ packet: SocketPacket) {
        guard packet.nsp == nsp else { return }

        switch packet.type {
        case .event, .binaryEvent:
            if canProcessRecoveryReplayEvents {
                bufferRecoveryReplayEvent(packet)
            } else {
                guard status == .connected else { return }
                handleEvent(packet.event, data: packet.args, isInternalMessage: false, withAck: packet.id)
                captureOffsetIfNeeded(from: packet.args)
            }
        case .ack, .binaryAck:
            handleAck(packet.id, data: packet.data)
        case .connect:
            didConnect(toNamespace: nsp, payload: packet.data.isEmpty ? nil : packet.data[0] as? [String: Any])
        case .disconnect:
            // JS-aligned: server-initiated DISCONNECT calls `destroy()` which
            // clears `subs` (and therefore `active`) before emitting the
            // disconnect event — see `socket.io-client/lib/socket.ts`
            // `onserverdisconnect` ("io server disconnect").
            active = false
            didDisconnect(reason: "Got Disconnect")
        case .error:
            // JS-aligned: receipt of CONNECT_ERROR calls `destroy()` before
            // emitting `connect_error`. The server has refused the namespace
            // connect; the manager will not auto-rejoin without explicit
            // `socket.connect()`, so `active` must reflect that.
            active = false
            handleEvent("error", data: packet.data, isInternalMessage: true, withAck: packet.id)
        }
    }

    /// Call when you wish to leave a namespace and disconnect this socket.
    open func leaveNamespace() {
        manager?.disconnectSocket(self)
    }

    /// Joins `nsp`. You shouldn't need to call this directly, instead call `connect`.
    ///
    /// - parameter withPayload: An optional payload sent on connect
    open func joinNamespace(withPayload payload: [String: Any]? = nil) {
        DefaultSocketLogger.Logger.log("Joining namespace \(nsp)", type: logType)

        connectPayload = payload

        manager?.connectSocket(self, withPayload: connectPayload)
    }

    /// Removes handler(s) for a client event.
    ///
    /// If you wish to remove a client event handler, call the `off(id:)` with the UUID received from its `on` call.
    ///
    /// - parameter clientEvent: The event to remove handlers for.
    open func off(clientEvent event: SocketClientEvent) {
        off(event.rawValue)
    }

    /// Removes handler(s) based on an event name.
    ///
    /// If you wish to remove a specific event, call the `off(id:)` with the UUID received from its `on` call.
    ///
    /// - parameter event: The event to remove handlers for.
    open func off(_ event: String) {
        DefaultSocketLogger.Logger.log("Removing handler for event: \(event)", type: logType)

        handlers = handlers.filter({ $0.event != event })
    }

    /// Removes a handler with the specified UUID gotten from an `on` or `once`
    ///
    /// If you want to remove all events for an event, call the off `off(_:)` method with the event name.
    ///
    /// - parameter id: The UUID of the handler you wish to remove.
    open func off(id: UUID) {
        DefaultSocketLogger.Logger.log("Removing handler with id: \(id)", type: logType)

        handlers = handlers.filter({ $0.id != id })
    }

    /// Adds a handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @discardableResult
    open func on(_ event: String, callback: @escaping NormalCallback) -> UUID {
        DefaultSocketLogger.Logger.log("Adding handler for event: \(event)", type: logType)

        let handler = SocketEventHandler(event: event, id: UUID(), callback: callback)
        handlers.append(handler)

        return handler.id
    }

    /// Adds a handler for a client event.
    ///
    /// Example:
    ///
    /// ```swift
    /// socket.on(clientEvent: .connect) {data, ack in
    ///     ...
    /// }
    /// ```
    ///
    /// - parameter event: The event for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @discardableResult
    open func on(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID {
        return on(event.rawValue, callback: callback)
    }

    /// Adds a single-use handler for a client event.
    ///
    /// - parameter clientEvent: The event for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @discardableResult
    open func once(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID {
        return once(event.rawValue, callback: callback)
    }

    /// Adds a single-use handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @discardableResult
    open func once(_ event: String, callback: @escaping NormalCallback) -> UUID {
        DefaultSocketLogger.Logger.log("Adding once handler for event: \(event)", type: logType)

        let id = UUID()

        let handler = SocketEventHandler(event: event, id: id) {[weak self] data, ack in
            guard let this = self else { return }
            this.off(id: id)
            callback(data, ack)
        }

        handlers.append(handler)

        return handler.id
    }

    /// Adds a handler that will be called on every event.
    ///
    /// - parameter handler: The callback that will execute whenever an event is received.
    open func onAny(_ handler: @escaping (SocketAnyEvent) -> ()) {
        anyHandler = handler
    }

    /// Append a catch-all listener. Returns a `UUID` handle for removal.
    /// Mirrors JS `socket.onAny(handler)`. Mutator serializes via `handleQueue.async`.
    @discardableResult
    open func addAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.append((id: id, handler: handler))
        }
        return id
    }

    /// Prepend a catch-all listener (fires before existing listeners). Returns
    /// a `UUID` handle. Mirrors JS `socket.prependAny(handler)`. Mutator
    /// serializes via `handleQueue.async`.
    @discardableResult
    open func prependAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.insert((id: id, handler: handler), at: 0)
        }
        return id
    }

    /// Remove a listener by its `UUID` handle. Unknown id is a silent no-op
    /// (matches JS `offAny`). Mutator serializes via `handleQueue.async`.
    open func removeAnyListener(id: UUID) {
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.removeAll { $0.id == id }
        }
    }

    /// Remove every listener registered via `addAnyListener` / `prependAnyListener`.
    /// Does NOT clear the legacy single `anyHandler`. Mutator serializes via
    /// `handleQueue.async`.
    open func removeAllAnyListeners() {
        manager?.handleQueue.async { [weak self] in
            self?.anyListeners.removeAll(keepingCapacity: false)
        }
    }

    /// Count of currently-registered any-listeners. Excludes the legacy single
    /// `anyHandler`. JS counterpart `socket.listenersAny()` returns the handler
    /// array; Swift returns count because closures lack identity.
    public var anyListenerCount: Int {
        return anyListeners.count
    }

    /// Append an outgoing-side catch-all listener. Fires after the
    /// `status == .connected` guard, immediately before `engine.send`.
    /// Mirrors JS `socket.onAnyOutgoing(handler)`.
    @discardableResult
    open func addAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.append((id: id, handler: handler))
        }
        return id
    }

    /// Prepend an outgoing-side catch-all listener.
    @discardableResult
    open func prependAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.insert((id: id, handler: handler), at: 0)
        }
        return id
    }

    /// Remove an outgoing-side listener by its `UUID`. Unknown id is a silent no-op.
    open func removeAnyOutgoingListener(id: UUID) {
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.removeAll { $0.id == id }
        }
    }

    /// Remove every registered outgoing-side listener.
    open func removeAllAnyOutgoingListeners() {
        manager?.handleQueue.async { [weak self] in
            self?.anyOutgoingListeners.removeAll(keepingCapacity: false)
        }
    }

    /// Count of currently-registered any-outgoing-listeners. JS counterpart
    /// `socket.listenersAnyOutgoing()` returns the handler array; Swift returns count.
    public var anyOutgoingListenerCount: Int {
        return anyOutgoingListeners.count
    }

    /// Tries to reconnect to the server.
    @available(*, unavailable, message: "Call the manager's reconnect method")
    open func reconnect() { }

    /// Removes all handlers.
    ///
    /// Can be used after disconnecting to break any potential remaining retain cycles.
    open func removeAllHandlers() {
        handlers.removeAll(keepingCapacity: false)
    }

    /// Puts the socket back into the connecting state.
    /// Called when the manager detects a broken connection, or when a manual reconnect is triggered.
    ///
    /// - parameter reason: The reason this socket is reconnecting.
    open func setReconnecting(reason: String) {
        status = .connecting

        handleClientEvent(.reconnect, data: [reason])
    }

    // Test properties

    var testHandlers: [SocketEventHandler] {
        return handlers
    }

    func setTestable() {
        status = .connected
    }

    func setTestStatus(_ status: SocketIOStatus) {
        self.status = status
    }

    func setTestRecovered(_ value: Bool) {
        recovered = value
    }

    func emitTest(event: String, _ data: Any...) {
        emit([event] + data)
    }
}

// MARK: - Auth provider

public extension SocketIOClient {
    /// Install a callback-form auth provider. Invoked on `handleQueue` for every
    /// CONNECT (initial + every reconnect). JS-aligned: multi-callback sends
    /// multiple CONNECT packets (mirrors `socket.io-client/lib/socket.ts`
    /// `onopen()` calling `this.auth(cb)` without dedup).
    func setAuth(_ provider: @escaping SocketAuthProvider) {
        manager?.handleQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAuthTask?()
            self.pendingAuthTask = nil
            self.authProvider = provider
            self.authGeneration &+= 1
            // Install-time warning so v2 misconfiguration is visible immediately
            // rather than only on the first CONNECT attempt.
            if let manager = self.manager, manager.version.rawValue < 3 {
                DefaultSocketLogger.Logger.error(
                    "setAuth has no effect on v2 (.connect protocol) managers; install on a .version(.three) manager",
                    type: self.logType
                )
            }
        }
    }

    /// Remove the installed provider; cancels any in-flight async `Task`.
    func clearAuth() {
        manager?.handleQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAuthTask?()
            self.pendingAuthTask = nil
            self.authProvider = nil
            self.authGeneration &+= 1
        }
    }
}

/// Internal `@unchecked Sendable` box used to ferry the non-Sendable
/// `SocketIOClient` reference through the `@Sendable` `Task { }` boundary
/// in `setAuth(_:)`'s async overload. Safe because the boxed reference is
/// only dereferenced on `handleQueue` after an `async` hop.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
private struct WeakClientBox: @unchecked Sendable {
    weak var ref: SocketIOClient?
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension SocketIOClient {
    /// Async/throws variant of `setAuth(_:)`. The async closure is invoked on
    /// every CONNECT (initial + reconnect) and its return value is used as the
    /// CONNECT payload. If the closure throws, a `.error` client event fires
    /// with the localized error description and the CONNECT packet is NOT sent
    /// (fail-closed). Pure Swift addition — JS callback-form has no
    /// thrown-error analog.
    func setAuth(_ provider: @escaping () async throws -> [String: Any]?) {
        let wrapped: SocketAuthProvider = { [weak self] cb in
            guard let self = self else { cb(nil); return }
            // Caller is on `handleQueue` (resolveConnectPayload contract). Snapshot
            // the generation now so a late async result can be discarded if the
            // socket has reconnected / re-auth'd in the meantime.
            let generation = self.authGeneration
            let box = WeakClientBox(ref: self)
            let task = Task {
                do {
                    let payload = try await provider()
                    guard let client = box.ref else { return }
                    client.manager?.handleQueue.async {
                        guard let client = box.ref else { return }
                        guard client.authGeneration == generation,
                              client.status == .connecting else {
                            DefaultSocketLogger.Logger.log(
                                "auth result discarded; generation mismatch or socket no longer .connecting",
                                type: "SocketIOClient{\(client.nsp)}"
                            )
                            return
                        }
                        cb(payload)
                    }
                } catch {
                    guard let client = box.ref else { return }
                    client.manager?.handleQueue.async {
                        guard let client = box.ref else { return }
                        guard client.authGeneration == generation else { return }
                        client.handleClientEvent(.error, data: [
                            "auth provider failed: \(error.localizedDescription)"
                        ])
                    }
                }
            }
            self.pendingAuthTask = { task.cancel() }
        }
        setAuth(wrapped)
    }
}

// MARK: - Auth provider resolution

extension SocketIOClient {
    /// Invokes the installed provider (callback or async-wrapped) and forwards
    /// the result to `completion` on `handleQueue`. If no provider is installed,
    /// invokes `completion` with `explicit` synchronously. Caller MUST be on
    /// `handleQueue`.
    ///
    /// On v2 managers with a provider installed: fires `.error` per CONNECT
    /// attempt and falls back to `nil` payload (the provider is never invoked
    /// on v2). This makes the silent v2 bypass observable to the caller.
    func resolveConnectPayload(explicit: [String: Any]?,
                               completion: @escaping ([String: Any]?) -> Void) {
        guard let provider = authProvider else {
            completion(explicit)
            return
        }

        // v2 manager: the v2 connectSocket path drops payloads, so a provider
        // would be silently bypassed. Make this observable.
        if (manager?.version.rawValue ?? 0) < 3 {
            DefaultSocketLogger.Logger.error(
                "setAuth provider installed on v2 manager — auth bypassed for this CONNECT",
                type: logType
            )
            handleClientEvent(.error, data: [
                "setAuth provider installed on v2 manager — auth bypassed for this CONNECT"
            ])
            completion(nil)
            return
        }

        provider { [weak self] resolved in
            guard let self = self else { return }
            // Always async-hop back. NEVER sync — callers like _engineDidOpen
            // are already on `handleQueue` and a sync re-entry would deadlock
            // on `handleQueue.sync` (and at minimum re-enter the dispatch chain
            // mid-iteration).
            self.manager?.handleQueue.async {
                completion(resolved ?? explicit)
            }
        }
    }
}

// MARK: Phase 9 — timed-emit per-emit ack with typed SocketAckError

public extension SocketIOClient {
    /// Returns a chainable `SocketTimedEmitter` that emits with a typed-error
    /// per-emit ack. Mirrors `socket.timeout(ms).emit(ev, ..., (err, data) =>)`
    /// from the JS client.
    ///
    /// Pass `.infinity` to disable the timeout (the ack will still fail with
    /// `.disconnected` if the socket disconnects before the server acks).
    /// Pass a non-positive value to fire `.timeout` on the next handle-queue
    /// tick (matches `setTimeout(fn, <=0)` JS behavior).
    ///
    /// - parameter seconds: Maximum seconds to wait for the server ack.
    func timeout(after seconds: Double) -> SocketTimedEmitter {
        return SocketTimedEmitter(socket: self, timeout: seconds)
    }
}

extension SocketIOClient {
    /// Internal — called from `SocketTimedEmitter`. Allocates an ack id (when
    /// not pre-allocated by the async overload), registers the timed ack BEFORE
    /// running the emit funnel, then routes through the funnel.
    ///
    /// Registration-before-funnel ordering is critical: if the funnel's
    /// connected guard fires `.error` and early-returns, the timer is already
    /// scheduled and will fire `cb(.timeout, [])` after `timeout` seconds —
    /// matching JS `_registerAckCallback` semantics.
    func emitTimed(event: String,
                   items: [SocketData],
                   timeout: Double,
                   ackId: Int? = nil,
                   ack: @escaping (Error?, [Any]) -> Void) {
        guard let manager = self.manager else {
            // No manager → no handleQueue, no transport. Fire .disconnected
            // synchronously so the caller gets a deterministic outcome instead
            // of a silently-dropped emit.
            ack(SocketAckError.disconnected, [])
            return
        }
        let queue = manager.handleQueue
        queue.async { [weak self] in
            guard let self = self else { return }
            let id = ackId ?? self.allocateAckId()
            self.ackHandlers.addTimedAck(id, on: queue, callback: ack, timeout: timeout)
            do {
                let mapped = [event] + (try items.map { try $0.socketRepresentation() })
                self.emit(mapped, ack: id, binary: true, isAck: false)
            } catch {
                // Representation failure → cancel the timer and fire the error
                // through the same one-shot path so the user gets exactly one
                // callback and we surface the underlying error.
                self.ackHandlers.cancelTimedAck(id, fireWith: error)
            }
        }
    }

    /// Internal — allocate the next ack id (matches existing `currentAck += 1`
    /// pattern from `createOnAck`). Called from the async emit overload before
    /// entering the cancellation handler so the cancel path can reference the
    /// same id.
    func allocateAckId() -> Int {
        currentAck += 1
        return currentAck
    }
}
