#!/bin/bash
# Generate FullyTracked.xcodeproj from project.yml.
# Checked against the Codemagic Xcode 26.6 image on 2026-11-09:
# Homebrew 6.0.2 is preinstalled; XcodeGen is not listed.
# https://docs.codemagic.io/specs-macos/xcode-26-6/
set -euo pipefail

if [[ ! -f project.yml ]]; then
  echo "project.yml is missing, so XcodeGen cannot generate FullyTracked.xcodeproj."
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is not installed on this image. Installing with Homebrew."
  export HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_NO_INSTALL_CLEANUP=1
  brew install xcodegen
fi

echo "Using $(xcodegen --version)"
xcodegen generate
