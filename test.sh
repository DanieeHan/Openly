#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" Sources/Model.swift Tests/ModelTests.swift -o .build/ModelTests
.build/ModelTests
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -DOPENLY_TESTING Sources/Model.swift Sources/Openly.swift Tests/LifecycleTests.swift -o .build/LifecycleTests
.build/LifecycleTests
