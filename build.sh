#!/bin/bash
# Builds RefTags.app.
#   ./build.sh          → builds, installs to /Applications and opens it
#   CI=1 ./build.sh     → just builds a universal (Apple Silicon + Intel) app into build/
# Needs Apple's command line tools (run `xcode-select --install` once if swiftc is missing).
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Run:  xcode-select --install   then run this script again."
  exit 1
fi

APP="build/RefTags.app"
BIN="$APP/Contents/MacOS/RefTags"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

compile() { # $1 = arch, $2 = output
  swiftc -O -swift-version 5 \
    -target "$1-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement \
    Sources/*.swift -o "$2"
}

if [ -n "$CI" ]; then
  echo "Building universal RefTags…"
  compile arm64 build/RefTags-arm64
  compile x86_64 build/RefTags-x86_64
  lipo -create build/RefTags-arm64 build/RefTags-x86_64 -output "$BIN"
  rm build/RefTags-arm64 build/RefTags-x86_64
else
  ARCH="$(uname -m)"
  echo "Building RefTags for $ARCH…"
  compile "$ARCH" "$BIN"
fi

codesign --force --deep --sign - --identifier com.harsh.reftags "$APP"

if [ -n "$CI" ]; then
  echo "✅ Built $APP"
  exit 0
fi

# Quit an old copy if it's running, then install.
pkill -x RefTags 2>/dev/null || true
sleep 0.5
rm -rf /Applications/RefTags.app
cp -R "$APP" /Applications/
echo ""
echo "✅ Installed to /Applications/RefTags.app"
echo "Opening it… (allow Accessibility when macOS asks)"
open /Applications/RefTags.app
