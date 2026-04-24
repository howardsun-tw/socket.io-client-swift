[![Build Status](https://travis-ci.org/socketio/socket.io-client-swift.svg?branch=master)](https://travis-ci.org/socketio/socket.io-client-swift)

# Socket.IO-Client-Swift
Socket.IO-client for iOS/OS X.

## Example
```swift
import SocketIO

let manager = SocketManager(socketURL: URL(string: "http://localhost:8080")!, config: [.log(true), .compress])
let socket = manager.defaultSocket

socket.on(clientEvent: .connect) {data, ack in
    print("socket connected")
}

socket.on("currentAmount") {data, ack in
    guard let cur = data[0] as? Double else { return }
    
    socket.emitWithAck("canUpdate", cur).timingOut(after: 0) {data in
        if data.first as? String ?? "passed" == SocketAckStatus.noAck {
            // Handle ack timeout 
        }

        socket.emit("update", ["amount": cur + 2.50])
    }

    ack.with("Got your currentAmount", "dude")
}

socket.connect()
```

## Features
- Supports Socket.IO server 2.0+/3.0+/4.0+ (see the [compatibility table](https://nuclearace.github.io/Socket.IO-Client-Swift/Compatibility.html))
- Supports Binary
- Supports Polling and WebSockets
- Supports TLS/SSL

### Auto-connect on `init`

```swift
let manager = SocketManager(socketURL: url, config: [.autoConnect(true)])
manager.defaultSocket.on(clientEvent: .connect) { _, _ in
    print("default socket connected")
}
```

Pass `.autoConnect(true)` to make `SocketManager.init` call `defaultSocket.connect()` and open the engine before returning. Defaults to `false` (Swift back-compat — JS reference defaults to `true`). Only the default namespace is auto-joined; namespaces created later via `manager.socket(forNamespace:)` still require explicit `socket.connect()`. Engine I/O begins synchronously inside `init`, matching JS.

### Connection State Recovery
When using a `.version(.three)` manager (the client/protocol mode for Socket.IO 3.x/4.x servers) against a Socket.IO 4.x server with `connectionStateRecovery` enabled, an abrupt transport drop followed by a reconnect can resume the prior session. If the server reports the session as recovered, missed server-to-client events replay on existing handlers and your event listeners fire as if the transport had never dropped.

Recovery is only attempted by v3 managers. v2 managers ignore the feature entirely.

#### Detecting recovery
The `connect` client event payload includes `recovered: Bool`. The same flag is also exposed as `socket.recovered` after the CONNECT ack.

```swift
socket.on(clientEvent: .connect) { data, _ in
    guard let payload = data.dropFirst().first as? [String: Any] else { return }

    if payload["recovered"] as? Bool == true {
        // Previous session resumed; missed events have replayed on existing handlers
    } else {
        // Fresh session; re-issue any subscription state the server needs
    }
}
```

#### How it works
- On every successful CONNECT ack the client stores the server-assigned private session id (`pid`) and, for each subsequent event, captures the server's trailing `String` offset argument (bounded to 256 UTF-8 bytes via `SocketIOClient.socketStateRecoveryMaxOffsetBytes`; oversized offsets are dropped with a log line).
- When the client reconnects it merges `{pid, offset}` into the CONNECT payload. Keys in your own `connectPayload` win on collision with the reserved `pid` / `offset` keys (a log line is emitted if this happens), matching `socket.io-client` JS.
- Event packets that arrive on the wire *before* the reconnect CONNECT ack are buffered and flushed in order once the ack arrives, so no replayed event is lost to the connect race.

#### Identity changes
In-memory recovery state is tied to the socket, not to the authenticated user. When the logged-in identity changes, call `clearRecoveryState()` before reconnecting so the next CONNECT does not resume the previous user's stream:

```swift
socket.clearRecoveryState()
socket.disconnect()
socket.connect(withPayload: ["token": newToken])
```

`clearRecoveryState()` resets `_pid`, `_lastOffset`, `recovered`, and any buffered replay packets. It is an *in-memory* clear only — it does not fence packets already dispatched to handlers, nor packets the server will deliver on the still-live transport before the next CONNECT ack. For a hard identity boundary, also `disconnect()` and reconnect (or create a fresh socket).

As a Swift-only side effect (no JS counterpart), `clearRecoveryState()` fails any outstanding `socket.timeout(after:).emit(...)` callbacks with `SocketAckError.disconnected`, since a successor session would never deliver an ack for an id issued by the prior session.

If you override `disconnect()` in a subclass and want auto-clear, call `clearRecoveryState()` **before** `super.disconnect()` — the `.disconnect` client event fires synchronously from super, and any observer that reconnects from that callback would otherwise send stale `pid`/`offset`.

## FAQS
Checkout the [FAQs](https://nuclearace.github.io/Socket.IO-Client-Swift/faq.html) for commonly asked questions.


Checkout the [12to13](https://nuclearace.github.io/Socket.IO-Client-Swift/12to13.html) guide for migrating to v13+ from v12 below.

Checkout the [15to16](https://nuclearace.github.io/Socket.IO-Client-Swift/15to16.html) guide for migrating to v16+ from v15.

## Installation
Requires Swift 4/5 and Xcode 10.x

### Swift Package Manager
Add the project as a dependency to your Package.swift:
```swift
// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "socket.io-test",
    products: [
        .executable(name: "socket.io-test", targets: ["YourTargetName"])
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", .upToNextMinor(from: "16.1.1"))
    ],
    targets: [
        .target(name: "YourTargetName", dependencies: ["SocketIO"], path: "./Path/To/Your/Sources")
    ]
)
```

Then import `import SocketIO`.

### Carthage
Add this line to your `Cartfile`:
```
github "socketio/socket.io-client-swift" ~> 16.1.1
```

Run `carthage update --platform ios,macosx`.

Add the `Starscream` and `SocketIO` frameworks to your projects and follow the usual Carthage process.

### CocoaPods 1.0.0 or later
Create `Podfile` and add `pod 'Socket.IO-Client-Swift'`:

```ruby
use_frameworks!

target 'YourApp' do
    pod 'Socket.IO-Client-Swift', '~> 16.1.1'
end
```

Install pods:

```
$ pod install
```

Import the module:

Swift:
```swift
import SocketIO
```

Objective-C:

```Objective-C
@import SocketIO;
```


# [Docs](https://nuclearace.github.io/Socket.IO-Client-Swift/index.html)

- [Client](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketIOClient.html)
- [Manager](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketManager.html)
- [Engine](https://nuclearace.github.io/Socket.IO-Client-Swift/Classes/SocketEngine.html)
- [Options](https://nuclearace.github.io/Socket.IO-Client-Swift/Enums/SocketIOClientOption.html)

## Detailed Example
A more detailed example can be found [here](https://github.com/nuclearace/socket.io-client-swift-example)

An example using the Swift Package Manager can be found [here](https://github.com/nuclearace/socket.io-client-swift-spm-example)

## License
MIT
