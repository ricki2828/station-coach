#!/usr/bin/env bash
# Lists the Xcodes on the runner and selects the newest stable Xcode 26.x. App Store Connect wants uploads
# built with the 26 SDKs, so CI and the TestFlight lane use the same toolchain. Fails if there is none.
set -eu
echo "Installed Xcodes:"
ls /Applications | grep -i '^xcode' || true
best=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | grep -vi beta | grep -vi 'release_candidate\|_rc' | sort -V | tail -n 1 || true)
if [ -z "$best" ]; then
  echo "::error::No stable Xcode 26.x on this runner; use a newer runner image."
  exit 1
fi
echo "Selecting $best"
sudo xcode-select -s "$best/Contents/Developer"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcrun --sdk watchos --show-sdk-version
