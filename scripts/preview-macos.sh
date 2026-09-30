#!/usr/bin/env bash
# Runs the diffkit-preview harness on macOS with the current system look (Liquid Glass).
# Arguments pass straight through, as with `swift run diffkit-preview`:
#
#   scripts/preview-macos.sh
#   git diff | scripts/preview-macos.sh -
#   scripts/preview-macos.sh --snapshot out --dark
#
# Both `swift build` and xcodebuild stamp the binary with the deployment target (macOS 14) as
# its SDK version, and AppKit runs anything linked against a pre-26 SDK in compatibility mode:
# old controls, no glass. So this states the installed SDK version to the linker explicitly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-version)"

cd "$ROOT"
swift build --product diffkit-preview --scratch-path .build/macos-preview \
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK"
exec .build/macos-preview/debug/diffkit-preview "$@"
