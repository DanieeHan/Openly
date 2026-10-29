#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" Sources/Model.swift Tests/ModelTests.swift -o .build/ModelTests
.build/ModelTests
