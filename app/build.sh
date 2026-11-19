#!/bin/sh
# Build K8 Tune for x86_64 (the K8 is an x86_64 hackintosh; this repo is built on any Mac).
# Requires Command Line Tools (swiftc). No Xcode project needed.
set -e
cd "$(dirname "$0")"

rm -rf build K8Tune.app
mkdir -p build K8Tune.app/Contents/MacOS K8Tune.app/Contents/Resources

swiftc -target x86_64-apple-macos13.0 -O Sources/main.swift \
       -o build/K8Tune -framework AppKit

cp build/K8Tune K8Tune.app/Contents/MacOS/K8Tune
cp Info.plist K8Tune.app/Contents/Info.plist
chmod +x K8Tune.app/Contents/MacOS/K8Tune

codesign --force --deep --sign - K8Tune.app
echo "built: $(pwd)/K8Tune.app"
file K8Tune.app/Contents/MacOS/K8Tune
