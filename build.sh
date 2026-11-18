#!/usr/bin/env bash
# 只编译 AutoScroll.dylib（注入与打包在本地做，CI 不需要 100MB 的原包）
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang \
  -target arm64-apple-ios13.0 \
  -isysroot "$SDK" \
  -fobjc-arc -O2 -Wall \
  -dynamiclib \
  -framework UIKit -framework QuartzCore -framework Foundation \
  -install_name @executable_path/Frameworks/AutoScroll.dylib \
  -o build/AutoScroll.dylib \
  src/AutoScroll.m

file build/AutoScroll.dylib
lipo -info build/AutoScroll.dylib
ls -l build/AutoScroll.dylib
