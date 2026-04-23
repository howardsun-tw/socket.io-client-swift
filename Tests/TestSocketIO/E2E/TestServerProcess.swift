import Foundation
import XCTest

/// Spawns the Node test server under `Tests/TestSocketIO/E2E/Fixtures/` and
/// exposes its ephemeral port + admin secret. Kills the process on `stop()`.
final class TestServerProcess {
    enum Error: Swift.Error { case nodeMissing, serverDidNotStart(String) }

    let port: Int
    let secret: String
    private let process: Process

    private init(port: Int, secret: String, process: Process) {
        self.port = port
        self.secret = secret
        self.process = process
    }

    static func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func ensureNodeModules() throws {
        let fixtures = fixturesDir()
        let nm = fixtures.appendingPathComponent("node_modules")
        if FileManager.default.fileExists(atPath: nm.path) { return }
        let p = Process()
        p.currentDirectoryURL = fixtures
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["npm", "install", "--no-audit", "--no-fund"]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Error.nodeMissing }
    }

    static func start(serverScript: String = "server.js", recoveryWindowMs: Int? = nil) throws -> TestServerProcess {
        try ensureNodeModules()

        let p = Process()
        p.currentDirectoryURL = fixturesDir()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", serverScript]
        var env = ProcessInfo.processInfo.environment
        if let w = recoveryWindowMs { env["RECOVERY_WINDOW_MS"] = String(w) }
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        try p.run()

        let deadline = Date().addingTimeInterval(15)
        var collected = ""
        let handle = out.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                collected += s
                if let match = collected.range(of: #"READY port=(\d+) secret=([0-9a-f]+)"#, options: .regularExpression) {
                    let scanner = Scanner(string: String(collected[match]))
                    _ = scanner.scanUpToString("=")
                    _ = scanner.scanString("=")
                    let port = scanner.scanInt() ?? 0
                    _ = scanner.scanUpToString("=")
                    _ = scanner.scanString("=")
                    let secret = scanner.scanCharacters(from: .alphanumerics) ?? ""
                    if port > 0 && !secret.isEmpty {
                        return TestServerProcess(port: port, secret: secret, process: p)
                    }
                }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        p.terminate()
        throw Error.serverDidNotStart(collected)
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// Send an authenticated admin request. Returns (status, body).
    func admin(_ path: String, method: String = "POST", body: Data? = nil) throws -> (Int, Data) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(secret, forHTTPHeaderField: "X-Admin-Secret")
        req.httpBody = body
        req.timeoutInterval = 5

        let sem = DispatchSemaphore(value: 0)
        var status = -1
        var data = Data()
        let task = URLSession.shared.dataTask(with: req) { d, resp, _ in
            if let http = resp as? HTTPURLResponse { status = http.statusCode }
            if let d = d { data = d }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 5)
        return (status, data)
    }
}
