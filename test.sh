#!/bin/zsh
# Runs the unit tests for the agent-detection logic (pure code: no system state, no app).
set -euo pipefail
cd "${0:A:h}"

mkdir -p build/tests
swiftc -parse-as-library \
  Sources/AgentCatalog.swift Sources/AgentTracker.swift Tests/*.swift \
  -o build/tests/AgentDetectionTests
build/tests/AgentDetectionTests
