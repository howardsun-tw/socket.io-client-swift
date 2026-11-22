#!/usr/bin/env bash
# Builds and runs a throwaway package that depends on this checkout the way an
# app would, so a manifest that only works from inside the repository fails here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONSUMER="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/socketio-consumer.XXXXXX")"
trap 'rm -rf "$CONSUMER"' EXIT

# A path dependency is identified by its directory name.
PACKAGE="$(basename "$ROOT")"
TOOLS_VERSION="$(head -n 1 "$ROOT/Package.swift")"

mkdir -p "$CONSUMER/Sources/Consumer"
cat > "$CONSUMER/Package.swift" <<EOF
$TOOLS_VERSION
import PackageDescription

let package = Package(
    name: "Consumer",
    dependencies: [.package(path: "$ROOT")],
    targets: [
        .executableTarget(name: "Consumer", dependencies: [.product(name: "SocketIO", package: "$PACKAGE")])
    ]
)
EOF
cat > "$CONSUMER/Sources/Consumer/main.swift" <<'EOF'
import Foundation
import SocketIO

let manager = SocketManager(socketURL: URL(string: "http://localhost:1")!, config: [.log(false)])
let socket = manager.defaultSocket

precondition(socket.status == .notConnected)
precondition(socket.nsp == "/")
print("SocketIO SPM consumer passed")
EOF

swift run --package-path "$CONSUMER" Consumer
