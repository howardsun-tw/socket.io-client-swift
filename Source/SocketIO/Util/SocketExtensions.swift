//
//  SocketExtensions.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 7/1/2016.
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
import Starscream

enum JSONError : Error {
    case notNSDictionary
}

extension Array {
    func toJSON() throws -> Data {
        return try JSONSerialization.data(withJSONObject: self, options: JSONSerialization.WritingOptions(rawValue: 0))
    }
}

extension CharacterSet {
    static var allowedURLCharacterSet: CharacterSet {
        return CharacterSet(charactersIn: "!*'();:@&=+$,/?%#[]\" {}^|").inverted
    }
}

extension Dictionary where Key == String, Value == Any {
    private static func keyValueToSocketIOClientOption(key: String, value: Any) -> SocketIOClientOption? {
        switch (key, value) {
        case let ("autoConnect", autoConnect as Bool):
            return .autoConnect(autoConnect)
        case let ("binaryReconstructionTimeout", seconds as Double):
            return .binaryReconstructionTimeout(seconds)
        case let ("connectParams", params as [String: Any]):
            return .connectParams(params)
        case let ("cookies", cookies as [HTTPCookie]):
            return .cookies(cookies)
        case let ("extraHeaders", headers as [String: String]):
            return .extraHeaders(headers)
        case let ("forceNew", force as Bool):
            return .forceNew(force)
        case let ("forcePolling", force as Bool):
            return .forcePolling(force)
        case let ("forceWebsockets", force as Bool):
            return .forceWebsockets(force)
        case let ("handleQueue", queue as DispatchQueue):
            return .handleQueue(queue)
        case let ("log", log as Bool):
            return .log(log)
        case let ("logger", logger as SocketLogger):
            return .logger(logger)
        case let ("maximumPollingResponseBytes", bytes as Int):
            return .maximumPollingResponseBytes(bytes)
        case let ("path", path as String):
            return .path(path)
        case let ("reconnects", reconnects as Bool):
            return .reconnects(reconnects)
        case let ("reconnectAttempts", attempts as Int):
            return .reconnectAttempts(attempts)
        case let ("reconnectWait", wait as Int):
            return .reconnectWait(wait)
        case let ("reconnectWaitMax", wait as Int):
            return .reconnectWaitMax(wait)
        case let ("randomizationFactor", factor as Double):
            return .randomizationFactor(factor)
        case let ("secure", secure as Bool):
            return .secure(secure)
        case let ("security", security as CertificatePinning):
            return .security(security)
        case let ("selfSigned", selfSigned as Bool):
            return .selfSigned(selfSigned)
        case let ("sessionDelegate", delegate as URLSessionDelegate):
            return .sessionDelegate(delegate)
        case let ("compress", compress as Bool):
            return compress ? .compress : nil
        case let ("enableSOCKSProxy", enable as Bool):
            return .enableSOCKSProxy(enable)
        case let ("version", version as Int):
            return .version(SocketIOVersion(rawValue: version) ?? .three)
        case _:
            return nil
        }
    }

    func toSocketConfiguration() -> SocketIOClientConfiguration {
        var options = [] as SocketIOClientConfiguration

        for (rawKey, value) in self {
            if let opt = Dictionary.keyValueToSocketIOClientOption(key: rawKey, value: value) {
                options.insert(opt)
            }
        }

        return options
    }
}

extension HTTPCookie {
    /// Whether a request to `url` carries this cookie (RFC 6265 section 5.4). The domain covers its subdomains with
    /// or without a leading dot, as section 5.2.3 reads a `Domain` attribute.
    func isSent(to url: URL, at date: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased() else { return false }

        let domain = self.domain.lowercased().drop(while: { $0 == "." })
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path

        guard host == domain || host.hasSuffix("." + domain) else {
            return false
        }

        guard requestPath == path || requestPath.hasPrefix(path.hasSuffix("/") ? path : path + "/") else {
            return false
        }

        // Browsers treat a loopback host as secure without TLS.
        guard !isSecure || ["https", "wss"].contains(url.scheme?.lowercased() ?? "")
                || ["localhost", "127.0.0.1", "::1"].contains(host) else {
            return false
        }

        return expiresDate.map({ $0 > date }) ?? true
    }
}

extension String {
    func toDictionary() throws -> [String: Any] {
        guard let binData = data(using: .utf16, allowLossyConversion: false) else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: binData, options: .allowFragments) as? [String: Any] else {
            throw JSONError.notNSDictionary
        }

        return json
    }

    func urlEncode() -> String? {
        return addingPercentEncoding(withAllowedCharacters: .allowedURLCharacterSet)
    }
}
