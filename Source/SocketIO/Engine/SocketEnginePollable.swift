//
//  SocketEnginePollable.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/15/16.
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

/// Protocol that is used to implement socket.io polling support
public protocol SocketEnginePollable: SocketEngineSpec {
    // MARK: Properties

    /// `true` If engine's session has been invalidated.
    var invalidated: Bool { get }

    /// A queue of engine.io messages waiting for POSTing
    ///
    /// **You should not touch this directly**
    var postWait: [Post] { get set }

    /// The largest polling response body, in bytes, that the engine accepts. `nil` means no limit.
    var maximumPollingResponseBytes: Int? { get }

    /// The URLSession that will be used for polling.
    var session: URLSession? { get }

    /// `true` if there is an outstanding poll. Trying to poll before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    var waitingForPoll: Bool { get set }

    /// `true` if there is an outstanding post. Trying to post before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    var waitingForPost: Bool { get set }

    // MARK: Methods

    /// Call to send a long-polling request.
    ///
    /// You shouldn't need to call this directly, the engine should automatically maintain a long-poll request.
    func doPoll()

    /// Sends an engine.io message through the polling transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    func sendPollMessage(_ message: String, withType type: SocketEnginePacketType, withData datas: [Data], completion: (() -> ())?)

    /// Call to stop polling and invalidate the URLSession.
    func stopPolling()
}

// Default polling methods
extension SocketEnginePollable {
    /// Engines that do not set a limit accept a response of any size.
    public var maximumPollingResponseBytes: Int? { return nil }

    func createRequestForPostWithPostWait() -> URLRequest {
        defer {
            for packet in postWait { packet.completion?() }
            postWait.removeAll(keepingCapacity: true)
        }

        var postStr = ""

        if version.rawValue >= 3 {
            postStr = postWait.lazy.map({ $0.msg }).joined(separator: "\u{1e}")
        } else {
            for packet in postWait {
                postStr += "\(packet.msg.utf16.count):\(packet.msg)"
            }
        }

        // Only a Socket.IO 3+ CONNECT packet has a payload to hide.
        DefaultSocketLogger.Logger.log(
            "Created POST string: \(version.rawValue >= 3 ? postWait.map({ SocketLogRedaction.enginePacket($0.msg) }).joined(separator: "\u{1e}") : postStr)",
            type: "SocketEnginePolling"
        )

        var req = URLRequest(url: urlPollingWithSid)
        let postData = postStr.data(using: .utf8, allowLossyConversion: false)!

        addHeaders(to: &req)

        req.httpMethod = "POST"
        req.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = postData
        req.setValue(String(postData.count), forHTTPHeaderField: "Content-Length")

        return req
    }

    /// Call to send a long-polling request.
    ///
    /// You shouldn't need to call this directly, the engine should automatically maintain a long-poll request.
    public func doPoll() {
        guard polling && !waitingForPoll && connected && !closed else { return }

        var req = URLRequest(url: urlPollingWithSid)
        addHeaders(to: &req)

        doLongPoll(for: req)
    }

    func doRequest(for req: URLRequest, callbackWith callback: @escaping (Data?, URLResponse?, Error?) -> ()) {
        guard polling && !closed && !invalidated && !fastUpgrade else { return }

        DefaultSocketLogger.Logger.log("Doing polling \(req.httpMethod ?? "") \(SocketLogRedaction.url(req.url))",
                                       type: "SocketEnginePolling")

        guard let limit = maximumPollingResponseBytes else {
            session?.dataTask(with: req, completionHandler: callback).resume()

            return
        }

        // A task with a completion handler keeps the whole body in memory until it ends, so a body that is too
        // large has to be stopped while it is still arriving.
        var task: URLSessionDataTask?
        var observation: NSKeyValueObservation?

        task = session?.dataTask(with: req) {data, res, err in
            observation?.invalidate()

            // The size of the delivered body is checked as well: the task counts decompressed bytes on current
            // systems, but that is not a documented guarantee.
            if (task?.countOfBytesReceived ?? 0) > Int64(limit) || (data?.count ?? 0) > limit {
                callback(nil, res, EngineError.pollingResponseTooLarge(limit: limit))
            } else {
                callback(data, res, err)
            }

            task = nil
        }
        observation = task?.observe(\.countOfBytesReceived) {task, _ in
            if task.countOfBytesReceived > Int64(limit) {
                task.cancel()
            }
        }
        task?.resume()
    }

    func doLongPoll(for req: URLRequest) {
        waitingForPoll = true

        doRequest(for: req) {[weak self] data, res, err in
            guard let this = self, this.polling else { return }
            guard let data = data, let res = res as? HTTPURLResponse, res.statusCode == 200 else {
                if let err = err {
                    DefaultSocketLogger.Logger.error(err.localizedDescription, type: "SocketEnginePolling")
                } else {
                    DefaultSocketLogger.Logger.error("Error during long poll request", type: "SocketEnginePolling")
                }

                if this.polling {
                    this.didError(reason: err?.localizedDescription ?? "Error")
                }

                return
            }

            DefaultSocketLogger.Logger.log("Got polling response", type: "SocketEnginePolling")

            if let str = String(data: data, encoding: .utf8) {
                this.parsePollingMessage(str)
            }

            this.waitingForPoll = false

            if this.fastUpgrade {
                this.doFastUpgrade()
            } else if !this.closed && this.polling {
                this.doPoll()
            }
        }
    }

    private func flushWaitingForPost() {
        guard postWait.count != 0 && connected else { return }
        guard polling else {
            flushWaitingForPostToWebSocket()

            return
        }

        let req = createRequestForPostWithPostWait()

        waitingForPost = true

        DefaultSocketLogger.Logger.log("POSTing", type: "SocketEnginePolling")

        doRequest(for: req) {[weak self] _, res, err in
            guard let this = self else { return }
            guard let res = res as? HTTPURLResponse, res.statusCode == 200 else {
                if let err = err {
                    DefaultSocketLogger.Logger.error(err.localizedDescription, type: "SocketEnginePolling")
                } else {
                    DefaultSocketLogger.Logger.error("Error flushing waiting posts", type: "SocketEnginePolling")
                }

                if this.polling {
                    this.didError(reason: err?.localizedDescription ?? "Error")
                }

                return
            }

            this.waitingForPost = false

            if !this.fastUpgrade {
                this.flushWaitingForPost()
                this.doPoll()
            }
        }
    }

    func parsePollingMessage(_ str: String) {
        guard !str.isEmpty else { return }

        // Only a Socket.IO 3+ CONNECT packet has a payload to hide.
        DefaultSocketLogger.Logger.log(
            "Got poll message: \(version.rawValue >= 3 ? str.components(separatedBy: "\u{1e}").map(SocketLogRedaction.enginePacket).joined(separator: "\u{1e}") : str)",
            type: "SocketEnginePolling"
        )

        if version.rawValue >= 3 {
            let records = str.components(separatedBy: "\u{1e}")

            for record in records {
                parseEngineMessage(record)
            }
        } else {
            guard str.count != 1 else {
                parseEngineMessage(str)

                return
            }

            var reader = SocketStringReader(message: str)

            while reader.hasNext {
                if let n = Int(reader.readUntilOccurence(of: ":")) {
                    parseEngineMessage(reader.read(count: n))
                } else {
                    parseEngineMessage(str)
                    break
                }
            }
        }
    }

    /// Sends an engine.io message through the polling transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    /// - parameter completion: Callback called on transport write completion.
    public func sendPollMessage(_ message: String, withType type: SocketEnginePacketType, withData datas: [Data], completion: (() -> ())? = nil) {
        DefaultSocketLogger.Logger.log(
            "Sending poll: \(type == .message ? SocketLogRedaction.socketPacket(message) : message) as type: \(type.rawValue)",
            type: "SocketEnginePolling"
        )

        postWait.append((String(type.rawValue) + message, completion))

        for data in datas {
            if case let .right(bin) = createBinaryDataForSend(using: data) {
                postWait.append((bin, {}))
            }
        }

        if !waitingForPost {
            flushWaitingForPost()
        }
    }

    /// Call to stop polling and invalidate the URLSession.
    public func stopPolling() {
        waitingForPoll = false
        waitingForPost = false
        session?.finishTasksAndInvalidate()
    }
}
