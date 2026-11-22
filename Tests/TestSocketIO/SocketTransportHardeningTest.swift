import XCTest
@testable import SocketIO

final class SocketTransportHardeningTest: XCTestCase {
    // MARK: Log redaction

    func testOnlyConnectPayloadsAreRedacted() {
        let hidden = SocketLogRedaction.placeholder

        XCTAssertEqual(SocketLogRedaction.socketPacket("0{\"token\":\"s\"}"), "0" + hidden)
        XCTAssertEqual(SocketLogRedaction.socketPacket("0/,{\"token\":\"s\"}"), "0/," + hidden)
        XCTAssertEqual(SocketLogRedaction.socketPacket("0/admin,{\"token\":\"s\"}"), "0/admin," + hidden)
        XCTAssertEqual(SocketLogRedaction.enginePacket("40/admin,{\"token\":\"s\"}"), "40/admin," + hidden)

        for untouched in ["0", "0/admin", "0/admin,", "2[\"e\",{\"token\":\"s\"}]", "1/admin,", ""] {
            XCTAssertEqual(SocketLogRedaction.socketPacket(untouched), untouched)
        }

        // An Engine.IO open packet also starts with 0, but is not a Socket.IO CONNECT.
        for untouched in ["0{\"sid\":\"x\"}", "2probe", "42[\"e\",1]", "b4AAEC", ""] {
            XCTAssertEqual(SocketLogRedaction.enginePacket(untouched), untouched)
        }
    }

    func testURLKeepsOnlyEngineQueryValues() {
        XCTAssertEqual(
            SocketLogRedaction.url(URL(string: "https://user:pw@example.com:8443/socket.io/?transport=polling&b64=1&token=s&EIO=4&sid=abc&bare")),
            "https://example.com:8443/socket.io/?transport=polling&b64=1&token=REDACTED&EIO=4&sid=abc&REDACTED"
        )
        XCTAssertEqual(SocketLogRedaction.url(URL(string: "http://localhost/")), "http://localhost/")
    }

    // MARK: Cookies

    private func cookie(domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "session", .value: "v", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires = expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    /// The Cookie header of the polling request and of the WebSocket handshake, which must agree.
    private func cookieHeader(for cookie: HTTPCookie, serverURL: String) -> String? {
        // The manager adds the path and, for https, `.secure(true)` to the configuration it gives its engine.
        let manager = SocketManager(socketURL: URL(string: serverURL)!, config: [.log(false), .cookies([cookie])])
        let engine = SocketEngine(client: manager, url: manager.socketURL, config: manager.config)
        var polling = URLRequest(url: engine.urlPolling)
        var webSocket = URLRequest(url: engine.urlWebSocket)

        engine.addHeaders(to: &polling)
        engine.addHeaders(to: &webSocket)
        XCTAssertEqual(polling.value(forHTTPHeaderField: "Cookie"), webSocket.value(forHTTPHeaderField: "Cookie"),
                       "\(serverURL)")

        return polling.value(forHTTPHeaderField: "Cookie")
    }

    func testConfiguredCookieIsSentOnlyWhereItsScopeAllows() {
        let sent = "session=v"
        let rows: [(HTTPCookie, String, String?, UInt)] = [
            (cookie(domain: "example.com"), "https://example.com", sent, #line),
            (cookie(domain: "Example.COM"), "https://example.com", sent, #line),
            (cookie(domain: "example.com"), "https://api.example.com", sent, #line),
            (cookie(domain: "api.example.com"), "https://example.com", nil, #line),
            (cookie(domain: ".example.com"), "https://api.example.com", sent, #line),
            (cookie(domain: ".example.com"), "https://example.com", sent, #line),
            (cookie(domain: ".example.com"), "https://badexample.com", nil, #line),
            (cookie(domain: "example.com"), "https://example.org", nil, #line),
            (cookie(domain: "example.com", path: "/socket.io"), "https://example.com", sent, #line),
            (cookie(domain: "example.com", path: "/socket.io/"), "https://example.com", sent, #line),
            (cookie(domain: "example.com", path: "/socket"), "https://example.com", nil, #line),
            (cookie(domain: "example.com", path: "/other"), "https://example.com", nil, #line),
            (cookie(domain: "example.com", secure: true), "https://example.com", sent, #line),
            (cookie(domain: "example.com", secure: true), "http://example.com", nil, #line),
            (cookie(domain: "localhost", secure: true), "http://localhost:3000", sent, #line),
            (cookie(domain: "127.0.0.1", secure: true), "http://127.0.0.1:3000", sent, #line),
            (cookie(domain: "example.com", expires: Date(timeIntervalSinceNow: 3600)), "https://example.com", sent, #line),
            (cookie(domain: "example.com", expires: Date(timeIntervalSinceNow: -3600)), "https://example.com", nil, #line),
        ]

        for (cookie, serverURL, expected, line) in rows {
            XCTAssertEqual(cookieHeader(for: cookie, serverURL: serverURL), expected, line: line)
        }
    }
}
