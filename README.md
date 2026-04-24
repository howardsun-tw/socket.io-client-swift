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
When using a `.version(.three)` manager, which is the client/protocol mode used for Socket.IO 3.x/4.x servers, against a Socket.IO 4.x server with `connectionStateRecovery` enabled, an abrupt transport drop followed by a reconnect can resume the prior session. If the server reports `payload["recovered"] == true`, missed server-to-client events may replay on existing handlers.

```swift
socket.on(clientEvent: .connect) { data, _ in
    guard let payload = data.dropFirst().first as? [String: Any] else { return }

    if payload["recovered"] as? Bool == true {
        // Previous session resumed; missed events may replay
    }
}
```

Call `socket.clearRecoveryState()` before reconnecting on an identity change to prevent resuming the previous user's session.

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
